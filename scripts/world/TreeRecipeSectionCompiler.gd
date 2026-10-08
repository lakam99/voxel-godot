extends RefCounted
class_name TreeRecipeSectionCompiler

## Resumable recipe-to-section value compiler. Recipe/LOD and gameplay remain
## owned by TreeSpawnService and the tree body; this type only builds renderer
## resources and assigns their exact instances to static render sections.

const SpawnService := preload("res://scripts/environment/TreeSpawnService.gd")
const FactoryScript := preload("res://scripts/visual/ProceduralTreeVisualFactory.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Adapter := preload("res://scripts/world/TreeSectionValueAdapter.gd")
const RemovedProps := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const ProducerDomain := preload("res://scripts/world/EcologyProducerDomain.gd")
const CompiledTreeSectionArtifact := preload("res://scripts/world/CompiledTreeSectionArtifact.gd")

const SCHEMA := "tree-recipe-section-compiler/v1"
const BAND_ARTIFACT_SCHEMA := CompiledTreeSectionArtifact.SCHEMA
const SOURCE_RECORD_ARTIFACT_SCHEMA := CompiledTreeSectionArtifact.SOURCE_RECORD_GEOMETRY_SCHEMA
const SUPPORT_ENVELOPE_SCHEMA := "tree-certified-support-envelope/v2"
const SUPPORT_ENVELOPE_POLICY_REVISION := "tree-factory-support-envelope/v2"
const IMMUTABLE_SOURCE_RECORD_SCHEMA := "ecology.static_source_value.v1"
const MAX_WORK_UNITS_PER_ADVANCE := 64
const ROLES := ["bole", "branches", "foliage"]

var _job: Dictionary = {}
var _native_tree_geometry_dispatcher: Object


func set_native_tree_geometry_dispatcher(dispatcher: Object) -> void:
	_native_tree_geometry_dispatcher = dispatcher if is_instance_valid(dispatcher) \
		and dispatcher.has_method("submit_foliage_compile") else null


## Certify the conservative world-space influence of the finalized render
## recipe. This runs after recipe/LOD selection and before section compilation;
## its bound is derived from the same factory meshes and instance transforms.
static func certify_recipe_support_envelope(recipe: Dictionary,
		body_global_transform: Transform3D) -> Dictionary:
	if recipe.is_empty() or not body_global_transform.is_finite():
		return {"status":"pending", "reason":"tree_support_envelope_input_invalid"}
	if bool(recipe.get("runtimeImpostor", false)) != (String(recipe.get("renderLod", {}).get("tier", "")) == "impostor"):
		return {"status":"pending", "reason":"tree_impostor_recipe_tier_mismatch"}
	var factory: Object = FactoryScript.new()
	factory.ensure_shared_geometry()
	var architecture := String(recipe.get("architecture", "broadleaf"))
	var bounds := AABB()
	var has_bounds := false
	var render_kind := "recipe"
	if bool(recipe.get("runtimeImpostor", false)) \
			or String((recipe.get("renderLod", {}) as Dictionary).get("tier", "")) == "impostor":
		render_kind = "impostor"
		var descriptor := FactoryScript.runtime_impostor_descriptor(recipe)
		if descriptor.get("status") != "ready": return descriptor
		for index in 3:
			var mesh: Mesh = factory.runtime_shared_branch_mesh() if index == 0 else factory.runtime_shared_impostor_crown_mesh()
			var local_bounds: AABB = descriptor.transforms[index] * FactoryScript.runtime_impostor_mesh_support(mesh)
			bounds = bounds.merge(local_bounds) if has_bounds else local_bounds
			has_bounds = true
	else:
		var branches: Variant = recipe.get("branches", [])
		var foliage: Variant = recipe.get("foliage", [])
		if not branches is Array:
			return {"status":"pending", "reason":"tree_support_envelope_branches_missing"}
		if not foliage is Array:
			return {"status":"pending", "reason":"tree_support_envelope_foliage_missing"}
		var branch_mesh: Mesh = factory.runtime_shared_branch_mesh()
		for branch_value: Variant in branches:
			if not branch_value is Dictionary:
				return {"status":"pending", "reason":"tree_support_envelope_branch_invalid"}
			var branch: Dictionary = branch_value
			var start_value: Variant = branch.get("start", null)
			var end_value: Variant = branch.get("end", null)
			if not start_value is Vector3 or not end_value is Vector3 \
					or not start_value.is_finite() or not end_value.is_finite():
				return {"status":"pending", "reason":"tree_support_envelope_branch_points_invalid"}
			var radius_start := maxf(0.025, float(branch.get("radiusStart", 0.1)))
			var branch_transform: Transform3D = factory.branch_transform(
				start_value, end_value, radius_start)
			var branch_bounds: AABB = branch_transform * branch_mesh.get_aabb()
			if not has_bounds:
				bounds = branch_bounds
				has_bounds = true
			else:
				bounds = bounds.merge(branch_bounds)
			# The connected bole is generated from branch centerlines and rings;
			# bound every recipe segment with a conservative radial envelope that
			# includes the compiler's 1.10 continuing-fork and 1.05 junction hull.
			var radius_end := maxf(0.012, float(branch.get("radiusEnd", radius_start * 0.5)))
			var bole_radius := maxf(0.065, maxf(radius_start, radius_end) * 1.14)
			var segment_bounds := AABB(start_value, Vector3.ZERO).expand(end_value)
			segment_bounds = segment_bounds.grow(bole_radius)
			bounds = bounds.merge(segment_bounds)
		var foliage_mesh: Mesh = factory.runtime_shared_foliage_cluster_mesh(4)
		for anchor_value: Variant in foliage:
			if not anchor_value is Dictionary:
				return {"status":"pending", "reason":"tree_support_envelope_anchor_invalid"}
			var anchor: Dictionary = anchor_value
			var position_value: Variant = anchor.get("position", null)
			var rotation_value: Variant = anchor.get("rotation", Vector3.ZERO)
			var scale_value: Variant = anchor.get("scale", Vector3.ONE)
			if not position_value is Vector3 or not rotation_value is Vector3 \
					or not scale_value is Vector3 or not position_value.is_finite() \
					or not rotation_value.is_finite() or not scale_value.is_finite():
				return {"status":"pending", "reason":"tree_support_envelope_anchor_transform_invalid"}
			var anchor_transform := Transform3D(
				Basis.from_euler(rotation_value).scaled(scale_value), position_value)
			var anchor_bounds: AABB = anchor_transform * foliage_mesh.get_aabb()
			bounds = bounds.merge(anchor_bounds)
			has_bounds = true
	if not has_bounds or bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		return {"status":"pending", "reason":"tree_support_envelope_geometry_empty"}
	var wind_envelope := ProducerDomain.active_tree_visual_wind_envelope()
	if String(wind_envelope.get("status", "")) != "ready" \
			or String(wind_envelope.get("digest", "")).length() != 64:
		return {"status":"pending", "reason":String(wind_envelope.get("reason",
			"tree_active_visual_wind_envelope_pending"))}
	var wind_role := "foliage" if render_kind == "impostor" \
		or not (recipe.get("foliage", []) as Array).is_empty() else "branches"
	var world_bounds: AABB = body_global_transform * bounds
	world_bounds = _expand_bounds_for_active_wind(world_bounds, wind_role, wind_envelope)
	if not Adapter._valid_bounds(world_bounds):
		return {"status":"pending", "reason":"tree_support_envelope_wind_expansion_invalid"}
	var support_keys := Grid.keys_intersecting_bounds(world_bounds)
	if support_keys.is_empty():
		return {"status":"pending", "reason":"tree_support_envelope_sections_empty"}
	support_keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var digest := _support_envelope_digest(recipe, body_global_transform,
		world_bounds, support_keys, render_kind, wind_envelope)
	if digest.is_empty():
		return {"status":"pending", "reason":"tree_support_envelope_digest_failed"}
	var value := {"schema":SUPPORT_ENVELOPE_SCHEMA,
		"policyRevision":SUPPORT_ENVELOPE_POLICY_REVISION,
		"recipeSignature":String(recipe.get("signature", "")),
		"architecture":architecture, "lodTier":String((recipe.get("renderLod", {}) as Dictionary).get("tier", "near")),
		"renderKind":render_kind, "worldBounds":world_bounds,
		"supportSectionKeys":support_keys,
		"windEnvelopeDigest":String(wind_envelope.get("digest", "")),
		"windExpansionMeters":Vector3(
			float(wind_envelope.get("foliageComponentDisplacementMaxMeters", 0.0)) \
				if wind_role == "foliage" else float(wind_envelope.get(
					"branchComponentDisplacementMaxMeters", 0.0)),
			float(wind_envelope.get("foliageVerticalDisplacementMaxMeters", 0.0)) \
				if wind_role == "foliage" else 0.0,
			float(wind_envelope.get("foliageComponentDisplacementMaxMeters", 0.0)) \
				if wind_role == "foliage" else float(wind_envelope.get(
					"branchComponentDisplacementMaxMeters", 0.0))),
		"certifiedEnvelopeDigest":digest}
	_deep_freeze(value)
	return {"status":"ready", "value":value}


static func _support_envelope_digest(recipe: Dictionary, transform: Transform3D,
		bounds: AABB, keys: Array, render_kind: String,
		wind_envelope: Dictionary) -> String:
	var context := HashingContext.new()
	var tuple := [SUPPORT_ENVELOPE_SCHEMA, SUPPORT_ENVELOPE_POLICY_REVISION,
		String(recipe.get("signature", "")),
		String(recipe.get("architecture", "broadleaf")),
		String((recipe.get("renderLod", {}) as Dictionary).get("tier", "near")),
		render_kind, transform, bounds, keys, wind_envelope]
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(var_to_bytes(tuple)) != OK:
		return ""
	return context.finish().hex_encode()


func begin(main: Object, world_id: String, records: Array,
		removed_snapshot: Dictionary) -> Dictionary:
	if _job.get("status", "") == "pending":
		return _pending("compiler_job_already_active")
	if not is_instance_valid(main) or world_id.is_empty() or records.is_empty():
		return _pending("tree_recipe_input_missing")
	if not bool(removed_snapshot.get("ok", false)):
		return _pending("tree_removed_props_snapshot_missing")
	var copied_records: Array = []
	var ids: Array[String] = []
	for value: Variant in records:
		if not value is Dictionary or not value.is_read_only():
			return _pending("tree_recipe_input_unsealed")
		var record: Dictionary = value
		var validated := _validate_record(main, world_id, record, removed_snapshot)
		if validated.get("status") != "ready":
			return validated
		var id := String(record.get("propId", ""))
		if id in ids:
			return _pending("duplicate_tree_source")
		ids.append(id)
		copied_records.append(record)
	_job = {"status":"pending", "mode":"legacy_section",
		"main":weakref(main), "mainInstanceId":main.get_instance_id(),
		"worldId":world_id, "records":copied_records, "recordIndex":0,
		"roleIndex":0, "factory":FactoryScript.new(), "buildState":{},
		"compileState":{}, "roleValues":{}, "sectionBatches":{}, "bindings":{}, "manifest":[],
		"currentSourceSections":{}, "currentSourceOwnedSections":{},
		"currentSourceGeometryOwnership":[], "currentSourceWorldBounds":{},
		"currentSourceEmptyRoles":[],
		"workUnits":0, "startedUsec":Time.get_ticks_usec(),
		"nativePackAcceptanceUsec":0, "nativePackAcceptedInstances":0,
		"lastAdvanceStartedUsec":0, "removedSnapshot":removed_snapshot,
		"nativeTreeGeometryDispatcher":_native_tree_geometry_dispatcher,
		"sourceIdentities":_source_identities(copied_records)}
	return {"status":"pending", "reason":"tree_section_compile_started", "retryable":true}


## Start a first-time recipe compile from deterministic, sealed producer values.
## These source records contain no gameplay Node; the source-domain validator
## remains authoritative for freshness throughout worker and mesh compilation.
func begin_from_source_records(main: Object, world_id: String, queue: Object,
		source_records: Array, provenance: Dictionary, publication_view: Dictionary = {}) -> Dictionary:
	return _begin_from_source_records(main, world_id, queue, source_records,
		provenance, publication_view, {})


## Start a section-scoped compile only from the exact tree source IDs admitted by
## the support index for this source-chunk/band pair. The full producer family
## remains the freshness authority; this list is only its certified projection.
func begin_from_source_band_records(main: Object, world_id: String, queue: Object,
		source_records: Array, provenance: Dictionary, publication_view: Dictionary,
		section_key: Vector3i, band_authority: Dictionary) -> Dictionary:
	if band_authority.get("sectionKey", null) != section_key:
		return _pending("tree_source_band_section_identity_invalid")
	return _begin_from_source_records(main, world_id, queue, source_records,
		provenance, publication_view, band_authority)


## Compile exactly one source record into a target-independent, all-section
## geometry artifact. The admitted tree-family manifest remains the authority;
## this entry point only narrows work after exact row membership is proven.
func begin_from_source_record(main: Object, world_id: String, queue: Object,
		source_record: Dictionary, provenance: Dictionary,
		publication_view: Dictionary) -> Dictionary:
	var source_id := String(source_record.get("sourceId", ""))
	if source_id.is_empty():
		return _pending("tree_source_record_compile_identity_missing")
	return _begin_from_source_records(main, world_id, queue, [source_record],
		provenance, publication_view, {}, source_id)


func _begin_from_source_records(main: Object, world_id: String, queue: Object,
		source_records: Array, provenance: Dictionary, publication_view: Dictionary,
		band_authority: Dictionary, source_record_id := "") -> Dictionary:
	if not is_instance_valid(queue) or not queue.has_method("_retain_source_publication"):
		return _pending("tree_source_publication_owner_unavailable")
	var retained: Dictionary = queue.call("_retain_source_publication", main, provenance,
		publication_view, "tree_section_compiler")
	if retained.get("status") != "ready": return retained
	var token := String(retained.get("leaseToken", ""))
	var result := _begin_from_owned_source_records(main, world_id, queue, source_records,
		provenance, retained.get("view", {}), token, band_authority, source_record_id)
	if String(_job.get("publicationLeaseToken", "")) != token:
		main.call("release_ecology_source_publication", token)
	return result


func _begin_from_owned_source_records(main: Object, world_id: String, queue: Object,
		source_records: Array, provenance: Dictionary, publication_view: Dictionary,
		publication_token: String, band_authority: Dictionary = {},
		source_record_id := "") -> Dictionary:
	if _job.get("status", "") == "pending":
		return _pending("compiler_job_already_active")
	if not is_instance_valid(main) or world_id.is_empty() \
			or (source_records.is_empty() and band_authority.is_empty()) \
			or not is_instance_valid(queue) \
			or not queue.has_method("request_ecology_source_recipe") \
			or not queue.has_method("poll_ecology_source_recipe"):
		return _pending("tree_source_compile_input_missing")
	var publication_current: Dictionary = main.call("ecology_source_publication_local_is_current",
		publication_view, publication_token)
	if publication_current.get("status") != "ready": return publication_current
	var frozen_provenance: Dictionary = provenance
	var provenance_chunk: Variant = frozen_provenance.get("sourceChunkKey", null)
	if not frozen_provenance.is_read_only() \
			or not is_same(frozen_provenance, publication_view.get("payload", {})) \
			or not provenance_chunk is Vector2i \
			or String(frozen_provenance.get("status", "")) != "ready":
		return _pending("tree_source_domain_provenance_incomplete")
	var artifact_id := String(frozen_provenance.get("catalogArtifactId", ""))
	var catalog_digest := String(frozen_provenance.get("catalogContentDigest", ""))
	var world_epoch := int(frozen_provenance.get("worldEpoch", -1))
	var policy_revision := String(frozen_provenance.get("influencePolicyRevision", ""))
	var policy_digest := String(frozen_provenance.get("influencePolicyDigest", ""))
	if artifact_id.is_empty() or catalog_digest.length() != 64 or world_epoch < 0 \
			or not main.has_method("acquire_ecology_catalog_artifact_lease") \
			or not main.has_method("resolve_ecology_catalog_artifact") \
			or not main.has_method("release_ecology_catalog_artifact_lease"):
		return _pending("tree_catalog_resolver_or_identity_missing")
	var lease_result: Variant = main.call("acquire_ecology_catalog_artifact_lease",
		artifact_id, "tree_compile_job", "tree-compiler:%d:%d" % [get_instance_id(),
		Time.get_ticks_usec()], world_id, world_epoch)
	if not lease_result is Dictionary or String(lease_result.get("status", "")) != "ready" \
			or String(lease_result.get("leaseToken", "")).is_empty():
		return _pending("tree_catalog_lease_acquire_pending")
	var catalog_lease_token := String(lease_result.leaseToken)
	var resolved_catalog: Variant = main.call("resolve_ecology_catalog_artifact",
		catalog_lease_token, world_id, world_epoch)
	var catalog_artifact: Variant = resolved_catalog.get("artifact", resolved_catalog) \
		if resolved_catalog is Dictionary else {}
	var resolved_artifact_id := String(catalog_artifact.get("artifactId",
		catalog_artifact.get("catalogArtifactId", ""))) if catalog_artifact is Dictionary else ""
	if not resolved_catalog is Dictionary or String(resolved_catalog.get("status", "")) != "ready" \
			or not catalog_artifact is Dictionary \
			or resolved_artifact_id != artifact_id \
			or String(catalog_artifact.get("catalogContentDigest", "")) != catalog_digest \
			or int(catalog_artifact.get("worldEpoch", -1)) != world_epoch \
			or String(catalog_artifact.get("worldId", "")) != world_id:
		main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
		return _pending("tree_catalog_lease_resolution_stale")
	var catalog_inputs: Variant = catalog_artifact.get("catalogInputs", null)
	var resolved_policy: Variant = catalog_artifact.get("supportPolicy", null)
	var compact_inputs: Variant = frozen_provenance.get("sourceInputs", null)
	var admitted_policy: Dictionary = publication_view.get("supportPolicy", {})
	var tree_policy: Dictionary = publication_view.get("familySupportPoliciesById", {}).get("trees", {})
	if not catalog_inputs is Dictionary or not resolved_policy is Dictionary \
			or not compact_inputs is Dictionary \
			or String(compact_inputs.get("schema", "")) != "ecology-source-domain-inputs/v2" \
			or String(tree_policy.get("status", "")) != "ready" \
			or String(resolved_policy.get("digest", "")) != policy_digest \
			or String(resolved_policy.get("revision", "")) != policy_revision \
			or String(admitted_policy.get("digest", "")) != policy_digest:
		main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
		return _pending("tree_catalog_support_policy_stale")
	var admitted_family: Dictionary = publication_view.get("familyResultsById", {}).get("trees", {})
	if String(admitted_family.get("status", "")) != "ready":
		main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
		return _pending("tree_source_family_coverage_incomplete", {
			"familyDisposition":String(admitted_family.get("disposition", ""))})
	var target_section: Variant = band_authority.get("sectionKey", null)
	var band_source_ids: Variant = band_authority.get("producerSourceIds", null)
	var frozen_band_authority: Dictionary = {}
	if band_authority.is_empty() and source_record_id.is_empty():
		if admitted_family.get("sourceRows", []) != source_records:
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending("tree_source_family_manifest_mismatch")
	elif band_authority.is_empty():
		if source_records.size() != 1 \
				or not source_records[0] is Dictionary \
				or not source_records[0].is_read_only() \
				or String(source_records[0].get("sourceId", "")) != source_record_id:
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending("tree_source_record_projection_identity_mismatch")
		var admitted_source_row: Dictionary = {}
		for family_row_value: Variant in admitted_family.get("sourceRows", []):
			if family_row_value is Dictionary \
					and String(family_row_value.get("sourceId", "")) == source_record_id:
				if not admitted_source_row.is_empty():
					main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
					return _pending("tree_source_record_projection_ambiguous")
				admitted_source_row = family_row_value
		if admitted_source_row.is_empty() or not is_same(admitted_source_row,
				source_records[0]):
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending("tree_source_record_not_exact_admitted_alias")
	else:
		if String(band_authority.get("schema", "")) != "ecology-tree-source-family-band-authority/v1" \
				or not target_section is Vector3i \
				or band_authority.get("sourceChunkKey", null) != provenance_chunk \
				or String(band_authority.get("sourceRevision", "")) != String(
					frozen_provenance.get("sourceRevision", "")) \
				or String(band_authority.get("sourceFamilyRevision", "")) != String(
					admitted_family.get("familyRevision", "")) \
				or String(band_authority.get("sourceFamilyManifestDigest", "")) != String(
					admitted_family.get("sourceManifestDigest", "")) \
				or String(band_authority.get("sourcePublicationId", "")) != String(
					publication_view.get("publicationId", "")) \
				or String(band_authority.get("sourcePublicationContentDigest", "")) != String(
					publication_view.get("contentDigest", "")) \
				or String(band_authority.get("authorityDigest", "")).length() != 64 \
				or not band_source_ids is Array:
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending("tree_source_band_authority_mismatch")
		var expected_ids: Array[String] = []
		for source_value: Variant in band_source_ids:
			if not source_value is String or String(source_value).is_empty() \
					or String(source_value) in expected_ids:
				main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
				return _pending("tree_source_band_expected_ids_invalid")
			expected_ids.append(String(source_value))
		expected_ids.sort()
		var declared_ids: Array[String] = []
		for source_value: Variant in band_source_ids:
			declared_ids.append(String(source_value))
		var expected_projection_disposition := "complete_empty" \
			if expected_ids.is_empty() else "complete_nonempty"
		if declared_ids != expected_ids \
				or String(band_authority.get("producerSourceIdsDigest", "")) \
				!= ProducerDomain._digest(declared_ids) \
				or String(band_authority.get("producerDisposition", "")) \
				!= expected_projection_disposition:
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending("tree_source_band_source_id_digest_mismatch")
		var authority_identity: Dictionary = band_authority.duplicate(true)
		authority_identity.erase("authorityDigest")
		authority_identity.erase("publicationLeaseToken")
		if String(band_authority.get("authorityDigest", "")) != _digest_value(authority_identity) \
				or not _source_value_tree_is_node_free(band_authority):
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending("tree_source_band_authority_digest_invalid")
		frozen_band_authority = _deep_frozen(band_authority)
		var supplied_ids: Array[String] = []
		for source_value: Variant in source_records:
			if not source_value is Dictionary or not source_value.has("sourceId") \
					or String(source_value.get("sourceId", "")).is_empty():
				main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
				return _pending("tree_source_band_record_invalid")
			supplied_ids.append(String(source_value.get("sourceId", "")))
		supplied_ids.sort()
		if supplied_ids != expected_ids \
				or (expected_ids.is_empty() \
					and String(band_authority.get("producerDisposition", "")) != "complete_empty"):
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending("tree_source_band_record_set_mismatch")
		var family_ids: Array[String] = []
		for source_value: Variant in admitted_family.get("sourceRows", []):
			if source_value is Dictionary:
				family_ids.append(String(source_value.get("sourceId", "")))
		family_ids.sort()
		for id: String in expected_ids:
			if id not in family_ids:
				main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
				return _pending("tree_source_band_id_outside_family")
			for source_value: Variant in source_records:
				if source_value is Dictionary and String(source_value.get("sourceId", "")) == id \
						and source_value not in admitted_family.get("sourceRows", []):
					main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
					return _pending("tree_source_band_record_not_from_publication")
	var copied_records: Array = []
	var ids: Array[String] = []
	for source_value: Variant in source_records:
		if not source_value is Dictionary or not source_value.is_read_only():
			_cancel_source_recipe_jobs(queue, copied_records)
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending("tree_source_record_unsealed")
		var frozen_source: Dictionary = source_value
		var member_current: Dictionary = main.call("ecology_source_publication_record_is_current",
			publication_view, publication_token, frozen_source)
		if member_current.get("status") != "ready":
			_cancel_source_recipe_jobs(queue, copied_records)
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending("tree_source_record_snapshot_not_frozen")
		var prepared := _prepare_immutable_source_record(main, world_id,
			frozen_source, frozen_provenance, catalog_artifact, publication_view, publication_token)
		if prepared.get("status") != "ready":
			_cancel_source_recipe_jobs(queue, copied_records)
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return prepared
		var record: Dictionary = prepared.record
		var id := String(record.get("propId", ""))
		if id.is_empty() or id in ids:
			_cancel_source_recipe_jobs(queue, copied_records)
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending("tree_source_record_identity_duplicate")
		ids.append(id)
		var owner_token := str(get_instance_id())
		var queued: Dictionary = queue.call("request_ecology_source_recipe", main,
			record.sourceRecord, record.sourceProvenance, record.request, owner_token, publication_view)
		if queued.get("status") == "failed":
			_cancel_source_recipe_jobs(queue, copied_records)
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return queued
		record["recipeJobKey"] = String(queued.get("jobKey", ""))
		if record.recipeJobKey.is_empty():
			_cancel_source_recipe_jobs(queue, copied_records)
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending("tree_source_recipe_job_key_missing")
		if queued.get("status") == "ready" and queued.get("artifact", null) is Dictionary:
			record["recipeArtifact"] = queued.artifact
		copied_records.append(record)
	_job = {"status":"pending", "mode":"immutable_source",
		"publicationView":publication_view, "publicationLeaseToken":publication_token,
		"treeFamilyRevision":String(admitted_family.get("familyRevision", "")),
		"treeFamilyManifestDigest":String(admitted_family.get("sourceManifestDigest", "")),
		"main":weakref(main), "mainInstanceId":main.get_instance_id(),
		"queue":weakref(queue), "worldId":world_id,
		"catalogLeaseToken":catalog_lease_token, "catalogLeaseReleased":false,
		"catalogArtifactId":artifact_id, "catalogContentDigest":catalog_digest,
		"worldEpoch":world_epoch, "influencePolicyRevision":policy_revision,
		"influencePolicyDigest":policy_digest,
		"sourceProvenanceDigest":String(publication_view.get("contentDigest", "")),
		"sourceChunkKey":provenance_chunk,
		"sourceRevision":String(frozen_provenance.get("sourceRevision", "")),
		"sourceRecordArtifact":not source_record_id.is_empty(),
		"sourceRecordId":source_record_id,
		"targetSectionKey":target_section if target_section is Vector3i else null,
		"bandAuthority":frozen_band_authority,
		"expectedSourceIds":band_source_ids.duplicate() if band_source_ids is Array else [],
		"records":copied_records, "recordIndex":0, "roleIndex":0,
		"factory":FactoryScript.new(), "buildState":{}, "compileState":{},
		"roleValues":{}, "sectionBatches":{}, "bindings":{}, "manifest":[],
		"currentSourceSections":{}, "currentSourceOwnedSections":{},
		"currentSourceGeometryOwnership":[], "currentSourceWorldBounds":{},
		"currentSourceEmptyRoles":[],
		"workUnits":0, "startedUsec":Time.get_ticks_usec(),
		"nativePackAcceptanceUsec":0, "nativePackAcceptedInstances":0,
		"lastAdvanceStartedUsec":0, "removedSnapshot":{},
		"nativeTreeGeometryDispatcher":_native_tree_geometry_dispatcher,
		"sourceIdentities":_source_identities(copied_records)}
	return {"status":"pending", "reason":"tree_source_section_compile_started",
		"retryable":true, "sourceCount":copied_records.size()}


func advance(work_units := 1) -> Dictionary:
	if String(_job.get("status", "")) == "failed":
		return {"status":"failed", "reason":String(_job.get("failureReason",
			"tree_section_compile_failed")), "retryable":false}
	if _job.is_empty() or _job.get("status", "") != "pending":
		return _pending("tree_section_compile_not_active")
	if String(_job.get("mode", "")) == "immutable_source":
		var catalog_current := _catalog_lease_current()
		if catalog_current.get("status") != "ready":
			return _discard(String(catalog_current.get("reason",
				"tree_catalog_artifact_became_stale")))
	# Record call entry so a stalled queue can be distinguished from one that is
	# being advanced each frame. The reported age intentionally includes work in
	# the most recent call.
	_job.lastAdvanceStartedUsec = Time.get_ticks_usec()
	var budget := clampi(work_units, 1, MAX_WORK_UNITS_PER_ADVANCE)
	var performed := 0
	while performed < budget and int(_job.recordIndex) < _job.records.size():
		var record: Dictionary = _job.records[_job.recordIndex]
		if String(_job.get("mode", "legacy_owner")) == "immutable_source":
			var freshness := _immutable_source_currentness(record)
			if freshness.get("status") == "pending":
				return freshness
			if freshness.get("status") != "ready":
				return _discard(String(freshness.get("reason", "tree_source_record_stale")))
			var recipe_ready := _ensure_immutable_source_recipe(record)
			if recipe_ready.get("status") == "pending":
				return recipe_ready
			if recipe_ready.get("status") != "ready":
				return _discard(String(recipe_ready.get("reason", "tree_source_recipe_invalid")))
			var native_record_admission := {"status":"ready"} if bool(record.recipeSnapshot.get("runtimeImpostor", false)) else _ensure_native_tree_record_compile(record)
			if native_record_admission.get("status") != "ready":
				return native_record_admission
		elif not _current(record):
			return _discard("tree_recipe_input_became_stale")
		var role_index := int(_job.roleIndex)
		var role := String(ROLES[role_index])
		if not _job.compileState.is_empty():
			var pack_result := _advance_native_tree_section_pack(record, _job.compileState)
			if pack_result.get("status") == "pending":
				return {"status":"pending", "reason":"tree_section_compile_in_progress",
					"stage":String(pack_result.get("reason", "tree_native_section_pack_pending")),
					"retryable":true,
					"workUnits":int(_job.workUnits), "recordIndex":int(_job.recordIndex),
					"roleIndex":int(_job.roleIndex)}
			if pack_result.get("status") != "ready":
				return _discard(String(pack_result.get("reason", "tree_native_section_pack_failed")))
			performed += 1
			_job.workUnits = int(_job.workUnits) + 1
			_job.roleValues[role] = _job.compileState.values
			_job.compileState = {}
			_job.roleIndex = role_index + 1
			if int(_job.roleIndex) >= ROLES.size():
				var source_manifest := _seal_source(record)
				if source_manifest.get("status") != "ready":
					return _discard(String(source_manifest.get("reason", "tree_source_manifest_failed")))
				_job.manifest.append(source_manifest.value)
				_job.recordIndex = int(_job.recordIndex) + 1
				_job.roleIndex = 0
				_job.roleValues = {}
			continue
		if _job.buildState.is_empty():
			var prepared := _begin_role(record, role)
			if prepared.get("status") == "pending":
				return prepared
			if prepared.get("status") != "ready":
				return _discard(String(prepared.get("reason", "tree_role_begin_failed")))
			if bool(prepared.get("emptyRole", false)):
				_job.currentSourceEmptyRoles.append(role)
				_job.roleIndex = role_index + 1
				performed += 1
				_job.workUnits = int(_job.workUnits) + 1
				if int(_job.roleIndex) >= ROLES.size():
					var source_manifest := _seal_source(record)
					if source_manifest.get("status") != "ready":
						return _discard(String(source_manifest.get("reason", "tree_source_manifest_failed")))
					_job.manifest.append(source_manifest.value)
					_job.recordIndex = int(_job.recordIndex) + 1
					_job.roleIndex = 0
					_job.roleValues = {}
				continue
			_job.buildState = prepared.get("state", {})
			performed += 1
			_job.workUnits = int(_job.workUnits) + 1
			continue
		var factory: Object = _job.factory
		var complete := _advance_role(factory, role, _job.buildState)
		performed += 1
		_job.workUnits = int(_job.workUnits) + 1
		if _job.buildState.has("nativeFailure"):
			return _discard(String(_job.buildState.get("nativeFailure",
				"tree_native_foliage_compile_failed")))
		if not complete:
			if role in ["branches", "foliage"] and _job.buildState.has("nativeTicket"):
				break
			continue
		var values := _finish_role(factory, record, role, _job.buildState)
		if role in ["branches", "foliage"] \
				and _job.buildState.get("nativeInstanceValues", null) is PackedFloat32Array:
			var packed_values: Dictionary = values.duplicate()
			packed_values["nativeInstanceValues"] = _job.buildState.nativeInstanceValues
			packed_values.make_read_only()
			values = packed_values
		_job.buildState = {}
		if values.is_empty():
			return _discard("tree_role_values_unavailable")
		var compiled := _prepare_role_compile(record, role, values)
		if compiled.get("status") != "ready":
			return _discard(String(compiled.get("reason", "tree_role_compile_failed")))
		_job.compileState = compiled.state
	if int(_job.recordIndex) < _job.records.size():
		return {"status":"pending", "reason":"tree_section_compile_in_progress",
			"retryable":true, "workUnits":int(_job.workUnits),
			"recordIndex":int(_job.recordIndex), "roleIndex":int(_job.roleIndex)}
	return _seal_candidate()


## Bounded diagnostic projection of state already owned by this compiler. It
## contains no recipe, node, resource, geometry, or mutable job containers.
func progress_snapshot() -> Dictionary:
	if _job.is_empty():
		return {"status":"idle", "reason":"tree_section_compile_not_active"}
	var records: Array = _job.get("records", [])
	var record_index := int(_job.get("recordIndex", 0))
	var role_index := int(_job.get("roleIndex", 0))
	var role := String(ROLES[role_index]) if role_index >= 0 and role_index < ROLES.size() else ""
	var record: Dictionary = records[record_index] if record_index >= 0 \
		and record_index < records.size() and records[record_index] is Dictionary else {}
	var compile_state: Dictionary = _job.get("compileState", {})
	var phase := "instance_encoding" if not compile_state.is_empty() else (
		"recipe_role_build" if not (_job.get("buildState", {}) as Dictionary).is_empty() else "role_start")
	var now_usec := Time.get_ticks_usec()
	return {"status":String(_job.get("status", "pending")),
		"failureReason":String(_job.get("failureReason", "")),
		"worldId":String(_job.get("worldId", "")),
		"activeCandidateId":String(record.get("propId", "")),
		"activeSourceId":String(record.get("sourceId", "")),
		"activeContentRevision":String(record.get("contentRevision", "")),
		"activeBodyInstanceId":int(record.get("bodyInstanceId", 0)),
		"activeArtifactGeneration":int(record.get("artifactGeneration", 0)),
		"startedElapsedUsec":maxi(0, now_usec - int(_job.get("startedUsec", now_usec))),
		"sinceLastAdvanceStartedUsec":maxi(0, now_usec - int(
			_job.get("lastAdvanceStartedUsec", now_usec))),
		"workUnits":int(_job.get("workUnits", 0)),
		"recordIndex":record_index, "recordCount":records.size(),
		"role":role, "roleIndex":role_index, "roleCount":ROLES.size(),
		"phase":phase,
		"instanceIndex":int(compile_state.get("nextIndex", 0)),
		"instanceCount":int(compile_state.get("instanceCount", 0))}


func cancel() -> void:
	_cancel_native_tree_compile()
	_cancel_active_source_recipe_jobs()
	_release_catalog_lease()
	_job.clear()


## Detach completed immutable-source compiler values so their large arrays can
## be released by the queue's value-retirement worker. Resource objects are
## returned separately for Main-thread lifetime management.
func take_completed_source_retirement_values() -> Dictionary:
	if String(_job.get("status", "")) != "complete" \
			or String(_job.get("mode", "")) != "immutable_source" \
			or not bool(_job.get("sourceRecordArtifact", false)):
		return {"status":"failed", "reason":"tree_source_compiler_retirement_not_complete"}
	return take_source_retirement_values()


## Cancel native tickets first, then detach the entire partial/completed source
## job graph. Native submissions own copied inputs; their tickets are canceled
## and released before these GDScript aliases are transferred.
func take_source_retirement_values() -> Dictionary:
	if _job.is_empty():
		return {"status":"ready", "valueRoots":{}, "mainRefCountedKeepalives":[]}
	var immutable_source := String(_job.get("mode", "")) == "immutable_source"
	_cancel_native_tree_compile()
	_cancel_active_source_recipe_jobs()
	var catalog_token := String(_job.get("catalogLeaseToken", ""))
	if not catalog_token.is_empty() and not bool(_job.get("catalogLeaseReleased", true)):
		var main_ref: WeakRef = _job.get("main") as WeakRef
		var main: Object = main_ref.get_ref() if main_ref != null else null
		if is_instance_valid(main) and main.has_method("release_ecology_catalog_artifact_lease"):
			main.call("release_ecology_catalog_artifact_lease", catalog_token)
		_job["catalogLeaseToken"] = ""
		_job["catalogLeaseReleased"] = true
	var resources: Array[RefCounted] = []
	for resource_value: Variant in _job.get("bindings", {}).values():
		_append_source_retirement_keepalive(resources, resource_value)
	var factory: Variant = _job.get("factory", null)
	_append_source_retirement_keepalive(resources, factory)
	_append_source_retirement_keepalive(resources,
		_job.get("nativeTreeGeometryDispatcher", null))
	var value_roots: Dictionary = {}
	var compile_state: Dictionary = _job.get("compileState", {})
	for resource_key: String in ["mesh", "multiMesh", "nativePackDispatcher"]:
		_append_source_retirement_keepalive(resources, compile_state.get(resource_key, null))
	var compile_values: Dictionary = compile_state.get("values", {})
	for resource_key: String in ["mesh", "multiMesh", "material"]:
		_append_source_retirement_keepalive(resources, compile_values.get(resource_key, null))
	if not compile_state.is_empty():
		var compile_value_root := compile_state.duplicate(false)
		for handle_key: String in ["mesh", "multiMesh", "nativePackDispatcher"]:
			compile_value_root.erase(handle_key)
		var compile_role_values: Variant = compile_value_root.get("values", null)
		if compile_role_values is Dictionary:
			var detached_compile_values: Dictionary = compile_role_values.duplicate(false)
			for handle_key: String in ["mesh", "multiMesh", "material"]:
				detached_compile_values.erase(handle_key)
			detached_compile_values.make_read_only()
			compile_value_root["values"] = detached_compile_values
		compile_value_root.make_read_only()
		value_roots["compileState"] = compile_value_root
	var keys: Array[String] = ["sectionBatches", "manifest",
		"currentSourceGeometryOwnership", "currentSourceSections",
		"currentSourceOwnedSections", "currentSourceWorldBounds",
		"currentSourceEmptyRoles"]
	keys.append("records")
	if immutable_source:
		keys.append_array(["snapshot", "publicationView", "sourceIdentities",
			"bandAuthority", "expectedSourceIds", "removedSnapshot"])
	for key: String in keys:
		var value: Variant = _job.get(key, null)
		if value is Dictionary and not value.is_empty(): value_roots[key] = value
		elif value is Array and not value.is_empty(): value_roots[key] = value
	# Gameplay section records carry a WeakRef to their StaticBody3D. Transfer
	# only shallow immutable record copies with that live owner handle removed.
	# Nested recipe/request payloads are already sealed value containers.
	var records_value: Variant = _job.get("records", null)
	if not immutable_source and records_value is Array:
		var detached_records: Array[Dictionary] = []
		for record_value: Variant in records_value:
			if not record_value is Dictionary: continue
			var detached_record: Dictionary = record_value.duplicate(false)
			detached_record.erase("body")
			detached_record.make_read_only()
			detached_records.append(detached_record)
		detached_records.make_read_only()
		if not detached_records.is_empty(): value_roots["records"] = detached_records
	# Partial bole/branch stages can own RefCounted builder resources. Keep
	# those exact handles on Main through the worker completion ACK, and put only
	# their known value fields into the retirement graph for either compiler mode.
	var build_state: Dictionary = _job.get("buildState", {})
	if not build_state.is_empty():
		var build_values := build_state.duplicate(false)
		for handle_key: String in ["surface", "mesh", "multiMesh", "material",
				"nativeDispatcher"]:
			_append_source_retirement_keepalive(resources, build_state.get(handle_key, null))
			build_values.erase(handle_key)
		if not build_values.is_empty():
			build_values.make_read_only()
			value_roots["buildState"] = build_values
	var role_values: Dictionary = _job.get("roleValues", {})
	if not role_values.is_empty():
		var role_value_roots: Dictionary = {}
		for role_key_value: Variant in role_values.keys():
			var role_key := String(role_key_value)
			var role_value: Variant = role_values[role_key_value]
			if not role_value is Dictionary:
				continue
			var role_dictionary: Dictionary = role_value
			var role_value_root: Dictionary = role_dictionary
			var has_handles := false
			for handle_key: String in ["mesh", "multiMesh", "material",
					"nativeDispatcher"]:
				if role_dictionary.has(handle_key):
					has_handles = true
					_append_source_retirement_keepalive(resources,
						role_dictionary.get(handle_key, null))
			if has_handles:
				role_value_root = role_dictionary.duplicate(false)
				for handle_key: String in ["mesh", "multiMesh", "material",
						"nativeDispatcher"]:
					role_value_root.erase(handle_key)
				role_value_root.make_read_only()
			role_value_roots[role_key] = role_value_root
		role_value_roots.make_read_only()
		if not role_value_roots.is_empty(): value_roots["roleValues"] = role_value_roots
	# A partial role compile can hold packed instance values alongside live Mesh
	# and MultiMesh resources. Transfer only the value-only packed buffer here;
	# all Resource aliases are held in the Main keepalive table above.
	value_roots.make_read_only()
	_job.clear()
	return {"status":"ready", "valueRoots":value_roots,
		"mainRefCountedKeepalives":resources}


func _append_source_retirement_keepalive(resources: Array[RefCounted],
		value: Variant) -> void:
	if not value is RefCounted or not is_instance_valid(value): return
	var retained: RefCounted = value as RefCounted
	for prior: RefCounted in resources:
		if is_same(prior, retained): return
	resources.append(retained)


func _begin_role(record: Dictionary, role: String) -> Dictionary:
	var recipe: Dictionary = record.recipeSnapshot
	if bool(recipe.get("runtimeImpostor", false)):
		if role == "branches": return {"status":"ready", "emptyRole":true, "role":role}
		return {"status":"ready", "state":{"impostor":true}}
	var branches: Array[Dictionary] = _typed_dictionary_array(recipe.get("branches", []))
	var foliage: Array = recipe.get("foliage", [])
	if role == "branches" and branches.is_empty():
		return {"status":"ready", "emptyRole":true, "role":role}
	if role == "foliage" and foliage.is_empty():
		return {"status":"ready", "emptyRole":true, "role":role}
	var factory: Object = _job.factory
	var state: Dictionary
	if String(_job.get("mode", "")) == "immutable_source" and role in ["branches", "foliage"]:
		return _begin_native_tree_record_role(factory, record, recipe, role)
	match role:
		"bole": state = factory.begin_runtime_bole_build(branches)
		"branches": state = factory.begin_runtime_distal_build(recipe, branches,
			String(record.request.get("biome", "forest")), String(record.request.get("treeId", "")))
		"foliage": return _begin_native_foliage_role(factory, record, recipe, foliage)
	if state.is_empty():
		return {"status":"pending", "reason":"tree_recipe_role_has_no_render_values"}
	return {"status":"ready", "state":state}


func _advance_role(factory: Object, role: String, state: Dictionary) -> bool:
	if bool(state.get("impostor", false)): return true
	match role:
		"bole": return bool(factory.advance_runtime_bole_build(state, 1))
		"branches": return state.get("nativeInstanceValues", null) is PackedFloat32Array \
			or bool(factory.advance_runtime_distal_build(state, 1))
		"foliage": return state.get("nativeInstanceValues", null) is PackedFloat32Array \
			or _advance_native_foliage_role(state)
	return false


func _ensure_native_tree_record_compile(record: Dictionary) -> Dictionary:
	if record.get("nativeTreeRecordBuffers", null) is Dictionary:
		return {"status":"ready"}
	var ticket := int(record.get("nativeTreeRecordTicket", 0))
	if ticket > 0:
		return {"status":"ready"}
	var dispatcher: Object = _job.get("nativeTreeGeometryDispatcher")
	if not is_instance_valid(dispatcher) or not dispatcher.has_method("submit_tree_record_compile"):
		return _pending("native_tree_record_dispatcher_unavailable", {
			"sourceId":String(record.get("sourceId", ""))})
	var identity := _native_tree_record_identity(record)
	if identity.is_empty():
		return _discard("native_tree_record_identity_incomplete")
	var admission: Dictionary = dispatcher.call("submit_tree_record_compile",
		record.recipeSnapshot, String(record.request.get("biome", "forest")),
		String(record.request.get("treeId", "")), identity)
	if admission.get("status") != "pending":
		return _pending(String(admission.get("reason", "native_tree_record_admission_pending")), {
			"sourceId":String(record.get("sourceId", "")),
			"nativeStatus":String(admission.get("status", "pending"))})
	if admission.get("identity", {}) != identity or int(admission.get("ticket", 0)) <= 0:
		return _discard("native_tree_record_admission_identity_mismatch")
	record["nativeTreeRecordTicket"] = int(admission.ticket)
	record["nativeTreeRecordIdentity"] = identity
	return {"status":"ready"}


func _native_tree_record_identity(record: Dictionary) -> Dictionary:
	var identity := {"worldId":String(_job.get("worldId", "")),
		"worldEpoch":String(record.get("sourceDomainRevision",
			record.get("sourceRevision", record.get("contentRevision", "")))),
		"sourceId":String(record.get("sourceId", "")),
		"sourceRevision":String(record.get("sourceRevision",
			record.get("contentRevision", ""))),
		"recipeSignature":String(record.get("recipeSignature", "")),
		"artifactGeneration":int(record.get("artifactGeneration", 0)),
		"sourceRecordDigest":String(record.get("sourceRecordDigest",
			record.get("contentRevision", ""))),
		"sourceProvenanceDigest":String(record.get("sourceProvenanceDigest",
			record.get("contentRevision", ""))),
		"requestDigest":String(record.get("requestDigest",
			_digest_value(record.get("request", {}))))}
	for key: String in identity:
		if str(identity[key]).is_empty() or (key == "artifactGeneration" \
				and int(identity[key]) <= 0):
			return {}
	return identity


func _begin_native_tree_record_role(factory: Object, record: Dictionary,
		recipe: Dictionary, role: String) -> Dictionary:
	var role_values: Dictionary = record.get("nativeTreeRecordBuffers", {})
	if role_values.is_empty():
		var dispatcher: Object = _job.get("nativeTreeGeometryDispatcher")
		var ticket := int(record.get("nativeTreeRecordTicket", 0))
		if ticket <= 0 or not is_instance_valid(dispatcher):
			return _pending("native_tree_record_ticket_missing", {
				"sourceId":String(record.get("sourceId", ""))})
		var polled: Dictionary = dispatcher.call("poll_tree_geometry_compile", ticket)
		if polled.get("status") in ["queued", "running"]:
			return _pending("native_tree_record_compile_pending", {
				"sourceId":String(record.get("sourceId", "")), "ticket":ticket})
		if polled.get("status") != "ready":
			dispatcher.call("release_tree_geometry_compile", ticket)
			record.erase("nativeTreeRecordTicket")
			return _discard(String(polled.get("reason", "native_tree_record_compile_failed")))
		var completed: Dictionary = dispatcher.call("take_tree_geometry_compile_result", ticket)
		var expected_identity: Dictionary = record.get("nativeTreeRecordIdentity", {})
		var echoed: Variant = completed.get("identity", null)
		var branch_values: Variant = completed.get("branchInstanceValues", null)
		var foliage_values: Variant = completed.get("instanceValues", null)
		var distal_count := 0
		for branch_value: Variant in recipe.get("branches", []):
			if branch_value is Dictionary and int(branch_value.get("order", 1)) != 0:
				distal_count += 1
		var foliage_count := (recipe.get("foliage", []) as Array).size()
		if completed.get("status") != "ready" or not echoed is Dictionary \
				or echoed != expected_identity \
				or not branch_values is PackedFloat32Array \
				or not foliage_values is PackedFloat32Array \
				or branch_values.size() != distal_count * Attributes.FLOATS_PER_INSTANCE \
				or foliage_values.size() != foliage_count * Attributes.FLOATS_PER_INSTANCE \
				or int(completed.get("branchInstanceCount", -1)) != distal_count \
				or int(completed.get("instanceCount", -1)) != foliage_count:
			dispatcher.call("release_tree_geometry_compile", ticket)
			record.erase("nativeTreeRecordTicket")
			return _discard("native_tree_record_output_identity_or_layout_invalid")
		var latest_identity := _native_tree_record_identity(record)
		var latest_source := _immutable_source_currentness(record)
		if latest_source.get("status") != "ready" \
				or not native_tree_record_identity_is_current(expected_identity, latest_identity):
			dispatcher.call("release_tree_geometry_compile", ticket)
			record.erase("nativeTreeRecordTicket")
			return _discard(String(latest_source.get("reason",
				"native_tree_record_source_epoch_replaced")))
		role_values = {"branches":branch_values, "foliage":foliage_values}
		role_values.make_read_only()
		record["nativeTreeRecordBuffers"] = role_values
		dispatcher.call("release_tree_geometry_compile", ticket)
		record.erase("nativeTreeRecordTicket")
	var packed: PackedFloat32Array = role_values.get(role, PackedFloat32Array())
	var count := packed.size() / Attributes.FLOATS_PER_INSTANCE
	if count <= 0:
		return {"status":"ready", "emptyRole":true, "role":role}
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_colors = true
	multi_mesh.use_custom_data = true
	if role == "branches":
		factory.ensure_shared_geometry()
		multi_mesh.mesh = factory.runtime_shared_branch_mesh()
	else:
		multi_mesh.mesh = factory.runtime_shared_foliage_cluster_mesh(4)
	multi_mesh.instance_count = count
	multi_mesh.set_buffer(packed)
	return {"status":"ready", "state":{"role":role, "values":{},
		"mesh":multi_mesh.mesh, "multiMesh":multi_mesh,
		"nativeInstanceValues":packed, "nextIndex":count}}


static func native_tree_record_identity_is_current(expected: Dictionary,
		current: Dictionary) -> bool:
	if expected.is_empty() or current.is_empty(): return false
	for key: String in ["worldId", "worldEpoch", "sourceId", "sourceRevision",
			"recipeSignature", "artifactGeneration", "sourceRecordDigest",
			"sourceProvenanceDigest", "requestDigest"]:
		if not expected.has(key) or expected.get(key) != current.get(key):
			return false
	return true


func _begin_native_foliage_role(factory: Object, record: Dictionary,
		recipe: Dictionary, foliage: Array) -> Dictionary:
	var dispatcher: Object = _job.get("nativeTreeGeometryDispatcher")
	if not is_instance_valid(dispatcher) or not dispatcher.has_method("submit_foliage_compile"):
		return _pending("native_tree_geometry_dispatcher_unavailable", {
			"sourceId":String(record.get("sourceId", ""))})
	var source_identity := {
		"worldId":String(_job.get("worldId", "")),
		"worldEpoch":String(record.get("sourceDomainRevision",
			record.get("sourceRevision", record.get("contentRevision", "")))),
		"sourceId":String(record.get("sourceId", "")),
		"sourceRevision":String(record.get("sourceRevision",
			record.get("contentRevision", ""))),
		"recipeSignature":String(record.get("recipeSignature", "")),
		"artifactGeneration":int(record.get("artifactGeneration", 0)),
		"sourceRecordDigest":String(record.get("sourceRecordDigest",
			record.get("contentRevision", ""))),
		"sourceProvenanceDigest":String(record.get("sourceProvenanceDigest",
			record.get("contentRevision", ""))),
		"requestDigest":String(record.get("requestDigest",
			_digest_value(record.get("request", {}))))}
	for key: String in source_identity:
		if str(source_identity[key]).is_empty() or (key == "artifactGeneration" \
				and int(source_identity[key]) <= 0):
			return _discard("native_tree_geometry_identity_incomplete")
	var admission: Dictionary = dispatcher.call("submit_foliage_compile", recipe,
		String(record.request.get("biome", "forest")), String(record.request.get("treeId", "")), source_identity)
	if admission.get("status") != "pending":
		return _pending(String(admission.get("reason", "native_tree_foliage_admission_pending")), {
			"sourceId":String(record.get("sourceId", "")),
			"nativeStatus":String(admission.get("status", "pending"))})
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_colors = true
	multi_mesh.use_custom_data = true
	multi_mesh.mesh = factory.runtime_shared_foliage_cluster_mesh(4)
	multi_mesh.instance_count = foliage.size()
	return {"status":"ready", "state":{"role":"foliage", "values":{},
		"mesh":multi_mesh.mesh, "multiMesh":multi_mesh,
		"nativeTicket":int(admission.get("ticket", 0)),
		"nativeIdentity":source_identity, "nativeInstanceCount":foliage.size(),
		"nativeDispatcher":dispatcher, "nextIndex":0}}


func _advance_native_foliage_role(state: Dictionary) -> bool:
	var ticket := int(state.get("nativeTicket", 0))
	var dispatcher: Object = state.get("nativeDispatcher")
	if ticket <= 0 or not is_instance_valid(dispatcher):
		state["nativeFailure"] = "native_tree_geometry_ticket_or_dispatcher_missing"
		return false
	var polled: Dictionary = dispatcher.call("poll_tree_geometry_compile", ticket)
	var status := String(polled.get("status", ""))
	if status == "queued" or status == "running": return false
	if status != "ready":
		state["nativeFailure"] = String(polled.get("reason", "native_tree_foliage_compile_rejected"))
		dispatcher.call("release_tree_geometry_compile", ticket)
		state.erase("nativeTicket")
		return false
	var completed: Dictionary = dispatcher.call("take_tree_geometry_compile_result", ticket)
	var expected: Dictionary = state.get("nativeIdentity", {})
	var echoed: Variant = completed.get("identity", null)
	var values: Variant = completed.get("instanceValues", null)
	var expected_count := int(state.get("nativeInstanceCount", -1))
	if completed.get("status") != "ready" or not echoed is Dictionary \
			or echoed != expected or not values is PackedFloat32Array \
			or values.size() != expected_count * Attributes.FLOATS_PER_INSTANCE \
			or int(completed.get("instanceCount", -1)) != expected_count:
		state["nativeFailure"] = "native_tree_foliage_result_identity_or_layout_invalid"
		dispatcher.call("release_tree_geometry_compile", ticket)
		state.erase("nativeTicket")
		return false
	var multi_mesh: MultiMesh = state.get("multiMesh")
	multi_mesh.set_buffer(values)
	state["nativeInstanceValues"] = values
	state["nextIndex"] = expected_count
	dispatcher.call("release_tree_geometry_compile", ticket)
	state.erase("nativeTicket")
	return true


func _finish_role(factory: Object, record: Dictionary, role: String,
		state: Dictionary) -> Dictionary:
	var recipe: Dictionary = record.recipeSnapshot
	var biome := String(record.request.get("biome", "forest"))
	if bool(state.get("impostor", false)):
		return factory.runtime_impostor_role_values(recipe, biome, role)
	match role:
		"bole": return factory.finish_runtime_bole_values(recipe, state, biome)
		"branches": return factory.finish_runtime_distal_build_values(state, recipe, biome)
		"foliage": return factory.finish_runtime_foliage_build_values(state, recipe, biome)
	return {}


func _prepare_role_compile(record: Dictionary, role: String, values: Dictionary) -> Dictionary:
	var mesh: Mesh
	var multi: MultiMesh
	var instance_count := 1
	var material: Material = values.get("material", null)
	if role == "bole":
		mesh = values.get("mesh", null) as Mesh
	else:
		multi = values.get("multiMesh", null) as MultiMesh
		if multi == null:
			return _pending("tree_multimesh_value_missing")
		mesh = multi.mesh
		instance_count = multi.instance_count
	if not is_instance_valid(mesh) or not is_instance_valid(material) or instance_count <= 0:
		return _pending("tree_render_resource_or_instance_missing")
	var layer := Adapter._supported_opaque_layer(material, role)
	if layer.is_empty(): return _pending("tree_render_layer_unsupported")
	var mesh_report := MeshFingerprint.inspect(mesh)
	var mesh_digest := String(mesh_report.get("contentDigest", ""))
	var material_digest := Adapter._material_digest(material)
	if mesh_report.get("status") != "ready" or mesh_digest.is_empty() or material_digest.is_empty():
		return _pending("tree_resource_fingerprint_unavailable")
	var bounds: AABB = values.get("meshSupportBounds", mesh.get_aabb())
	if values.has("meshSupportBounds") and (not bool(record.recipeSnapshot.get("runtimeImpostor", false)) \
			or values.get("geometryBoundsPolicy") != FactoryScript.IMPOSTOR_BOUNDS_POLICY \
			or bounds != FactoryScript.runtime_impostor_mesh_support(mesh)):
		return _pending("tree_mesh_support_policy_invalid")
	if not Adapter._valid_bounds(bounds): return _pending("tree_mesh_bounds_invalid")
	var resource_key := "tree.runtime.%s:%s/v1" % [role, mesh_digest]
	if values.has("geometryBoundsPolicy"): resource_key += ":" + String(values.geometryBoundsPolicy)
	var material_key := "tree.material.%s:%s" % [role, material_digest]
	var policy: Dictionary = values.get("renderPolicy", {})
	var compatibility := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":material_key, "materialContentDigest":material_digest,
		"renderTier":"detail" if role == "foliage" else "structural",
		"meshResourceKey":resource_key, "meshContentDigest":mesh_digest,
		"meshKey":"%s|pipeline=%s|layer=%s|sort=none" % [resource_key, Adapter.PIPELINE_REVISION, layer],
		"pipelineRevision":Adapter.PIPELINE_REVISION, "renderLayer":layer,
		"translucentSortPolicy":"none", "meshLocalBounds":bounds,
		"castShadows":int(policy.get("castShadow", GeometryInstance3D.SHADOW_CASTING_SETTING_ON)) != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"visibilityRangeEnd":float(policy.get("visibilityRangeEnd", 0.0)),
		"fadeMargin":float(policy.get("visibilityRangeEndMargin", 0.0))}
	var batch_key := SnapshotBuilder.batch_compatibility_key(compatibility)
	if batch_key.is_empty(): return _pending("tree_batch_compatibility_invalid")
	compatibility["batchKey"] = batch_key
	compatibility["compatibilityKey"] = batch_key
	compatibility.make_read_only()
	_job.bindings[resource_key] = mesh
	_job.bindings[material_key] = material
	var compile_state := {"role":role, "values":values, "mesh":mesh,
		"multiMesh":multi, "bounds":bounds, "compatibility":compatibility,
		"batchKey":batch_key, "resourceKey":resource_key, "materialKey":material_key,
		"meshDigest":mesh_digest, "materialDigest":material_digest,
		"ownerCell":record.logicalOwnerCell, "instanceCount":instance_count, "nextIndex":0}
	var native_values: Variant = values.get("nativeInstanceValues", null)
	if native_values is PackedFloat32Array:
		if native_values.size() != instance_count * Attributes.FLOATS_PER_INSTANCE:
			return _pending("tree_native_instance_value_layout_invalid")
		compile_state["nativeInstanceValues"] = native_values
	return {"status":"ready", "state":compile_state}


func _advance_native_tree_section_pack(record: Dictionary, state: Dictionary) -> Dictionary:
	var dispatcher: Object = _job.get("nativeTreeGeometryDispatcher")
	if not is_instance_valid(dispatcher) or not dispatcher.has_method("submit_tree_section_pack"):
		return _pending("native_tree_section_pack_dispatcher_unavailable")
	var ticket := int(state.get("nativePackTicket", 0))
	if ticket <= 0:
		var packed_values: PackedFloat32Array
		var instance_stride := Attributes.FLOATS_PER_INSTANCE
		var use_instance_colors := true
		var use_instance_custom_data := true
		if state.get("nativeInstanceValues", null) is PackedFloat32Array:
			packed_values = state.nativeInstanceValues
		elif state.get("multiMesh", null) is MultiMesh:
			var multi: MultiMesh = state.multiMesh
			packed_values = multi.buffer
			use_instance_colors = multi.use_colors
			use_instance_custom_data = multi.use_custom_data
			instance_stride = 12 + (4 if use_instance_colors else 0) \
				+ (4 if use_instance_custom_data else 0)
		else:
			packed_values = PackedFloat32Array([
				1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
				0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0,
				0.0, 0.0, 0.0, 0.0])
		if packed_values.size() != int(state.instanceCount) * instance_stride:
			return _pending("tree_section_pack_instance_layout_invalid", {
				"sourceId":String(record.get("sourceId", "")),
				"role":String(state.get("role", "")), "expectedCount":int(state.instanceCount),
				"actualFloatCount":packed_values.size()})
		var identity := _native_tree_record_identity(record)
		var envelope: Dictionary = record.get("supportEnvelope", {})
		var world_bounds: Variant = envelope.get("worldBounds", null)
		if identity.is_empty() or not world_bounds is AABB:
			return _discard("tree_section_pack_identity_or_certified_bounds_missing")
		var role := String(state.get("role", ""))
		var wind := ProducerDomain.active_tree_visual_wind_envelope()
		if wind.get("status") != "ready" or String(wind.get("digest", "")).length() != 64:
			return _pending(String(wind.get("reason", "tree_active_visual_wind_envelope_pending")))
		var horizontal := 0.0
		var vertical := 0.0
		if role == "branches":
			horizontal = float(wind.get("branchComponentDisplacementMaxMeters", -1.0))
		elif role == "foliage":
			horizontal = float(wind.get("foliageComponentDisplacementMaxMeters", -1.0))
			vertical = float(wind.get("foliageVerticalDisplacementMaxMeters", -1.0))
		if horizontal < 0.0 or vertical < 0.0:
			return _discard("tree_section_pack_wind_policy_invalid")
		var packet := {"role":role, "sourcePartId":role,
			"batchKey":String(state.get("batchKey", "")),
			"meshContentDigest":String(state.get("meshDigest", "")),
			"supportEnvelopePolicyRevision":SUPPORT_ENVELOPE_POLICY_REVISION,
			"meshLocalBounds":state.get("bounds", AABB()),
			"sourceGlobalTransform":record.get("bodyGlobalTransform", Transform3D.IDENTITY),
			"certifiedWorldBounds":world_bounds, "windEnvelopeDigest":String(wind.digest),
			"windHorizontalMeters":horizontal, "windVerticalMeters":vertical,
			"sectionSize":Grid.SECTION_SIZE_METERS, "instanceValues":packed_values,
			"instanceStride":instance_stride,
			"useInstanceColors":use_instance_colors,
			"useInstanceCustomData":use_instance_custom_data}
		var admission: Dictionary = dispatcher.call("submit_tree_section_pack", packet, identity)
		if admission.get("status") == "backpressure":
			return _pending("native_tree_section_pack_backpressure", {
				"sourceId":String(record.get("sourceId", "")), "retryable":true})
		if admission.get("status") != "pending" or int(admission.get("ticket", 0)) <= 0 \
				or admission.get("identity", {}) != identity:
			return _discard(String(admission.get("reason",
				"native_tree_section_pack_admission_invalid")))
		state["nativePackTicket"] = int(admission.ticket)
		state["nativePackIdentity"] = identity
		state["nativePackDispatcher"] = dispatcher
		return _pending("native_tree_section_pack_queued", {
			"sourceId":String(record.get("sourceId", "")), "ticket":int(admission.ticket)})
	var polled: Dictionary = dispatcher.call("poll_tree_geometry_compile", ticket)
	var status := String(polled.get("status", ""))
	if status in ["queued", "running"]:
		return _pending("native_tree_section_pack_running", {
			"sourceId":String(record.get("sourceId", "")), "ticket":ticket})
	if status != "ready":
		dispatcher.call("release_tree_geometry_compile", ticket)
		state.erase("nativePackTicket")
		return _discard(String(polled.get("reason", "native_tree_section_pack_failed")))
	var completed: Dictionary = dispatcher.call("take_tree_geometry_compile_result", ticket)
	var expected_identity: Dictionary = state.get("nativePackIdentity", {})
	var latest_identity := _native_tree_record_identity(record)
	var latest_source := _immutable_source_currentness(record) \
		if String(_job.get("mode", "")) == "immutable_source" else (
			{"status":"ready"} if _current(record) else {"status":"failed",
				"reason":"tree_recipe_input_stale_during_section_pack"})
	if completed.get("status") != "ready" or completed.get("identity", {}) != expected_identity \
			or not native_tree_record_identity_is_current(expected_identity, latest_identity) \
			or latest_source.get("status") != "ready" \
			or String(completed.get("role", "")) != String(state.get("role", "")) \
			or String(completed.get("sourcePartId", "")) != String(state.get("role", "")) \
			or String(completed.get("batchKey", "")) != String(state.get("batchKey", "")) \
			or String(completed.get("meshContentDigest", "")) != String(state.get("meshDigest", "")) \
			or String(completed.get("windEnvelopeDigest", "")) \
				!= String(ProducerDomain.active_tree_visual_wind_envelope().get("digest", "")):
		dispatcher.call("release_tree_geometry_compile", ticket)
		state.erase("nativePackTicket")
		return _discard(String(latest_source.get("reason",
			"native_tree_section_pack_result_identity_or_revision_stale")))
	var accept_started_usec := Time.get_ticks_usec()
	var accepted := _accept_native_tree_section_pack(record, state, completed)
	_job.nativePackAcceptanceUsec = int(_job.get("nativePackAcceptanceUsec", 0)) \
		+ maxi(0, Time.get_ticks_usec() - accept_started_usec)
	_job.nativePackAcceptedInstances = int(_job.get("nativePackAcceptedInstances", 0)) \
		+ maxi(0, int(completed.get("instanceCount", 0)))
	dispatcher.call("release_tree_geometry_compile", ticket)
	state.erase("nativePackTicket")
	state.erase("nativePackIdentity")
	state.erase("nativePackDispatcher")
	if accepted.get("status") != "ready":
		return _discard(String(accepted.get("reason",
			"native_tree_section_pack_result_invalid")))
	return accepted


func _accept_native_tree_section_pack(record: Dictionary, state: Dictionary,
		packed: Dictionary) -> Dictionary:
	var sections_value: Variant = packed.get("sections", null)
	if not sections_value is Array or not sections_value.is_read_only():
		return _pending("native_tree_section_pack_sections_invalid")
	var role := String(state.get("role", ""))
	var source_id := String(record.get("sourceId", ""))
	var recipe_signature := String(record.get("recipeSignature", ""))
	var artifact_generation := int(record.get("artifactGeneration", 0))
	var wind_digest := String(packed.get("windEnvelopeDigest", ""))
	if String(packed.get("supportEnvelopePolicyRevision", "")) \
			!= SUPPORT_ENVELOPE_POLICY_REVISION:
		return _pending("native_tree_section_pack_support_policy_revision_mismatch")
	var total_instances := 0
	var seen_instance_indices := {}
	var seen_owner_sections := {}
	for section_value: Variant in sections_value:
		if not section_value is Dictionary or not section_value.is_read_only():
			return _pending("native_tree_section_pack_section_invalid")
		var section: Dictionary = section_value
		var section_key_value: Variant = section.get("sectionKey", null)
		var attributes_value: Variant = section.get("instanceAttributes", null)
		var members_value: Variant = section.get("members", null)
		if not section_key_value is Vector3i or not attributes_value is Array \
				or not attributes_value.is_read_only() \
				or attributes_value.get_typed_builtin() != TYPE_FLOAT \
				or not members_value is Array or not members_value.is_read_only() \
				or int(section.get("instanceCount", -1)) != members_value.size() \
				or attributes_value.size() != members_value.size() * Attributes.FLOATS_PER_INSTANCE:
			return _pending("native_tree_section_pack_section_layout_invalid")
		var section_key: Vector3i = section_key_value
		if seen_owner_sections.has(section_key):
			return _pending("native_tree_section_pack_duplicate_owner_section")
		seen_owner_sections[section_key] = true
		var batch_key := String(state.get("batchKey", ""))
		var key := "%s|%s" % [section_key, batch_key]
		var section_origin := Grid.origin_for_key(section_key)
		if not _job.sectionBatches.has(key):
			_job.sectionBatches[key] = {"sectionKey":section_key, "batchKey":batch_key,
				"role":role, "compatibilityKey":state.compatibility,
				"meshKey":state.resourceKey, "materialKey":state.materialKey,
				"meshDigest":state.meshDigest, "materialDigest":state.materialDigest,
				"sectionOrigin":section_origin, "ownerCell":state.ownerCell,
				"streamChunkDependencies":Grid.stream_chunk_keys_intersecting_section(section_key),
				"instanceAttributes":[], "contributors":{}}
		var batch: Dictionary = _job.sectionBatches[key]
		var batch_offset := int(batch.instanceAttributes.size()) / Attributes.FLOATS_PER_INSTANCE
		var batch_attributes: Array = batch.instanceAttributes
		batch_attributes.append_array(attributes_value)
		var expected_local_offset := 0
		for member_value: Variant in members_value:
			if not member_value is Dictionary or not member_value.is_read_only():
				return _pending("native_tree_section_pack_member_invalid")
			var member: Dictionary = member_value
			var instance_index := int(member.get("instanceIndex", -1))
			var local_offset := int(member.get("attributeOffset", -1))
			var bounds_value: Variant = member.get("worldBounds", null)
			var owned_key_value: Variant = member.get("ownedSectionKey", null)
			var support_value: Variant = member.get("supportSectionKeys", null)
			if instance_index < 0 or instance_index >= int(state.instanceCount) \
					or seen_instance_indices.has(instance_index) \
					or local_offset != expected_local_offset \
					or local_offset < 0 or local_offset >= members_value.size() \
					or not bounds_value is AABB or not Adapter._valid_bounds(bounds_value) \
					or not owned_key_value is Vector3i or owned_key_value != section_key \
					or not support_value is Array or not support_value.is_read_only() \
					or support_value.is_empty():
				return _pending("native_tree_section_pack_member_proof_invalid")
			seen_instance_indices[instance_index] = true
			expected_local_offset += 1
			var expected_support := Grid.keys_intersecting_bounds(bounds_value)
			if expected_support != support_value or not support_value.has(section_key):
				return _pending("native_tree_section_pack_support_coverage_mismatch", {
					"instanceIndex":instance_index, "sectionKey":section_key,
					"expectedSupport":expected_support, "actualSupport":support_value})
			var expected_owner := Grid.key_for_world_position(bounds_value.get_center())
			if section_key != expected_owner:
				return _pending("native_tree_section_pack_geometry_owner_mismatch", {
					"instanceIndex":instance_index, "expectedOwner":expected_owner,
					"actualOwner":section_key})
			var member_id := "%s:%08d" % [role, instance_index]
			var envelope_digest := _compiled_member_envelope_digest(_job.worldId,
				source_id, member_id, bounds_value, String(state.meshDigest),
				recipe_signature, artifact_generation, wind_digest)
			if envelope_digest.is_empty():
				return _pending("tree_compiled_member_envelope_digest_failed")
			var support_keys: Array[Vector3i] = []
			for support_key_value: Variant in support_value:
				if not support_key_value is Vector3i:
					return _pending("native_tree_section_pack_support_key_invalid")
				var support_key: Vector3i = support_key_value
				if support_key not in support_keys:
					support_keys.append(support_key)
				_job.currentSourceSections[support_key] = true
			_job.currentSourceOwnedSections[section_key] = true
			if _job.currentSourceWorldBounds.has(source_id):
				_job.currentSourceWorldBounds[source_id] = \
					_job.currentSourceWorldBounds[source_id].merge(bounds_value)
			else:
				_job.currentSourceWorldBounds[source_id] = bounds_value
			_job.currentSourceGeometryOwnership.append({"role":role,
				"instanceIndex":instance_index, "memberId":member_id,
				"ownedSectionKey":section_key, "geometryOwnerSectionKey":section_key,
				"supportSectionKeys":support_keys,
				"conservativeWorldBounds":bounds_value, "exactWorldBounds":bounds_value,
				"meshContentDigest":String(state.meshDigest),
				"certifiedEnvelopeDigest":envelope_digest,
				"certifiedEnvelopeProof":{"meshContentDigest":String(state.meshDigest),
					"policyRevision":SUPPORT_ENVELOPE_POLICY_REVISION,
					"activeWindEnvelopeDigest":wind_digest, "digest":envelope_digest},
				"recipeSignature":recipe_signature, "artifactGeneration":artifact_generation})
			var part_key := _source_part_identity_key(source_id, member_id)
			if part_key.is_empty():
				return _pending("tree_member_identity_invalid")
			if not batch.contributors.has(part_key):
				batch.contributors[part_key] = {"sourceId":source_id,
					"sourcePartId":member_id, "instanceAttributes":[],
					"instanceAttributeOffsets":[]}
			var contributor: Dictionary = batch.contributors[part_key]
			var member_attributes: Array = contributor.instanceAttributes
			var source_begin := local_offset * Attributes.FLOATS_PER_INSTANCE
			for lane in range(Attributes.FLOATS_PER_INSTANCE):
				member_attributes.append(attributes_value[source_begin + lane])
			(contributor.instanceAttributeOffsets as Array).append(batch_offset + local_offset)
			total_instances += 1
	if total_instances != int(packed.get("instanceCount", -1)) \
			or total_instances != int(state.instanceCount) \
			or seen_instance_indices.size() != int(state.instanceCount):
		return _pending("native_tree_section_pack_instance_total_mismatch", {
			"expected":int(state.instanceCount), "actual":total_instances})
	return {"status":"ready"}


func _seal_source(record: Dictionary) -> Dictionary:
	if String(_job.get("mode", "legacy_owner")) == "immutable_source":
		var freshness := _immutable_source_currentness(record)
		if freshness.get("status") != "ready":
			return freshness
	elif not _current(record):
		return _pending("tree_recipe_input_stale_before_source_seal")
	var digest_context := HashingContext.new()
	if digest_context.start(HashingContext.HASH_SHA256) != OK:
		return _pending("tree_source_digest_begin_failed")
	var source_id := String(record.sourceId)
	for key: Variant in _job.sectionBatches.keys():
		var batch: Dictionary = _job.sectionBatches[key]
		if String(batch.role) not in ROLES:
			continue
		var member_keys: Array[String] = []
		for member_key_value: Variant in batch.contributors:
			var member_value: Variant = batch.contributors[member_key_value]
			if member_value is Dictionary and String(member_value.get("sourceId", "")) == source_id:
				member_keys.append(String(member_key_value))
		member_keys.sort()
		for member_key: String in member_keys:
			var member_contributor: Dictionary = batch.contributors[member_key]
			var packed := var_to_bytes([key, member_key, batch.meshDigest,
				batch.materialDigest, member_contributor.get("instanceAttributes", [])])
			if digest_context.update(packed) != OK:
				return _pending("tree_source_digest_update_failed")
	var compiled_digest := digest_context.finish().hex_encode()
	var revision_context := HashingContext.new()
	if revision_context.start(HashingContext.HASH_SHA256) != OK \
			or revision_context.update(var_to_bytes([SCHEMA,
				String(record.contentRevision), compiled_digest])) != OK:
		return _pending("tree_source_revision_digest_failed")
	var values := {"schema":SCHEMA, "sourceId":String(record.sourceId),
		"sourceRevision":revision_context.finish().hex_encode(),
		"sourceDomainRevision":String(record.get("sourceDomainRevision", "")),
		"producerRevision":String(record.get("producerRevision", "")),
		"sourceRecordDigest":String(record.get("sourceRecordDigest", "")),
		"artifactGeneration":int(record.get("artifactGeneration", 0)),
		"recipeArtifactRevision":String(record.contentRevision),
		"recipeSignature":String(record.recipeSignature),
		"bodyInstanceId":int(record.bodyInstanceId),
		"bodyGlobalTransform":record.bodyGlobalTransform,
		"sectionKeys":_source_section_keys(_job.currentSourceSections),
		"ownedSectionKeys":_source_section_keys(_job.currentSourceOwnedSections),
		"geometryWorldBounds":_job.currentSourceWorldBounds.get(record.sourceId, AABB()),
		"emptyRoles":(_job.currentSourceEmptyRoles as Array).duplicate(),
		"supportEnvelope":record.get("supportEnvelope", {}),
		"certifiedEnvelopeDigest":String(record.get("certifiedEnvelopeDigest", "")),
		"sourceChunkKey":record.get("sourceChunkKey",
			Grid.chunk_key_for_world_position((record.bodyGlobalTransform as Transform3D).origin)),
		"state":"compiled",
		"geometryOwnership":_freeze_ownership(_job.currentSourceGeometryOwnership),
		"compiledAttributeDigest":compiled_digest}
	_deep_freeze(values)
	_job.currentSourceSections.clear()
	_job.currentSourceOwnedSections.clear()
	_job.currentSourceGeometryOwnership.clear()
	_job.currentSourceWorldBounds.clear()
	_job.currentSourceEmptyRoles.clear()
	return {"status":"ready", "value":values}


static func _compiled_member_envelope_digest(world_id: String, source_id: String,
		member_id: String, bounds: AABB, mesh_digest: String,
		recipe_signature: String, artifact_generation: int,
		wind_envelope_digest: String) -> String:
	var proof := ["ecology-certified-member-envelope/v2", world_id,
		source_id, member_id, bounds, mesh_digest,
		SUPPORT_ENVELOPE_POLICY_REVISION, recipe_signature, artifact_generation,
		wind_envelope_digest]
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(proof)) != OK:
		return ""
	return context.finish().hex_encode()


static func _expand_bounds_for_active_wind(bounds: AABB, role: String,
		wind_envelope: Dictionary) -> AABB:
	if not Adapter._valid_bounds(bounds): return AABB()
	var horizontal := 0.0
	var vertical := 0.0
	if role == "branches":
		horizontal = float(wind_envelope.get("branchComponentDisplacementMaxMeters", -1.0))
	elif role == "foliage":
		horizontal = float(wind_envelope.get("foliageComponentDisplacementMaxMeters", -1.0))
		vertical = float(wind_envelope.get("foliageVerticalDisplacementMaxMeters", -1.0))
	if horizontal < 0.0 or vertical < 0.0 or not is_finite(horizontal) or not is_finite(vertical):
		return AABB()
	var expansion := Vector3(horizontal, vertical, horizontal)
	return AABB(bounds.position - expansion, bounds.size + expansion * 2.0)


func _seal_candidate() -> Dictionary:
	var main_ref := _job.main as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	if not is_instance_valid(main) or main.get_instance_id() != int(_job.mainInstanceId):
		return _discard("tree_compile_main_authority_replaced_before_seal")
	if String(_job.get("mode", "legacy_owner")) != "immutable_source" \
			and not RemovedProps.is_current_for_ids(main, _job.removedSnapshot, _source_prop_ids()):
		return _discard("tree_removed_props_or_main_stale_before_seal")
	for record: Dictionary in _job.records:
		if not _current(record):
			return _discard("tree_recipe_input_stale_before_candidate_seal")
	if not _resources_current():
		return _discard("tree_render_resource_fingerprint_changed_before_candidate_seal")
	var batches: Array[Dictionary] = []
	var manifest: Array = _job.manifest.duplicate(true)
	var target_section: Variant = _job.get("targetSectionKey", null)
	var source_record_artifact := bool(_job.get("sourceRecordArtifact", false))
	for key: Variant in _job.sectionBatches.keys():
		var batch: Dictionary = _job.sectionBatches[key]
		if target_section is Vector3i and batch.get("sectionKey", null) != target_section:
			continue
		var attrs: Array = batch.instanceAttributes
		if attrs.is_empty() or attrs.size() % Attributes.FLOATS_PER_INSTANCE != 0:
			return _discard("tree_instance_attribute_buffer_invalid")
		if target_section is Vector3i or source_record_artifact:
			var typed_attrs: Array[float] = []
			for component_value: Variant in attrs:
				if not component_value is float or not is_finite(float(component_value)):
					return _discard("tree_instance_attribute_component_invalid")
				typed_attrs.append(float(component_value))
			typed_attrs.make_read_only()
			attrs = typed_attrs
		else:
			attrs.make_read_only()
		var row := {"sectionKey":batch.sectionKey, "batchKey":batch.batchKey,
			"role":batch.role, "renderLayer":"opaque", "compatibilityKey":batch.compatibilityKey,
			"meshKey":batch.meshKey, "materialKey":batch.materialKey,
			"meshContentDigest":batch.meshDigest, "materialContentDigest":batch.materialDigest,
			"sectionOrigin":batch.sectionOrigin, "ownerCell":batch.ownerCell,
			"streamChunkDependencies":batch.streamChunkDependencies,
			"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"instanceCount":attrs.size() / Attributes.FLOATS_PER_INSTANCE,
			"contributors":_freeze_contributors(batch.contributors, manifest,
				target_section is Vector3i or source_record_artifact),
			"instanceAttributes":attrs}
		_deep_freeze(row)
		batches.append(row)
	batches.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ak: Vector3i = a.sectionKey
		var bk: Vector3i = b.sectionKey
		if ak.x != bk.x: return ak.x < bk.x
		if ak.y != bk.y: return ak.y < bk.y
		if ak.z != bk.z: return ak.z < bk.z
		return String(a.batchKey) < String(b.batchKey))
	batches.make_read_only()
	var band_completion_manifest: Array[Dictionary] = []
	var owner_payload_rows: Array = []
	var band_source_ids: Array[String] = []
	var band_disposition := "complete_nonempty"
	var band_resource_bindings: Dictionary = {}
	if target_section is Vector3i:
		var expected_source_ids: Variant = _job.get("expectedSourceIds", [])
		if not expected_source_ids is Array:
			return _discard("tree_band_expected_source_ids_unavailable")
		for source_id_value: Variant in expected_source_ids:
			if not source_id_value is String or String(source_id_value).is_empty():
				return _discard("tree_band_expected_source_id_invalid")
			band_source_ids.append(String(source_id_value))
		for batch_value: Variant in batches:
			if not batch_value is Dictionary:
				return _discard("tree_band_owner_batch_invalid")
			var batch: Dictionary = batch_value
			for resource_key: String in [String(batch.get("meshKey", "")),
					String(batch.get("materialKey", ""))]:
				if resource_key.is_empty() or not _job.bindings.has(resource_key):
					return _discard("tree_band_owner_batch_resource_missing")
				band_resource_bindings[resource_key] = _job.bindings[resource_key]
		var band_proof := _build_band_completion_proof(target_section,
			band_source_ids, manifest, batches, band_resource_bindings)
		if band_proof.get("status") != "ready":
			return _discard(String(band_proof.get("reason", "tree_band_completion_proof_invalid")))
		band_completion_manifest = band_proof.get("sourceCompletionManifest", [])
		owner_payload_rows = band_proof.get("ownerBatchContributors", [])
		band_disposition = String(band_proof.get("disposition", ""))
	band_completion_manifest.make_read_only()
	manifest.make_read_only()
	var bindings: Dictionary = band_resource_bindings if target_section is Vector3i \
		else _job.bindings.duplicate()
	bindings.make_read_only()
	var output_schema := BAND_ARTIFACT_SCHEMA if target_section is Vector3i \
		else SOURCE_RECORD_ARTIFACT_SCHEMA if source_record_artifact else SCHEMA
	var output := {"status":"ready", "schema":output_schema, "worldId":_job.worldId,
		"sourceMode":String(_job.get("mode", "legacy_owner")),
		"treeFamilyRevision":String(_job.get("treeFamilyRevision", "")),
		"treeFamilyManifestDigest":String(_job.get("treeFamilyManifestDigest", "")),
		"sources":manifest, "batches":batches, "resourceBindings":bindings,
		"workUnits":int(_job.workUnits),
		"nativeTreePackAcceptanceUsec":int(_job.get("nativePackAcceptanceUsec", 0)),
		"nativeTreePackAcceptedInstances":int(_job.get("nativePackAcceptedInstances", 0)),
		"oldRepresentationRetention":"caller_owned_until_receipt"}
	if source_record_artifact:
		if manifest.size() != 1:
			return _discard("tree_source_record_artifact_manifest_incomplete")
		var source_manifest: Dictionary = manifest[0]
		if String(source_manifest.get("sourceId", "")) != String(
				_job.get("sourceRecordId", "")):
			return _discard("tree_source_record_artifact_identity_mismatch")
		var resource_keys: Array[String] = []
		for resource_key_value: Variant in bindings:
			resource_keys.append(String(resource_key_value))
		resource_keys.sort()
		var artifact_digest := _digest_value([SOURCE_RECORD_ARTIFACT_SCHEMA,
			String(_job.get("worldId", "")), _job.get("sourceChunkKey", Vector2i.ZERO),
			String(_job.get("sourceRevision", "")),
			String(_job.get("treeFamilyRevision", "")),
			String(_job.get("treeFamilyManifestDigest", "")),
			String(_job.get("sourceRecordId", "")), manifest, batches, resource_keys])
		if artifact_digest.length() != 64:
			return _discard("tree_source_record_artifact_digest_failed")
		output["sourceId"] = String(_job.get("sourceRecordId", ""))
		output["sourceChunkKey"] = _job.get("sourceChunkKey", Vector2i.ZERO)
		output["sourceRevision"] = String(_job.get("sourceRevision", ""))
		output["sourceRecordDigest"] = String(source_manifest.get("sourceRecordDigest", ""))
		output["sourceArtifactDigest"] = artifact_digest
		output["sourceGeometryDisposition"] = "complete_nonempty" if not batches.is_empty() \
			else "complete_empty"
	if target_section is Vector3i:
		output["sectionKey"] = target_section
		output["sourceChunkKey"] = _job.get("sourceChunkKey", Vector2i.ZERO)
		output["sourceRevision"] = String(_job.get("sourceRevision", ""))
		output["authorityDigest"] = String(_job.get("bandAuthority", {}).get("authorityDigest", ""))
		output["expectedSourceIds"] = band_source_ids
		output["disposition"] = band_disposition
		output["sourceCompletionManifest"] = band_completion_manifest
		output["sourceCompletionDigest"] = _digest_value(band_completion_manifest)
		output["ownerBatchContributors"] = owner_payload_rows
		output["ownerBatchPayloadDigest"] = _digest_value(owner_payload_rows)
	_deep_freeze(output)
	_job.status = "complete"
	_release_catalog_lease()
	return output


func _build_band_completion_proof(target_section: Vector3i,
		expected_source_ids_value: Array, source_manifest: Array,
		batches: Array, resource_bindings: Dictionary) -> Dictionary:
	var expected_source_ids: Array[String] = []
	for source_id_value: Variant in expected_source_ids_value:
		if not source_id_value is String or String(source_id_value).is_empty() \
				or String(source_id_value) in expected_source_ids:
			return {"status":"pending", "reason":"tree_band_expected_source_ids_invalid"}
		expected_source_ids.append(String(source_id_value))
	var expected_sorted := expected_source_ids.duplicate()
	expected_sorted.sort()
	var source_by_id: Dictionary = {}
	var expected_owner_members: Dictionary = {}
	var expected_support_members: Dictionary = {}
	var source_completion_manifest: Array[Dictionary] = []
	for source_value: Variant in source_manifest:
		if not source_value is Dictionary:
			return {"status":"pending", "reason":"tree_band_source_completion_row_invalid"}
		var source_row: Dictionary = source_value
		var source_id := String(source_row.get("sourceId", ""))
		var geometry_value: Variant = source_row.get("geometryOwnership", null)
		if source_id.is_empty() or source_by_id.has(source_id) \
				or not geometry_value is Array \
				or String(source_row.get("sourceRecordDigest", "")).is_empty() \
				or String(source_row.get("recipeArtifactRevision", "")).is_empty() \
				or String(source_row.get("recipeSignature", "")).is_empty():
			return {"status":"pending", "reason":"tree_band_source_completion_identity_invalid"}
		source_by_id[source_id] = source_row
		var owner_ids: Array[String] = []
		var support_ids: Array[String] = []
		var source_members: Dictionary = {}
		for member_value: Variant in geometry_value:
			if not member_value is Dictionary:
				return {"status":"pending", "reason":"tree_band_member_completion_row_invalid"}
			var member: Dictionary = member_value
			var member_id := String(member.get("memberId", ""))
			var owner: Variant = member.get("ownedSectionKey",
				member.get("geometryOwnerSectionKey", null))
			var support_keys_value: Variant = member.get("supportSectionKeys", null)
			var bounds: Variant = member.get("conservativeWorldBounds", null)
			if member_id.is_empty() or source_members.has(member_id) \
					or not owner is Vector3i or not support_keys_value is Array \
					or not bounds is AABB or not Adapter._valid_bounds(bounds) \
					or String(member.get("meshContentDigest", "")).is_empty() \
					or String(member.get("certifiedEnvelopeDigest", "")).is_empty():
				return {"status":"pending", "reason":"tree_band_member_completion_identity_invalid"}
			source_members[member_id] = true
			var support_keys: Array[Vector3i] = []
			for support_value: Variant in support_keys_value:
				if not support_value is Vector3i or support_value in support_keys:
					return {"status":"pending", "reason":"tree_band_member_support_keys_invalid"}
				support_keys.append(support_value)
			if owner not in support_keys:
				return {"status":"pending", "reason":"tree_band_geometry_owner_not_supported"}
			var identity := _source_part_identity_key(source_id, member_id)
			if identity.is_empty():
				return {"status":"pending", "reason":"tree_band_member_identity_invalid"}
			if owner == target_section:
				owner_ids.append(member_id)
				expected_owner_members[identity] = {"sourceId":source_id,
					"sourcePartId":member_id, "sourceRevision":String(source_row.get("sourceRevision", "")),
					"recipeArtifactRevision":String(source_row.get("recipeArtifactRevision", "")),
					"recipeSignature":String(source_row.get("recipeSignature", "")),
					"meshContentDigest":String(member.get("meshContentDigest", "")),
					"conservativeWorldBounds":bounds,
					"certifiedEnvelopeDigest":String(member.get("certifiedEnvelopeDigest", ""))}
			if target_section in support_keys:
				support_ids.append(member_id)
				expected_support_members[identity] = true
		owner_ids.sort()
		support_ids.sort()
		source_completion_manifest.append({"sourceId":source_id,
			"sourceRecordDigest":String(source_row.get("sourceRecordDigest", "")),
			"recipeArtifactRevision":String(source_row.get("recipeArtifactRevision", "")),
			"recipeSignature":String(source_row.get("recipeSignature", "")),
			"completionState":"complete",
			"ownerMemberIds":owner_ids, "ownerMemberDigest":_digest_value(owner_ids),
			"supportMemberIds":support_ids, "supportMemberDigest":_digest_value(support_ids),
			"ownerMemberCount":owner_ids.size(), "supportMemberCount":support_ids.size()})
	if source_by_id.size() != expected_sorted.size():
		return {"status":"pending", "reason":"tree_band_source_completion_manifest_incomplete"}
	for source_id: String in expected_sorted:
		if not source_by_id.has(source_id):
			return {"status":"pending", "reason":"tree_band_expected_source_completion_missing"}
	var completion_support_members: Dictionary = {}
	var completion_owner_members: Dictionary = {}
	for completion: Dictionary in source_completion_manifest:
		var source_id := String(completion.sourceId)
		var source_support_members: Dictionary = {}
		for member_id_value: Variant in completion.supportMemberIds:
			var identity := _source_part_identity_key(source_id, String(member_id_value))
			if identity.is_empty() or completion_support_members.has(identity):
				return {"status":"pending", "reason":"tree_band_support_completion_duplicate"}
			completion_support_members[identity] = true
			source_support_members[identity] = true
		for member_id_value: Variant in completion.ownerMemberIds:
			var identity := _source_part_identity_key(source_id, String(member_id_value))
			if identity.is_empty() or completion_owner_members.has(identity) \
					or not source_support_members.has(identity):
				return {"status":"pending", "reason":"tree_band_owner_support_closure_invalid"}
			completion_owner_members[identity] = true
	if completion_support_members.size() != expected_support_members.size() \
			or completion_owner_members.size() != expected_owner_members.size():
		return {"status":"pending", "reason":"tree_band_support_owner_closure_incomplete"}
	for identity: String in expected_support_members:
		if not completion_support_members.has(identity):
			return {"status":"pending", "reason":"tree_band_support_member_missing"}
	var actual_owner_members: Dictionary = {}
	var batch_compatibility_by_key: Dictionary = {}
	var seen_owner_batch_slices: Dictionary = {}
	var used_resource_keys: Dictionary = {}
	var owner_payload_rows: Array = []
	for batch_value: Variant in batches:
		if not batch_value is Dictionary:
			return {"status":"pending", "reason":"tree_band_owner_batch_invalid"}
		var batch: Dictionary = batch_value
		var batch_key := String(batch.get("batchKey", ""))
		var mesh_key := String(batch.get("meshKey", ""))
		var material_key := String(batch.get("materialKey", ""))
		var mesh_digest := String(batch.get("meshContentDigest", ""))
		var material_digest := String(batch.get("materialContentDigest", ""))
		var compatibility_value: Variant = batch.get("compatibilityKey", null)
		var prior_compatibility: Variant = batch_compatibility_by_key.get(batch_key, null)
		if batch.get("sectionKey", null) != target_section \
				or String(batch.get("renderLayer", "")) != "opaque" \
				or batch_key.is_empty() \
				or not compatibility_value is Dictionary \
				or String(compatibility_value.get("batchKey", "")) != batch_key \
				or String(compatibility_value.get("compatibilityKey", "")) != batch_key \
				or String(compatibility_value.get("renderLayer", "")) != "opaque" \
				or String(compatibility_value.get("meshResourceKey", "")) != mesh_key \
				or not String(compatibility_value.get("meshKey", "")).contains(mesh_digest) \
				or String(compatibility_value.get("pipelineRevision", "")).is_empty() \
				or String(compatibility_value.get("translucentSortPolicy", "")) != "none" \
				or String(compatibility_value.get("materialKey", "")) != material_key \
				or String(compatibility_value.get("meshContentDigest", "")) != mesh_digest \
				or String(compatibility_value.get("materialContentDigest", "")) != material_digest \
				or String(batch.get("instanceAttributeLayout", "")) != Attributes.LAYOUT_SCHEMA \
				or int(batch.get("instanceCount", -1)) < 0 \
				or not batch.get("instanceAttributes", null) is Array \
				or batch.get("instanceAttributes", []).size() \
				!= int(batch.get("instanceCount", -1)) * Attributes.FLOATS_PER_INSTANCE \
				or mesh_key.is_empty() or material_key.is_empty() \
				or mesh_digest.is_empty() or material_digest.is_empty() \
				or not mesh_key.contains(mesh_digest) or not material_key.contains(material_digest) \
				or not resource_bindings.has(mesh_key) or not resource_bindings.has(material_key):
			return {"status":"pending", "reason":"tree_band_owner_batch_binding_invalid"}
		if prior_compatibility != null and prior_compatibility != compatibility_value:
			return {"status":"pending", "reason":"tree_band_compatibility_slice_conflict",
				"batchKey":batch_key}
		batch_compatibility_by_key[batch_key] = compatibility_value
		used_resource_keys[mesh_key] = true
		used_resource_keys[material_key] = true
		var aggregate_attributes: Array = batch.get("instanceAttributes", [])
		var covered_instance_offsets: Dictionary = {}
		var contributors_value: Variant = batch.get("contributors", null)
		if not contributors_value is Dictionary:
			return {"status":"pending", "reason":"tree_band_owner_batch_contributors_invalid"}
		var contributors: Dictionary = contributors_value
		for contributor_key_value: Variant in contributors:
			var contributor_value: Variant = contributors[contributor_key_value]
			if not contributor_value is Dictionary:
				return {"status":"pending", "reason":"tree_band_owner_contributor_invalid"}
			var contributor: Dictionary = contributor_value
			var source_id := String(contributor.get("sourceId", ""))
			var member_id := String(contributor.get("sourcePartId", ""))
			var identity := _source_part_identity_key(source_id, member_id)
			var owner_batch_slice_key := identity + "|batch:" + batch_key
			if identity.is_empty() or identity != String(contributor_key_value) \
					or not expected_owner_members.has(identity) \
					or actual_owner_members.has(identity) \
					or seen_owner_batch_slices.has(owner_batch_slice_key):
				return {"status":"pending", "reason":"tree_band_owner_batch_member_set_mismatch"}
			actual_owner_members[identity] = true
			seen_owner_batch_slices[owner_batch_slice_key] = true
			var expected: Dictionary = expected_owner_members[identity]
			if String(contributor.get("sourceRevision", "")) != String(expected.sourceRevision):
				return {"status":"pending", "reason":"tree_band_owner_source_revision_mismatch"}
			var contributor_attributes: Variant = contributor.get("instanceAttributes", null)
			var offsets_value: Variant = contributor.get("instanceAttributeOffsets", null)
			if not contributor_attributes is Array \
					or contributor_attributes.get_typed_builtin() != TYPE_FLOAT \
					or not contributor_attributes.is_read_only() \
					or not offsets_value is Array \
					or contributor_attributes.size() % Attributes.FLOATS_PER_INSTANCE != 0 \
					or offsets_value.size() != contributor_attributes.size() \
					/ Attributes.FLOATS_PER_INSTANCE:
				return {"status":"pending", "reason":"tree_band_owner_attribute_layout_invalid"}
			for contributor_instance_index: int in range(offsets_value.size()):
				var instance_offset_value: Variant = offsets_value[contributor_instance_index]
				if not instance_offset_value is int:
					return {"status":"pending", "reason":"tree_band_owner_attribute_offset_invalid"}
				var instance_offset := int(instance_offset_value)
				if instance_offset < 0 or instance_offset >= int(batch.instanceCount) \
						or covered_instance_offsets.has(instance_offset):
					return {"status":"pending", "reason":"tree_band_owner_attribute_offset_duplicate"}
				covered_instance_offsets[instance_offset] = true
				var contributor_start := contributor_instance_index * Attributes.FLOATS_PER_INSTANCE
				var aggregate_start := instance_offset * Attributes.FLOATS_PER_INSTANCE
				for attribute_index: int in range(Attributes.FLOATS_PER_INSTANCE):
					if contributor_attributes[contributor_start + attribute_index] \
							!= aggregate_attributes[aggregate_start + attribute_index]:
						return {"status":"pending", "reason":"tree_band_owner_attributes_do_not_match_batch"}
			var payload := [source_id, member_id,
				String(expected.recipeArtifactRevision), String(expected.recipeSignature),
				mesh_digest, material_digest, String(expected.meshContentDigest),
				expected.conservativeWorldBounds, String(expected.certifiedEnvelopeDigest),
			contributor_attributes]
			owner_payload_rows.append([batch_key, payload])
		if covered_instance_offsets.size() != int(batch.get("instanceCount", -1)):
			return {"status":"pending", "reason":"tree_band_batch_instance_coverage_incomplete"}
	if actual_owner_members.size() != expected_owner_members.size():
		return {"status":"pending", "reason":"tree_band_owner_batch_payload_incomplete"}
	if used_resource_keys.size() != resource_bindings.size():
		return {"status":"pending", "reason":"tree_band_resource_binding_set_mismatch"}
	source_completion_manifest.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("sourceId", "")) < String(b.get("sourceId", "")))
	owner_payload_rows.sort_custom(func(a: Array, b: Array) -> bool:
		return String(a[0]) + var_to_str(a[1]) < String(b[0]) + var_to_str(b[1]))
	return {"status":"ready",
		"disposition":"complete_empty" if actual_owner_members.is_empty() else "complete_nonempty",
		"sourceCompletionManifest":source_completion_manifest,
		"ownerBatchContributors":owner_payload_rows}


## Compose a target-section proof from already sealed per-source geometry.
## Batch and contributor arrays are retained by alias; only small manifest,
## resource-key, and proof containers are constructed here.
func project_source_record_artifacts_to_band(world_id: String,
		source_chunk: Vector2i, section_key: Vector3i, source_revision: String,
		family_revision: String, family_manifest_digest: String,
		authority: Dictionary, expected_source_ids_value: Array,
		source_artifacts_value: Array) -> Dictionary:
	var expected_source_ids: Array[String] = []
	for source_id_value: Variant in expected_source_ids_value:
		if not source_id_value is String or String(source_id_value).is_empty() \
				or String(source_id_value) in expected_source_ids:
			return _pending("tree_source_record_projection_expected_ids_invalid")
		expected_source_ids.append(String(source_id_value))
	expected_source_ids.sort()
	if expected_source_ids.is_empty() or source_artifacts_value.size() != expected_source_ids.size():
		return _pending("tree_source_record_projection_set_incomplete")
	var artifact_by_id: Dictionary = {}
	for artifact_value: Variant in source_artifacts_value:
		if not artifact_value is Dictionary or not artifact_value.is_read_only():
			return _pending("tree_source_record_projection_artifact_unsealed")
		var artifact: Dictionary = artifact_value
		if String(artifact.get("schema", "")) != SOURCE_RECORD_ARTIFACT_SCHEMA \
				or String(artifact.get("status", "")) != "ready" \
				or String(artifact.get("worldId", "")) != world_id \
				or artifact.get("sourceChunkKey", null) != source_chunk \
				or String(artifact.get("sourceRevision", "")) != source_revision \
				or String(artifact.get("treeFamilyRevision", "")) != family_revision \
				or String(artifact.get("treeFamilyManifestDigest", "")) != family_manifest_digest \
				or String(artifact.get("sourceArtifactDigest", "")).length() != 64:
			return _pending("tree_source_record_projection_artifact_identity_mismatch")
		var source_id := String(artifact.get("sourceId", ""))
		var sources_value: Variant = artifact.get("sources", null)
		if source_id.is_empty() or artifact_by_id.has(source_id) \
				or not sources_value is Array or sources_value.size() != 1 \
				or not sources_value[0] is Dictionary \
				or String(sources_value[0].get("sourceId", "")) != source_id \
				or String(sources_value[0].get("sourceRecordDigest", "")) \
				!= String(artifact.get("sourceRecordDigest", "")):
			return _pending("tree_source_record_projection_source_manifest_mismatch")
		artifact_by_id[source_id] = artifact
	var sources: Array = []
	var batches: Array = []
	var resource_bindings: Dictionary = {}
	var source_artifact_digests: Array[Dictionary] = []
	for source_id: String in expected_source_ids:
		if not artifact_by_id.has(source_id):
			return _pending("tree_source_record_projection_source_missing", {"sourceId":source_id})
		var artifact: Dictionary = artifact_by_id[source_id]
		sources.append(artifact.get("sources", [])[0])
		source_artifact_digests.append({"sourceId":source_id,
			"sourceRecordDigest":String(artifact.get("sourceRecordDigest", "")),
			"sourceArtifactDigest":String(artifact.get("sourceArtifactDigest", ""))})
		var resource_bindings_value: Variant = artifact.get("resourceBindings", null)
		if not resource_bindings_value is Dictionary:
			return _pending("tree_source_record_projection_resource_bindings_invalid")
		for batch_value: Variant in artifact.get("batches", []):
			if not batch_value is Dictionary or not batch_value.is_read_only():
				return _pending("tree_source_record_projection_batch_unsealed")
			var batch: Dictionary = batch_value
			if batch.get("sectionKey", null) != section_key:
				continue
			batches.append(batch)
			for resource_key_value: Variant in [String(batch.get("meshKey", "")),
					String(batch.get("materialKey", ""))]:
				var resource_key := String(resource_key_value)
				if resource_key.is_empty() or not resource_bindings_value.has(resource_key):
					return _pending("tree_source_record_projection_resource_missing")
				var resource: Variant = resource_bindings_value[resource_key]
				if not resource is Resource or not is_instance_valid(resource):
					return _pending("tree_source_record_projection_resource_invalid")
				if resource_bindings.has(resource_key) \
						and not is_same(resource_bindings[resource_key], resource):
					return _pending("tree_source_record_projection_resource_alias_conflict")
				resource_bindings[resource_key] = resource
	sources.make_read_only()
	batches.make_read_only()
	resource_bindings.make_read_only()
	var proof := _build_band_completion_proof(section_key, expected_source_ids,
		sources, batches, resource_bindings)
	if String(proof.get("status", "")) != "ready":
		return proof
	source_artifact_digests.make_read_only()
	var output := {"status":"ready", "schema":BAND_ARTIFACT_SCHEMA,
		"worldId":world_id, "sourceChunkKey":source_chunk,
		"sectionKey":section_key, "sourceRevision":source_revision,
		"treeFamilyRevision":family_revision,
		"treeFamilyManifestDigest":family_manifest_digest,
		"authorityDigest":String(authority.get("authorityDigest", "")),
		"expectedSourceIds":expected_source_ids,
		"sourceArtifactDigests":source_artifact_digests,
		"sources":sources, "batches":batches,
		"resourceBindings":resource_bindings,
		"sourceCompletionManifest":proof.get("sourceCompletionManifest", []),
		"sourceCompletionDigest":_digest_value(proof.get("sourceCompletionManifest", [])),
		"ownerBatchContributors":proof.get("ownerBatchContributors", []),
		"ownerBatchPayloadDigest":_digest_value(proof.get("ownerBatchContributors", [])),
		"disposition":String(proof.get("disposition", "")),
		"oldRepresentationRetention":"caller_owned_until_receipt"}
	if String(output.get("sourceCompletionDigest", "")).length() != 64 \
			or String(output.get("ownerBatchPayloadDigest", "")).length() != 64:
		return _pending("tree_source_record_projection_digest_failed")
	_deep_freeze(output)
	return {"status":"ready", "artifact":output,
		"sourceCompileCount":source_artifacts_value.size(),
		"sourceIds":expected_source_ids}


func _prepare_immutable_source_record(main: Object, world_id: String,
		source: Dictionary, provenance: Dictionary,
		catalog_artifact: Dictionary, publication_view: Dictionary,
		publication_token: String) -> Dictionary:
	if String(source.get("schema", "")) != IMMUTABLE_SOURCE_RECORD_SCHEMA \
			or String(source.get("producerFamily", "")) != "trees" \
			or String(source.get("kind", "")) != "trees_foliage" \
			or int(source.get("recipeVersion", 0)) != 2:
		return _pending("tree_source_record_schema_or_family_invalid")
	var source_id := String(source.get("sourceId", ""))
	var prop_id := String(source.get("propId", ""))
	var chunk: Variant = source.get("sourceChunkKey", null)
	var source_revision := String(source.get("sourceRevision", ""))
	var producer_revision := String(source.get("producerRevision", ""))
	var source_transform: Variant = source.get("transform", null)
	var source_origin: Variant = source.get("sourceOrigin", null)
	var runtime_spec: Variant = source.get("runtimeSpec", null)
	var legacy_spec: Variant = source.get("legacySpec", null)
	var support_proof: Variant = source.get("supportProof", null)
	if source_id.is_empty() or prop_id.is_empty() or not chunk is Vector2i \
			or chunk != provenance.get("sourceChunkKey", null) \
			or source_revision.is_empty() or producer_revision.is_empty() \
			or not source_transform is Transform3D or not source_transform.is_finite() \
			or not source_origin is Vector3 or not source_origin.is_finite() \
			or not runtime_spec is Dictionary or not runtime_spec.is_read_only() \
			or not legacy_spec is Dictionary or not legacy_spec.is_read_only() \
			or not support_proof is Dictionary:
		return _pending("tree_source_record_values_incomplete", {"sourceId":source_id})
	var provenance_source_revision := String(provenance.get("sourceRevision", ""))
	var provenance_seed := String(provenance.get("worldSeed", ""))
	if String(provenance.get("worldId", "")) != world_id \
			or provenance_seed.is_empty() or provenance_source_revision.is_empty() \
			or source_revision != provenance_source_revision \
			or producer_revision != provenance_source_revision \
			or String(provenance.get("terrainVolumeChunkRevision", "")).is_empty() \
			or String(provenance.get("structureAdmissionRevision", "")).is_empty() \
			or String(provenance.get("structureAdmissionStatus", "")) != "ready" \
			or String(provenance.get("removedSourceProjectionDigest", "")).length() != 64 \
			or String(source.get("removedSourceProjectionDigest", "")) \
				!= String(provenance.removedSourceProjectionDigest):
		return _pending("tree_source_record_provenance_incomplete", {"sourceId":source_id})
	var runtime_policy: Dictionary = publication_view.get("supportPolicy", {})
	var tree_policy: Dictionary = publication_view.get("familySupportPoliciesById", {}).get("trees", {})
	if String(tree_policy.get("status", "")) != "ready":
		return _pending("tree_source_runtime_support_policy_pending", {
			"supportPolicyStatus":String(tree_policy.get("status", "pending")),
			"supportPolicyReason":String(tree_policy.get("reason", ""))})
	var chunk_size := float(runtime_policy.get("sourceChunkSizeMeters", 0.0))
	if chunk_size <= 0.0:
		return _pending("tree_source_chunk_grid_policy_missing")
	var chunk_origin := Vector3(float(chunk.x) * chunk_size, 0.0,
		float(chunk.y) * chunk_size)
	var chunk_to_world := Transform3D(Basis.IDENTITY, chunk_origin)
	var world_transform: Transform3D = chunk_to_world * source_transform
	if not world_transform.is_finite() or not world_transform.origin.is_equal_approx(source_origin):
		return _pending("tree_source_transform_origin_mismatch", {"sourceId":source_id})
	var request_input: Dictionary = runtime_spec.duplicate(true)
	request_input["treeId"] = prop_id
	request_input["worldSeed"] = provenance_seed
	request_input["biome"] = String(source.get("biome", ""))
	request_input["worldPosition"] = world_transform.origin
	request_input["worldRotationY"] = atan2(-world_transform.basis.x.z,
		world_transform.basis.x.x)
	request_input["renderLodTier"] = String(runtime_spec.get("renderLodTier",
		source.get("renderLodTier", "near")))
	request_input["presentation"] = "runtime"
	var service := SpawnService.new()
	var normalized: Dictionary = service.normalize_request(request_input)
	if normalized.is_empty() or String(normalized.get("worldSeed", "")) != provenance_seed \
			or String(normalized.get("treeId", "")) != prop_id:
		return _pending("tree_source_runtime_spec_invalid", {"sourceId":source_id})
	var current: Variant = main.call("ecology_source_publication_record_is_current",
		publication_view, publication_token, source)
	if not current is Dictionary or current.get("status", "") != "ready":
		return current if current is Dictionary else _pending(
			"ecology_source_currentness_validator_unavailable")
	var source_digest := String(current.get("memberDigest", ""))
	var provenance_digest := String(publication_view.get("contentDigest", ""))
	var request_digest := _digest_value(normalized)
	if source_digest.is_empty() or provenance_digest.is_empty() or request_digest.is_empty():
		return _pending("tree_source_record_digest_failed", {"sourceId":source_id})
	var internal := {"schema":IMMUTABLE_SOURCE_RECORD_SCHEMA,
		"recordMode":"immutable_source", "sourceId":source_id, "propId":prop_id,
		"sourceChunkKey":chunk, "sourceOrigin":source_origin,
		"sourceRevision":source_revision, "producerRevision":producer_revision,
		"sourceDomainRevision":provenance_source_revision,
		"sourceRecord":source, "sourceProvenance":provenance,
		"sourceRecordDigest":source_digest, "sourceProvenanceDigest":provenance_digest,
		"requestDigest":request_digest,
		"request":_deep_frozen(normalized),
		"bodyGlobalTransform":world_transform,
		"logicalOwnerCell":Grid.logical_owner_cell_for_world_position(world_transform.origin),
		"bodyInstanceId":0, "producerGeneration":0,
		"artifactGeneration":maxi(1, int(source.get("artifactGeneration", 1))),
		"renderLodTier":String(normalized.get("renderLodTier", "near")),
		"recipeVersion":2, "contentRevision":"", "recipeSignature":"",
		"recipeSnapshot":{}, "supportEnvelope":{}, "certifiedEnvelopeDigest":"",
		"supportProof":support_proof, "recipeJobKey":""}
	var copy: Dictionary = internal
	return {"status":"ready", "record":copy}


func _immutable_source_currentness(record: Dictionary) -> Dictionary:
	var main_ref := _job.get("main") as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	if not is_instance_valid(main) or not main.has_method("ecology_source_publication_record_is_current"):
		return _pending("ecology_source_currentness_validator_unavailable")
	var source_value: Variant = record.get("sourceRecord", null)
	var provenance_value: Variant = record.get("sourceProvenance", null)
	if not source_value is Dictionary or not provenance_value is Dictionary \
			or not is_same(provenance_value, _job.get("publicationView", {}).get("payload", {})):
		return {"status":"failed", "reason":"tree_source_record_mutated_or_unsealed"}
	var result: Variant = main.call("ecology_source_publication_record_is_current",
		_job.get("publicationView", {}), String(_job.get("publicationLeaseToken", "")), source_value)
	return result if result is Dictionary else _pending(
		"ecology_source_currentness_result_invalid")


func _ensure_immutable_source_recipe(record: Dictionary) -> Dictionary:
	if record.get("recipeSnapshot", {}) is Dictionary \
			and not (record.get("recipeSnapshot", {}) as Dictionary).is_empty():
		return {"status":"ready"}
	var queue_ref := _job.get("queue") as WeakRef
	var queue: Object = queue_ref.get_ref() if queue_ref != null else null
	if not is_instance_valid(queue) or not queue.has_method("poll_ecology_source_recipe"):
		return _pending("tree_source_recipe_queue_unavailable")
	var polled: Variant = queue.call("poll_ecology_source_recipe",
		String(record.get("recipeJobKey", "")), record.sourceRecord,
		record.sourceProvenance, str(get_instance_id()))
	if polled is Dictionary and polled.get("status", "") == "ready" \
			and polled.get("artifact", null) is Dictionary:
		record["recipeArtifact"] = polled.artifact
	if not polled is Dictionary:
		return _pending("tree_source_recipe_poll_result_invalid")
	if polled.get("status", "") != "ready":
		return polled
	var artifact_value: Variant = record.get("recipeArtifact", polled.get("artifact", null))
	if not artifact_value is Dictionary or not artifact_value.is_read_only() \
			or String(artifact_value.get("schema", "")) \
			!= "ecology-tree-source-recipe-artifact/v1" \
			or String(artifact_value.get("sourceId", "")) != String(record.sourceId) \
			or String(artifact_value.get("sourceRevision", "")) != String(record.sourceRevision) \
			or String(artifact_value.get("producerRevision", "")) \
			!= String(record.producerRevision) \
			or String(artifact_value.get("requestDigest", "")) \
			!= String(record.requestDigest) \
			or String(artifact_value.get("sourceRecordDigest", "")) \
			!= String(record.sourceRecordDigest) \
			or String(artifact_value.get("provenanceDigest", "")) \
			!= String(record.sourceProvenanceDigest) \
			or String(artifact_value.get("sourceDomainRevision", "")) \
			!= String(record.sourceDomainRevision) \
			or artifact_value.get("request", null) != record.request:
		return _pending("tree_source_recipe_artifact_identity_invalid")
	var artifact_provenance: Variant = artifact_value.get("provenance", null)
	if not artifact_provenance is Dictionary \
			or not is_same(artifact_provenance, record.sourceProvenance) \
			or String(artifact_provenance.get("sourceRevision", "")) \
			!= String(record.sourceDomainRevision):
		return _pending("tree_source_recipe_artifact_provenance_invalid")
	var recipe_value: Variant = artifact_value.get("recipe", null)
	if not recipe_value is Dictionary or not recipe_value.is_read_only() \
			or recipe_value.is_empty():
		return _pending("tree_source_recipe_artifact_missing")
	var recipe: Dictionary = recipe_value
	var service := SpawnService.new()
	var recipe_signature := String(service.runtime_recipe_signature(recipe, record.request))
	if recipe_signature.is_empty() or recipe_signature != String(recipe.get("signature", "")):
		return _pending("tree_source_recipe_signature_or_lod_invalid")
	var envelope_result := certify_recipe_support_envelope(recipe,
		record.bodyGlobalTransform)
	if envelope_result.get("status") != "ready":
		return envelope_result
	var envelope: Dictionary = envelope_result.value
	var support_proof: Dictionary = record.get("supportProof", {})
	var artifact_result := _resolve_tree_catalog_artifact()
	if artifact_result.get("status") != "ready":
		return artifact_result
	var catalog_artifact: Dictionary = artifact_result.artifact
	var compact_inputs: Variant = record.sourceProvenance.get("sourceInputs", null)
	if not compact_inputs is Dictionary:
		return _pending("tree_source_support_policy_inputs_missing")
	var publication_view: Dictionary = _job.get("publicationView", {})
	var policy: Dictionary = publication_view.get("supportPolicy", {})
	var family_policy: Dictionary = publication_view.get("familySupportPoliciesById", {}).get("trees", {})
	if String(family_policy.get("status", "")) != "ready":
		return _pending("tree_source_runtime_support_policy_pending", {
			"supportPolicyStatus":String(policy.get("status", "pending")),
			"supportPolicyReason":String(policy.get("reason", ""))})
	var declared_bounds: Variant = support_proof.get("worldBounds", null)
	var proof_origin: Variant = support_proof.get("sourceOrigin", null)
	if String(support_proof.get("status", "")) != "ready" \
			or String(support_proof.get("family", "")) != "trees" \
			or not proof_origin is Vector3 \
			or not proof_origin.is_equal_approx(record.sourceOrigin) \
			or not declared_bounds is AABB \
			or String(support_proof.get("influencePolicyRevision", "")) \
			!= String(policy.get("revision", "")) \
			or String(support_proof.get("influencePolicyDigest", "")) \
			!= String(policy.get("digest", "")) \
			or not _bounds_contains(declared_bounds, envelope.worldBounds):
		return _pending("tree_source_family_envelope_unproven", {
			"sourceId":String(record.sourceId),
			"supportPolicyStatus":String(policy.get("status", "pending"))})
	var source_bounds := ProducerDomain.validate_source_bounds("trees",
		record.sourceOrigin, envelope.worldBounds, policy)
	if source_bounds.get("status") != "ready":
		return {"status":String(source_bounds.get("status", "pending")),
			"reason":String(source_bounds.get("reason", "tree_source_bounds_unproven")),
			"sourceId":String(record.sourceId), "supportPolicyEvidence":source_bounds,
			"retryable":true}
	var content_revision := immutable_source_content_revision(
		String(record.sourceDomainRevision), String(record.sourceRevision),
		String(record.producerRevision), String(record.sourceRecordDigest),
		String(record.sourceProvenanceDigest), String(recipe_signature),
		record.request, recipe, envelope)
	if content_revision.is_empty():
		return _pending("tree_source_recipe_content_digest_failed")
	record["recipeSnapshot"] = recipe
	record["recipeSignature"] = recipe_signature
	record["supportEnvelope"] = envelope
	record["certifiedEnvelopeDigest"] = String(envelope.get("certifiedEnvelopeDigest", ""))
	record["contentRevision"] = content_revision
	if is_instance_valid(queue) and queue.has_method("consume_ecology_source_recipe"):
		queue.call("consume_ecology_source_recipe", String(record.recipeJobKey),
			str(get_instance_id()))
	record["recipeJobConsumed"] = true
	return {"status":"ready"}


func _digest_value(value: Variant) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(value)) != OK:
		return ""
	return context.finish().hex_encode()


## Recipe builder timings are profiling output, not deterministic source content.
## Preserve the sealed recipe for rendering and observability; hash a shallow
## owned projection that omits only stats.timingUsec. Geometry and other nested
## immutable values remain shared with the admitted recipe.
static func immutable_source_content_revision(source_domain_revision: String,
		source_revision: String, producer_revision: String, source_record_digest: String,
		source_provenance_digest: String, recipe_signature: String,
		request: Dictionary, recipe: Dictionary, support_envelope: Dictionary) -> String:
	if recipe.is_empty():
		return ""
	var identity_recipe: Dictionary = recipe.duplicate(false)
	var stats_value: Variant = recipe.get("stats", null)
	if stats_value is Dictionary:
		var identity_stats: Dictionary = (stats_value as Dictionary).duplicate(false)
		identity_stats.erase("timingUsec")
		identity_stats.make_read_only()
		identity_recipe["stats"] = identity_stats
	identity_recipe.make_read_only()
	var content := [IMMUTABLE_SOURCE_RECORD_SCHEMA, source_domain_revision,
		source_revision, producer_revision, source_record_digest,
		source_provenance_digest, recipe_signature, request, identity_recipe,
		support_envelope]
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(content)) != OK:
		return ""
	return context.finish().hex_encode()


func _deep_frozen(value: Variant) -> Variant:
	if value is Dictionary:
		var frozen: Dictionary = {}
		for key: Variant in value:
			frozen[key] = _deep_frozen(value[key])
		frozen.make_read_only()
		return frozen
	if value is Array:
		var frozen: Array = []
		for item: Variant in value:
			frozen.append(_deep_frozen(item))
		frozen.make_read_only()
		return frozen
	return value


func _source_value_tree_is_node_free(value: Variant) -> bool:
	if value is Object or value is RID or value is Callable or value is Signal:
		return false
	if value is Dictionary:
		for key: Variant in value:
			if not _source_value_tree_is_node_free(key) \
					or not _source_value_tree_is_node_free(value[key]): return false
	elif value is Array:
		for child: Variant in value:
			if not _source_value_tree_is_node_free(child): return false
	return true


func _source_value_tree_is_read_only(value: Variant) -> bool:
	if value is Dictionary:
		if not value.is_read_only(): return false
		for key: Variant in value:
			if not _source_value_tree_is_read_only(key) \
					or not _source_value_tree_is_read_only(value[key]): return false
	elif value is Array:
		if not value.is_read_only(): return false
		for child: Variant in value:
			if not _source_value_tree_is_read_only(child): return false
	return true


func _validate_record(main: Object, world_id: String, record: Dictionary,
		removed_snapshot: Dictionary) -> Dictionary:
	if String(record.get("schema", "")) != "tree-section-recipe-input/v1" \
			or int(record.get("worldOwnerInstanceId", 0)) != main.get_instance_id():
		return _pending("tree_recipe_artifact_identity_invalid")
	var check := _record_currentness(main, world_id, record, removed_snapshot)
	return {"status":"ready"} if check else _pending("tree_recipe_artifact_stale")


func _current(record: Dictionary) -> bool:
	var main_ref := _job.main as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	if String(record.get("recordMode", "legacy_owner")) == "immutable_source":
		return is_instance_valid(main) \
			and main.get_instance_id() == int(_job.mainInstanceId) \
			and _immutable_source_currentness(record).get("status") == "ready"
	return is_instance_valid(main) and main.get_instance_id() == int(_job.mainInstanceId) \
		and _record_currentness(main, String(_job.worldId), record, _job.removedSnapshot)


func _record_currentness(main: Object, world_id: String, record: Dictionary,
		removed_snapshot: Dictionary) -> bool:
	var body_ref := record.get("body") as WeakRef
	var body := body_ref.get_ref() as StaticBody3D if body_ref != null else null
	if not is_instance_valid(body) or not body.is_inside_tree() or body.is_queued_for_deletion() \
			or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
			or int(record.get("worldOwnerInstanceId", 0)) != main.get_instance_id() \
			or not (record.get("bodyGlobalTransform") as Transform3D).is_equal_approx(body.global_transform) \
			or String(body.get_meta("prop_id", "")) != String(record.get("propId", "")) \
			or bool(body.get_meta("tree_publication_cancelled", false)):
		return false
	var expected_generation := int(body.get_meta("tree_section_recipe_input_expected_generation", 0))
	if expected_generation > 0 and expected_generation != int(record.get("producerGeneration", 0)):
		return false
	if String(record.get("worldSeed", "")) != String(main.get("seed_text")) \
			or not RemovedProps.is_current_for_ids(main, removed_snapshot, [String(record.propId)]) \
			or (removed_snapshot.get("ids", []) as Array).has(String(record.propId)):
		return false
	var service := SpawnService.new()
	var normalized: Dictionary = service.normalize_request(record.get("request", {}))
	var recipe: Dictionary = record.get("recipeSnapshot", {})
	if normalized.is_empty() or normalized != record.get("request", {}) \
			or String(service.runtime_recipe_signature(recipe, normalized)) != String(record.get("recipeSignature", "")):
		return false
	var envelope_value: Variant = record.get("supportEnvelope", null)
	var computed_envelope := certify_recipe_support_envelope(recipe,
		record.get("bodyGlobalTransform", Transform3D.IDENTITY))
	if computed_envelope.get("status") != "ready" or not envelope_value is Dictionary \
			or computed_envelope.value != envelope_value \
			or String(record.get("certifiedEnvelopeDigest", "")) \
			!= String(envelope_value.get("certifiedEnvelopeDigest", "")):
		return false
	var context := HashingContext.new()
	var content := [String(record.get("schema", "")), "tree-recipe-section-compiler/v1",
		String(record.get("worldSeed", "")), String(record.get("propId", "")),
		String(record.get("renderLodTier", "")), String(record.get("recipeSignature", "")),
		record.get("request", {}), recipe, envelope_value]
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(var_to_bytes(content)) != OK:
		return false
	return context.finish().hex_encode() == String(record.get("contentRevision", "")) \
		and String(record.get("renderLodTier", "")) == String(recipe.get("renderLod", {}).get("tier", ""))


static func _bounds_contains(outer: AABB, inner: AABB, epsilon := 0.002) -> bool:
	return inner.position.x >= outer.position.x - epsilon \
		and inner.position.y >= outer.position.y - epsilon \
		and inner.position.z >= outer.position.z - epsilon \
		and inner.end.x <= outer.end.x + epsilon \
		and inner.end.y <= outer.end.y + epsilon \
		and inner.end.z <= outer.end.z + epsilon


func _source_identities(records: Array) -> Array:
	var ids: Array = []
	for record: Dictionary in records:
		ids.append([String(record.get("sourceId", "")),
			String(record.get("sourceDomainRevision", "")),
			String(record.get("producerRevision", "")),
			String(record.get("sourceRecordDigest", "")),
			String(record.get("sourceProvenanceDigest", "")),
			String(record.get("contentRevision", "")),
			int(record.get("bodyInstanceId", 0)), int(record.get("producerGeneration", 0))])
	_deep_freeze(ids)
	return ids


func _typed_dictionary_array(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not value is Array:
		return result
	for item: Variant in value:
		if item is Dictionary:
			result.append(item)
	return result


func _source_prop_ids() -> Array:
	var ids: Array = []
	for record: Dictionary in _job.records:
		ids.append(String(record.get("propId", "")))
	return ids


func _source_section_keys(source_sections: Dictionary) -> Array:
	var keys: Array[Vector3i] = []
	for key: Variant in source_sections.keys():
		if key is Vector3i: keys.append(key)
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	_deep_freeze(keys)
	return keys


func _freeze_ownership(rows: Array) -> Array:
	var frozen: Array = rows.duplicate(true)
	_deep_freeze(frozen)
	return frozen


func _resources_current() -> bool:
	for key_value: Variant in _job.bindings.keys():
		var key := String(key_value)
		var resource: Variant = _job.bindings[key_value]
		if key.begins_with("tree.runtime."):
			if not resource is Mesh: return false
			var current_mesh := MeshFingerprint.inspect(resource as Mesh)
			if current_mesh.get("status") != "ready" \
					or not key.contains(String(current_mesh.get("contentDigest", ""))):
				return false
		elif key.begins_with("tree.material."):
			if not resource is Material: return false
			var digest := Adapter._material_digest(resource as Material)
			if digest.is_empty() or not key.ends_with(digest): return false
		else:
			return false
	return true


func _freeze_contributors(contributors: Dictionary, manifest: Array,
		canonical_typed_buffers: bool = false) -> Dictionary:
	var copy := {}
	for member_key_value: Variant in contributors:
		var member_value: Variant = contributors[member_key_value]
		if not member_value is Dictionary:
			return {}
		var member: Dictionary = member_value
		var source_id := String(member.get("sourceId", ""))
		var source_part_id := String(member.get("sourcePartId", ""))
		var identity_key := _source_part_identity_key(source_id, source_part_id)
		if identity_key.is_empty() or identity_key != String(member_key_value):
			return {}
		var attributes_value: Variant = member.get("instanceAttributes", null)
		var offsets_value: Variant = member.get("instanceAttributeOffsets", null)
		if not attributes_value is Array or not offsets_value is Array \
				or attributes_value.size() % Attributes.FLOATS_PER_INSTANCE != 0 \
				or offsets_value.size() != attributes_value.size() \
				/ Attributes.FLOATS_PER_INSTANCE:
			return {}
		var attributes: Array
		if canonical_typed_buffers:
			if attributes_value.get_typed_builtin() == TYPE_FLOAT \
					and attributes_value.is_read_only():
				attributes = attributes_value
			else:
				var typed_attributes: Array[float] = []
				for component_value: Variant in attributes_value:
					if not component_value is float or not is_finite(float(component_value)):
						return {}
					typed_attributes.append(float(component_value))
				typed_attributes.make_read_only()
				attributes = typed_attributes
		else:
			attributes = attributes_value.duplicate()
			attributes.make_read_only()
		var offsets: Array = offsets_value.duplicate()
		offsets.make_read_only()
		var source_revision := ""
		for source_value: Variant in manifest:
			if source_value is Dictionary and String(source_value.get("sourceId", "")) == String(source_id):
				source_revision = String(source_value.get("sourceRevision", ""))
				break
		if source_revision.is_empty():
			return {}
		copy[identity_key] = {"sourceId":source_id,
			"sourcePartId":source_part_id, "sourceRevision":source_revision,
			"instanceCount":attributes.size() / Attributes.FLOATS_PER_INSTANCE,
			"instanceAttributeOffsets":offsets, "instanceAttributes":attributes}
	_deep_freeze(copy)
	return copy


static func _deep_freeze(value: Variant) -> void:
	if value is Dictionary:
		for nested: Variant in value.values(): _deep_freeze(nested)
		(value as Dictionary).make_read_only()
	elif value is Array:
		for nested: Variant in value: _deep_freeze(nested)
		(value as Array).make_read_only()


static func _source_part_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


func _discard(reason: String) -> Dictionary:
	_cancel_native_tree_compile()
	_cancel_active_source_recipe_jobs()
	if String(_job.get("mode", "")) in ["immutable_source", "legacy_section"]:
		var catalog_token := String(_job.get("catalogLeaseToken", ""))
		if not catalog_token.is_empty() and not bool(_job.get("catalogLeaseReleased", true)):
			var main_ref: WeakRef = _job.get("main") as WeakRef
			var main: Object = main_ref.get_ref() if main_ref != null else null
			if is_instance_valid(main) and main.has_method("release_ecology_catalog_artifact_lease"):
				main.call("release_ecology_catalog_artifact_lease", catalog_token)
		_job["catalogLeaseToken"] = ""
		_job["catalogLeaseReleased"] = true
		_job["status"] = "failed"
		_job["failureReason"] = reason
		return {"status":"failed", "reason":reason, "retryable":false}
	_release_catalog_lease()
	_job.clear()
	return _pending(reason)


func _resolve_tree_catalog_artifact() -> Dictionary:
	var main_ref := _job.get("main") as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	var token := String(_job.get("catalogLeaseToken", ""))
	if not is_instance_valid(main) or token.is_empty() \
			or not main.has_method("resolve_ecology_catalog_artifact"):
		return _pending("tree_catalog_lease_owner_unavailable")
	var resolved: Variant = main.call("resolve_ecology_catalog_artifact", token,
		String(_job.get("worldId", "")), int(_job.get("worldEpoch", -1)))
	var artifact: Variant = resolved.get("artifact", resolved) \
		if resolved is Dictionary else {}
	var resolved_artifact_id := String(artifact.get("artifactId",
		artifact.get("catalogArtifactId", ""))) if artifact is Dictionary else ""
	if not resolved is Dictionary or String(resolved.get("status", "")) != "ready" \
			or not artifact is Dictionary \
			or resolved_artifact_id != String(_job.get("catalogArtifactId", "")) \
			or String(artifact.get("catalogContentDigest", "")) \
			!= String(_job.get("catalogContentDigest", "")) \
			or int(artifact.get("worldEpoch", -1)) != int(_job.get("worldEpoch", -1)):
		return _pending("tree_catalog_artifact_became_stale")
	var policy: Variant = artifact.get("supportPolicy", null)
	if not policy is Dictionary \
			or String(policy.get("revision", "")) != String(_job.get("influencePolicyRevision", "")) \
			or String(policy.get("digest", "")) != String(_job.get("influencePolicyDigest", "")):
		return _pending("tree_catalog_policy_became_stale")
	if not artifact.get("catalogInputs", null) is Dictionary:
		return _pending("tree_catalog_inputs_missing")
	return {"status":"ready", "artifact":artifact}


func _catalog_lease_current() -> Dictionary:
	var resolved := _resolve_tree_catalog_artifact()
	if resolved.get("status") != "ready": return resolved
	if String(_job.get("mode", "")) == "immutable_source":
		var main_ref := _job.get("main") as WeakRef
		var main: Object = main_ref.get_ref() if main_ref != null else null
		if not is_instance_valid(main): return _pending("tree_source_publication_owner_unavailable")
		return main.call("ecology_source_publication_local_is_current", _job.get("publicationView", {}),
			String(_job.get("publicationLeaseToken", "")))
	return {"status":"ready"}


func _release_catalog_lease() -> void:
	var publication_token := String(_job.get("publicationLeaseToken", ""))
	if not publication_token.is_empty():
		_job["publicationLeaseToken"] = ""
		var publication_main_ref := _job.get("main") as WeakRef
		var publication_main: Object = publication_main_ref.get_ref() if publication_main_ref != null else null
		if is_instance_valid(publication_main):
			publication_main.call("release_ecology_source_publication", publication_token)
	if _job.is_empty() or bool(_job.get("catalogLeaseReleased", true)):
		return
	_job.catalogLeaseReleased = true
	var main_ref := _job.get("main") as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	var token := String(_job.get("catalogLeaseToken", ""))
	if is_instance_valid(main) and not token.is_empty() \
			and main.has_method("release_ecology_catalog_artifact_lease"):
		main.call("release_ecology_catalog_artifact_lease", token)


func _cancel_active_source_recipe_jobs() -> void:
	if String(_job.get("mode", "")) != "immutable_source":
		return
	var queue_ref := _job.get("queue") as WeakRef
	var queue: Object = queue_ref.get_ref() if queue_ref != null else null
	if not is_instance_valid(queue) or not queue.has_method("cancel_ecology_source_recipe"):
		return
	for record_value: Variant in _job.get("records", []):
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		if bool(record.get("recipeJobConsumed", false)):
			continue
		queue.call("cancel_ecology_source_recipe", String(record.get("recipeJobKey", "")),
			str(get_instance_id()))


func _cancel_source_recipe_jobs(queue: Object, records: Array) -> void:
	if not is_instance_valid(queue) or not queue.has_method("cancel_ecology_source_recipe"):
		return
	for record_value: Variant in records:
		if record_value is Dictionary:
			queue.call("cancel_ecology_source_recipe",
				String(record_value.get("recipeJobKey", "")), str(get_instance_id()))


func _pending(reason: String, details: Dictionary = {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":true}
	for key_value: Variant in details.keys():
		var key := String(key_value)
		if key not in ["status", "reason", "retryable"]:
			result[key] = details[key_value]
	return result


func _cancel_native_tree_compile() -> void:
	if _job.is_empty(): return
	var dispatcher: Object = _job.get("nativeTreeGeometryDispatcher")
	if is_instance_valid(dispatcher):
		for record_value: Variant in _job.get("records", []):
			if not record_value is Dictionary: continue
			var record: Dictionary = record_value
			var record_ticket := int(record.get("nativeTreeRecordTicket", 0))
			if record_ticket > 0:
				dispatcher.call("cancel_tree_geometry_compile", record_ticket)
				dispatcher.call("release_tree_geometry_compile", record_ticket)
				record.erase("nativeTreeRecordTicket")
	var state: Dictionary = _job.get("buildState", {})
	var ticket := int(state.get("nativeTicket", 0))
	dispatcher = state.get("nativeDispatcher", dispatcher)
	if ticket > 0 and is_instance_valid(dispatcher):
		dispatcher.call("cancel_tree_geometry_compile", ticket)
		dispatcher.call("release_tree_geometry_compile", ticket)
		state.erase("nativeTicket")
	var compile_state: Dictionary = _job.get("compileState", {})
	var pack_ticket := int(compile_state.get("nativePackTicket", 0))
	var pack_dispatcher: Object = compile_state.get("nativePackDispatcher", dispatcher)
	if pack_ticket > 0 and is_instance_valid(pack_dispatcher):
		pack_dispatcher.call("cancel_tree_geometry_compile", pack_ticket)
		pack_dispatcher.call("release_tree_geometry_compile", pack_ticket)
		compile_state.erase("nativePackTicket")
