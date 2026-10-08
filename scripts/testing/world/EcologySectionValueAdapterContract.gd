extends SceneTree

const Adapter := preload("res://scripts/world/EcologySectionValueAdapter.gd")
const Ledger := preload("res://scripts/world/EcologySourceValueLedger.gd")
const InstanceAttributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Roster := preload("res://scripts/world/StaticSectionSourceRoster.gd")
const Assembler := preload("res://scripts/world/WorldStaticSectionCandidateAssembler.gd")
const RemovedProps := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const DetailSourceValues := preload("res://scripts/world/EcologyDetailSourceValueBuilder.gd")
const ProducerDomain := preload("res://scripts/world/EcologyProducerDomain.gd")
const SupportIndex := preload("res://scripts/world/EcologyWorldSupportIndex.gd")
const SectionCoordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const BiomeCatalog := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const BiomeSnapshot := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
const TreeQueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const TreeCompilerScript := preload("res://scripts/world/TreeRecipeSectionCompiler.gd")
const CertifiedTreeRequestFixture := preload("res://scripts/testing/CertifiedTreeRequestFixture.gd")
const CompiledTreeSectionArtifact := preload("res://scripts/world/CompiledTreeSectionArtifact.gd")

class FairSchedulerAdapter extends "res://scripts/world/EcologySectionValueAdapter.gd":
	var sealed_sections: Array[Vector3i] = []

	func _seal_retained_section_preparation(_main: Object,
			preparation: Dictionary) -> Dictionary:
		var section_key := Vector3i(preparation.get("sectionKey", Vector3i.ZERO))
		sealed_sections.append(section_key)
		return {"status":"complete", "sectionKey":section_key}

class TerminalFailureSchedulerAdapter extends "res://scripts/world/EcologySectionValueAdapter.gd":
	func _advance_next_source_section_preparation_step(_main: Object) -> Dictionary:
		var preparation_key := String(_source_section_preparation_order[0])
		var preparation: Dictionary = _source_section_preparations[preparation_key]
		return _fail_source_section_preparation(Vector3i(preparation.get(
			"sectionKey", Vector3i.ZERO)), preparation,
			"fixture_terminal_preparation_failure")

class TerminalRegistrationSchedulerAdapter extends "res://scripts/world/EcologySectionValueAdapter.gd":
	var band_queue: Object
	var band_demand: Dictionary = {}
	var band_section := Vector3i.ZERO
	var band_source_chunk := Vector2i.ZERO
	var band_consumer_token := ""
	var band_authority_digest := ""
	var use_first_poll := false
	var first_poll_main: Object
	var first_poll_snapshot: Dictionary = {}
	var first_poll_bundle: Dictionary = {}
	var first_poll_publication_view: Dictionary = {}
	var first_poll_lease_token := ""

	func _advance_next_source_section_preparation_step(_main: Object) -> Dictionary:
		var registration_result: Dictionary = {}
		if use_first_poll:
			registration_result = _admit_compile_register_tree_band(first_poll_main,
				_world_id, "fixture-first-poll-capture", band_source_chunk,
				band_section, first_poll_snapshot, first_poll_bundle,
				first_poll_publication_view, first_poll_lease_token)
		else:
			var resolved: Dictionary = _resolve_existing_tree_band_demand(band_queue,
				band_demand, band_authority_digest, band_consumer_token,
				band_source_chunk, band_section)
			registration_result = resolved.get("result", {})
		return {"status":"pending", "reason":"fixture_registration_pending_wrapper",
			"registration":registration_result}

class FixtureTreeBandAdmissionIndex extends SupportIndex:
	var authority: Dictionary = {}

	func admit_tree_source_family_section_band(_world_id: String,
			_source_chunk_key: Vector2i, _section_key: Vector3i,
			_source_snapshot: Dictionary, _projected_bundle: Dictionary,
			_publication_view: Dictionary, _publication_lease_token: String) -> Dictionary:
		return {"status":"ready", "authority":authority}

	func register_tree_section_geometry_overlay(_world_id: String,
			_source_chunk_key: Vector2i, _section_key: Vector3i,
			_projected_source_ids: Array, _compiled_artifact: Dictionary,
			_support_rows: Array) -> Dictionary:
		return {"status":"ready"}

class CachedRowScanAdapter extends "res://scripts/world/EcologySectionValueAdapter.gd":
	var cached_rows_visited := 0

	func _prepare_retained_source_family(_main: Object, _preparation: Dictionary,
			_plan: Dictionary, _snapshot: Dictionary, _publication_view: Dictionary,
			_lease: String, _family: String, _source_row: Dictionary) -> Dictionary:
		cached_rows_visited += 1
		return {"status":"ready", "supportRows":[], "memberArtifacts":[],
			"cacheHit":true}

class PreparationCurrentAuthority extends RefCounted:
	var seed_text := "seed:section-preparation-cache-scan"
	var world_static_section_coordinator: Object

	func ecology_source_publication_local_is_current(_view: Dictionary,
			_lease: String) -> Dictionary:
		return {"status":"ready"}

class FixturePreparationWakeCoordinator extends RefCounted:
	var wakes: Array[Dictionary] = []

	func wake_visible_section_demand(section_key: Vector3i, reason: String,
			wake_token: String) -> void:
		wakes.append({"sectionKey":section_key, "reason":reason,
			"wakeToken":wake_token})

class FixtureTreeAdmissionMain extends RefCounted:
	var tree_publication_queue: Object
	var world_static_section_coordinator: Object

class FixtureWorldGeneration extends RefCounted:
	func terrain_volume_chunk_revision(_key: Vector2i, _chunk_size: int) -> String:
		return "synthetic-terrain-revision-v1"

class FixtureStructureAuthority extends RefCounted:
	var revision := "synthetic-structure-revision-v1"

	func region_dependency_revision(_bounds: Rect2i) -> String:
		return revision

class FixtureWorldCoordinator extends RefCounted:
	var identity := ""

	func world_identity() -> String:
		return identity

class FixtureTreeQueue extends Node:
	var pending_reason := "ecology_tree_queue_geometry_not_committed"
	var poll_status := "pending"
	var request_count := 0
	var poll_count := 0
	var poll_artifact: Dictionary = {"status":"ready", "sources":[]}
	var poll_tokens: Array[String] = []
	var last_source_ids: Array[String] = []
	var consumers_by_job: Dictionary = {}
	var cancellations: Array[Dictionary] = []
	var band_jobs: Dictionary = {}
	var last_band_authority: Dictionary = {}
	var last_band_artifact: Dictionary = {}
	var last_band_request_reason := ""

	func request_ecology_tree_source_band_compile(main: Object,
			snapshot: Dictionary, section_key: Vector3i, authority: Dictionary,
			publication_view: Dictionary = {}, consumer_token := "",
			_priority_distance_squared := INF) -> Dictionary:
		last_band_authority = authority
		last_band_artifact = {}
		last_band_request_reason = ""
		var source_chunk: Variant = snapshot.get("sourceChunkKey", null)
		var expected_ids: Variant = authority.get("producerSourceIds", null)
		var tree_family: Dictionary = publication_view.get("familyResultsById", {}).get(
			"trees", {})
		var tree_rows: Variant = tree_family.get("sourceRows", null)
		if not is_instance_valid(main) or not snapshot.is_read_only() \
				or not authority.is_read_only() or not publication_view.is_read_only() \
				or not source_chunk is Vector2i or not expected_ids is Array \
				or expected_ids != [] or not tree_rows is Array or not tree_rows.is_empty() \
				or String(tree_family.get("status", "")) != "ready" \
				or authority.get("sectionKey", null) != section_key \
				or authority.get("sourceChunkKey", null) != source_chunk \
				or String(authority.get("worldId", "")) != String(snapshot.get("worldId", "")) \
				or String(authority.get("sourceRevision", "")) != String(
					snapshot.get("sourceRevision", "")) \
				or String(authority.get("sourceFamilyRevision", "")) != String(
					tree_family.get("familyRevision", "")) \
				or String(authority.get("sourceFamilyManifestDigest", "")) != String(
					tree_family.get("sourceManifestDigest", "")) \
				or not is_same(snapshot, publication_view.get("payload", {})):
			last_band_request_reason = "fixture_tree_band_not_authoritatively_empty"
			return {"status":"pending", "reason":last_band_request_reason,
				"retryable":true}
		if not main.has_method("ecology_source_publication_local_is_current"):
			last_band_request_reason = "fixture_tree_band_publication_stale"
			return {"status":"pending", "reason":last_band_request_reason,
				"retryable":true}
		var publication_current: Variant = main.call(
			"ecology_source_publication_local_is_current", publication_view,
			String(authority.get("publicationLeaseToken", "")))
		if not publication_current is Dictionary \
				or String(publication_current.get("status", "")) != "ready":
			last_band_request_reason = "fixture_tree_band_publication_stale"
			return {"status":"pending", "reason":last_band_request_reason,
				"retryable":true}
		var empty_digest := _var_bytes_digest([])
		if empty_digest.is_empty():
			last_band_request_reason = "fixture_tree_band_empty_digest_failed"
			return {"status":"pending", "reason":last_band_request_reason,
				"retryable":true}
		var artifact_value: Variant = ProducerDomain.freeze_value({
			"status":"ready", "schema":"compiled-tree-section-source/v2",
			"worldId":String(snapshot.get("worldId", "")),
			"sourceChunkKey":source_chunk, "sectionKey":section_key,
			"sourceRevision":String(snapshot.get("sourceRevision", "")),
			"treeFamilyRevision":String(tree_family.get("familyRevision", "")),
			"treeFamilyManifestDigest":String(tree_family.get("sourceManifestDigest", "")),
			"authorityDigest":String(authority.get("authorityDigest", "")),
			"expectedSourceIds":[], "sourceArtifactDigests":[],
			"sourceCompletionManifest":[],
			"sourceCompletionDigest":empty_digest, "sources":[], "batches":[],
			"resourceBindings":{}, "ownerBatchContributors":[],
			"ownerBatchPayloadDigest":empty_digest,
			"disposition":"complete_empty",
			"oldRepresentationRetention":"caller_owned_until_receipt"})
		if not artifact_value is Dictionary or not artifact_value.is_read_only():
			last_band_request_reason = "fixture_tree_band_empty_artifact_unsealed"
			return {"status":"pending", "reason":last_band_request_reason,
				"retryable":true}
		var artifact: Dictionary = artifact_value
		var key := "%s|%d,%d|%d,%d,%d|%s" % [String(snapshot.get("worldId", "")),
			source_chunk.x, source_chunk.y, section_key.x, section_key.y,
			section_key.z, String(authority.get("authorityDigest", ""))]
		var consumers: Dictionary = band_jobs.get(key, {}).get("consumers", {})
		consumers[consumer_token] = true
		var job := {"artifact":artifact, "authority":authority,
			"snapshot":snapshot, "publicationView":publication_view,
			"sectionKey":section_key, "consumerToken":consumer_token,
			"consumers":consumers}
		band_jobs[key] = job
		last_band_artifact = artifact
		return {"status":"ready", "reason":"fixture_tree_source_band_compile_empty",
			"jobKey":key, "consumerToken":consumer_token,
			"artifact":artifact, "retryable":true}

	func poll_ecology_tree_source_band_compile(job_key: String,
			consumer_token := "") -> Dictionary:
		var job: Dictionary = band_jobs.get(job_key, {})
		if job.is_empty() or consumer_token.is_empty() \
				or not job.get("consumers", {}).has(consumer_token):
			return {"status":"pending", "reason":"fixture_tree_band_consumer_missing",
				"retryable":true, "jobKey":job_key}
		var artifact: Dictionary = job.get("artifact", {})
		if not artifact.is_read_only() or artifact.get("sectionKey", null) \
				!= job.get("sectionKey", null) \
				or String(artifact.get("authorityDigest", "")) != String(
					job.get("authority", {}).get("authorityDigest", "")):
			return {"status":"pending", "reason":"fixture_tree_band_artifact_stale",
				"retryable":true, "jobKey":job_key}
		return {"status":"ready", "artifact":artifact, "jobKey":job_key}

	func cancel_ecology_tree_source_band_compile(job_key: String,
			consumer_token := "") -> void:
		var job: Dictionary = band_jobs.get(job_key, {})
		if job.is_empty() or consumer_token.is_empty(): return
		var consumers: Dictionary = job.get("consumers", {})
		consumers.erase(consumer_token)
		if consumers.is_empty(): band_jobs.erase(job_key)
		else: job["consumers"] = consumers

	func authority_for_band(source_chunk: Vector2i,
			section_key: Vector3i) -> Dictionary:
		for job_value: Variant in band_jobs.values():
			if not job_value is Dictionary: continue
			var authority: Dictionary = job_value.get("authority", {})
			if authority.get("sourceChunkKey", null) == source_chunk \
					and authority.get("sectionKey", null) == section_key:
				return authority
		return {}

	func artifact_for_band(source_chunk: Vector2i,
			section_key: Vector3i) -> Dictionary:
		for job_value: Variant in band_jobs.values():
			if not job_value is Dictionary: continue
			var authority: Dictionary = job_value.get("authority", {})
			if authority.get("sourceChunkKey", null) == source_chunk \
					and authority.get("sectionKey", null) == section_key:
				return job_value.get("artifact", {})
		return {}

	func _var_bytes_digest(value: Variant) -> String:
		var context := HashingContext.new()
		if context.start(HashingContext.HASH_SHA256) != OK \
				or context.update(var_to_bytes(value)) != OK:
			return ""
		return context.finish().hex_encode()

	func request_ecology_tree_source_compile(_main: Object, snapshot: Dictionary,
			_consumer: String, _publication_view: Dictionary = {}) -> Dictionary:
		request_count += 1
		last_source_ids.clear()
		for row_value: Variant in snapshot.get("sourceRows", []):
			if row_value is Dictionary and String(row_value.get("producerFamily", "")) == "trees":
				last_source_ids.append(String(row_value.get("sourceId", "")))
		var consumers: Dictionary = consumers_by_job.get("synthetic-pending-tree-job", {})
		consumers[_consumer] = true
		consumers_by_job["synthetic-pending-tree-job"] = consumers
		return {"status":"pending", "jobKey":"synthetic-pending-tree-job"}

	func poll_ecology_tree_source_compile(_job_key: String, consumer: String) -> Dictionary:
		poll_count += 1
		poll_tokens.append(consumer)
		return {"status":poll_status, "reason":pending_reason, "retryable":true,
			"artifact":poll_artifact}

	func cancel_ecology_tree_source_compile(job_key: String, consumer: String) -> void:
		cancellations.append({"jobKey":job_key, "consumer":consumer})
		var consumers: Dictionary = consumers_by_job.get(job_key, {})
		consumers.erase(consumer)
		consumers_by_job[job_key] = consumers

class FixtureBandPollQueue extends RefCounted:
	var poll_result: Variant = {}
	var poll_calls := 0
	var request_calls := 0
	var cancel_calls: Array[Dictionary] = []
	var request_status := "ready"
	var request_reason := ""
	var request_job_key := "fixture-first-poll-job"
	var attach_request_consumer := true
	var request_terminal_failure := false
	var request_retryable := true
	var last_requested_consumer := ""
	var last_polled_job_key := ""
	var last_polled_consumer := ""

	func request_ecology_tree_source_band_compile(_main: Object,
			_snapshot: Dictionary, _section_key: Vector3i, _authority: Dictionary,
			_publication_view: Dictionary, consumer_token: String,
			_priority_distance_squared: float) -> Dictionary:
		request_calls += 1
		last_requested_consumer = consumer_token
		var result: Dictionary = {"status":request_status}
		if not request_reason.is_empty(): result["reason"] = request_reason
		if not request_job_key.is_empty(): result["jobKey"] = request_job_key
		if request_terminal_failure: result["terminalFailure"] = true
		result["retryable"] = request_retryable
		if attach_request_consumer: result["consumerToken"] = consumer_token
		return result

	func poll_ecology_tree_source_band_compile(job_key: String,
			consumer_token: String) -> Variant:
		poll_calls += 1
		last_polled_job_key = job_key
		last_polled_consumer = consumer_token
		return poll_result

	func cancel_ecology_tree_source_band_compile(job_key: String,
			consumer_token: String) -> void:
		cancel_calls.append({"jobKey":job_key, "consumerToken":consumer_token})

class PartialSourceAdmissionQueue extends "res://scripts/environment/TreePublicationQueue.gd":
	var source_requests: Array[Dictionary] = []
	var source_cancellations: Array[Dictionary] = []
	var source_b_pending_before_attachment := false

	func request_ecology_tree_source_record_compile(_main: Object,
			_snapshot: Dictionary, source_record: Dictionary,
			_publication_view: Dictionary, consumer_token: String,
			_priority_distance_squared: Variant = INF) -> Dictionary:
		var source_id := String(source_record.get("sourceId", ""))
		source_requests.append({"sourceId":source_id,
			"consumerToken":consumer_token})
		if source_id == "source-a":
			return {"status":"pending", "reason":"tree_source_record_compile_queued",
				"jobKey":"source-job-a", "consumerToken":consumer_token,
				"retryable":true}
		if source_b_pending_before_attachment:
			# Matches source-cache retirement backpressure: the key is only
			# prospective and no consumer has been attached yet.
			return {"status":"pending",
				"reason":"tree_source_value_retirement_backpressure",
				"jobKey":"source-job-b-prospective", "retryable":true}
		# This pre-attachment failure mirrors a cached failed source record: the
		# request function returns before it attaches the new consumer token.
		return {"status":"failed", "reason":"tree_source_record_compile_failed",
			"jobKey":"source-job-b", "sourceId":source_id}

	func cancel_ecology_tree_source_compile(job_key: String,
			consumer_token := "") -> void:
		source_cancellations.append({"jobKey":job_key,
			"consumerToken":consumer_token})

class FixtureContributionSupportIndex extends SupportIndex:
	var query_result: Dictionary = {}
	var released_sections: Array[Vector3i] = []

	func query_section(_world_id: String, _section_key: Vector3i) -> Dictionary:
		return query_result

	func release_section_demand(section_key: Vector3i) -> void:
		released_sections.append(section_key)

class FixtureBandProjectionSupportIndex extends SupportIndex:
	var expectations: Dictionary = {}
	var registrations_by_section: Dictionary = {}
	var selected_families_by_section: Dictionary = {}
	var pending_keys: Dictionary = {}
	var publication_authority: Object

	func expected_source_family_section_band_projection(_world_id: String,
			source_chunk_key: Vector2i, section_key: Vector3i,
			family: String) -> Dictionary:
		var key := _projection_key(source_chunk_key, section_key, family)
		if pending_keys.has(key):
			return {"status":"pending", "reason":"fixture_band_projection_missing"}
		var expected: Variant = expectations.get(key, null)
		if not expected is Dictionary:
			return {"status":"pending", "reason":"fixture_band_projection_expectation_missing"}
		var result: Dictionary = expected.duplicate(true)
		result["status"] = "ready"
		return result

	func register_source_family_section_band_projection(world_id: String,
			source_chunk_key: Vector2i, section_key: Vector3i,
			source_snapshot: Dictionary, projected_bundle: Dictionary,
			selected_families: Array = [], publication_view: Dictionary = {},
			publication_lease_token := "") -> Dictionary:
		var band_bundle: Dictionary = projected_bundle
		if String(projected_bundle.get("schema", "")) == \
				"ecology-source-publication-section-band-slice/v1":
			if not is_instance_valid(publication_authority) \
					or not is_same(publication_view.get("payload", null), source_snapshot) \
					or publication_lease_token.is_empty():
				return {"status":"pending", "reason":"fixture_band_slice_owner_missing"}
			var owner_result: Variant = publication_authority.call(
				"resolve_ecology_source_publication_section_band_slice",
				publication_view, publication_lease_token, section_key, projected_bundle)
			if not owner_result is Dictionary \
					or String(owner_result.get("status", "")) != "ready" \
					or not is_same(owner_result.get("slice", null), projected_bundle):
				return {"status":"pending", "reason":"fixture_band_slice_alias_invalid"}
			var bundle_value: Variant = projected_bundle.get("bundle", null)
			if not bundle_value is Dictionary or not bundle_value.is_read_only():
				return {"status":"pending", "reason":"fixture_band_slice_bundle_invalid"}
			band_bundle = bundle_value
		if band_bundle.get("sourceChunkKey", null) != source_chunk_key \
				or band_bundle.get("bandKey", null) != section_key:
			return {"status":"pending", "reason":"fixture_band_projection_identity_mismatch"}
		var selected: Dictionary = {}
		for family_value: Variant in selected_families:
			if not family_value is String or String(family_value).is_empty() \
					or selected.has(String(family_value)):
				return {"status":"pending", "reason":"fixture_band_projection_selected_families_invalid"}
			selected[String(family_value)] = true
		for coverage_value: Variant in band_bundle.get("familyCoverage", []):
			if not coverage_value is Dictionary:
				return {"status":"pending", "reason":"fixture_band_projection_family_invalid"}
			var coverage: Dictionary = coverage_value
			var family := String(coverage.get("family", ""))
			if not selected_families.is_empty() and not selected.has(family):
				continue
			var expected: Dictionary = expectations.get(
				_projection_key(source_chunk_key, section_key, family), {})
			if coverage.get("sourceIds", []) != expected.get("expectedSourceIds", null) \
					or String(coverage.get("sourceIdsDigest", "")) != String(
						expected.get("expectedSourceIdsDigest", "")):
				return {"status":"pending", "reason":"fixture_band_projection_source_ids_mismatch"}
		registrations_by_section[section_key] = band_bundle
		selected_families_by_section[section_key] = selected_families.duplicate()
		return {"status":"ready", "sectionKey":section_key,
			"selectedFamilies":selected_families.duplicate()}

	func _projection_key(source_chunk_key: Vector2i, section_key: Vector3i,
			family: String) -> String:
		return "%d,%d|%d,%d,%d|%s" % [source_chunk_key.x, source_chunk_key.y,
			section_key.x, section_key.y, section_key.z, family]


class FixtureBandProjectionAuthority extends RefCounted:
	var expected_view: Dictionary = {}
	var expected_token := ""
	var catalog_artifact: Dictionary = {}
	var band_slices_by_section: Dictionary = {}
	var band_slice_prepare_calls := 0
	var band_slice_resolve_calls := 0

	func ecology_source_publication_local_is_current(view: Dictionary,
			token: String) -> Dictionary:
		if not is_same(view, expected_view) or token != expected_token:
			return {"status":"failed", "reason":"fixture_source_publication_stale"}
		return {"status":"ready"}

	func prepare_ecology_source_publication_section_band_slices(view: Dictionary,
			token: String, section_keys: Array) -> Dictionary:
		band_slice_prepare_calls += 1
		if not is_same(view, expected_view) or token != expected_token \
				or not view.get("payload", null) is Dictionary:
			return {"status":"failed", "reason":"fixture_source_publication_stale"}
		var output: Dictionary = {}
		for section_value: Variant in section_keys:
			if not section_value is Vector3i:
				return {"status":"failed", "reason":"fixture_band_section_invalid"}
			var section_key: Vector3i = section_value
			var slice_value: Variant = band_slices_by_section.get(section_key, null)
			if not slice_value is Dictionary:
				var payload: Dictionary = view.get("payload", {})
				var bundle := ProducerDomain.project_source_domain_family_bundle_to_band(
					payload, section_key, ProducerDomain.section_bounds(section_key),
					catalog_artifact)
				if String(bundle.get("status", "")) != "ready":
					return bundle
				var slice := {"schema":"ecology-source-publication-section-band-slice/v1",
					"publicationId":String(view.get("publicationId", "")),
					"publicationContentDigest":String(view.get("contentDigest", "")),
					"worldId":String(view.get("worldId", "")),
					"worldEpoch":int(view.get("worldEpoch", -1)),
					"sourceChunkKey":payload.get("sourceChunkKey", Vector2i.ZERO),
					"sourceRevision":String(payload.get("sourceRevision", "")),
					"sourceBundleDigest":ProducerDomain.digest_value(payload),
					"sectionKey":section_key,
					"bandBounds":ProducerDomain.section_bounds(section_key),
					"bundle":bundle}
				var slice_digest := ProducerDomain.digest_value(slice)
				slice["sliceDigest"] = slice_digest
				slice = ProducerDomain.freeze_value(slice)
				band_slices_by_section[section_key] = slice
				slice_value = slice
			output[section_key] = slice_value
		output.make_read_only()
		return {"status":"ready", "sectionBandSlicesByKey":output}

	func resolve_ecology_source_publication_section_band_slice(view: Dictionary,
			token: String, section_key: Vector3i, exact_slice: Dictionary) -> Dictionary:
		band_slice_resolve_calls += 1
		if not is_same(view, expected_view) or token != expected_token \
				or not is_same(band_slices_by_section.get(section_key, null), exact_slice):
			return {"status":"failed", "reason":"fixture_band_slice_alias_invalid"}
		return {"status":"ready", "slice":exact_slice}

class FixtureContributionAuthority extends Node:
	var tree_publication_queue: Node
	var expected_view: Dictionary = {}
	var expected_token := ""

	func ecology_source_publication_local_is_current(view: Dictionary,
			token: String) -> Dictionary:
		if not is_same(view, expected_view) or token != expected_token:
			return {"status":"failed", "reason":"fixture_publication_lease_stale"}
		return {"status":"ready"}

	func ecology_source_publication_record_is_current(view: Dictionary,
			token: String, record: Dictionary) -> Dictionary:
		var current := ecology_source_publication_local_is_current(view, token)
		if current.get("status") != "ready":
			return current
		var rows: Array = view.get("payload", {}).get("sourceRows", [])
		for index in range(rows.size()):
			if is_same(rows[index], record):
				return {"status":"ready", "rowIndex":index,
					"memberDigest":"fixture-row-digest"}
		return {"status":"failed", "reason":"fixture_source_row_alias_stale"}

func _tree_demand_bookkeeping_contract() -> Dictionary:
	var world_id := "tree-contribution-demand-lifecycle"
	var section_key := Vector3i(3, 0, -2)
	var source_chunk := Vector2i(4, -3)
	var source_id := "fixture-tree-contribution-source"
	var source_part_id := "trunk"
	var source_revision := "compiled-tree-source-r1"
	var capture_identity := "fixture-tree-contribution-capture"
	var publication_id := "fixture-tree-contribution-publication"
	var publication_token := "fixture-tree-publication-lease"
	var compile_job_key := "fixture-tree-compile-job"
	var compile_consumer_token := "retained-section-tree-demand"
	var mesh := BoxMesh.new()
	var material := StandardMaterial3D.new()
	var mesh_digest := String(MeshFingerprint.inspect(mesh).get("contentDigest", ""))
	var material_digest := Adapter._material_digest(material)
	var mesh_key := "tree-mesh"
	var material_key := "tree-material"
	var identity_key: String = Adapter.new()._source_part_identity_key(source_id, source_part_id)
	var compatibility := {"batchKey":"tree-batch", "meshResourceKey":mesh_key,
		"materialKey":material_key, "meshContentDigest":mesh_digest,
		"materialDigest":material_digest, "meshLocalBounds":mesh.get_aabb()}
	compatibility.make_read_only()
	var attributes: Array = []
	for _index in range(InstanceAttributes.FLOATS_PER_INSTANCE):
		attributes.append(0.0)
	attributes.make_read_only()
	var member := {"instanceAttributes":attributes, "instanceCount":1}
	var contributors := {identity_key:member}
	var batch := {"batchKey":"tree-batch", "sectionKey":section_key,
		"ownerCell":Vector2i(0, 0), "compatibilityKey":compatibility,
		"contributors":contributors}
	var batches: Array[Dictionary] = [batch]
	batches.make_read_only()
	var resources := {mesh_key:mesh, material_key:material}
	resources.make_read_only()
	var artifact := {"batches":batches, "resourceBindings":resources}
	artifact.make_read_only()
	var queue := FixtureTreeQueue.new()
	queue.poll_status = "ready"
	queue.poll_artifact = artifact
	queue.consumers_by_job[compile_job_key] = {compile_consumer_token:true}
	var authority := FixtureContributionAuthority.new()
	root.add_child(authority)
	authority.tree_publication_queue = queue
	var producer_row := {"producerFamily":"trees", "sourceId":source_id,
		"sourcePartId":"", "sourceChunkKey":source_chunk, "sourceRevision":"domain-r1"}
	producer_row.make_read_only()
	var source_rows: Array[Dictionary] = [producer_row]
	source_rows.make_read_only()
	var snapshot := {"schema":"ecology-source-domain-family-bundle/v2",
		"status":"ready", "worldId":world_id, "sourceChunkKey":source_chunk,
		"sourceRevision":"domain-r1", "sourceRows":source_rows}
	snapshot.make_read_only()
	var tree_family := {"status":"ready", "familyRevision":"tree-family-r1",
		"sourceManifestDigest":"a".repeat(64)}
	var family_results := {"trees":tree_family}
	var publication_view := {"schema":"ecology-source-publication-view/v1",
		"publicationId":publication_id, "worldId":world_id, "worldEpoch":1,
		"sourceDomainRevision":"domain-r1", "contentDigest":"b".repeat(64),
		"payload":snapshot, "familyResultsById":family_results}
	publication_view.make_read_only()
	authority.expected_view = publication_view
	authority.expected_token = publication_token
	var support_row := {"sourceId":source_id, "sourcePartId":source_part_id,
		"sourceRevision":source_revision, "producerSnapshotRevision":"tree-family-r1",
		"geometryOwnerSection":section_key,
		"worldBounds":AABB(Vector3(63.0, 0.0, -45.0), Vector3.ONE),
		"certifiedEnvelopeDigest":"c".repeat(64)}
	support_row.make_read_only()
	var support_rows: Array[Dictionary] = [support_row]
	support_rows.make_read_only()
	var support_identity: String = Adapter.new()._source_part_identity_key(source_id,
		source_part_id)
	var support_index := FixtureContributionSupportIndex.new()
	support_index.query_result = {"status":"ready", "sourceIndexRevision":7,
		"coverageCertificate":{"coverageDigest":"d".repeat(64),
			"sourceIndexRevision":7}}
	var provider := Adapter.new()
	provider.configure(world_id)
	provider._main_authority_ref = weakref(authority)
	provider._support_index = support_index
	provider._latest_support_ranges_by_section[section_key] = {support_identity:support_rows}
	var manifest := {"sourceRevision":source_revision}
	var demand := {"jobKey":compile_job_key,
		"consumerToken":compile_consumer_token, "queueRef":weakref(queue),
		"treeFamilyRevision":"tree-family-r1",
		"treeFamilyManifestDigest":"a".repeat(64),
		"sourcePublicationId":publication_id}
	var source_capture_job := {"identity":capture_identity, "status":"ready",
		"snapshot":snapshot, "sourcePublicationView":publication_view,
		"sections":{section_key:true}, "treeCompileDemands":{section_key:demand}}
	provider._source_capture_jobs[capture_identity] = source_capture_job
	provider._source_capture_jobs_by_section[section_key] = {capture_identity:true}
	provider._canonical_tree_artifact_by_member[support_identity] = {
		"sourceChunkKey":source_chunk, "jobKey":compile_job_key,
		"captureIdentity":capture_identity, "snapshot":snapshot,
		"producerRow":producer_row, "publicationView":publication_view,
		"publicationLeaseToken":publication_token,
		"sourcePublicationId":publication_id, "sourceManifest":manifest,
		"artifact":artifact}
	var census := {"status":"complete", "worldId":world_id,
		"sections":[section_key],
		"expectedContributorsBySection":{section_key:[support_identity]},
		"sourceProviderIds":{support_identity:Adapter.PROVIDER_ID},
		"sourceRevisions":{support_identity:source_revision},
		"sourceIdentities":{support_identity:{"sourceId":source_id,
			"sourcePartId":source_part_id}},
		"providerCoverageRevisions":{Adapter.PROVIDER_ID:{section_key:"d".repeat(64)}},
		"providerSnapshotRevisions":{Adapter.PROVIDER_ID:"authority-r1"}}
	var contribution := provider.capture_static_section_contribution(census, section_key)
	var polled_retained_token := not queue.poll_tokens.is_empty() \
		and queue.poll_tokens[0] == compile_consumer_token
	var ready_contribution: bool = String(contribution.get("status", "")) == "ready" \
		and contribution.get("contribution", {}).get("inputs", []).size() == 1 \
		and polled_retained_token
	var released := provider.release_section_capture_demand(section_key)
	var exact_consumer_detached: bool = released.get("status", "") == "released" \
		and support_index.released_sections.has(section_key) \
		and not queue.consumers_by_job.get(compile_job_key, {}).has(compile_consumer_token)
	var poll_count_after_release := queue.poll_count
	var after_release := provider.capture_static_section_contribution(census, section_key)
	var retired_demand_not_repolled := String(after_release.get("status", "")) == "pending" \
		and queue.poll_count == poll_count_after_release
	provider.reset_source_domain_captures()
	var polled_tokens: Array[String] = queue.poll_tokens.duplicate()
	authority.free()
	queue.free()
	return {"readyContributionUsedRetainedToken":ready_contribution,
		"polledRetainedToken":polled_retained_token,
		"exactConsumerDetachedOnUnload":exact_consumer_detached,
		"retiredDemandNotRepolled":retired_demand_not_repolled,
		"firstContributionReason":String(contribution.get("reason", "")),
		"afterReleaseReason":String(after_release.get("reason", "")),
		"polledTokens":polled_tokens,
		"released":released}

class ProductionAuthority extends Node:
	const SyntheticDomain := preload("res://scripts/world/EcologyProducerDomain.gd")
	const CatalogStore := preload("res://scripts/world/EcologyProducerCatalogContext.gd")
	const SyntheticBiomeCatalog := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
	const SyntheticBiomeSnapshot := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
	const SyntheticGrid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
	var seed_text := "ecology-production-contract"
	var seed_hash := 31
	var removed_props_revision := 0
	var removed_props := {}
	var terrain_revision := 0
	var chunks: Dictionary = {}
	var underground_required := true
	var production_mesh: Mesh = BoxMesh.new()
	var production_material: Material = StandardMaterial3D.new()
	var unsupported_flower_material := true
	var tree_publication_queue: Node
	var world_static_section_coordinator: Object
	var world_generation_system := FixtureWorldGeneration.new()
	var structure_system := FixtureStructureAuthority.new()
	var visual_quality := {"decorativeDensity":0.74, "decorativeDetailCap":72}
	var materials: Dictionary = {}
	var fixture_rows_by_chunk: Dictionary = {}
	var fixture_snapshots_by_chunk: Dictionary = {}
	var fixture_snapshots_by_chunk_family: Dictionary = {}
	var _fixture_prop_owner_by_id: Dictionary = {}
	var _policy_inputs: Dictionary = {}
	var _profile_snapshot: Dictionary = {}
	var _rock_envelope: Dictionary = {}
	var _tree_request_envelope: Dictionary = {}
	var _tree_support_envelope: Dictionary = {}
	var corrupt_next_source_domain_snapshot := false
	var source_domain_corruption_applied := false
	var corrupted_source_domain_snapshot: Dictionary = {}
	var last_captured_source_domain_snapshot: Dictionary = {}
	var source_domain_capture_calls := 0
	var captured_structure_dependency_digests: Array[String] = []
	var incomplete_source_categories: Array[String] = []
	var catalog_scope_begins := 0
	var catalog_scope_ends := 0
	var catalog_scope_depth := 0
	var _catalog_scope_profile_snapshot: Dictionary = {}
	var _catalog_scope_catalog_inputs: Dictionary = {}
	var _catalog_scope_artifacts_by_world: Dictionary = {}
	var catalog_scope_artifact_interns := 0
	var ecology_world_epoch := 1
	var _catalog_store := CatalogStore.new()
	var publication_sequence := 0
	var publication_identity_by_id: Dictionary = {}
	var band_slice_prepare_calls := 0
	var band_slice_resolve_calls := 0
	var band_slice_exact_alias_resolutions := 0

	func admit_ecology_source_publication(snapshot: Dictionary, catalog_token: String,
			owner_kind: String, owner_key: String) -> Dictionary:
		var world := String(snapshot.get("worldId", ""))
		var epoch := int(snapshot.get("worldEpoch", -1))
		var resolved := resolve_ecology_catalog_artifact(catalog_token, world, epoch)
		if resolved.get("status") != "ready": return resolved
		publication_sequence += 1
		var hold := acquire_ecology_catalog_artifact_lease(String(snapshot.get("catalogArtifactId", "")),
			"source_publication", str(publication_sequence), world, epoch)
		if hold.get("status") != "ready": return hold
		var result := _catalog_store.publish_source_bundle(snapshot, String(hold.leaseToken),
			owner_kind, owner_key, {"mainInstanceId":get_instance_id(), "worldId":world,
			"worldEpoch":epoch, "catalogArtifactId":String(snapshot.get("catalogArtifactId", "")),
			"catalogContentDigest":String(snapshot.get("catalogContentDigest", ""))})
		if result.get("status") != "ready" or not bool(result.get("catalogLeaseAdopted", false)):
			release_ecology_catalog_artifact_lease(String(hold.leaseToken))
		if result.get("status") == "ready": publication_identity_by_id[String(result.publicationId)] = [world, epoch]
		return result

	func acquire_ecology_source_publication(id: String, kind: String, key: String) -> Dictionary:
		var identity: Array = publication_identity_by_id.get(id, [])
		if identity.size() != 2: return {"status":"failed", "reason":"synthetic_publication_missing"}
		var lease := _catalog_store.acquire_source_publication_lease(id, kind, key, identity[0], identity[1])
		if lease.get("status") != "ready": return lease
		var resolved := resolve_ecology_source_publication(String(lease.leaseToken), identity[0], identity[1])
		if resolved.get("status") != "ready":
			release_ecology_source_publication(String(lease.leaseToken))
			return resolved
		lease["view"] = resolved.view
		return lease

	func resolve_ecology_source_publication(token: String, world: String, epoch: int) -> Dictionary:
		if epoch != ecology_world_epoch: return {"status":"failed", "reason":"synthetic_catalog_epoch_stale"}
		var result := _catalog_store.resolve_source_publication(token, world, epoch)
		if result.get("status") == "ready" and int(result.view.ownerReceipt.get("mainInstanceId", 0)) != get_instance_id():
			return {"status":"failed", "reason":"synthetic_publication_owner_stale"}
		return result

	func ecology_source_publication_is_current(token: String, world: String, epoch: int,
			receipt: Dictionary, revision: String, removal: String) -> Dictionary:
		var resolved := resolve_ecology_source_publication(token, world, epoch)
		if resolved.get("status") != "ready": return resolved
		return _catalog_store.source_publication_is_current(token, world, epoch, receipt, revision, removal)

	func ecology_source_publication_local_is_current(view: Dictionary, token: String) -> Dictionary:
		var owns_scope := catalog_scope_depth == 0
		var scope: Dictionary = {}
		if owns_scope:
			scope = begin_ecology_source_catalog_context_scope()
			if String(scope.get("status", "")) != "ready": return scope
		var resolved := resolve_ecology_source_publication(token, String(view.get("worldId", "")), int(view.get("worldEpoch", -1)))
		if resolved.get("status") != "ready" or not is_same(resolved.get("view", {}), view):
			if owns_scope: end_ecology_source_catalog_context_scope(scope)
			return {"status":"failed", "reason":"synthetic_publication_alias_stale"}
		var snapshot: Dictionary = view.payload
		var inputs: Dictionary = snapshot.sourceInputs
		var current_inputs := _canonical_fixture_source_inputs_in_scope(
			String(snapshot.worldId), snapshot.sourceChunkKey, seed_text, inputs)
		if current_inputs != inputs:
			if owns_scope: end_ecology_source_catalog_context_scope(scope)
			return {"status":"failed", "reason":"synthetic_source_revision_stale"}
		var removal := _removed_props_projection_for_source_chunk(snapshot.sourceChunkKey, RemovedProps.capture(self))
		if removal.get("status") != "ready" or String(removal.get("digest", "")) != String(snapshot.get("removedSourceProjectionDigest", "")):
			if owns_scope: end_ecology_source_catalog_context_scope(scope)
			return {"status":"failed", "reason":"synthetic_source_removal_stale"}
		for family: String in snapshot.get("requestedFamilies", []):
			var latest: Dictionary = fixture_snapshots_by_chunk_family.get(snapshot.sourceChunkKey, {}).get(family, {})
			if latest.is_empty(): continue
			for coverage: Dictionary in latest.get("familyCoverage", []):
				if String(coverage.get("family", "")) == family and String(coverage.get("familyRevision", "")) != String(view.get("familyResultsById", {}).get(family, {}).get("familyRevision", "")):
					if owns_scope: end_ecology_source_catalog_context_scope(scope)
					return {"status":"failed", "reason":"synthetic_source_record_replaced"}
		if owns_scope:
			var ended := end_ecology_source_catalog_context_scope(scope)
			if String(ended.get("status", "")) != "ready": return ended
		return {"status":"ready"}

	func prepare_ecology_source_publication_section_band_slices(view: Dictionary,
			token: String, section_keys: Array) -> Dictionary:
		band_slice_prepare_calls += 1
		var world_id := String(view.get("worldId", ""))
		var world_epoch := int(view.get("worldEpoch", -1))
		var resolved := resolve_ecology_source_publication(token, world_id, world_epoch)
		if String(resolved.get("status", "")) != "ready" \
				or not is_same(resolved.get("view", null), view):
			return {"status":"failed", "reason":"synthetic_band_slice_view_stale"}
		return _catalog_store.prepare_source_publication_section_band_slices(
			token, world_id, world_epoch, section_keys)

	func resolve_ecology_source_publication_section_band_slice(view: Dictionary,
			token: String, section_key: Vector3i, exact_slice: Dictionary) -> Dictionary:
		band_slice_resolve_calls += 1
		var world_id := String(view.get("worldId", ""))
		var world_epoch := int(view.get("worldEpoch", -1))
		var resolved := resolve_ecology_source_publication(token, world_id, world_epoch)
		if String(resolved.get("status", "")) != "ready" \
				or not is_same(resolved.get("view", null), view):
			return {"status":"failed", "reason":"synthetic_band_slice_view_stale"}
		var result := _catalog_store.resolve_source_publication_section_band_slice(
			token, world_id, world_epoch, view, section_key, exact_slice)
		if String(result.get("status", "")) == "ready" \
				and is_same(result.get("slice", null), exact_slice):
			band_slice_exact_alias_resolutions += 1
		return result

	func ecology_source_publication_record_is_current(view: Dictionary, token: String, record: Dictionary) -> Dictionary:
		var resolved := resolve_ecology_source_publication(token, String(view.get("worldId", "")), int(view.get("worldEpoch", -1)))
		if resolved.get("status") != "ready" or not is_same(resolved.get("view", {}), view):
			return {"status":"failed", "reason":"synthetic_publication_alias_stale"}
		var key := SyntheticDomain.source_publication_member_key(String(record.get("producerFamily", "")), String(record.get("sourceId", "")), String(record.get("sourcePartId", "")))
		var index := int(view.get("memberIndex", {}).get(key, -1))
		var rows: Array = view.payload.sourceRows
		if index < 0 or index >= rows.size() or not is_same(rows[index], record):
			return {"status":"failed", "reason":"synthetic_publication_member_alias_stale"}
		return {"status":"ready", "rowIndex":index, "memberDigest":String(view.memberDigestsByIndex[index])}

	func release_ecology_source_publication(token: String) -> Dictionary:
		return _catalog_store.release_source_publication_lease(token)

	func acquire_ecology_catalog_artifact_lease(artifact_id: String, owner_kind: String,
			owner_key: String, world_id: String, world_epoch: int) -> Dictionary:
		if world_epoch != ecology_world_epoch:
			return {"status":"failed", "reason":"synthetic_catalog_epoch_stale"}
		return _catalog_store.acquire_lease(artifact_id, owner_kind, owner_key, world_id, world_epoch)

	func resolve_ecology_catalog_artifact(token: String, world_id: String, world_epoch: int) -> Dictionary:
		if world_epoch != ecology_world_epoch:
			return {"status":"failed", "reason":"synthetic_catalog_epoch_stale"}
		var resolved := _catalog_store.resolve_leased_artifact(token, world_id, world_epoch)
		if resolved.get("status") == "ready": resolved["catalogArtifactId"] = resolved.artifactId
		return resolved

	func release_ecology_catalog_artifact_lease(token: String) -> Dictionary:
		return _catalog_store.release_lease(token)

	func _fixture_artifact_for(inputs: Dictionary) -> Dictionary:
		var lease := _catalog_store.acquire_lease(String(inputs.get("catalogArtifactId", "")),
			"synthetic_sync_capture", str(get_instance_id()), String(inputs.get("worldId", "")), ecology_world_epoch)
		if lease.get("status") != "ready": return {}
		var resolved := _catalog_store.resolve_leased_artifact(String(lease.leaseToken),
			String(inputs.get("worldId", "")), ecology_world_epoch)
		_catalog_store.release_lease(String(lease.leaseToken))
		return resolved.get("artifact", {})

	# Mirror Main's no-yield catalog scope: capture catalog inputs at the outer
	# boundary, reuse their exact interned artifact in nested source checks, and
	# recapture after the outer scope ends.
	func begin_ecology_source_catalog_context_scope() -> Dictionary:
		catalog_scope_begins += 1
		if catalog_scope_depth == 0:
			_catalog_scope_profile_snapshot = _profile_snapshot.duplicate(true)
			_catalog_scope_catalog_inputs = _fixture_catalog_inputs(
				_catalog_scope_profile_snapshot)
			_catalog_scope_artifacts_by_world.clear()
		catalog_scope_depth += 1
		return {"status":"ready", "scopeId":catalog_scope_depth,
			"contextDigest":SyntheticDomain.digest_value([
				_catalog_scope_profile_snapshot.get("contentIdentity", ""),
				_catalog_scope_catalog_inputs.get("producerCatalogRevision", "")])}

	func end_ecology_source_catalog_context_scope(token: Dictionary) -> Dictionary:
		if int(token.get("scopeId", -1)) != catalog_scope_depth or catalog_scope_depth < 1:
			return {"status":"failed", "reason":"synthetic_catalog_scope_mismatch"}
		catalog_scope_ends += 1
		catalog_scope_depth -= 1
		if catalog_scope_depth == 0:
			_catalog_scope_profile_snapshot.clear()
			_catalog_scope_catalog_inputs.clear()
			_catalog_scope_artifacts_by_world.clear()
		return {"status":"ready"}

	func _init() -> void:
		var detail_shader := load("res://resources/visual/detail_material.gdshader") as Shader
		var detail_shader_material := ShaderMaterial.new()
		detail_shader_material.shader = detail_shader
		detail_shader_material.set_shader_parameter("base_color", Color(0.5, 0.72, 0.42, 1.0))
		production_material = detail_shader_material
		var catalog = SyntheticBiomeCatalog.new()
		if catalog.setup():
			var captured := SyntheticBiomeSnapshot.capture(catalog)
			if bool(captured.get("ok", false)):
				_profile_snapshot = {"schemaVersion":int(captured.schemaVersion),
					"fallbackId":String(captured.fallbackId),
					"contentIdentity":String(captured.contentIdentity),
					"profiles":(captured.profiles as Array).duplicate(true)}
				_profile_snapshot = _minimal_synthetic_profile_snapshot(_profile_snapshot)
				_tree_request_envelope = SyntheticDomain.derive_tree_request_envelope(
					_profile_snapshot)
				_tree_support_envelope = SyntheticDomain.derive_tree_grammar_support_envelope(
					_profile_snapshot)
				var rock_digest := SyntheticDomain.digest_value(["synthetic-rock-catalog-v1",
					_profile_snapshot.contentIdentity])
				_rock_envelope = {"status":"ready", "profileCatalogRevision":
					_profile_snapshot.contentIdentity, "eligibleAssetSetDigest":rock_digest,
					"digest":rock_digest, "assetSetDigest":rock_digest,
					"registryRevision":"synthetic-rock-registry-v1",
					"assetRows":[{"assetId":"synthetic-bounded-rock",
						"maxHorizontalSupportMeters":2.0,
						"maxVerticalSupportMeters":2.0}],
					"maxHorizontalSupportMeters":2.0,
					"maxVerticalSupportMeters":2.0}
		var queue := FixtureTreeQueue.new()
		queue.name = "SyntheticTreePublicationQueue"
		add_child(queue)
		tree_publication_queue = queue
		materials = {"forage":StandardMaterial3D.new(),
			"detailGrass":production_material, "detailFlower":production_material}

	func detail_mesh(_detail_type: String) -> Mesh:
		return production_mesh

	func detail_material(detail_type: String) -> Material:
		if detail_type == "flowerBloom" and unsupported_flower_material:
			return null
		return production_material

	func _ecology_chunk_source_revision(key: Vector2i) -> String:
		return "ecology-v2:%s:%d,%d:static-props-v1" % [seed_text, key.x, key.y]

	func _removed_props_projection_for_source_chunk(source_chunk_key: Vector2i,
			removed_props_snapshot: Dictionary) -> Dictionary:
		var removed_ids: Array[String] = []
		for id_value: Variant in removed_props_snapshot.get("ids", []):
			if not id_value is String:
				return {"status":"failed", "reason":"fixture_removed_prop_id_invalid"}
			# Fixture IDs are opaque. Use ownership registered with the source rows,
			# retaining it after a row disappears so deletion snapshots can tombstone it.
			if _fixture_prop_owner_by_id.get(String(id_value), null) == source_chunk_key:
				removed_ids.append(String(id_value))
		removed_ids.sort()
		return {"status":"ready", "removedIds":removed_ids,
			"digest":SyntheticDomain.digest_value(removed_ids)}

	func terrain_volume_chunk_revision(_key: Vector2i, _chunk_size: int) -> int:
		return terrain_revision

	func visible_world_underground_visuals_required() -> bool:
		return underground_required

	func set_fixture_rows(chunk_key: Vector2i, rows: Array) -> void:
		fixture_rows_by_chunk[chunk_key] = rows.duplicate(true)
		for row_value: Variant in rows:
			if not row_value is Dictionary:
				continue
			var prop_id := String(row_value.get("propId", ""))
			if not prop_id.is_empty():
				_fixture_prop_owner_by_id[prop_id] = chunk_key

	func ecology_source_support_policy_inputs(world_id: String, source_chunk_key: Vector2i,
			world_seed: String, base_inputs: Dictionary) -> Dictionary:
		var inputs := _canonical_fixture_inputs(world_id, source_chunk_key, world_seed,
			base_inputs)
		var policy: Dictionary = SyntheticDomain.support_policy(inputs, _fixture_artifact_for(inputs))
		var frozen_inputs: Dictionary = SyntheticDomain._freeze_value(inputs)
		var frozen_policy: Dictionary = SyntheticDomain._freeze_value(policy)
		return {"status":String(policy.get("status", "pending")),
			"schema":"ecology-source-support-policy-inputs/v2",
			"worldId":world_id, "worldSeed":world_seed,
			"sourceChunkKey":source_chunk_key, "sourceInputs":frozen_inputs,
			"supportPolicy":frozen_policy,
			"catalogArtifact":_fixture_artifact_for(inputs),
			"catalogArtifactId":inputs.get("catalogArtifactId", ""),
			"catalogContentDigest":inputs.get("catalogContentDigest", ""),
			"worldEpoch":ecology_world_epoch,
			"influencePolicyRevision":String(policy.get("revision", "")),
			"influencePolicyDigest":String(policy.get("digest", "")),
			"reason":String(policy.get("runtimePolicyReason", ""))}

	func capture_ecology_source_domain(world_id: String, source_chunk_key: Vector2i,
			world_seed: String, source_inputs: Dictionary,
			removed_props_snapshot: Dictionary, catalog_lease_token := "",
			family_request: Dictionary = {}) -> Dictionary:
		source_domain_capture_calls += 1
		if not catalog_lease_token.is_empty() and resolve_ecology_catalog_artifact(
				catalog_lease_token, world_id, ecology_world_epoch).get("status") != "ready":
			return {"status":"failed", "reason":"synthetic_catalog_lease_invalid"}
		var inputs := _canonical_fixture_inputs(world_id, source_chunk_key,
			world_seed, source_inputs)
		captured_structure_dependency_digests.append(String(
			inputs.get("structureDependencyContentDigest", "")))
		var removed_projection := _removed_props_projection_for_source_chunk(
			source_chunk_key, removed_props_snapshot)
		if String(removed_projection.get("status", "")) != "ready":
			return {"status":String(removed_projection.get("status", "failed")),
				"reason":String(removed_projection.get("reason", "fixture_removed_prop_projection_failed"))}
		var removed_ids: Array[String] = []
		for removed_id_value: Variant in removed_projection.get("removedIds", []):
			removed_ids.append(String(removed_id_value))
		var rows: Array = []
		for row_value: Variant in fixture_rows_by_chunk.get(source_chunk_key, []):
			if not row_value is Dictionary:
				continue
			var prop_id := String(row_value.get("propId", ""))
			if not prop_id.is_empty() and removed_ids.has(prop_id):
				continue
			rows.append(row_value.duplicate(true))
		var removed_digest := String(removed_projection.get("digest", ""))
		var source_revision := SyntheticDomain.source_domain_revision(world_id, world_seed,
			source_chunk_key, inputs, removed_digest, _fixture_artifact_for(inputs))
		var support_policy: Dictionary = SyntheticDomain.support_policy(inputs, _fixture_artifact_for(inputs))
		for row_value: Variant in rows:
			if not row_value is Dictionary:
				continue
			row_value["sourceChunkKey"] = source_chunk_key
			row_value["sourceRevision"] = source_revision
			row_value["producerRevision"] = source_revision
			row_value["terrainVolumeChunkRevision"] = String(inputs.terrainVolumeChunkRevision)
			row_value["structureAdmissionRevision"] = String(inputs.structureAdmissionRevision)
			row_value["structureAdmissionStatus"] = "ready"
			row_value["influencePolicyRevision"] = String(support_policy.revision)
			row_value["influencePolicyDigest"] = String(support_policy.digest)
			row_value["removedSourceProjectionDigest"] = removed_digest
			var chunk_origin := Vector3(float(source_chunk_key.x) * \
				SyntheticGrid.STREAM_CHUNK_SIZE_METERS, 0.0,
				float(source_chunk_key.y) * SyntheticGrid.STREAM_CHUNK_SIZE_METERS)
			row_value["sourceOrigin"] = row_value.get("sourceOrigin", chunk_origin)
			# The synthetic realized-census producer uses actual detail mesh data,
			# so mirror the production capture's forward world-bounds proof before
			# sealing the source bundle. Missing geometry must remain pending.
			if String(row_value.get("producerFamily", "")) == "details":
				var detail_transform: Variant = row_value.get("transform", null)
				var detail_mesh_bounds: Variant = row_value.get("meshBounds", null)
				if detail_transform is Transform3D and detail_mesh_bounds is AABB:
					var world_transform := Transform3D(Basis.IDENTITY, chunk_origin) \
						* (detail_transform as Transform3D)
					var world_bounds: AABB = world_transform * (detail_mesh_bounds as AABB)
					var source_origin: Vector3 = chunk_origin \
						+ (detail_transform as Transform3D).origin
					var proof := SyntheticDomain.validate_source_bounds("details",
						source_origin, world_bounds, support_policy)
					proof["worldBounds"] = world_bounds
					proof["sourceOrigin"] = source_origin
					row_value["sourceOrigin"] = source_origin
					row_value["supportProof"] = proof
			elif row_value.get("renderMembers", null) is Array:
				var body_transform := Transform3D.IDENTITY
				var body_transform_value: Variant = row_value.get("transform", null)
				if body_transform_value is Transform3D:
					body_transform = body_transform_value
				else:
					var position: Variant = row_value.get("position", Vector3.ZERO)
					var rotation: Variant = row_value.get("bodyRotation", Vector3.ZERO)
					if position is Vector3 and rotation is Vector3:
						body_transform = Transform3D(Basis.from_euler(rotation), position)
				var world_bounds := AABB()
				var has_world_bounds := false
				for member_value: Variant in row_value.get("renderMembers", []):
					if not member_value is Dictionary:
						has_world_bounds = false
						break
					var member_mesh_bounds: Variant = member_value.get("meshBounds", null)
					var member_transform: Variant = member_value.get(
						"transform", Transform3D.IDENTITY)
					if not member_mesh_bounds is AABB or not member_transform is Transform3D:
						has_world_bounds = false
						break
					var member_world_bounds: AABB = Transform3D(Basis.IDENTITY, chunk_origin) \
						* body_transform * member_transform * member_mesh_bounds
					world_bounds = member_world_bounds if not has_world_bounds \
						else world_bounds.merge(member_world_bounds)
					has_world_bounds = true
				if has_world_bounds:
					var source_origin: Vector3 = chunk_origin + body_transform.origin
					var family := String(row_value.get("producerFamily", ""))
					var proof := SyntheticDomain.validate_source_bounds(family,
						source_origin, world_bounds, support_policy)
					proof["worldBounds"] = world_bounds
					proof["sourceOrigin"] = source_origin
					row_value["sourceOrigin"] = source_origin
					row_value["supportProof"] = proof
		var categories_complete: Array = SyntheticDomain.REQUIRED_CATEGORIES.duplicate()
		for category: String in incomplete_source_categories:
			categories_complete.erase(category)
		var artifact := _fixture_artifact_for(inputs)
		var request := family_request if not family_request.is_empty() else SyntheticDomain.build_source_family_request(
			SyntheticDomain.REQUIRED_CATEGORIES, world_id, world_seed, source_chunk_key,
			inputs, removed_digest, artifact, catalog_lease_token)
		var snapshot := SyntheticDomain.seal_source_domain_family_bundle({
			"worldId":world_id, "worldSeed":world_seed,
			"sourceChunkKey":source_chunk_key, "sourceInputs":inputs,
			"sourceRows":rows, "categoriesComplete":categories_complete,
			"completedFamilies":categories_complete, "familyRequest":request,
			"catalogLeaseToken":catalog_lease_token, "actorIntentSnapshot":[],
			"removedSourceProjectionDigest":removed_digest,
			"removedSourceIds":removed_ids}, artifact)
		if corrupt_next_source_domain_snapshot:
			corrupt_next_source_domain_snapshot = false
			source_domain_corruption_applied = true
			var corrupted := snapshot.duplicate(true)
			corrupted["sourceManifestDigest"] = "0".repeat(64)
			snapshot = SyntheticDomain.freeze_value(corrupted)
			corrupted_source_domain_snapshot = snapshot
		fixture_snapshots_by_chunk[source_chunk_key] = snapshot
		if snapshot.get("status") == "ready":
			var family_snapshots: Dictionary = fixture_snapshots_by_chunk_family.get(source_chunk_key, {})
			for family: String in snapshot.get("requestedFamilies", []):
				family_snapshots[family] = snapshot
			fixture_snapshots_by_chunk_family[source_chunk_key] = family_snapshots
		last_captured_source_domain_snapshot = snapshot
		if snapshot.get("status") != "ready": return snapshot
		publication_sequence += 1
		var capture_hold := acquire_ecology_catalog_artifact_lease(String(inputs.catalogArtifactId),
			"synthetic_capture_admission", str(publication_sequence), world_id, ecology_world_epoch)
		if capture_hold.get("status") != "ready": return capture_hold
		var admitted := admit_ecology_source_publication(snapshot, String(capture_hold.leaseToken),
			"synthetic_source_capture", str(publication_sequence))
		release_ecology_catalog_artifact_lease(String(capture_hold.leaseToken))
		if admitted.get("status") != "ready": return admitted
		return {"status":"ready", "snapshot":snapshot,
			"sourcePublicationId":String(admitted.publicationId),
			"sourcePublicationView":admitted.view,
			"sourcePublicationLeaseToken":String(admitted.leaseToken)}

	func ecology_source_domain_family_result(snapshot: Dictionary, family: String,
			owner_lease_token := "") -> Dictionary:
		var current := ecology_source_domain_is_current(snapshot, owner_lease_token)
		if current.get("status") != "ready": return current
		return SyntheticDomain.source_family_result(snapshot, family,
			_fixture_artifact_for(snapshot.get("sourceInputs", {})))

	func ecology_source_domain_is_current(snapshot: Dictionary, owner_lease_token := "") -> Dictionary:
		var inputs: Dictionary = snapshot.get("sourceInputs", {})
		var artifact := _fixture_artifact_for(inputs)
		var token := owner_lease_token if not owner_lease_token.is_empty() else String(snapshot.get("catalogLeaseToken", ""))
		if resolve_ecology_catalog_artifact(token, String(snapshot.get("worldId", "")),
				int(snapshot.get("worldEpoch", -1))).get("status") != "ready" \
				or not SyntheticDomain.validate_source_domain_family_bundle(snapshot,
					String(snapshot.get("worldId", "")), snapshot.get("sourceChunkKey", Vector2i.ZERO), artifact):
			return {"status":"failed", "reason":"synthetic_source_snapshot_stale"}
		var current_inputs := _canonical_fixture_inputs(String(snapshot.get("worldId", "")),
			snapshot.get("sourceChunkKey", Vector2i.ZERO), seed_text, inputs)
		if current_inputs != inputs:
			return {"status":"failed", "reason":"synthetic_source_revision_stale"}
		return {"status":"ready"}

	func ecology_source_record_is_current(record: Dictionary,
			enclosing_provenance: Dictionary) -> Dictionary:
		var chunk_value: Variant = enclosing_provenance.get("sourceChunkKey", null)
		var family := String(record.get("producerFamily", ""))
		var snapshot: Variant = fixture_snapshots_by_chunk_family.get(chunk_value, {}).get(family, null)
		if not chunk_value is Vector2i or not snapshot is Dictionary \
				or not SyntheticDomain.validate_source_domain_snapshot(snapshot,
					String(snapshot.get("worldId", "")), chunk_value,
					_fixture_artifact_for(snapshot.get("sourceInputs", {}))):
			return {"status":"failed", "reason":"synthetic_source_snapshot_stale"}
		if String(enclosing_provenance.get("sourceDomainRevision", "")) \
				!= String(snapshot.get("sourceDomainRevision", "")):
			return {"status":"failed", "reason":"synthetic_source_revision_stale"}
		for row_value: Variant in snapshot.get("sourceRows", []):
			if row_value is Dictionary and String(row_value.get("sourceId", "")) \
					== String(record.get("sourceId", "")) and row_value == record:
				return {"status":"ready", "sourceDomainRevision":snapshot.sourceDomainRevision}
		return {"status":"failed", "reason":"synthetic_source_record_replaced"}

	func detail_type_material_key(detail_type: String) -> String:
		return "detailFlower" if detail_type == "flowerBloom" else "detailGrass"

	func _materialize_source_mesh(recipe: Dictionary) -> Mesh:
		var primitive := String(recipe.get("primitive", ""))
		var parameters: Dictionary = recipe.get("parameters", {})
		if primitive == "box":
			var mesh := BoxMesh.new()
			mesh.size = parameters.get("size", Vector3.ONE)
			return mesh
		return null

	func _canonical_fixture_inputs(world_id: String, source_chunk_key: Vector2i,
			world_seed: String, base_inputs: Dictionary) -> Dictionary:
		var profile_snapshot: Dictionary = _catalog_scope_profile_snapshot \
			if catalog_scope_depth > 0 else _profile_snapshot
		var catalog_inputs := _catalog_scope_catalog_inputs \
			if catalog_scope_depth > 0 else _fixture_catalog_inputs(profile_snapshot)
		var interned := _fixture_catalog_artifact(world_id, world_seed,
			catalog_inputs)
		if String(interned.get("status", "")) != "ready": return {}
		return _compose_fixture_source_inputs(world_id, source_chunk_key,
			world_seed, base_inputs, catalog_inputs, interned)

	func _fixture_catalog_inputs(profile_snapshot: Dictionary) -> Dictionary:
		var inputs: Dictionary = {}
		inputs["biomeProfileSnapshotStatus"] = "ready" if not profile_snapshot.is_empty() else "failed"
		inputs["biomeProfileSnapshot"] = profile_snapshot.duplicate(true)
		var tree_request: Dictionary = _tree_request_envelope
		var tree_envelope: Dictionary = _tree_support_envelope
		inputs["treeProducerEnvelopeStatus"] = String(tree_request.get("status", "failed"))
		inputs["treeProducerEnvelope"] = tree_request.duplicate(true)
		inputs["treeGrammarEnvelopeStatus"] = String(tree_envelope.get("status", "failed"))
		inputs["treeGrammarEnvelope"] = tree_envelope.duplicate(true)
		inputs["treeGrammarEnvelopeDigest"] = String(tree_envelope.get("digest", ""))
		inputs["rockSupportEnvelopeStatus"] = String(_rock_envelope.get("status", "pending"))
		inputs["rockSupportEnvelope"] = _rock_envelope.duplicate(true)
		inputs["staticRecipeEnvelopeStatus"] = "ready"
		inputs["producerCatalogRevision"] = SyntheticDomain.digest_value([
			"synthetic-source-domain-fixture-v1", profile_snapshot.get("contentIdentity", "")])
		return inputs

	func _fixture_catalog_artifact(world_id: String, world_seed: String,
			catalog_inputs: Dictionary) -> Dictionary:
		var scope_artifact_key := JSON.stringify([world_id, world_seed,
			ecology_world_epoch])
		if catalog_scope_depth > 0 \
				and _catalog_scope_artifacts_by_world.has(scope_artifact_key):
			return _catalog_scope_artifacts_by_world[scope_artifact_key]
		var interned := _catalog_store.intern_fresh(world_id, world_seed,
			ecology_world_epoch, {"owner":get_instance_id()}, catalog_inputs)
		if interned.get("status") == "ready" and catalog_scope_depth > 0:
			catalog_scope_artifact_interns += 1
			_catalog_scope_artifacts_by_world[scope_artifact_key] = interned.duplicate(true)
		return interned

	func _compose_fixture_source_inputs(world_id: String,
			source_chunk_key: Vector2i, world_seed: String, base_inputs: Dictionary,
			catalog_inputs: Dictionary, interned: Dictionary) -> Dictionary:
		var compact := {"schema":"ecology-source-domain-inputs/v2",
			"worldId":world_id, "worldSeed":world_seed, "worldEpoch":ecology_world_epoch,
			"sourceChunkKey":source_chunk_key,
			"catalogArtifactId":String(interned.get("artifactId", "")),
			"catalogContentDigest":String(interned.get("catalogContentDigest", "")),
			"producerCatalogRevision":String(catalog_inputs.get("producerCatalogRevision", "")),
			"terrainVolumeChunkRevision":String(base_inputs.get("terrainVolumeChunkRevision", "synthetic-terrain-revision-v1"))}
		var artifact := _fixture_artifact_for(compact)
		var policy: Dictionary = artifact.get("supportPolicy", {})
		compact["influencePolicyRevision"] = String(policy.get("revision", ""))
		compact["influencePolicyDigest"] = String(policy.get("digest", ""))
		var dependency: Dictionary = base_inputs.get("structureDependencies", {}).duplicate(true)
		if dependency.is_empty():
			var fixture_structure_revision := String(base_inputs.get(
				"structureAdmissionRevision", structure_system.region_dependency_revision(Rect2i())))
			var content := {"fixtureRevision":fixture_structure_revision}
			dependency = {"schema":"ecology-structure-dependency-snapshot/v1", "status":"ready",
				"content":content, "contentDigest":SyntheticDomain.digest_value(content),
				"ownerInstanceId":get_instance_id(), "ownerGeneration":ecology_world_epoch}
		compact["structureDependencies"] = dependency
		compact["structureDependencyContentDigest"] = dependency.contentDigest
		compact["structureDependencyStatus"] = dependency.status
		compact["structureAdmissionRevision"] = dependency.contentDigest
		compact["structureAdmissionStatus"] = dependency.status
		return compact

	func _canonical_fixture_source_inputs_in_scope(world_id: String,
			source_chunk_key: Vector2i, world_seed: String,
			base_inputs: Dictionary) -> Dictionary:
		var catalog_inputs: Dictionary = _catalog_scope_catalog_inputs
		if catalog_scope_depth < 1 or catalog_inputs.is_empty(): return {}
		var interned := _fixture_catalog_artifact(world_id, world_seed, catalog_inputs)
		if String(interned.get("status", "")) != "ready": return {}
		return _compose_fixture_source_inputs(world_id, source_chunk_key,
			world_seed, base_inputs, catalog_inputs, interned)

	func _minimal_synthetic_profile_snapshot(source: Dictionary) -> Dictionary:
		var result := source.duplicate(true)
		var profiles: Array = result.get("profiles", []).duplicate(true)
		for profile_value: Variant in profiles:
			if not profile_value is Dictionary:
				continue
			var profile: Dictionary = profile_value
			for field: String in ["tree_scale", "tree_height_min", "tree_height_max",
					"crown_radius_min", "crown_radius_max", "trunk_radius_min",
					"trunk_radius_max", "wind_response"]:
				profile[field] = {"value":0.001, "float32BytesHex":PackedFloat32Array(
					[0.001]).to_byte_array().hex_encode(),
					"float64BytesHex":PackedFloat64Array([0.001]).to_byte_array().hex_encode()}
		result["profiles"] = profiles
		result["contentIdentity"] = SyntheticDomain.digest_value([
			"synthetic-minimal-tree-profile-catalog/v1", profiles])
		return result

	func detail_mesh_surface(detail_type: String, _surface_index: int) -> Mesh:
		return detail_mesh(detail_type)

	func detail_surface_material(detail_type: String, _surface_index: int) -> Material:
		return detail_material(detail_type)

	func detail_surface_material_key(detail_type: String, _surface_index: int) -> String:
		return detail_type_material_key(detail_type)

class StaleCaptureWakeRecorder extends RefCounted:
	var sections: Array[Vector3i] = []
	func wake_visible_section_demand(section: Vector3i, _reason: String,
			_token: String) -> Dictionary:
		sections.append(section)
		return {"status":"woken"}


class StaleCaptureAuthority extends ProductionAuthority:
	var capture_calls := 0
	var permanent_failure := false
	var cancelled_capture_keys: Array[String] = []
	var cancelled_capture_lease_tokens: Array[String] = []
	var capture_domain := ProducerDomain.new()
	func cancel_ecology_source_domain_capture(key: String,
			owner_lease_token := "") -> Dictionary:
		cancelled_capture_keys.append(key)
		cancelled_capture_lease_tokens.append(owner_lease_token)
		capture_domain.clear_pending_capture_progress(key)
		return {"status":"cancelled"}
	func capture_ecology_source_domain(_world: String, _chunk: Vector2i,
			_seed: String, _inputs: Dictionary, _removed: Dictionary,
			_catalog_lease_token := "", _family_request: Dictionary = {}) -> Dictionary:
		capture_calls += 1
		if permanent_failure:
			return {"status":"failed", "reason":"fixture_unbounded_source", "retryable":false}
		return {"status":"pending", "reason":"ecology_structure_admission_revision_stale",
			"requiresRecapture":true, "retryable":true,
			"capturedRevision":"old", "currentRevision":"current"}


class ReceiptAuthority extends RefCounted:
	var accepted: Dictionary = {}

	func installed_section_receipt_is_current(section_key: Vector3i,
			receipt: Dictionary) -> bool:
		return accepted.get(section_key, {}) == receipt

class RemovalFixtureAdapter extends Adapter:
	func capture_static_section_sources(world_id: String,
			requested_sections: Array) -> Dictionary:
		return {"status":"complete", "worldId":world_id,
			"sections":requested_sections.duplicate(), "sourceRevisions":{}}

## This fixture advances admitted source jobs explicitly, then observes the
## accepted provider result. Production continues to service the same queue
## from Main's loading/gameplay lanes.
class PumpedAdapter extends Adapter:
	var pump_retained_preparation := false
	var _test_pump_diagnostics: Dictionary = {}

	func pending_source_capture_reason_seen(expected_reason: String) -> bool:
		for job_value: Variant in _source_capture_jobs.values():
			if job_value is Dictionary and String(job_value.get("lastReason", "")) == expected_reason:
				return true
		return false

	func failed_source_capture_reason_seen(expected_reason: String) -> bool:
		for job_value: Variant in _source_capture_jobs.values():
			if not job_value is Dictionary or String(job_value.get("status", "")) != "failed":
				continue
			var failure: Dictionary = job_value.get("failure", {})
			if String(failure.get("reason", "")) == expected_reason:
				return true
		return false

	func capture_static_section_sources(world_id: String,
			requested_sections: Array) -> Dictionary:
		var result: Dictionary = super.capture_static_section_sources(world_id,
			requested_sections)
		var diagnostics: Dictionary = _test_pump_diagnostics.duplicate(true) \
			if not _test_pump_diagnostics.is_empty() else {
				"advanceCalls":0, "maximumCombinedUnits":0,
				"maximumFamilyUnits":0, "sawFamilyUnit":false,
				"unitCursorAdvancedSequentially":true,
				"terminalFailureSeen":false,
				"familyUnitCountsBySection":{}}
		if not pump_retained_preparation or result.get("status") != "pending":
			return result
		var made_progress := false
		var should_observe_terminal_state := false
		for _round in range(4):
			if String(result.get("reason", "")) == \
					"ecology_section_preparation_stale_requeued":
				# Stale invalidation retires the old demand. The retry is a new
				# admission before the bounded service lane.
				result = super.capture_static_section_sources(world_id, requested_sections)
				if result.get("status", "") != "pending":
					break
			var round_progress := false
			for _attempt in range(512):
				var advanced: Dictionary = advance_source_domain_captures(8)
				if _attempt == 0:
					diagnostics["firstServiceStatus"] = String(advanced.get("status", ""))
					diagnostics["firstServiceReason"] = String(advanced.get("reason", ""))
					diagnostics["firstServiceAdvancedCount"] = int(advanced.get(
						"advancedCount", 0))
				diagnostics["advanceCalls"] = int(diagnostics.advanceCalls) + 1
				diagnostics["maximumCombinedUnits"] = maxi(
					int(diagnostics.maximumCombinedUnits),
					int(advanced.get("advancedCount", 0)))
				diagnostics["maximumFamilyUnits"] = maxi(
					int(diagnostics.maximumFamilyUnits),
					int(advanced.get("sectionPreparationAdvancedCount", 0)))
				var family_counts: Dictionary = diagnostics.get("familyUnitCountsBySection", {})
				var terminal_failure := String(advanced.get("status", "")) == "failed"
				for unit_value: Variant in advanced.get("results", []):
					if not unit_value is Dictionary:
						continue
					if String(unit_value.get("status", "")) == "failed":
						terminal_failure = true
						continue
					if String(unit_value.get("stage", "")) != "family_complete":
						continue
					diagnostics["sawFamilyUnit"] = true
					var section_key: Variant = unit_value.get("sectionKey", null)
					if not section_key is Vector3i:
						diagnostics["unitCursorAdvancedSequentially"] = false
						continue
					var section_id := "%d,%d,%d" % [section_key.x, section_key.y,
						section_key.z]
					var unit_count := int(unit_value.get("unitCount", 0))
					var prior_count := int(family_counts.get(section_id, 0))
					if unit_count != prior_count + 1:
						diagnostics["unitCursorAdvancedSequentially"] = false
					family_counts[section_id] = unit_count
					diagnostics["familyUnitCountsBySection"] = family_counts
				if terminal_failure:
					diagnostics["terminalFailureSeen"] = true
					should_observe_terminal_state = true
					break
				var advanced_count := int(advanced.get("advancedCount", 0))
				if advanced_count <= 0:
					break
				round_progress = true
				made_progress = true
				var all_requested_ready := true
				for section_value: Variant in requested_sections:
					if not section_value is Vector3i:
						all_requested_ready = false
						break
					var cohort: Dictionary = _source_capture_cohorts.get(section_value, {})
					var preparation_value: Variant = cohort.get("sectionPreparation", null)
					if String(cohort.get("status", "")) == "failed":
						continue
					if String(cohort.get("status", "")) != "complete":
						all_requested_ready = false
						break
					if preparation_value is Dictionary \
							and String(preparation_value.get("status", "")) not in ["complete", "failed"]:
						all_requested_ready = false
						break
				if all_requested_ready:
					break
			if not round_progress or should_observe_terminal_state:
				break
			result = super.capture_static_section_sources(world_id, requested_sections)
			if String(result.get("reason", "")) != \
					"ecology_section_preparation_stale_requeued":
				break
		if should_observe_terminal_state:
			# The retained service lane records the terminal producer state; a
			# fresh provider observation reports it to the same caller.
			result = super.capture_static_section_sources(world_id, requested_sections)
		diagnostics["combinedUnitsWithinConfiguredBudget"] = \
			int(diagnostics.maximumCombinedUnits) <= 8 \
			and int(diagnostics.maximumFamilyUnits) <= 8
		_test_pump_diagnostics = diagnostics
		return result


func _coordinator_retryable_capture_recovery_contract() -> Dictionary:
	var main := ProductionAuthority.new()
	main.seed_text = "ecology-coordinator-capture-recovery"
	main.seed_hash = 307
	main.terrain_revision = 1
	main.underground_required = false
	main.structure_system.revision = "structure-owner-before-capture-failure"
	root.add_child(main)
	var world_id: String = "seed:%s:%d" % [main.seed_text, main.seed_hash]
	var section: Vector3i = Vector3i.ZERO
	var coordinator := SectionCoordinator.new()
	coordinator.configure(world_id)
	coordinator.configure_source_roster([Adapter.PROVIDER_ID])
	main.world_static_section_coordinator = coordinator
	var provider := PumpedAdapter.new()
	provider.configure(world_id)
	provider.bind_main_authority(main)
	provider.pump_retained_preparation = true
	coordinator.register_source_provider(Adapter.PROVIDER_ID, provider,
		"capture_static_section_sources")
	coordinator.request_visible_section_demand(section, main.terrain_revision, 0.0)
	main.corrupt_next_source_domain_snapshot = true
	var first_advance: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	var first_results: Array = first_advance.get("results", [])
	var first_admission: Dictionary = first_results[0].get("admission", {}) \
		if not first_results.is_empty() else {}
	var first_detail: Dictionary = first_admission.get("providerDetails", {})
	var first_producer_status: String = String(first_detail.get("producerStatus", ""))
	var first_reason: String = String(first_admission.get("providerReason", ""))
	var first_state: Dictionary = coordinator._visible_section_demands.get(section, {})
	var old_digest: String = String(main.captured_structure_dependency_digests[-1]) \
		if not main.captured_structure_dependency_digests.is_empty() else ""
	var first_failure_stayed_waiting: bool = main.source_domain_corruption_applied \
		and first_admission.get("status") == "pending" \
		and first_producer_status == "failed" \
		and first_reason == "ecology_source_publication_payload_invalid" \
		and String(first_state.get("stage", "")) == "waiting" \
		and not first_state.has("blockedReason") \
		and provider.failed_source_capture_reason_seen(
			"ecology_source_publication_payload_invalid")

	var capture_count_after_first_failure := main.source_domain_capture_calls
	var unchanged_retry: Dictionary = provider.capture_static_section_sources(
		world_id, [section])
	var unchanged_retry_demand: Dictionary = coordinator._visible_section_demands.get(
		section, {}).duplicate(true)
	var retained_failure_prep: Dictionary = provider._source_capture_cohorts.get(
		section, {}).get("sectionPreparation", {}).duplicate(true)
	var unchanged_identity_failure_stays_latched: bool = \
		String(unchanged_retry.get("status", "")) == "pending" \
		and String(unchanged_retry.get("reason", "")) \
			== "ecology_source_publication_payload_invalid" \
		and main.source_domain_capture_calls == capture_count_after_first_failure \
		and String(unchanged_retry_demand.get("stage", "")) == "waiting" \
		and not unchanged_retry_demand.has("blockedReason") \
		and String(retained_failure_prep.get("status", "")) == "failed" \
		and not retained_failure_prep.get("sourcePlans", []).is_empty()
	var multi_plan_revision_is_detected: bool = false
	var multi_plan_revision_reason := ""
	var mixed_ready_failed_identity_retained: bool = false
	var source_plans: Array = retained_failure_prep.get("sourcePlans", []).duplicate(true)
	if not source_plans.is_empty() and source_plans[0] is Dictionary:
		var first_plan: Dictionary = source_plans[0]
		var first_capture_id := String(first_plan.get("captureIdentity", ""))
		var first_job: Dictionary = provider._source_capture_jobs.get(first_capture_id, {})
		if not first_job.is_empty():
			var sibling_plan: Dictionary = first_plan.duplicate(true)
			var sibling_capture_id := first_capture_id + "|stale-sibling-fixture"
			sibling_plan["captureIdentity"] = sibling_capture_id
			var sibling_job: Dictionary = first_job.duplicate(true)
			sibling_job["captureIdentity"] = sibling_capture_id
			sibling_job["status"] = "ready"
			sibling_job["captureCacheIdentity"] = String(first_job.get("captureCacheIdentity", ""))
			provider._source_capture_jobs[sibling_capture_id] = sibling_job
			source_plans.append(sibling_plan)
			retained_failure_prep["sourcePlans"] = source_plans
			var mixed_state_check: Dictionary = provider._failed_source_section_preparation_identity_is_current(
				main, retained_failure_prep)
			mixed_ready_failed_identity_retained = \
				String(mixed_state_check.get("status", "")) == "ready" \
				and bool(mixed_state_check.get("unchangedFailure", false))
			sibling_job["captureCacheIdentity"] = "deliberately-stale-sibling-identity"
			provider._source_capture_jobs[sibling_capture_id] = sibling_job
			var multi_plan_check: Dictionary = provider._failed_source_section_preparation_identity_is_current(
				main, retained_failure_prep)
			multi_plan_revision_reason = String(multi_plan_check.get("reason", ""))
			multi_plan_revision_is_detected = \
				String(multi_plan_check.get("status", "")) == "stale" \
				and multi_plan_revision_reason \
					== "ecology_section_preparation_failed_source_identity_changed" \
				and String(multi_plan_check.get("captureIdentity", "")) == sibling_capture_id
			multi_plan_revision_is_detected = multi_plan_revision_is_detected \
				and mixed_ready_failed_identity_retained
			source_plans.pop_back()
			retained_failure_prep["sourcePlans"] = source_plans
			provider._source_capture_jobs.erase(sibling_capture_id)

	var capture_count_before_revision := main.source_domain_capture_calls
	main.structure_system.revision = "structure-owner-after-capture-failure"
	var terrain_before_revision := main.terrain_revision
	provider.advance_source_domain_captures(8)
	coordinator.wake_visible_section_demand(section,
		"fixture_structure_owner_revision_changed", "structure-revision-2")
	var second_advance: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	var second_results: Array = second_advance.get("results", [])
	var second_admission: Dictionary = second_results[0].get("admission", {}) \
		if not second_results.is_empty() else {}
	var recovery_service_opportunities := 0
	for _opportunity in range(Adapter.SOURCE_CAPTURE_BLOCKED_RETRY_OPPORTUNITIES):
		provider.advance_source_domain_captures(1)
		recovery_service_opportunities += 1
	var recovery_advance: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	var recovery_results: Array = recovery_advance.get("results", [])
	var recovery_admission: Dictionary = recovery_results[0].get("admission", {}) \
		if not recovery_results.is_empty() else {}
	provider.advance_source_domain_captures(8)
	var new_digest: String = ""
	var recaptured_new_owner: bool = false
	for job_value: Variant in provider._source_capture_jobs.values():
		if not job_value is Dictionary:
			continue
		var job: Dictionary = job_value
		var inputs: Dictionary = job.get("sourceInputs", {})
		var digest := String(inputs.get("structureDependencyContentDigest", ""))
		if digest != old_digest and not digest.is_empty():
			new_digest = digest
			recaptured_new_owner = true
	var changed_capture_recorded: bool = main.source_domain_capture_calls > capture_count_before_revision \
		and main.captured_structure_dependency_digests.has(new_digest) \
		and not new_digest.is_empty() and new_digest != old_digest
	var candidate_job: Dictionary = coordinator._section_compile_jobs.get(section, {})
	var candidate_ticket := int(second_admission.get("compileTicket", 0))
	var candidate_census_digest := String(second_admission.get("censusDigest", ""))
	var candidate_job_census: Dictionary = candidate_job.get("census", {})
	var candidate_admission_reached: bool = \
		String(second_admission.get("status", "")) == "queued" \
		and String(second_admission.get("stage", "")) == "native_compile" \
		and candidate_ticket > 0 \
		and int(candidate_job.get("ticket", 0)) == candidate_ticket \
		and int(candidate_job.get("generation", 0)) == int(
			second_admission.get("generation", 0)) \
		and not candidate_census_digest.is_empty() \
		and String(candidate_job_census.get("censusDigest", "")) \
			== candidate_census_digest
	var terrain_stayed_unchanged: bool = main.terrain_revision == terrain_before_revision
	var total_capture_count := main.source_domain_capture_calls
	coordinator.withdraw_visible_section_demand(section)
	provider.reset_source_domain_captures()
	var drained: Dictionary = coordinator.drain_section_compiles()
	var cleanup_drained: bool = drained.get("status") == "drained" \
		and int(drained.get("pendingJobCount", 0)) == 0 \
		and provider.source_domain_capture_pending_count() == 0
	main.free()
	return {"firstFailureStayedWaiting":first_failure_stayed_waiting,
		"firstAdmission":first_admission, "firstReason":first_reason,
		"firstProducerStatus":first_producer_status,
		"unchangedIdentityFailureStaysLatched":unchanged_identity_failure_stays_latched,
		"unchangedRetryStatus":String(unchanged_retry.get("status", "")),
		"unchangedRetryReason":String(unchanged_retry.get("reason", "")),
		"unchangedRetryDemandStage":String(unchanged_retry_demand.get("stage", "")),
		"unchangedRetryDemandRetained":String(unchanged_retry_demand.get("stage", "")) == "waiting" \
			and not unchanged_retry_demand.has("blockedReason"),
		"retainedFailurePreparationStatus":String(retained_failure_prep.get("status", "")),
		"multiPlanRevisionIsDetected":multi_plan_revision_is_detected,
		"multiPlanRevisionReason":multi_plan_revision_reason,
		"mixedReadyFailedIdentityRetained":mixed_ready_failed_identity_retained,
		"terrainStayedUnchanged":terrain_stayed_unchanged,
		"newOwnerRevisionWasCaptured":changed_capture_recorded and recaptured_new_owner,
		"candidateAdmissionReached":candidate_admission_reached,
		"firstStructureDigest":old_digest, "newStructureDigest":new_digest,
		"firstCaptureCount":capture_count_before_revision,
		"totalCaptureCount":total_capture_count,
		"secondAdmission":second_admission,
		"recoveryAdmission":recovery_admission,
		"recoveryServiceOpportunities":recovery_service_opportunities,
		"secondProviderReason":String(recovery_admission.get("providerReason", "")),
		"secondProviderDetails":recovery_admission.get("providerDetails", {}),
		"cleanupDrained":cleanup_drained}

var checks := {}
var _contract_run_started_msec := 0


func _check_partial_capture_removal_history() -> Dictionary:
	var section_a := Vector3i.ZERO
	var section_b := Vector3i(1, 0, 0)
	var main := ProductionAuthority.new()
	main.seed_text = "ecology-partial-removal-history-contract"
	main.seed_hash = 97
	main.underground_required = false
	main.materials["forage"] = StandardMaterial3D.new()
	root.add_child(main)
	var provider = PumpedAdapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	provider.configure(world_id)
	provider.bind_main_authority(main)
	provider.pump_retained_preparation = true
	var source_id := "%s:forage:cross-section-prop" % main.seed_text
	var prop_id := "cross-section-prop"
	var mesh := BoxMesh.new()
	var material: Material = main.materials["forage"]
	var mesh_digest := String(MeshFingerprint.inspect(mesh).get("contentDigest", ""))
	var material_digest := Adapter._material_digest(material)
	var transform := Transform3D(Basis.IDENTITY,
		Vector3(Grid.SECTION_SIZE_METERS - 1.0, 1.0, 2.0))
	var recipe := {"identity":"synthetic-contract-box/v1", "version":1,
		"primitive":"box", "parameters":{"size":Vector3.ONE}}
	var row := {"schema":"ecology.synthetic-source-row/v1", "sourceId":source_id,
		"propId":prop_id, "producerFamily":"forage", "kind":"forage",
		"position":transform.origin, "sourceOrigin":transform.origin,
		"bodyRotation":Vector3.ZERO,
		"renderMembers":[
			{"memberId":"left", "meshRecipe":recipe, "materialKey":"forage",
				"fallbackMaterialKeys":[], "renderLayer":"opaque",
				"transform":Transform3D.IDENTITY, "meshContentDigest":mesh_digest,
				"materialContentDigest":material_digest},
			{"memberId":"right", "meshRecipe":recipe, "materialKey":"forage",
				"fallbackMaterialKeys":[], "renderLayer":"opaque",
				"transform":Transform3D(Basis.IDENTITY, Vector3(0.75, 0.0, 0.0)),
				"meshContentDigest":mesh_digest,
				"materialContentDigest":material_digest}]}
	_apply_fixture_source_bounds_proof(main, world_id, Vector2i.ZERO, row,
		"forage", mesh)
	main.set_fixture_rows(Vector2i.ZERO, [row])
	var initial_capture: Dictionary = provider.capture_static_section_sources(
		world_id, [section_a, section_b])
	var initial_a: Dictionary = provider.query_section(world_id, section_a)
	var initial_b: Dictionary = provider.query_section(world_id, section_b)
	var initially_spans_both: bool = initial_capture.get("status") == "complete" \
		and initial_a.get("status") == "ready" and initial_b.get("status") == "ready" \
		and not initial_a.get("contributors", []).is_empty() \
		and not initial_b.get("contributors", []).is_empty()
	main.removed_props[prop_id] = true
	main.removed_props_revision = 1
	main.set_fixture_rows(Vector2i.ZERO, [])
	var capture_a: Dictionary = provider.capture_static_section_sources(world_id, [section_a])
	var query_a: Dictionary = provider.query_section(world_id, section_a)
	var query_b_before_capture: Dictionary = provider.query_section(world_id, section_b)
	var raw_b_support_owner_demands: Array = query_b_before_capture.get(
		"supportOwnerDemands", []).duplicate(true)
	var raw_b_retired_postings: Variant = provider._support_index \
		._retired_postings_by_section.get(section_b, {}).duplicate(true)
	var retained_b_posting_before_capture := false
	for posting_value: Variant in raw_b_retired_postings.values():
		if posting_value is Dictionary \
				and String(posting_value.get("sourceId", "")) == source_id \
				and String(posting_value.get("memberId", "")) == "right" \
				and String(posting_value.get("state", "")) == "tombstoned" \
				and section_b in posting_value.get("supportSectionKeys", []):
			retained_b_posting_before_capture = true
	var retained_a := _query_has_tombstone(query_a, source_id, "left")
	var retained_b_before_capture := _query_has_tombstone(query_b_before_capture, source_id, "right")
	var capture_b: Dictionary = provider.capture_static_section_sources(world_id, [section_b])
	var query_b: Dictionary = provider.query_section(world_id, section_b)
	var retained_a_after_b := _query_has_tombstone(provider.query_section(world_id,
		section_a), source_id, "left")
	var retained_b := _query_has_tombstone(query_b, source_id, "right")
	var removal_a: Array = capture_a.get("removalsBySection", {}).get(section_a, [])
	var removal_b: Array = capture_b.get("removalsBySection", {}).get(section_b, [])
	var row_a_revision := _tombstone_revision_for(removal_a, source_id, "left")
	var row_b_revision := _tombstone_revision_for(removal_b, source_id, "right")
	var receipt_a := _support_absence_receipt(section_a, query_a)
	var ack_a: Dictionary = provider.acknowledge_section_receipt(section_a,
		int(query_a.get("sourceIndexRevision", -1)), receipt_a)
	var tombstone_b_after_a := _query_has_tombstone(provider.query_section(world_id,
		section_b), source_id, "right")
	var receipt_b := _support_absence_receipt(section_b, query_b)
	var ack_b: Dictionary = provider.acknowledge_section_receipt(section_b,
		int(query_b.get("sourceIndexRevision", -1)), receipt_b)
	var all_retired_after_b: bool = provider.query_section(world_id, section_a).get(
		"supportOwnerDemands", []).is_empty() \
		and provider.query_section(world_id, section_b).get("supportOwnerDemands", []).is_empty()
	main.removed_props.erase(prop_id)
	main.removed_props_revision = 2
	main.set_fixture_rows(Vector2i.ZERO, [row])
	var reappeared_capture: Dictionary = provider.capture_static_section_sources(
		world_id, [section_a])
	var stale_old_receipt: Dictionary = provider.acknowledge_section_receipt(section_b,
		int(query_b.get("sourceIndexRevision", -1)), receipt_b)
	var reappeared_query: Dictionary = provider.query_section(world_id, section_a)
	var reappeared_source_current: bool = reappeared_capture.get("status") == "complete" \
		and _query_has_compiled_source(reappeared_query, source_id, "left")
	main.free()
	return {"initialCaptureStatus":initial_capture.get("status", ""),
		"initialCaptureReason":initial_capture.get("reason", ""),
		"initialCaptureDetails":initial_capture.get("details", {}),
		"initiallySpansBoth":initially_spans_both,
		"captureAStatus":capture_a.get("status", ""), "rowARetained":retained_a,
		"captureAReason":capture_a.get("reason", ""),
		"captureADetails":capture_a.get("details", {}),
		"waitsForB":retained_b_before_capture,
		"queryBBeforeCaptureStatus":String(query_b_before_capture.get("status", "")),
		"queryBBeforeCaptureReason":String(query_b_before_capture.get("reason", "")),
		"queryBBeforeCaptureSourceIndexRevision":int(query_b_before_capture.get(
			"sourceIndexRevision", -1)),
		"queryBBeforeCaptureSupportOwnerDemands":raw_b_support_owner_demands,
		"sectionBRetiredPostingsBeforeCapture":raw_b_retired_postings,
		"retainedBPostingBeforeCapture":retained_b_posting_before_capture,
		"expectedUncapturedRemovalIdentity":{"sourceId":source_id,
			"sourcePartId":"right", "sectionKey":section_b},
		"captureBStatus":capture_b.get("status", ""),
		"captureBReason":capture_b.get("reason", ""),
		"captureBDetails":capture_b.get("details", {}),
		"rowARetainedAfterB":retained_a_after_b, "rowBPresent":retained_b,
		"rowARevision":row_a_revision, "rowBRevision":row_b_revision,
		"ackAStatus":ack_a.get("status", ""), "visibleAfterA":tombstone_b_after_a,
		"ackAReason":ack_a.get("reason", ""),
		"ackBStatus":ack_b.get("status", ""), "retiredAfterB":all_retired_after_b,
		"ackBReason":ack_b.get("reason", ""),
		"reappearedCaptureStatus":reappeared_capture.get("status", ""),
		"reappearedCaptureReason":reappeared_capture.get("reason", ""),
		"reappearedCaptureDetails":reappeared_capture.get("details", {}),
		"staleOldReceiptStatus":stale_old_receipt.get("status", ""),
		"oldRemovalRejected":stale_old_receipt.get("status", "") == "pending",
		"reappearedVisualAndCollisionPreserved":reappeared_source_current}


func _query_has_tombstone(query: Dictionary, source_id: String, source_part_id: String) -> bool:
	for value: Variant in query.get("supportOwnerDemands", []):
		if value is Dictionary and String(value.get("sourceId", "")) == source_id \
				and String(value.get("memberId", "")) == source_part_id \
				and String(value.get("state", "")) == "tombstoned":
			return true
	return false


func _query_has_compiled_source(query: Dictionary, source_id: String, source_part_id: String) -> bool:
	for value: Variant in query.get("supportOwnerDemands", []):
		if value is Dictionary and String(value.get("sourceId", "")) == source_id \
				and String(value.get("memberId", "")) == source_part_id \
				and String(value.get("state", "")) == "compiled":
			return true
	return false


func _tombstone_revision_for(rows: Array, source_id: String, source_part_id: String) -> String:
	for value: Variant in rows:
		if value is Dictionary and String(value.get("sourceId", "")) == source_id \
				and String(value.get("sourcePartId", "")) == source_part_id:
			return String(value.get("sourceRevision", ""))
	return ""


func _support_absence_receipt(section: Vector3i, query: Dictionary) -> Dictionary:
	var absent: Array[Dictionary] = []
	for value: Variant in query.get("supportOwnerDemands", []):
		if not value is Dictionary or String(value.get("state", "")) != "tombstoned":
			continue
		absent.append({"sourceId":String(value.get("sourceId", "")),
			"sourceRevision":String(value.get("sourceRevision", "")),
			"memberId":String(value.get("memberId", "")),
			"ownerSectionKey":value.get("ownerSectionKey", Vector3i.ZERO),
			"supportLeaseToken":String(value.get("supportLeaseToken", ""))})
	return {"schema":"ecology-support-section-install-receipt/v1",
		"sectionKey":section,
		"sourceIndexRevision":int(query.get("sourceIndexRevision", -1)),
		"coverageDigest":String(query.get("coverageCertificate", {}).get(
			"coverageDigest", "")),
		"nativeReceipt":{"receiptId":"synthetic-install:%s" % str(section)},
		"installedMemberReceipts":[], "verifiedAbsentMemberReceipts":absent}


func _check_legacy_partial_capture_removal_history() -> Dictionary:
	var section_a := Vector3i.ZERO
	var section_b := Vector3i(1, 0, 0)
	var main := ProductionAuthority.new()
	main.seed_text = "ecology-partial-removal-history-contract"
	main.seed_hash = 97
	main.underground_required = false
	root.add_child(main)
	var coordinator := ReceiptAuthority.new()
	main.world_static_section_coordinator = coordinator
	var provider = PumpedAdapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	provider.configure(world_id)
	provider.bind_main_authority(main)
	var owner := Node3D.new()
	main.add_child(owner)
	main.chunks[Vector2i.ZERO] = owner
	var source_id := "%s:forage:cross-section-prop" % main.seed_text
	var prop_id := "cross-section-prop"
	var mesh := BoxMesh.new()
	var material := StandardMaterial3D.new()
	var mesh_digest := String(MeshFingerprint.inspect(mesh).get("contentDigest", ""))
	var material_digest := Adapter._material_digest(material)
	var prop_transform := Transform3D(Basis.IDENTITY, Vector3(14.0, 1.0, 1.0))
	var members: Array[Dictionary] = []
	var resource_bindings: Dictionary = {}
	for member_row: Array in [["left", Transform3D.IDENTITY],
		["right", Transform3D(Basis.IDENTITY, Vector3(8.0, 0.0, 0.0))]]:
		var member_id := String(member_row[0])
		var member_transform: Transform3D = member_row[1]
		members.append({"memberId":member_id,
			"meshContentDigest":mesh_digest, "materialContentDigest":material_digest,
			"transform":member_transform,
			"meshBounds":mesh.get_aabb(),
			"localBounds":member_transform * mesh.get_aabb(),
			"materialKey":"forage", "renderLayer":"opaque"})
		var binding := {"mesh":mesh, "material":material,
			"meshContentDigest":mesh_digest, "materialContentDigest":material_digest,
			"materialKey":"forage", "renderLayer":"opaque"}
		binding.make_read_only()
		resource_bindings[source_id + "|" + member_id] = binding
	resource_bindings.make_read_only()
	owner.set_meta("static_ecology_render_resource_bindings", resource_bindings)
	var candidate := {"sourceId":source_id, "propId":prop_id,
		"kind":"realized_static_prop", "category":"forage", "sourceKind":"forage",
		"transform":prop_transform,
		"localBounds":(Transform3D.IDENTITY * mesh.get_aabb()).merge(
			Transform3D(Basis.IDENTITY, Vector3(8.0, 0.0, 0.0)) * mesh.get_aabb()),
		"renderStatus":"ready", "renderMembers":members,
		"provenance":{"producer":"surface_spawn", "chunk":Vector2i.ZERO,
			"sourceRevision":main._ecology_chunk_source_revision(Vector2i.ZERO),
			"terrainRevision":0, "creatorOutputComplete":true}}
	var producer_row := candidate.duplicate(true)
	producer_row["producerFamily"] = "forage"
	producer_row["sourceOrigin"] = prop_transform.origin
	main.set_fixture_rows(Vector2i.ZERO, [producer_row])
	var body := StaticBody3D.new()
	body.set_meta("static_ecology_source_id", source_id)
	owner.add_child(body)
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	body.add_child(visual)
	var collision := CollisionShape3D.new()
	collision.shape = BoxShape3D.new()
	body.add_child(collision)
	var initial_ledger = Ledger.new()
	initial_ledger.configure(main.seed_text, Vector2i.ZERO,
		main._ecology_chunk_source_revision(Vector2i.ZERO), 0, 0)
	initial_ledger.record_candidate(candidate)
	for category: String in ["surface_rocks", "ore", "forage", "underground_props"]:
		initial_ledger.mark_category_complete(category, {"producer":"surface_spawn",
			"chunk":Vector2i.ZERO,
			"sourceRevision":main._ecology_chunk_source_revision(Vector2i.ZERO),
			"terrainRevision":0, "scanRevision":"fixture-floor-scan:0,0",
			"producerComplete":true})
	var initial_snapshot: Dictionary = initial_ledger.snapshot()
	initial_snapshot["status"] = "ready"
	initial_snapshot["producerOwnerInstanceId"] = owner.get_instance_id()
	owner.set_meta("static_ecology_source_value_snapshot", initial_snapshot)
	var adjacent_owner := Node3D.new()
	adjacent_owner.position = Vector3(Grid.STREAM_CHUNK_SIZE_METERS, 0.0, 0.0)
	main.add_child(adjacent_owner)
	main.chunks[Vector2i(1, 0)] = adjacent_owner
	var adjacent_ledger = Ledger.new()
	adjacent_ledger.configure(main.seed_text, Vector2i(1, 0),
		main._ecology_chunk_source_revision(Vector2i(1, 0)), 0, 0)
	for category: String in ["surface_rocks", "ore", "forage", "underground_props"]:
		adjacent_ledger.mark_category_complete(category, {"producer":"surface_spawn",
			"chunk":Vector2i(1, 0),
			"sourceRevision":main._ecology_chunk_source_revision(Vector2i(1, 0)),
			"terrainRevision":0, "scanRevision":"fixture-floor-scan:1,0",
			"producerComplete":true})
	var adjacent_snapshot: Dictionary = adjacent_ledger.snapshot()
	adjacent_snapshot["status"] = "ready"
	adjacent_snapshot["producerOwnerInstanceId"] = adjacent_owner.get_instance_id()
	adjacent_owner.set_meta("static_ecology_source_value_snapshot", adjacent_snapshot)
	var adjacent_bindings: Dictionary = {}
	adjacent_bindings.make_read_only()
	adjacent_owner.set_meta("static_ecology_render_resource_bindings", adjacent_bindings)
	_ensure_complete_empty_source_owners(main, [section_a, section_b])
	var initial_capture: Dictionary = provider.capture_static_section_sources(world_id,
		[section_a, section_b])
	var initial_unit: Dictionary = provider._latest_legacy_visual_units.get(
		"prop:%s" % source_id, {})
	var initially_spans_both: bool = initial_capture.get("status") == "complete" \
		and initial_unit.get("requiredSections", []).has(section_a) \
		and initial_unit.get("requiredSections", []).has(section_b)
	main.removed_props[prop_id] = true
	main.removed_props_revision = 1
	var removed_ledger = Ledger.new()
	removed_ledger.configure(main.seed_text, Vector2i.ZERO,
		main._ecology_chunk_source_revision(Vector2i.ZERO), 1, 0)
	removed_ledger.record_candidate(candidate)
	removed_ledger.record_tombstone(source_id, "removed_props")
	for category: String in ["surface_rocks", "ore", "forage", "underground_props"]:
		removed_ledger.mark_category_complete(category, {"producer":"surface_spawn",
			"chunk":Vector2i.ZERO,
			"sourceRevision":main._ecology_chunk_source_revision(Vector2i.ZERO),
			"terrainRevision":0, "scanRevision":"fixture-floor-scan:0,0",
			"producerComplete":true})
	var removed_snapshot: Dictionary = removed_ledger.snapshot()
	removed_snapshot["status"] = "ready"
	removed_snapshot["producerOwnerInstanceId"] = owner.get_instance_id()
	owner.set_meta("static_ecology_source_value_snapshot", removed_snapshot)
	var capture_a: Dictionary = provider.capture_static_section_sources(world_id, [section_a])
	var after_a: Dictionary = provider._latest_legacy_visual_units.get("prop:%s" % source_id, {})
	var row_a_retained: bool = after_a.get("removalRevisionsBySection", {}).get(
		section_a, {}).has(source_id)
	var waiting_for_b := not provider._legacy_visual_unit_section_is_current(
		after_a, section_b, {})
	var capture_b: Dictionary = provider.capture_static_section_sources(world_id, [section_b])
	var removal_unit: Dictionary = provider._latest_legacy_visual_units.get(
		"prop:%s" % source_id, {}).duplicate(false)
	var retained_a_after_b: bool = removal_unit.get("removalRevisionsBySection", {}).get(
		section_a, {}).has(source_id)
	var has_b_removal: bool = removal_unit.get("removalRevisionsBySection", {}).get(
		section_b, {}).has(source_id)
	var row_a_revision := String(removal_unit.get("removalRevisionsBySection", {}).get(
		section_a, {}).get(source_id, ""))
	var row_b_revision := String(removal_unit.get("removalRevisionsBySection", {}).get(
		section_b, {}).get(source_id, ""))
	var receipt_a := {"status":"installed", "sectionKey":section_a,
		"generation":1, "providerCoverage":[[Adapter.PROVIDER_ID,
			String(provider._latest_coverage_by_section.get(section_a, ""))]]}
	receipt_a.make_read_only()
	var receipt_b := {"status":"installed", "sectionKey":section_b,
		"generation":1, "providerCoverage":[[Adapter.PROVIDER_ID,
			String(provider._latest_coverage_by_section.get(section_b, ""))]]}
	receipt_b.make_read_only()
	var removed_coverage_a := String(provider._latest_coverage_by_section.get(section_a, ""))
	coordinator.accepted[section_a] = receipt_a
	coordinator.accepted[section_b] = receipt_b
	var ack_a: Dictionary = provider.acknowledge_section_install(section_a,
		String(provider._latest_coverage_by_section.get(section_a, "")), receipt_a)
	var still_visible_after_a := visual.visible and body.visible \
		and collision.get_parent() == body and not collision.disabled
	var ack_b: Dictionary = provider.acknowledge_section_install(section_b,
		String(provider._latest_coverage_by_section.get(section_b, "")), receipt_b)
	var retired_after_b := not visual.visible and body.visible \
		and collision.get_parent() == body and not collision.disabled
	main.removed_props.erase(prop_id)
	main.removed_props_revision = 2
	var replacement_body := StaticBody3D.new()
	replacement_body.set_meta("static_ecology_source_id", source_id)
	owner.add_child(replacement_body)
	var replacement_visual := MeshInstance3D.new()
	replacement_visual.mesh = mesh
	replacement_body.add_child(replacement_visual)
	var replacement_collision := CollisionShape3D.new()
	replacement_collision.shape = BoxShape3D.new()
	replacement_body.add_child(replacement_collision)
	var reappeared_ledger = Ledger.new()
	reappeared_ledger.configure(main.seed_text, Vector2i.ZERO,
		main._ecology_chunk_source_revision(Vector2i.ZERO), 2, 0)
	reappeared_ledger.record_candidate(candidate)
	for category: String in ["surface_rocks", "ore", "forage", "underground_props"]:
		reappeared_ledger.mark_category_complete(category, {"producer":"surface_spawn",
			"chunk":Vector2i.ZERO,
			"sourceRevision":main._ecology_chunk_source_revision(Vector2i.ZERO),
			"terrainRevision":0, "scanRevision":"fixture-floor-scan:0,0",
			"producerComplete":true})
	var reappeared_snapshot: Dictionary = reappeared_ledger.snapshot()
	reappeared_snapshot["status"] = "ready"
	reappeared_snapshot["producerOwnerInstanceId"] = owner.get_instance_id()
	owner.set_meta("static_ecology_source_value_snapshot", reappeared_snapshot)
	var reappeared_capture: Dictionary = provider.capture_static_section_sources(world_id,
		[section_a])
	var stale_old_receipt: Dictionary = provider.acknowledge_section_install(section_a,
		removed_coverage_a, receipt_a)
	var old_removal_rejected: bool = not provider._pending_legacy_removal_revisions_by_section \
		.get(section_a, {}).has(source_id) \
		and provider._latest_by_section.get(section_a, {}).has(source_id) \
		and stale_old_receipt.get("status", "") == "pending"
	var reappeared_visible := replacement_visual.visible and replacement_body.visible \
		and replacement_collision.get_parent() == replacement_body \
		and not replacement_collision.disabled
	main.free()
	return {"initialCaptureStatus":initial_capture.get("status", ""),
		"initialCaptureReason":initial_capture.get("reason", ""),
		"initialCaptureDetails":initial_capture.get("details", {}),
		"initiallySpansBoth":initially_spans_both,
		"captureAStatus":capture_a.get("status", ""), "rowARetained":row_a_retained,
		"captureAReason":capture_a.get("reason", ""),
		"waitsForB":waiting_for_b, "captureBStatus":capture_b.get("status", ""),
		"captureBReason":capture_b.get("reason", ""),
		"rowARetainedAfterB":retained_a_after_b, "rowBPresent":has_b_removal,
		"rowARevision":row_a_revision, "rowBRevision":row_b_revision,
		"ackAStatus":ack_a.get("status", ""), "visibleAfterA":still_visible_after_a,
		"ackAReason":ack_a.get("reason", ""),
		"ackBStatus":ack_b.get("status", ""), "retiredAfterB":retired_after_b,
		"ackBReason":ack_b.get("reason", ""),
		"reappearedCaptureStatus":reappeared_capture.get("status", ""),
		"reappearedCaptureReason":reappeared_capture.get("reason", ""),
		"staleOldReceiptStatus":stale_old_receipt.get("status", ""),
		"oldRemovalRejected":old_removal_rejected,
		"reappearedVisualAndCollisionPreserved":reappeared_visible}


func _check_owner_replacement_removal_history() -> Dictionary:
	var section_a := Vector3i.ZERO
	var section_b := Vector3i(1, 0, 0)
	var main := ProductionAuthority.new()
	main.seed_text = "ecology-owner-replacement-contract"
	main.seed_hash = 113
	main.underground_required = false
	root.add_child(main)
	var receipt_authority := ReceiptAuthority.new()
	main.world_static_section_coordinator = receipt_authority
	var provider = PumpedAdapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	provider.configure(world_id)
	provider.bind_main_authority(main)
	var original_owner := Node3D.new()
	main.add_child(original_owner)
	main.chunks[Vector2i.ZERO] = original_owner
	var source_id := "%s:forage:owner-replacement" % main.seed_text
	var prop_id := "owner-replacement"
	var mesh := BoxMesh.new()
	var material := StandardMaterial3D.new()
	var mesh_digest := String(MeshFingerprint.inspect(mesh).get("contentDigest", ""))
	var material_digest := Adapter._material_digest(material)
	var prop_transform := Transform3D(Basis.IDENTITY, Vector3(14.0, 1.0, 1.0))
	var members: Array[Dictionary] = []
	var resource_bindings: Dictionary = {}
	for member_row: Array in [["left", Transform3D.IDENTITY],
		["right", Transform3D(Basis.IDENTITY, Vector3(8.0, 0.0, 0.0))]]:
		var member_id := String(member_row[0])
		var member_transform: Transform3D = member_row[1]
		members.append({"memberId":member_id, "meshContentDigest":mesh_digest,
			"materialContentDigest":material_digest, "transform":member_transform,
			"meshBounds":mesh.get_aabb(),
			"localBounds":member_transform * mesh.get_aabb(),
			"materialKey":"forage", "renderLayer":"opaque"})
		var binding := {"mesh":mesh, "material":material,
			"meshContentDigest":mesh_digest, "materialContentDigest":material_digest,
			"materialKey":"forage", "renderLayer":"opaque"}
		binding.make_read_only()
		resource_bindings[source_id + "|" + member_id] = binding
	resource_bindings.make_read_only()
	original_owner.set_meta("static_ecology_render_resource_bindings", resource_bindings)
	var candidate := {"sourceId":source_id, "propId":prop_id,
		"kind":"realized_static_prop", "category":"forage", "sourceKind":"forage",
		"transform":prop_transform,
		"localBounds":(Transform3D.IDENTITY * mesh.get_aabb()).merge(
			Transform3D(Basis.IDENTITY, Vector3(8.0, 0.0, 0.0)) * mesh.get_aabb()),
		"renderStatus":"ready", "renderMembers":members,
		"provenance":{"producer":"surface_spawn", "chunk":Vector2i.ZERO,
			"sourceRevision":main._ecology_chunk_source_revision(Vector2i.ZERO),
			"terrainRevision":0, "creatorOutputComplete":true}}
	var producer_row := candidate.duplicate(true)
	producer_row["producerFamily"] = "forage"
	producer_row["sourceOrigin"] = prop_transform.origin
	main.set_fixture_rows(Vector2i.ZERO, [producer_row])
	var original_body := StaticBody3D.new()
	original_body.set_meta("static_ecology_source_id", source_id)
	original_owner.add_child(original_body)
	var original_visual := MeshInstance3D.new()
	original_visual.mesh = mesh
	original_body.add_child(original_visual)
	var original_collision := CollisionShape3D.new()
	original_collision.shape = BoxShape3D.new()
	original_body.add_child(original_collision)
	var initial_ledger = Ledger.new()
	initial_ledger.configure(main.seed_text, Vector2i.ZERO,
		main._ecology_chunk_source_revision(Vector2i.ZERO), 0, 0)
	initial_ledger.record_candidate(candidate)
	for category: String in ["surface_rocks", "ore", "forage", "underground_props"]:
		initial_ledger.mark_category_complete(category, {"producer":"surface_spawn",
			"chunk":Vector2i.ZERO,
			"sourceRevision":main._ecology_chunk_source_revision(Vector2i.ZERO),
			"terrainRevision":0, "scanRevision":"owner-floor-scan:0,0",
			"producerComplete":true})
	var initial_snapshot: Dictionary = initial_ledger.snapshot()
	initial_snapshot["status"] = "ready"
	initial_snapshot["producerOwnerInstanceId"] = original_owner.get_instance_id()
	original_owner.set_meta("static_ecology_source_value_snapshot", initial_snapshot)
	var adjacent_owner := Node3D.new()
	adjacent_owner.position = Vector3(Grid.STREAM_CHUNK_SIZE_METERS, 0.0, 0.0)
	main.add_child(adjacent_owner)
	main.chunks[Vector2i(1, 0)] = adjacent_owner
	var adjacent_ledger = Ledger.new()
	adjacent_ledger.configure(main.seed_text, Vector2i(1, 0),
		main._ecology_chunk_source_revision(Vector2i(1, 0)), 0, 0)
	for category: String in ["surface_rocks", "ore", "forage", "underground_props"]:
		adjacent_ledger.mark_category_complete(category, {"producer":"surface_spawn",
			"chunk":Vector2i(1, 0),
			"sourceRevision":main._ecology_chunk_source_revision(Vector2i(1, 0)),
			"terrainRevision":0, "scanRevision":"owner-floor-scan:1,0",
			"producerComplete":true})
	var adjacent_snapshot: Dictionary = adjacent_ledger.snapshot()
	adjacent_snapshot["status"] = "ready"
	adjacent_snapshot["producerOwnerInstanceId"] = adjacent_owner.get_instance_id()
	adjacent_owner.set_meta("static_ecology_source_value_snapshot", adjacent_snapshot)
	var empty_bindings: Dictionary = {}
	empty_bindings.make_read_only()
	adjacent_owner.set_meta("static_ecology_render_resource_bindings", empty_bindings)
	_ensure_complete_empty_source_owners(main, [section_a, section_b])
	var initial_capture: Dictionary = provider.capture_static_section_sources(world_id,
		[section_a, section_b])
	main.removed_props[prop_id] = true
	main.removed_props_revision = 1
	var removed_ledger = Ledger.new()
	removed_ledger.configure(main.seed_text, Vector2i.ZERO,
		main._ecology_chunk_source_revision(Vector2i.ZERO), 1, 0)
	removed_ledger.record_candidate(candidate)
	removed_ledger.record_tombstone(source_id, "removed_props")
	for category: String in ["surface_rocks", "ore", "forage", "underground_props"]:
		removed_ledger.mark_category_complete(category, {"producer":"surface_spawn",
			"chunk":Vector2i.ZERO,
			"sourceRevision":main._ecology_chunk_source_revision(Vector2i.ZERO),
			"terrainRevision":0, "scanRevision":"owner-floor-scan:0,0",
			"producerComplete":true})
	var removed_snapshot: Dictionary = removed_ledger.snapshot()
	removed_snapshot["status"] = "ready"
	removed_snapshot["producerOwnerInstanceId"] = original_owner.get_instance_id()
	original_owner.set_meta("static_ecology_source_value_snapshot", removed_snapshot)
	var capture_a: Dictionary = provider.capture_static_section_sources(world_id, [section_a])
	var partial_unit: Dictionary = provider._latest_legacy_visual_units.get(
		"prop:%s" % source_id, {})
	var partial_a_revision := String(partial_unit.get("removalRevisionsBySection", {}).get(
		section_a, {}).get(source_id, ""))
	var partial_a_only: bool = not partial_a_revision.is_empty() \
		and not partial_unit.get("removalRevisionsBySection", {}).get(section_b, {}).has(source_id)
	var capture_b: Dictionary = provider.capture_static_section_sources(world_id, [section_b])
	var tombstone_unit: Dictionary = provider._latest_legacy_visual_units.get(
		"prop:%s" % source_id, {})
	var merged_a_revision := String(tombstone_unit.get("removalRevisionsBySection", {}).get(
		section_a, {}).get(source_id, ""))
	var old_history_complete: bool = not merged_a_revision.is_empty() \
		and merged_a_revision == partial_a_revision \
		and not String(tombstone_unit.get("removalRevisionsBySection", {}).get(
			section_b, {}).get(source_id, "")).is_empty()
	var old_coverage_b := String(provider._latest_coverage_by_section.get(section_b, ""))
	var old_receipt_b := {"status":"installed", "sectionKey":section_b,
		"generation":3, "providerCoverage":[[Adapter.PROVIDER_ID, old_coverage_b]]}
	old_receipt_b.make_read_only()
	receipt_authority.accepted[section_b] = old_receipt_b
	main.removed_props.erase(prop_id)
	main.removed_props_revision = 2
	var replacement_owner := Node3D.new()
	main.add_child(replacement_owner)
	main.chunks[Vector2i.ZERO] = replacement_owner
	replacement_owner.set_meta("static_ecology_render_resource_bindings", resource_bindings)
	var replacement_body := StaticBody3D.new()
	replacement_body.set_meta("static_ecology_source_id", source_id)
	replacement_owner.add_child(replacement_body)
	var replacement_visual := MeshInstance3D.new()
	replacement_visual.mesh = mesh
	replacement_body.add_child(replacement_visual)
	var replacement_collision := CollisionShape3D.new()
	replacement_collision.shape = BoxShape3D.new()
	replacement_body.add_child(replacement_collision)
	var replacement_ledger = Ledger.new()
	replacement_ledger.configure(main.seed_text, Vector2i.ZERO,
		main._ecology_chunk_source_revision(Vector2i.ZERO), 2, 0)
	replacement_ledger.record_candidate(candidate)
	for category: String in ["surface_rocks", "ore", "forage", "underground_props"]:
		replacement_ledger.mark_category_complete(category, {"producer":"surface_spawn",
			"chunk":Vector2i.ZERO,
			"sourceRevision":main._ecology_chunk_source_revision(Vector2i.ZERO),
			"terrainRevision":0, "scanRevision":"owner-floor-scan:0,0",
			"producerComplete":true})
	var replacement_snapshot: Dictionary = replacement_ledger.snapshot()
	replacement_snapshot["status"] = "ready"
	replacement_snapshot["producerOwnerInstanceId"] = replacement_owner.get_instance_id()
	replacement_owner.set_meta("static_ecology_source_value_snapshot", replacement_snapshot)
	var replacement_capture: Dictionary = provider.capture_static_section_sources(world_id,
		[section_b])
	var current_unit: Dictionary = provider._latest_legacy_visual_units.get(
		"prop:%s" % source_id, {})
	var new_coverage_b := String(provider._latest_coverage_by_section.get(section_b, ""))
	var old_history_not_merged: bool = current_unit.get("chunkOwnerInstanceId", 0) \
		== replacement_owner.get_instance_id() \
		and current_unit.get("chunkOwnerKey", Vector2i(-1, -1)) == Vector2i.ZERO \
		and current_unit.get("removalRevisionsBySection", {}).is_empty() \
		and current_unit.get("sourceRevisions", {}).has(source_id) \
		and current_unit.get("sourceRevisionsBySection", {}).get(section_b, {}).has(source_id)
	var stale_ack: Dictionary = provider.acknowledge_section_install(section_b,
		old_coverage_b, old_receipt_b)
	var replacement_gameplay_preserved := replacement_visual.visible and replacement_body.visible \
		and replacement_collision.get_parent() == replacement_body \
		and not replacement_collision.disabled and original_visual.visible \
		and original_body.visible \
		and original_collision.get_parent() == original_body \
		and not original_collision.disabled
	main.free()
	return {"initialStatus":initial_capture.get("status", ""),
		"initialReason":initial_capture.get("reason", ""),
		"initialDetails":initial_capture.get("details", {}),
		"captureAStatus":capture_a.get("status", ""),
		"captureAReason":capture_a.get("reason", ""),
		"captureADetails":capture_a.get("details", {}),
		"captureBStatus":capture_b.get("status", ""),
		"captureBReason":capture_b.get("reason", ""),
		"captureBDetails":capture_b.get("details", {}),
		"partialAOnly":partial_a_only,
		"oldHistoryComplete":old_history_complete,
		"replacementCaptureStatus":replacement_capture.get("status", ""),
		"replacementCaptureReason":replacement_capture.get("reason", ""),
		"replacementCaptureDetails":replacement_capture.get("details", {}),
		"ownerReplacementDoesNotMergeOldHistory":old_history_not_merged,
		"replacementCoverageChanged":not new_coverage_b.is_empty() \
			and new_coverage_b != old_coverage_b,
		"staleAckStatus":stale_ack.get("status", ""),
		"replacementGameplayPreserved":replacement_gameplay_preserved}


func _check_source_domain_authority_replacement() -> Dictionary:
	var section_key := Vector3i.ZERO
	var seed_text := "ecology-owner-replacement-contract"
	var seed_hash := 113
	var world_id := "seed:%s:%d" % [seed_text, seed_hash]
	var prop_id := "owner-replacement"
	var source_id := "%s:forage:%s" % [seed_text, prop_id]
	var source_part_id := "mushroom_cap"
	var mesh := BoxMesh.new()
	var mesh_digest := String(MeshFingerprint.inspect(mesh).get("contentDigest", ""))
	var material := StandardMaterial3D.new()
	var material_digest := Adapter._material_digest(material)
	var recipe := {"identity":"synthetic-contract-box/v1", "version":1,
		"primitive":"box", "parameters":{"size":Vector3.ONE}}
	var row := {"schema":"ecology.synthetic-source-row/v1", "sourceId":source_id,
		"propId":prop_id, "producerFamily":"forage", "kind":"forage",
		"position":Vector3(4.0, 1.0, 4.0), "sourceOrigin":Vector3(4.0, 1.0, 4.0),
		"bodyRotation":Vector3.ZERO,
		"renderMembers":[{"memberId":source_part_id, "meshRecipe":recipe,
			"materialKey":"forage", "fallbackMaterialKeys":[],
			"renderLayer":"opaque", "transform":Transform3D.IDENTITY,
			"meshContentDigest":mesh_digest, "materialContentDigest":material_digest}]}
	var original_main := ProductionAuthority.new()
	original_main.seed_text = seed_text
	original_main.seed_hash = seed_hash
	original_main.materials["forage"] = material
	_apply_fixture_source_bounds_proof(original_main, world_id, Vector2i.ZERO,
		row, "forage", mesh)
	original_main.set_fixture_rows(Vector2i.ZERO, [row])
	root.add_child(original_main)
	var original_provider = PumpedAdapter.new()
	original_provider.configure(world_id)
	original_provider.bind_main_authority(original_main)
	original_provider.pump_retained_preparation = true
	var original_capture: Dictionary = original_provider.capture_static_section_sources(
		world_id, [section_key])
	var original_snapshot: Dictionary = original_main.fixture_snapshots_by_chunk.get(
		Vector2i.ZERO, {}).duplicate(false)
	original_main.removed_props[prop_id] = true
	original_main.removed_props_revision = 1
	var removed_capture: Dictionary = original_provider.capture_static_section_sources(
		world_id, [section_key])
	var removed_query: Dictionary = original_provider.query_section(world_id, section_key)
	var tombstone_present := _query_has_tombstone(removed_query, source_id, source_part_id)
	var old_coverage := String(original_provider._latest_coverage_by_section.get(section_key, ""))
	var old_receipt := _support_absence_receipt(section_key, removed_query)
	var replacement_main := ProductionAuthority.new()
	replacement_main.seed_text = seed_text
	replacement_main.seed_hash = seed_hash
	replacement_main.materials["forage"] = material
	replacement_main.set_fixture_rows(Vector2i.ZERO, [row])
	root.add_child(replacement_main)
	var replacement_provider = PumpedAdapter.new()
	replacement_provider.configure(world_id)
	replacement_provider.bind_main_authority(replacement_main)
	replacement_provider.pump_retained_preparation = true
	var replacement_capture: Dictionary = replacement_provider.capture_static_section_sources(
		world_id, [section_key])
	var replacement_snapshot: Dictionary = replacement_main.fixture_snapshots_by_chunk.get(
		Vector2i.ZERO, {}).duplicate(false)
	var replacement_query: Dictionary = replacement_provider.query_section(world_id, section_key)
	var new_coverage := String(replacement_provider._latest_coverage_by_section.get(section_key, ""))
	var replacement_record_current := false
	for row_value: Variant in replacement_snapshot.get("sourceRows", []):
		if row_value is Dictionary and String(row_value.get("sourceId", "")) == source_id:
			replacement_record_current = String(replacement_main.ecology_source_record_is_current(
				row_value, replacement_snapshot).get("status", "")) == "ready"
	var stale_ack: Dictionary = replacement_provider.acknowledge_section_receipt(section_key,
		int(removed_query.get("sourceIndexRevision", -1)), old_receipt)
	var replacement_member_is_current: bool = replacement_capture.get("status") == "complete" \
		and _query_has_compiled_source(replacement_query, source_id, source_part_id) \
		and replacement_record_current \
		and not _query_has_tombstone(replacement_query, source_id, source_part_id)
	var semantic_source_revision_stable: bool = not original_snapshot.is_empty() \
		and not replacement_snapshot.is_empty() \
		and String(original_snapshot.get("sourceRevision", "")) == \
			String(replacement_snapshot.get("sourceRevision", ""))
	var catalog_artifact_replaced: bool = not original_snapshot.is_empty() \
		and not replacement_snapshot.is_empty() \
		and String(original_snapshot.get("catalogArtifactId", "")) != \
			String(replacement_snapshot.get("catalogArtifactId", ""))
	var provider_authority_rotated: bool = not String(original_capture.get(
		"authorityRevision", "")).is_empty() \
		and String(original_capture.get("authorityRevision", "")) != \
			String(replacement_capture.get("authorityRevision", ""))
	original_main.free()
	replacement_main.free()
	return {"initialStatus":original_capture.get("status", ""),
		"captureAStatus":removed_capture.get("status", ""),
		"captureBStatus":replacement_capture.get("status", ""),
		"removedSourceHasExactSectionTombstone":tombstone_present,
		"oldTombstoneHasExactMemberLease":not old_coverage.is_empty() \
			and old_receipt.get("verifiedAbsentMemberReceipts", []).size() == 1,
		"replacementCaptureStatus":replacement_capture.get("status", ""),
		"ownerReplacementDoesNotMergeOldHistory":replacement_member_is_current,
		"replacementCoverageChanged":not new_coverage.is_empty() and new_coverage != old_coverage,
		"staleAckStatus":stale_ack.get("status", ""),
		"replacementValueSourceIsCurrent":replacement_member_is_current,
		"semanticSourceRevisionStable":semantic_source_revision_stable,
		"catalogArtifactReplaced":catalog_artifact_replaced,
		"providerAuthorityRotated":provider_authority_rotated}

func _init() -> void:
	call_deferred("run")


func _check_legacy_visual_retirement_receipt_gate() -> void:
	var main := ProductionAuthority.new()
	root.add_child(main)
	var coordinator := ReceiptAuthority.new()
	main.world_static_section_coordinator = coordinator
	var provider = PumpedAdapter.new()
	provider.configure("seed:ecology-retirement-contract:31")
	provider.bind_main_authority(main)
	var chunk := Node3D.new()
	main.add_child(chunk)
	var body := StaticBody3D.new()
	body.set_meta("static_ecology_source_id", "prop:revision-1")
	chunk.add_child(body)
	var visual := MeshInstance3D.new()
	visual.mesh = BoxMesh.new()
	body.add_child(visual)
	var collision := CollisionShape3D.new()
	collision.shape = BoxShape3D.new()
	body.add_child(collision)
	var section_a := Vector3i.ZERO
	var section_b := Vector3i(1, 0, 0)
	var required: Array[Vector3i] = [section_a, section_b]
	required.make_read_only()
	var targets: Array[WeakRef] = [weakref(visual)]
	targets.make_read_only()
	var unit := {"kind":"static_prop", "sourceId":"prop:revision-1",
		"unitRevision":"unit-revision-1", "chunkOwner":weakref(chunk),
		"chunkOwnerInstanceId":chunk.get_instance_id(),
		"requiredSections":required, "targets":targets,
		"sourceRevisionsBySection":{},
		"removalRevisionsBySection":{
			section_a:{"prop:revision-1":"durable-tombstone:r5"},
			section_b:{"prop:revision-1":"authoritative-absence:r9"}}}
	var receipt_a := {"status":"installed", "sectionKey":section_a,
		"generation":4, "contentManifestDigest":"section-a"}
	receipt_a.make_read_only()
	var receipt_b := {"status":"installed", "sectionKey":section_b,
		"generation":7, "contentManifestDigest":"section-b"}
	receipt_b.make_read_only()
	var unrelated_visual := MeshInstance3D.new()
	unrelated_visual.mesh = BoxMesh.new()
	chunk.add_child(unrelated_visual)
	var invalid_targets: Array[WeakRef] = [weakref(visual), weakref(unrelated_visual)]
	invalid_targets.make_read_only()
	var invalid_target_unit: Dictionary = unit.duplicate(false)
	invalid_target_unit["targets"] = invalid_targets
	var invalid_target_rejected: bool = not provider._retire_legacy_visual_unit(
		invalid_target_unit)
	var invalid_target_kept_all: bool = visual.visible and unrelated_visual.visible
	coordinator.accepted[section_a] = receipt_a
	var receipts := {section_a:receipt_a}
	var incomplete_rejected: bool = not provider._legacy_visual_unit_receipts_are_current(
		unit, receipts)
	var kept_until_complete: bool = visual.visible and is_instance_valid(body) \
		and is_instance_valid(collision)
	receipts[section_b] = receipt_b
	coordinator.accepted[section_b] = {"status":"installed",
		"sectionKey":section_b, "generation":6,
		"contentManifestDigest":"stale-generation"}
	var stale_receipt_rejected: bool = not provider._legacy_visual_unit_receipts_are_current(
		unit, receipts)
	coordinator.accepted[section_b] = receipt_b
	var complete_receipts_current: bool = provider._legacy_visual_unit_receipts_are_current(
		unit, receipts)
	var retired: bool = complete_receipts_current \
		and provider._retire_legacy_visual_unit(unit)
	var retired_visual_hidden := not visual.visible
	provider._pending_legacy_removal_revisions_by_section = {
		section_a:{"prop:revision-1":"durable-tombstone:r5"},
		section_b:{"prop:revision-1":"authoritative-absence:r9"}}
	var gone_visual_ref: WeakRef = weakref(visual)
	visual.free()
	var gone_targets: Array[WeakRef] = [gone_visual_ref]
	gone_targets.make_read_only()
	var tombstoned_unit: Dictionary = unit.duplicate(false)
	tombstoned_unit["targets"] = gone_targets
	tombstoned_unit["sourceRevisions"] = {}
	tombstoned_unit["sourceRevisionsBySection"] = {
		section_a:{}, section_b:{}}
	var absent_visual_retired := provider._retire_legacy_visual_unit(tombstoned_unit)
	provider._latest_by_section[section_a] = {"prop:revision-1":"replacement:r6"}
	var replacement_body := StaticBody3D.new()
	replacement_body.set_meta("static_ecology_source_id", "prop:revision-1")
	chunk.add_child(replacement_body)
	var replacement_visual := MeshInstance3D.new()
	replacement_visual.mesh = BoxMesh.new()
	replacement_body.add_child(replacement_visual)
	var live_replacement_rejected := not provider._retire_legacy_visual_unit( \
		tombstoned_unit) and replacement_visual.visible
	provider._latest_by_section.erase(section_a)
	var stale_tombstone_unit: Dictionary = tombstoned_unit.duplicate(false)
	stale_tombstone_unit["removalRevisionsBySection"] = {
		section_a:{"prop:revision-1":"stale-tombstone:r4"},
		section_b:{"prop:revision-1":"authoritative-absence:r9"}}
	var stale_tombstone_rejected := not provider._retire_legacy_visual_unit(
		stale_tombstone_unit)
	var tombstone_current: bool = provider._legacy_visual_unit_section_is_current(
		unit, section_a, {})
	var authoritative_absence_current: bool = provider._legacy_visual_unit_section_is_current(
		unit, section_b, {})
	provider._pending_legacy_removal_revisions_by_section[section_b]["prop:revision-1"] = \
		"stale-absence:r8"
	var stale_removal_rejected: bool = not provider._legacy_visual_unit_section_is_current(
		unit, section_b, {})
	var missing_removal_rejected: bool = not provider._legacy_visual_unit_section_is_current(
		unit, Vector3i(2, 0, 0), {})
	check("retirement_tombstone_revision_is_current", tombstone_current)
	check("retirement_authoritative_absence_revision_is_current", authoritative_absence_current)
	check("retirement_stale_removal_revision_is_rejected", stale_removal_rejected)
	check("retirement_missing_removal_revision_is_rejected", missing_removal_rejected)
	check("retirement_missing_second_native_receipt_is_rejected", incomplete_rejected)
	check("retirement_stale_native_receipt_is_rejected", stale_receipt_rejected)
	check("retirement_invalid_late_target_preserves_all_visuals",
		invalid_target_rejected and invalid_target_kept_all)
	check("harvested_prop_weak_visual_can_retire_only_after_exact_tombstone",
		absent_visual_retired and live_replacement_rejected and stale_tombstone_rejected)
	check("retirement_keeps_live_body_and_collision", body.visible \
		and collision.get_parent() == body and not collision.disabled)
	check("legacy_prop_visual_waits_for_every_current_affected_section_receipt",
		incomplete_rejected and kept_until_complete and stale_receipt_rejected \
		and complete_receipts_current and retired and retired_visual_hidden \
		and body.visible and collision.get_parent() == body and not collision.disabled \
		and invalid_target_rejected and invalid_target_kept_all \
		and tombstone_current and authoritative_absence_current \
		and stale_removal_rejected and missing_removal_rejected)
	check("removed_prop_visual_waits_for_exact_tombstone_or_authoritative_absence",
		tombstone_current and authoritative_absence_current \
		and stale_removal_rejected and missing_removal_rejected \
		and absent_visual_retired and live_replacement_rejected and stale_tombstone_rejected \
		and body.visible and not collision.disabled)
	main.free()


func check(name: String, condition: bool) -> void:
	checks[name] = condition


func _candidate(source_id: String, x: float, instance_color: Color,
		detail_type := "grass", mesh_value: Mesh = null) -> Dictionary:
	var mesh: Mesh = mesh_value if is_instance_valid(mesh_value) else BoxMesh.new()
	var transform := Transform3D(Basis.IDENTITY, Vector3(x, 1.0, 1.0))
	var material_key := "detailFlower" if detail_type == "flowerBloom" else "detailGrass"
	return {
		"sourceId":source_id,
		"kind":"surface_detail",
		"detailType":detail_type,
		"renderLayers":["alpha_scissor"],
		"materials":[material_key],
		"meshSource":"procedural_detail:%s" % detail_type,
		"transform":transform,
		"meshBounds":mesh.get_aabb(),
		"instanceColor":instance_color,
		"customData":Color(0.37, 0.0, 0.0, 1.0),
		"localBounds":transform * mesh.get_aabb(),
		"shadowCasting":"off",
		"visibilityRangeEnd":64.0
	}


func _synthetic_detail_source_row(source_id: String, detail_type: String, x: float,
		mesh: Mesh, material: Material, material_key: String) -> Dictionary:
	var transform := Transform3D(Basis.IDENTITY, Vector3(x, 1.0, 1.0))
	return {"schema":"ecology.synthetic-source-row/v1",
		"sourceId":source_id, "producerFamily":"details", "kind":"surface_detail",
		"sourceOrigin":transform.origin,
		"detailType":detail_type, "surfaceIndex":-1,
		"renderLayers":["opaque"], "materials":[material_key],
		"meshSource":"procedural_detail:%s" % detail_type,
		"meshContentDigest":String(MeshFingerprint.inspect(mesh).get("contentDigest", "")),
		"materialContentDigest":Adapter._material_digest(material),
		"resourceContentIdentitySchema":"ecology-render-member-content/v1",
		"transform":transform, "meshBounds":mesh.get_aabb(), "instanceColor":Color.WHITE,
		"customData":Color(0.37, 0.0, 0.0, 1.0),
		"localBounds":transform * mesh.get_aabb(), "shadowCasting":"off",
		"visibilityRangeEnd":64.0}


func _apply_fixture_source_bounds_proof(main: Object, world_id: String,
		source_chunk_key: Vector2i, row: Dictionary, family: String,
		mesh: Mesh) -> Dictionary:
	if not is_instance_valid(main) or not is_instance_valid(mesh) \
			or not main.has_method("_canonical_fixture_inputs") \
			or not main.has_method("_fixture_artifact_for") \
			or not row.get("renderMembers", null) is Array:
		return {"status":"pending", "reason":"fixture_source_bounds_inputs_missing"}
	var chunk_origin := Vector3(float(source_chunk_key.x) \
		* Grid.STREAM_CHUNK_SIZE_METERS, 0.0,
		float(source_chunk_key.y) * Grid.STREAM_CHUNK_SIZE_METERS)
	var body_transform := Transform3D.IDENTITY
	var transform_value: Variant = row.get("transform", null)
	if transform_value is Transform3D:
		body_transform = transform_value
	else:
		var position: Variant = row.get("position", Vector3.ZERO)
		var rotation: Variant = row.get("bodyRotation", Vector3.ZERO)
		if not position is Vector3 or not rotation is Vector3:
			return {"status":"pending", "reason":"fixture_source_body_transform_missing"}
		body_transform = Transform3D(Basis.from_euler(rotation), position)
	var raw_mesh_bounds := mesh.get_aabb()
	var local_bounds := AABB()
	var world_bounds := AABB()
	var has_bounds := false
	var members: Array = row.get("renderMembers", [])
	for member_value: Variant in members:
		if not member_value is Dictionary:
			return {"status":"pending", "reason":"fixture_source_member_invalid"}
		var member: Dictionary = member_value
		var member_transform_value: Variant = member.get("transform", Transform3D.IDENTITY)
		if not member_transform_value is Transform3D:
			return {"status":"pending", "reason":"fixture_source_member_transform_missing"}
		var member_transform: Transform3D = member_transform_value
		var member_local_bounds: AABB = member_transform * raw_mesh_bounds
		var member_world_bounds: AABB = Transform3D(Basis.IDENTITY, chunk_origin) \
			* body_transform * member_transform * raw_mesh_bounds
		member["meshBounds"] = raw_mesh_bounds
		member["localBounds"] = member_local_bounds
		local_bounds = member_local_bounds if not has_bounds \
			else local_bounds.merge(member_local_bounds)
		world_bounds = member_world_bounds if not has_bounds \
			else world_bounds.merge(member_world_bounds)
		has_bounds = true
	if not has_bounds:
		return {"status":"pending", "reason":"fixture_source_bounds_empty"}
	row["renderMembers"] = members
	row["localBounds"] = local_bounds
	var source_origin: Vector3 = chunk_origin + body_transform.origin
	row["sourceOrigin"] = source_origin
	var inputs: Dictionary = main.call("_canonical_fixture_inputs", world_id,
		source_chunk_key, String(main.get("seed_text")), {})
	var artifact: Dictionary = main.call("_fixture_artifact_for", inputs)
	if inputs.is_empty() or artifact.is_empty():
		return {"status":"pending", "reason":"fixture_source_support_policy_missing"}
	var support_policy := ProducerDomain.support_policy(inputs, artifact)
	var proof := ProducerDomain.validate_source_bounds(family, source_origin,
		world_bounds, support_policy)
	proof["worldBounds"] = world_bounds
	proof["sourceOrigin"] = source_origin
	proof["influencePolicyRevision"] = String(support_policy.get("revision", ""))
	proof["influencePolicyDigest"] = String(support_policy.get("digest", ""))
	row["supportProof"] = proof
	return proof


func _forward_transform_aabb(mesh_bounds: AABB, world_transform: Transform3D) -> AABB:
	var result := AABB()
	var has_corner := false
	for x: float in [mesh_bounds.position.x, mesh_bounds.end.x]:
		for y: float in [mesh_bounds.position.y, mesh_bounds.end.y]:
			for z: float in [mesh_bounds.position.z, mesh_bounds.end.z]:
				var world_corner: Vector3 = world_transform * Vector3(x, y, z)
				if not has_corner:
					result = AABB(world_corner, Vector3.ZERO)
					has_corner = true
				else:
					result = result.expand(world_corner)
	return result


func _ensure_complete_empty_source_owners(main: ProductionAuthority,
		requested_sections: Array[Vector3i]) -> Array[Vector2i]:
	var closure_keys: Dictionary = {}
	for section_key: Vector3i in requested_sections:
		var section_bounds := AABB(Grid.origin_for_key(section_key),
			Vector3.ONE * Grid.SECTION_SIZE_METERS)
		var closure_bounds := AABB(
			section_bounds.position - Vector3(5.0, 0.0, 5.0),
			section_bounds.size + Vector3(10.0, 0.0, 10.0))
		for chunk_key: Vector2i in Partitioner._stream_chunks_intersecting_bounds(closure_bounds):
			closure_keys[chunk_key] = true
	var admitted: Array[Vector2i] = []
	for chunk_value: Variant in closure_keys:
		var chunk_key := Vector2i(chunk_value)
		admitted.append(chunk_key)
		var owner: Node3D = main.chunks.get(chunk_key) as Node3D
		if is_instance_valid(owner):
			continue
		owner = Node3D.new()
		owner.position = Vector3(chunk_key.x * Grid.STREAM_CHUNK_SIZE_METERS,
			0.0, chunk_key.y * Grid.STREAM_CHUNK_SIZE_METERS)
		main.add_child(owner)
		main.chunks[chunk_key] = owner
		var source_revision := main._ecology_chunk_source_revision(chunk_key)
		var ledger = Ledger.new()
		ledger.configure(main.seed_text, chunk_key, source_revision, main.removed_props_revision, 0)
		for category: String in ["surface_rocks", "ore", "forage", "underground_props"]:
			ledger.mark_category_complete(category, {"producer":"fixture_empty_source_owner",
				"chunk":chunk_key, "sourceRevision":source_revision, "terrainRevision":0,
				"scanRevision":"fixture-empty-scan:%d,%d" % [chunk_key.x, chunk_key.y],
				"producerComplete":true})
		var snapshot: Dictionary = ledger.snapshot()
		snapshot["status"] = "ready"
		snapshot["producerOwnerInstanceId"] = owner.get_instance_id()
		owner.set_meta("static_ecology_source_value_snapshot", snapshot)
		var resource_bindings: Dictionary = {}
		resource_bindings.make_read_only()
		owner.set_meta("static_ecology_render_resource_bindings", resource_bindings)
	return admitted


func _snapshot(rows: Array, seed := "ecology-adapter-contract",
		producer_revision := "detail-producer-revision-1",
		chunk_key := Vector2i.ZERO) -> Dictionary:
	var ledger = Ledger.new()
	ledger.configure(seed, chunk_key, producer_revision, 0)
	for row: Dictionary in rows:
		if not ledger.record_candidate(row):
			return {}
	return ledger.snapshot()


func _source_part_key(source_id: String, source_part_id: String) -> String:
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


func _query_contributor_for_pair(query: Dictionary, source_id: String,
		source_part_id: String, state := "compiled") -> Dictionary:
	for row_value: Variant in query.get("contributors", []):
		if row_value is Dictionary and String(row_value.get("sourceId", "")) == source_id \
				and String(row_value.get("sourcePartId", "")) == source_part_id \
				and String(row_value.get("state", "")) == state:
			return row_value
	return {}


func _query_lease_token_for_pair_and_domain(query: Dictionary, source_id: String,
		source_part_id: String, source_domain_revision: String) -> String:
	for lease_value: Variant in query.get("supportOwnerDemands", []):
		if lease_value is Dictionary and String(lease_value.get("sourceId", "")) == source_id \
				and String(lease_value.get("memberId", "")) == source_part_id \
				and String(lease_value.get("sourceDomainRevision", "")) == source_domain_revision:
			return String(lease_value.get("supportLeaseToken", ""))
	return ""


func _bindings() -> Dictionary:
	return _bindings_with_resources(null, null)


func _bindings_with_resources(mesh_override: Mesh, material_override: Material) -> Dictionary:
	var mesh: Mesh = mesh_override if is_instance_valid(mesh_override) else BoxMesh.new()
	var material: Material = material_override if is_instance_valid(material_override) \
		else StandardMaterial3D.new()
	if material is StandardMaterial3D and material_override == null:
		(material as StandardMaterial3D).albedo_color = Color(0.62, 0.78, 0.44, 1.0)
	if material is BaseMaterial3D:
		(material as BaseMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	var binding := {"mesh":mesh, "material":material,
		"meshSource":"procedural_detail:grass",
		"meshResourceKey":"environment.detail.grass/v1",
		"materialKey":"detailGrass",
		"materialContentDigest":Adapter._material_digest(material),
		"pipelineRevision":"detail_pipeline_contract/v1",
		"fadeMargin":12.0}
	binding.make_read_only()
	var bindings := {"procedural_detail:grass|detailGrass":binding}
	bindings.make_read_only()
	return bindings


func _flower_surface_bindings() -> Dictionary:
	var grass_mesh := BoxMesh.new()
	var flower_mesh := BoxMesh.new()
	var grass_material := StandardMaterial3D.new()
	var flower_material := StandardMaterial3D.new()
	grass_material.albedo_color = Color(0.24, 0.55, 0.2, 1.0)
	flower_material.albedo_color = Color(0.92, 0.28, 0.52, 1.0)
	grass_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	flower_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	var grass_binding := {"mesh":grass_mesh, "material":grass_material,
		"meshSource":"procedural_detail:flowerBloom:surface:0",
		"meshResourceKey":"environment.detail.flowerBloom.surface.0/v1",
		"materialKey":"detailGrass",
		"materialContentDigest":Adapter._material_digest(grass_material),
		"pipelineRevision":"detail_pipeline_contract/v1", "fadeMargin":12.0}
	var flower_binding := {"mesh":flower_mesh, "material":flower_material,
		"meshSource":"procedural_detail:flowerBloom:surface:1",
		"meshResourceKey":"environment.detail.flowerBloom.surface.1/v1",
		"materialKey":"detailFlower",
		"materialContentDigest":Adapter._material_digest(flower_material),
		"pipelineRevision":"detail_pipeline_contract/v1", "fadeMargin":12.0}
	grass_binding.make_read_only()
	flower_binding.make_read_only()
	var bindings := {
		"procedural_detail:flowerBloom:surface:0|detailGrass":grass_binding,
		"procedural_detail:flowerBloom:surface:1|detailFlower":flower_binding
	}
	bindings.make_read_only()
	return bindings


func _run_realized_prop_assembler_contract() -> Dictionary:
	var section_key := Vector3i.ZERO
	var interleaved_section_key := Vector3i(1, 0, 0)
	var underground_section_key := Vector3i(0, -2, 0)
	var main := ProductionAuthority.new()
	main.seed_text = "ecology-realized-assembler-contract"
	main.seed_hash = 83
	main.underground_required = false
	root.add_child(main)
	var provider = PumpedAdapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	provider.configure(world_id)
	provider.bind_main_authority(main)
	provider.pump_retained_preparation = true
	var mesh := BoxMesh.new()
	var actual_detail_mesh := BoxMesh.new()
	actual_detail_mesh.size = Vector3(0.6, 0.8, 0.4)
	main.production_mesh = actual_detail_mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.5, 0.72, 0.42, 1.0)
	var detail_shader := load("res://resources/visual/detail_material.gdshader") as Shader
	var detail_material := ShaderMaterial.new()
	detail_material.shader = detail_shader
	detail_material.set_shader_parameter("base_color", Color(0.5, 0.72, 0.42, 1.0))
	main.production_material = detail_material
	main.materials["detailGrass"] = detail_material
	main.materials["detailFlower"] = detail_material
	main.materials["forage"] = material
	var source_id := "%s:forage:adapter-prop" % main.seed_text
	var underground_source_id := "%s:underground:adapter-prop" % main.seed_text
	var underground_transform := Transform3D(Basis.IDENTITY, Vector3(2.0, -30.0, 2.0))
	var prop_mesh_digest := String(MeshFingerprint.inspect(mesh).get("contentDigest", ""))
	var prop_material_digest := Adapter._material_digest(material)
	var box_recipe := {"identity":"synthetic-contract-box/v1", "version":1,
		"primitive":"box", "parameters":{"size":mesh.size}}
	var forage_row := {"schema":"ecology.synthetic-source-row/v1",
		"sourceId":source_id, "propId":"adapter-prop", "producerFamily":"forage",
				"kind":"forage", "position":Vector3(2.0, 0.0, 2.0),
				"sourceOrigin":Vector3(2.0, 0.0, 2.0),
				"localBounds":mesh.get_aabb(),
				"bodyRotation":Vector3.ZERO,
				"renderMembers":[{"memberId":"mushroom_cap", "meshRecipe":box_recipe,
					"materialKey":"forage", "fallbackMaterialKeys":[], "renderLayer":"opaque",
					"transform":Transform3D.IDENTITY, "meshContentDigest":prop_mesh_digest,
					"materialContentDigest":prop_material_digest, "meshBounds":mesh.get_aabb(),
					"localBounds":mesh.get_aabb()}]}
	var underground_row := {"schema":"ecology.synthetic-source-row/v1",
		"sourceId":underground_source_id, "propId":"adapter-underground-prop",
				"producerFamily":"underground_props", "kind":"ore",
				"position":underground_transform.origin,
				"sourceOrigin":underground_transform.origin,
				"localBounds":mesh.get_aabb(), "bodyRotation":Vector3.ZERO,
				"renderMembers":[{"memberId":"underground_ore", "meshRecipe":box_recipe,
					"materialKey":"forage", "fallbackMaterialKeys":[], "renderLayer":"opaque",
					"transform":Transform3D.IDENTITY, "meshContentDigest":prop_mesh_digest,
					"materialContentDigest":prop_material_digest, "meshBounds":mesh.get_aabb(),
					"localBounds":mesh.get_aabb()}]}
	var grass_detail := _synthetic_detail_source_row(
		"%s:detail:0,0:grass:0" % main.seed_text, "grass", 3.0,
		actual_detail_mesh, detail_material, "detailGrass")
	var flower_detail := _synthetic_detail_source_row(
		"%s:detail:0,0:flowerBloom:0" % main.seed_text, "flowerBloom", 4.0,
		actual_detail_mesh, detail_material, "detailFlower")
	main.set_fixture_rows(Vector2i.ZERO,
		[forage_row, underground_row, grass_detail, flower_detail])
	var prop_ledger: Object = null
	var prop_chunk: Node3D = null
	var setup_chunk_keys: Dictionary = {}
	for requested_section: Vector3i in [section_key, interleaved_section_key]:
		for chunk_key: Vector2i in provider._chunks_for_section(requested_section):
			setup_chunk_keys[chunk_key] = true
	for chunk_value: Variant in setup_chunk_keys:
		var chunk_key := Vector2i(chunk_value)
		var chunk_owner := Node3D.new()
		chunk_owner.position = Vector3(chunk_key.x * Grid.STREAM_CHUNK_SIZE_METERS,
			0.0, chunk_key.y * Grid.STREAM_CHUNK_SIZE_METERS)
		main.add_child(chunk_owner)
		main.chunks[chunk_key] = chunk_owner
		var source_revision := main._ecology_chunk_source_revision(chunk_key)
		var ledger = Ledger.new()
		ledger.configure(main.seed_text, chunk_key, source_revision, 0, 0)
		if chunk_key == Vector2i.ZERO:
			prop_ledger = ledger
			prop_chunk = chunk_owner
			var mesh_digest := String(MeshFingerprint.inspect(mesh).get("contentDigest", ""))
			var material_digest := Adapter._material_digest(material)
			var prop_transform := Transform3D(Basis.IDENTITY, Vector3(2, 0, 2))
			var candidate := {"sourceId":source_id, "propId":"adapter-prop",
				"kind":"realized_static_prop", "category":"forage", "sourceKind":"forage",
				"transform":prop_transform,
				"localBounds":mesh.get_aabb(),
				"renderStatus":"ready", "renderMembers":[{"memberId":"mushroom_cap",
					"meshContentDigest":mesh_digest, "materialContentDigest":material_digest,
					"transform":Transform3D.IDENTITY, "meshBounds":mesh.get_aabb(),
					"localBounds":mesh.get_aabb(),
					"materialKey":"forage", "renderLayer":"opaque"}],
				"provenance":{"producer":"surface_spawn", "chunk":chunk_key,
					"sourceRevision":source_revision, "terrainRevision":0,
					"creatorOutputComplete":true}}
			ledger.record_candidate(candidate)
			var underground_candidate := {"sourceId":underground_source_id,
				"propId":"adapter-underground-prop", "kind":"realized_static_prop",
				"category":"underground_props", "sourceKind":"ore",
				"transform":underground_transform,
				"localBounds":mesh.get_aabb(),
				"renderStatus":"ready", "renderMembers":[{"memberId":"underground_ore",
					"meshContentDigest":mesh_digest, "materialContentDigest":material_digest,
					"transform":Transform3D.IDENTITY, "meshBounds":mesh.get_aabb(),
					"localBounds":mesh.get_aabb(),
					"materialKey":"forage", "renderLayer":"opaque"}],
				"provenance":{"producer":"underground_exposed_floor_scan",
					"chunk":chunk_key, "sourceRevision":source_revision,
					"terrainRevision":0, "scanRevision":"fixture-floor-scan:0,0",
					"creatorOutputComplete":true}}
			ledger.record_candidate(underground_candidate)
			ledger.record_candidate(_candidate(
				"%s:detail:0,0:grass:0" % main.seed_text, 3.0, Color.WHITE, "grass",
				actual_detail_mesh))
			ledger.record_candidate(_candidate(
				"%s:detail:0,0:flowerBloom:0" % main.seed_text, 4.0, Color.WHITE,
				"flowerBloom", actual_detail_mesh))
		for category: String in ["surface_rocks", "ore", "forage"]:
			ledger.mark_category_complete(category, {"producer":"surface_spawn",
				"chunk":chunk_key, "sourceRevision":source_revision,
				"terrainRevision":0, "producerComplete":true})
		ledger.mark_category_complete("underground_props", {
			"producer":"underground_exposed_floor_scan", "chunk":chunk_key,
			"sourceRevision":source_revision, "terrainRevision":0,
			"scanRevision":"fixture-floor-scan:%d,%d" % [chunk_key.x, chunk_key.y],
			"producerComplete":true})
		var snapshot: Dictionary = ledger.snapshot()
		snapshot["status"] = "ready"
		snapshot["producerOwnerInstanceId"] = chunk_owner.get_instance_id()
		chunk_owner.set_meta("static_ecology_source_value_snapshot", snapshot)
		var resource_map: Dictionary = {}
		if chunk_key == Vector2i.ZERO:
			var resource_binding := {"mesh":mesh, "material":material,
				"meshContentDigest":String(MeshFingerprint.inspect(mesh).get("contentDigest", "")),
				"materialContentDigest":Adapter._material_digest(material),
				"materialKey":"forage", "renderLayer":"opaque"}
			resource_binding.make_read_only()
			resource_map[source_id + "|mushroom_cap"] = resource_binding
			var underground_resource_binding := {"mesh":mesh, "material":material,
				"meshContentDigest":String(MeshFingerprint.inspect(mesh).get("contentDigest", "")),
				"materialContentDigest":Adapter._material_digest(material),
				"materialKey":"forage", "renderLayer":"opaque"}
			underground_resource_binding.make_read_only()
			resource_map[underground_source_id + "|underground_ore"] = underground_resource_binding
		resource_map.make_read_only()
		chunk_owner.set_meta("static_ecology_render_resource_bindings", resource_map)
	_ensure_complete_empty_source_owners(main, [section_key, interleaved_section_key])
	var roster := Roster.new()
	roster.bind_world(world_id, [Adapter.PROVIDER_ID])
	roster.register_provider(Adapter.PROVIDER_ID, provider, "capture_static_section_sources")
	var unsupported_census: Dictionary = roster.capture_sections([section_key])
	var unsupported_provider_census: Dictionary = provider.capture_static_section_sources(
		world_id, [section_key])
	var unsupported_detail_ids: Array[String] = [
		"%s:detail:0,0:flowerBloom:0" % main.seed_text]
	var unsupported_detail_part_ids: Array[String] = ["surface:-1"]
	main.unsupported_flower_material = false
	var direct_census := provider.capture_static_section_sources(world_id,
		[section_key, interleaved_section_key])
	main.underground_required = true
	var underground_required_census := provider.capture_static_section_sources(
		world_id, [section_key, interleaved_section_key, underground_section_key])
	var underground_census: Dictionary = roster.capture_sections([underground_section_key])
	var underground_contribution: Dictionary = provider.capture_static_section_contribution(
		underground_census, underground_section_key) \
		if underground_census.get("status") == "complete" else {}
	main.underground_required = false
	var census: Dictionary = roster.capture_sections([section_key, interleaved_section_key])
	var initial_support_query: Dictionary = provider.query_section(world_id, section_key)
	var initial_interleaved_ids: Array = census.get("expectedContributorsBySection", {}) \
		.get(interleaved_section_key, [])
	var interleaved_census: Dictionary = roster.capture_sections([interleaved_section_key])
	var latest_after_initial_census: Dictionary = provider._latest_by_section.duplicate(true)
	var expected_sources: Array = census.get("expectedContributorsBySection", {}) \
		.get(section_key, [])
	var contribution_result: Dictionary = provider.capture_static_section_contribution(
		census, section_key) if census.get("status") == "complete" else {}
	var contributions: Array = []
	if contribution_result.get("status") == "ready":
		contributions.append(contribution_result.contribution)
	contributions.make_read_only()
	var assembled: Dictionary = Assembler.assemble(census, section_key, contributions, 1) \
		if contribution_result.get("status") == "ready" else {}
	var manifest_ids: Array[String] = []
	for row_value: Variant in assembled.get("candidate", {}).get("candidate", {}) \
			.get("snapshot", {}).get("manifest", []):
		if row_value is Dictionary:
			manifest_ids.append(_source_part_key(String(row_value.get("sourceId", "")),
				String(row_value.get("sourcePartId", ""))))
	var exact_manifest_ids := manifest_ids.duplicate()
	exact_manifest_ids.sort()
	var exact_expected_ids: Array[String] = []
	for expected_value: Variant in expected_sources:
		exact_expected_ids.append(String(expected_value))
	exact_expected_ids.sort()
	var detail_source_ids: Array[String] = [
		_source_part_key("%s:detail:0,0:grass:0" % main.seed_text, "surface:-1"),
		_source_part_key("%s:detail:0,0:flowerBloom:0" % main.seed_text, "surface:-1")]
	var contribution_input_ids: Array[String] = []
	var fixture_tree_queue := main.tree_publication_queue as FixtureTreeQueue
	var empty_band_authority: Dictionary = fixture_tree_queue.authority_for_band(
		Vector2i(-1, -1), section_key)
	var empty_band_artifact: Dictionary = fixture_tree_queue.artifact_for_band(
		Vector2i(-1, -1), section_key)
	var empty_band_overlay: Dictionary = provider._support_index \
		._tree_section_geometry_overlays.get(Vector2i(-1, -1), {}).get(section_key, {})
	var contribution_detail_bounds_match := true
	for input_value: Variant in contribution_result.get("contribution", {}).get("inputs", []):
		if not input_value is Dictionary:
			continue
		var input: Dictionary = input_value
		var input_id := _source_part_key(String(input.get("sourceId", "")),
			String(input.get("sourcePartId", "")))
		contribution_input_ids.append(input_id)
		if detail_source_ids.has(input_id):
			contribution_detail_bounds_match = contribution_detail_bounds_match \
				and input.get("meshLocalBounds", AABB()) == actual_detail_mesh.get_aabb()
	var underground_input_ids: Array[String] = []
	var underground_mesh_bounds_match := false
	for input_value: Variant in underground_contribution.get("contribution", {}).get("inputs", []):
		if not input_value is Dictionary:
			continue
		var input: Dictionary = input_value
		var input_id := String(input.get("sourceId", ""))
		var input_pair_key := _source_part_key(input_id,
			String(input.get("sourcePartId", "")))
		underground_input_ids.append(input_pair_key)
		if input_id == underground_source_id:
			var underground_pair_key := provider._source_part_identity_key(
				underground_source_id, "underground_ore")
			var support_rows: Array = underground_contribution.get("contribution", {}) \
				.get("supportRangesBySource", {}).get(underground_pair_key, [])
			underground_mesh_bounds_match = input.get("meshLocalBounds", AABB()) == mesh.get_aabb() \
				and support_rows.any(func(row: Dictionary) -> bool:
					return row.get("supportSectionKey") == underground_section_key \
						and row.get("worldBounds") is AABB \
						and (row.get("worldBounds") as AABB).is_equal_approx(
							_forward_transform_aabb(mesh.get_aabb(), underground_transform)))
	var conflict_members: Dictionary = {}
	var conflict_revisions: Dictionary = {}
	var first_member_accepted := Adapter._append_section_member(conflict_members,
		conflict_revisions, section_key, "conflicting-source", "revision-a")
	var conflicting_revision_rejected := not Adapter._append_section_member(
		conflict_members, conflict_revisions, section_key, "conflicting-source", "revision-b")
	var forage_member_key := provider._source_part_identity_key(source_id, "mushroom_cap")
	var compiled_forage: Dictionary = provider._canonical_static_artifact_by_member.get(
		forage_member_key, {})
	var cached_mesh: Variant = compiled_forage.get("mesh", null)
	var cached_mesh_was_mutated := cached_mesh is BoxMesh
	var cached_box_mesh: BoxMesh = cached_mesh as BoxMesh if cached_mesh_was_mutated else null
	if cached_mesh_was_mutated:
		cached_box_mesh.size = Vector3(2.0, 2.0, 2.0)
	var stale_resource_contribution: Dictionary = provider.capture_static_section_contribution(
		census, section_key)
	if cached_mesh_was_mutated:
		cached_box_mesh.size = Vector3.ONE
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var translucent_census: Dictionary = roster.capture_sections([section_key])
	var translucent_contribution: Dictionary = provider.capture_static_section_contribution(
		census, section_key)
	var translucent_layer_fails_closed := Adapter._supported_ecology_layer(material, "opaque").is_empty()
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	main.removed_props["adapter-prop"] = true
	main.removed_props_revision += 1
	var dynamic_removal_census: Dictionary = roster.capture_sections(
		[section_key, interleaved_section_key])
	var dynamic_removals: Array = dynamic_removal_census.get("removalsBySection", {}) \
		.get(section_key, [])
	var dynamic_expected: Array = dynamic_removal_census.get(
		"expectedContributorsBySection", {}).get(section_key, [])
	var dynamic_support_query: Dictionary = provider.query_section(world_id, section_key)
	var unaffected_revisions_stable := true
	var removed_source_part_key := _source_part_key(source_id, "mushroom_cap")
	for unaffected_source_id_value: Variant in expected_sources:
		var unaffected_source_id := String(unaffected_source_id_value)
		if unaffected_source_id == removed_source_part_key:
			continue
		if not census.get("sourceRevisions", {}).has(unaffected_source_id) \
				or String(census.sourceRevisions[unaffected_source_id]) != String(
				dynamic_removal_census.get("sourceRevisions", {}).get(unaffected_source_id, "")):
			unaffected_revisions_stable = false
	var unaffected_detail_source_id := "%s:detail:0,0:grass:0" % main.seed_text
	var unaffected_detail_pair_key := _source_part_key(unaffected_detail_source_id, "surface:-1")
	var initial_unaffected_member := _query_contributor_for_pair(initial_support_query,
		unaffected_detail_source_id, "surface:-1")
	var dynamic_unaffected_member := _query_contributor_for_pair(dynamic_support_query,
		unaffected_detail_source_id, "surface:-1")
	var initial_unaffected_domain_revision := String(initial_unaffected_member.get(
		"sourceDomainRevision", ""))
	var dynamic_unaffected_domain_revision := String(dynamic_unaffected_member.get(
		"sourceDomainRevision", ""))
	var initial_unaffected_producer_revision := String(initial_unaffected_member.get(
		"producerSnapshotRevision", ""))
	var dynamic_unaffected_producer_revision := String(dynamic_unaffected_member.get(
		"producerSnapshotRevision", ""))
	var initial_unaffected_lease := _query_lease_token_for_pair_and_domain(
		initial_support_query, unaffected_detail_source_id, "surface:-1",
		initial_unaffected_domain_revision)
	var dynamic_unaffected_lease := _query_lease_token_for_pair_and_domain(
		dynamic_support_query, unaffected_detail_source_id, "surface:-1",
		dynamic_unaffected_domain_revision)
	var unaffected_authority_rotated := not initial_unaffected_domain_revision.is_empty() \
		and not dynamic_unaffected_domain_revision.is_empty() \
		and initial_unaffected_domain_revision != dynamic_unaffected_domain_revision \
		and initial_unaffected_producer_revision != dynamic_unaffected_producer_revision \
		and not initial_unaffected_lease.is_empty() and not dynamic_unaffected_lease.is_empty() \
		and initial_unaffected_lease != dynamic_unaffected_lease \
		and String(census.get("sourceRevisions", {}).get(unaffected_detail_pair_key, "")) \
		== String(dynamic_removal_census.get("sourceRevisions", {}).get(
			unaffected_detail_pair_key, ""))
	main.removed_props_revision = 1
	provider._latest_by_section = latest_after_initial_census.duplicate(true)
	var tombstone_census: Dictionary = roster.capture_sections([section_key])
	var section_removals: Array = tombstone_census.get("removalsBySection", {}) \
		.get(section_key, [])
	main.corrupt_next_source_domain_snapshot = true
	# Corrupt a new admission, not a previously accepted immutable cache entry.
	var corrupt_provider := PumpedAdapter.new()
	corrupt_provider.configure(world_id)
	corrupt_provider.bind_main_authority(main)
	corrupt_provider.pump_retained_preparation = true
	var corrupted_snapshot_census: Dictionary = corrupt_provider.capture_static_section_sources(
		world_id, [section_key])
	var corrupted_snapshot_was_not_resealed: bool = main.source_domain_corruption_applied \
		and not ProducerDomain.validate_source_domain_snapshot(
			main.corrupted_source_domain_snapshot, world_id,
			main.corrupted_source_domain_snapshot.get("sourceChunkKey", Vector2i.ZERO),
			main._fixture_artifact_for(main.corrupted_source_domain_snapshot.get("sourceInputs", {})))
	var empty_band_queue_reason := fixture_tree_queue.last_band_request_reason
	var empty_band_expected_digest := fixture_tree_queue._var_bytes_digest([])
	main.free()
	return {"census":census, "censusDetails":census.get("details", {}),
		"directCensus":direct_census,
		"directCensusDetails":direct_census.get("details", {}),
		"undergroundRequiredCensus":underground_required_census,
		"undergroundRequiredDetails":underground_required_census.get("details", {}),
		"undergroundContributionCensus":underground_census,
		"undergroundContribution":underground_contribution,
		"undergroundContributionInputIds":underground_input_ids,
		"undergroundMeshBoundsMatch":underground_mesh_bounds_match,
		"undergroundSectionKey":underground_section_key,
		"undergroundSourceId":underground_source_id,
		"detailSourceIds":detail_source_ids,
		"emptyTreeBandAuthority":empty_band_authority,
		"emptyTreeBandArtifact":empty_band_artifact,
		"emptyTreeBandOverlay":empty_band_overlay,
		"emptyTreeBandQueueReason":empty_band_queue_reason,
		"emptyTreeBandExpectedDigest":empty_band_expected_digest,
		"contributionInputIds":contribution_input_ids,
		"contributionDetailBoundsMatch":contribution_detail_bounds_match,
		"expectedSources":expected_sources,
		"interleavedSectionKey":interleaved_section_key,
		"initialInterleavedIds":initial_interleaved_ids,
		"interleavedCensus":interleaved_census,
		"unsupportedCensus":unsupported_census,
		"unsupportedProviderCensus":unsupported_provider_census,
		"unsupportedDetailIds":unsupported_detail_ids,
		"unsupportedDetailPartIds":unsupported_detail_part_ids,
		"contribution":contribution_result, "assembled":assembled,
		"sourceId":source_id, "manifestIds":manifest_ids,
		"exactExpectedIds":exact_expected_ids, "exactManifestIds":exact_manifest_ids,
		"firstConflictMemberAccepted":first_member_accepted,
		"conflictingRevisionRejected":conflicting_revision_rejected,
		"staleResourceContribution":stale_resource_contribution,
		"cachedCompiledMeshWasMutated":cached_mesh_was_mutated,
		"translucentCensus":translucent_census,
		"translucentContribution":translucent_contribution,
		"translucentLayerFailsClosed":translucent_layer_fails_closed,
		"dynamicRemovalCensus":dynamic_removal_census,
		"dynamicRemovalSourceId":source_id,
		"dynamicRemovalRows":dynamic_removals,
		"dynamicExpectedSources":dynamic_expected,
		"unaffectedRevisionsStable":unaffected_revisions_stable,
		"initialSupportQuery":initial_support_query,
		"dynamicSupportQuery":dynamic_support_query,
		"unaffectedAuthorityRotated":unaffected_authority_rotated,
		"unaffectedMemberContentRevision":String(initial_unaffected_member.get(
			"sourceRevision", "")),
		"dynamicUnchangedMemberContentRevision":String(dynamic_unaffected_member.get(
			"sourceRevision", "")),
		"initialUnchangedMemberDomainRevision":initial_unaffected_domain_revision,
		"dynamicUnchangedMemberDomainRevision":dynamic_unaffected_domain_revision,
		"initialUnchangedMemberProducerRevision":initial_unaffected_producer_revision,
		"dynamicUnchangedMemberProducerRevision":dynamic_unaffected_producer_revision,
		"initialUnchangedMemberLease":initial_unaffected_lease,
		"dynamicUnchangedMemberLease":dynamic_unaffected_lease,
		"initialSourceRevisions":census.get("sourceRevisions", {}),
		"dynamicSourceRevisions":dynamic_removal_census.get("sourceRevisions", {}),
		"tombstoneCensus":tombstone_census, "sectionRemovals":section_removals,
		"tombstoneReason":String(tombstone_census.get("reason", "")),
		"corruptedSnapshotCensus":corrupted_snapshot_census,
		"corruptedSnapshotWasNotResealed":corrupted_snapshot_was_not_resealed}


func run() -> void:
	_contract_run_started_msec = Time.get_ticks_msec()
	if OS.get_environment("ECOLOGY_SECTION_VALUE_ADAPTER_UNCOMMITTED_TREE_ONLY") == "1":
		var uncommitted_result := _tree_without_committed_queue_geometry_stays_pending()
		var overlap: Dictionary = uncommitted_result.get("overlapping", {})
		var isolated_report := {"schema":"ecology-section-value-adapter-contract/v1",
			"diagnosticOnly":true,
			"passed":String(overlap.get("status", "")) == "pending" \
				and String(overlap.get("reason", "")) \
				== "ecology_band_projection_member_bounds_pending" \
				and String(overlap.get("sourceId", "")) \
				== String(uncommitted_result.get("treeSourceId", "")) \
				and int(uncommitted_result.get("treeQueueRequestCount", -1)) == 0 \
				and uncommitted_result.get("queuedSourceIds", []).is_empty(),
			"uncommittedTree":uncommitted_result,
			"evidence":"isolated existing uncommitted-tree fixture case; synthetic diagnostic, not gameplay evidence"}
		var isolated_report_path := OS.get_environment("ECOLOGY_SECTION_VALUE_ADAPTER_REPORT")
		if not isolated_report_path.is_empty():
			var isolated_file := FileAccess.open(isolated_report_path, FileAccess.WRITE)
			if isolated_file != null:
				isolated_file.store_string(JSON.stringify(isolated_report, "\t"))
				isolated_file.close()
		print("ECOLOGY UNCOMMITTED TREE DIAGNOSTIC ", JSON.stringify(isolated_report))
		quit(0)
		return
	if OS.get_environment("ECOLOGY_SECTION_VALUE_ADAPTER_HANDOFF_ONLY") == "1":
		print("ECOLOGY_SECTION_VALUE_STAGE handoff-only diagnostic")
		var handoff_result := await _real_tree_band_handoff_contract()
		var diagnostic_report := {"schema":"ecology-section-value-adapter-contract/v1",
			"diagnosticOnly":true,
			"passed":String(handoff_result.get("status", "")) == "ready",
			"checks":handoff_result.get("checks", {}),
			"realTreeBandHandoff":handoff_result,
			"evidence":"one isolated real tree census/queue/adapter diagnostic; not a full contract or acceptance gate"}
		var diagnostic_report_path := OS.get_environment("ECOLOGY_SECTION_VALUE_ADAPTER_REPORT")
		if not diagnostic_report_path.is_empty():
			var diagnostic_file := FileAccess.open(diagnostic_report_path, FileAccess.WRITE)
			if diagnostic_file != null:
				diagnostic_file.store_string(JSON.stringify(diagnostic_report, "\t"))
				diagnostic_file.close()
		print("ECOLOGY TREE HANDOFF DIAGNOSTIC ", JSON.stringify(diagnostic_report))
		quit(0)
		return
	print("ECOLOGY_SECTION_VALUE_STAGE start: immutable inputs and value/resource contracts")
	var immutable_policy_inputs: Dictionary = ProducerDomain.freeze_value({
		"catalog":[{"contentIdentity":"support-policy-catalog-v1"}]})
	check("support_policy_inputs_are_deeply_immutable_values",
		immutable_policy_inputs.is_read_only() \
		and (immutable_policy_inputs.get("catalog", []) as Array).is_read_only() \
		and ((immutable_policy_inputs.get("catalog", []) as Array)[0] as Dictionary).is_read_only())
	_check_detail_source_resource_digests()
	var production_detail_shader := load("res://resources/visual/detail_material.gdshader") as Shader
	var production_detail_material := ShaderMaterial.new()
	production_detail_material.shader = production_detail_shader
	production_detail_material.set_shader_parameter("base_color", Color(0.8, 0.3, 0.5, 1.0))
	var production_material_digest := Adapter._material_digest(production_detail_material)
	var stable_production_material_digest := Adapter._material_digest(production_detail_material)
	production_detail_material.set_shader_parameter("tint_strength", 0.28)
	var materialized_default_digest := Adapter._material_digest(production_detail_material)
	production_detail_material.set_shader_parameter("base_color", Color(0.3, 0.8, 0.5, 1.0))
	var changed_production_material_digest := Adapter._material_digest(production_detail_material)
	check("production_detail_shader_is_classified_by_its_opaque_fragment_contract",
		Adapter._supported_surface_detail_layer(production_detail_material, "opaque") == "opaque" \
		and Adapter._supported_surface_detail_layer(production_detail_material,
			"alpha_scissor").is_empty())
	check("shader_material_digest_binds_code_and_supported_uniform_values",
		production_material_digest.length() == 64 \
		and production_material_digest == stable_production_material_digest \
		and production_material_digest != changed_production_material_digest)
	check("shader_material_digest_normalizes_unset_uniform_to_compiled_default",
		production_material_digest == materialized_default_digest)
	var texture_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	texture_image.fill(Color(0.8, 0.2, 0.1, 1.0))
	var textured_material := StandardMaterial3D.new()
	textured_material.albedo_texture = ImageTexture.create_from_image(texture_image)
	var texture_material_digest := Adapter._material_digest(textured_material)
	texture_image.fill(Color(0.1, 0.2, 0.8, 1.0))
	textured_material.albedo_texture = ImageTexture.create_from_image(texture_image)
	var changed_texture_material_digest := Adapter._material_digest(textured_material)
	check("standard_material_digest_binds_referenced_texture_content",
		texture_material_digest.length() == 64 \
		and texture_material_digest != changed_texture_material_digest)
	_check_census_resource_fingerprint_cache()
	var rows: Array = [
		_candidate("ecology-adapter-contract:detail:0,0:grass:0", 21.0, Color.WHITE),
		_candidate("ecology-adapter-contract:detail:0,0:grass:1", 22.2, Color.WHITE)
	]
	var snapshot := _snapshot(rows)
	var world_id := "world:ecology-adapter-contract"
	var prepared: Dictionary = Adapter.prepare_surface_detail(snapshot, _bindings(),
		Transform3D.IDENTITY, world_id)
	check("canonical_detail_values_partition_to_exact_16_cell_sections",
		prepared.get("status") == "prepared" \
		and prepared.get("partition", {}).get("outputInstanceCount", -1) == 2 \
		and prepared.get("sections", {}).size() == 2)
	var mesh_fingerprint: Dictionary = MeshFingerprint.inspect(_bindings().values()[0].mesh)
	check("shared_mesh_fingerprint_binds_actual_mesh_arrays",
		mesh_fingerprint.get("status") == "ready" \
		and String(mesh_fingerprint.get("contentDigest", "")).length() == 64)
	check("source_ids_and_content_revisions_are_retained",
		prepared.get("candidateIds", []).size() == 2 \
		and prepared.get("sourceRevisions", {}).size() == 2)
	var stable_producer_revision := "ecology-v2:reload-contract:0,0:static-props-v1"
	var initial_owner_ledger = Ledger.new()
	initial_owner_ledger.configure("reload-contract", Vector2i.ZERO,
		stable_producer_revision, 0, 0)
	initial_owner_ledger.record_candidate(_candidate(
		"reload-contract:detail:0,0:grass:0", 1.0, Color.WHITE))
	var initial_owner_snapshot: Dictionary = initial_owner_ledger.snapshot()
	var reloaded_owner_ledger = Ledger.new()
	reloaded_owner_ledger.configure("reload-contract", Vector2i.ZERO,
		stable_producer_revision, 0, 1)
	reloaded_owner_ledger.record_candidate(_candidate(
		"reload-contract:detail:0,0:grass:0", 2.0, Color.WHITE))
	var reloaded_owner_snapshot: Dictionary = reloaded_owner_ledger.snapshot()
	check("stable_producer_identity_allows_changed_reloaded_content_revision",
		initial_owner_snapshot.get("sourceRevision", "") == \
			reloaded_owner_snapshot.get("sourceRevision", "") \
		and initial_owner_snapshot.get("terrainRevision", -1) != \
			reloaded_owner_snapshot.get("terrainRevision", -1) \
		and initial_owner_snapshot.get("contentRevision", "") != \
			reloaded_owner_snapshot.get("contentRevision", ""))
	var tombstone_ledger = Ledger.new()
	tombstone_ledger.configure("ecology-tombstone-contract", Vector2i.ZERO,
		"ecology-source-r1", 6)
	var tombstone_candidate := _candidate(
		"ecology-tombstone-contract:detail:0,0:grass:harvested", 1.0, Color.WHITE)
	tombstone_candidate["propId"] = "harvested-prop"
	var candidate_recorded := tombstone_ledger.record_candidate(tombstone_candidate)
	var explicit_tombstone := tombstone_ledger.record_tombstone(
		String(tombstone_candidate.sourceId), "harvested")
	var tombstone_snapshot: Dictionary = tombstone_ledger.snapshot()
	check("producer_tombstone_replaces_current_member_with_exact_removal_revision",
		candidate_recorded and explicit_tombstone \
		and tombstone_snapshot.get("candidates", []).is_empty() \
		and tombstone_snapshot.get("removedPropsRevision", -1) == 6 \
		and tombstone_snapshot.get("tombstones", []).size() == 1 \
		and tombstone_snapshot.tombstones[0].sourceId == tombstone_candidate.sourceId)
	var durable_removal_ledger = Ledger.new()
	durable_removal_ledger.configure("ecology-durable-removal-contract", Vector2i.ZERO,
		"ecology-source-r1", 7)
	var durable_candidate := _candidate(
		"ecology-durable-removal-contract:detail:0,0:grass:removed", 1.0, Color.WHITE)
	durable_candidate["propId"] = "durable-removal"
	durable_removal_ledger.record_candidate(durable_candidate)
	durable_removal_ledger.apply_removed_props({"durable-removal":true}, 8)
	var durable_snapshot: Dictionary = durable_removal_ledger.snapshot()
	check("durable_harvest_snapshot_emits_tombstone_and_advances_removed_revision",
		durable_snapshot.get("removedPropsRevision", -1) == 8 \
		and durable_snapshot.get("candidates", []).is_empty() \
		and durable_snapshot.get("tombstones", []).size() == 1 \
		and durable_snapshot.tombstones[0].reason == "removed_props")
	var changed_producer_revision: Dictionary = Adapter.prepare_surface_detail(
		_snapshot(rows, "ecology-adapter-contract", "detail-producer-revision-2"),
		_bindings(), Transform3D.IDENTITY, world_id)
	var changed_transform_rows: Array = rows.duplicate(true)
	var changed_transform_row: Dictionary = changed_transform_rows[0]
	var changed_detail_transform: Transform3D = changed_transform_row.transform
	changed_detail_transform.origin.x += 0.25
	changed_transform_row["transform"] = changed_detail_transform
	changed_transform_row["localBounds"] = changed_detail_transform * changed_transform_row.meshBounds
	var changed_transform_prepared: Dictionary = Adapter.prepare_surface_detail(
		_snapshot(changed_transform_rows), _bindings(), Transform3D.IDENTITY, world_id)
	var changed_mesh := BoxMesh.new()
	changed_mesh.size = Vector3(2.0, 1.0, 1.0)
	var changed_mesh_rows: Array = rows.duplicate(true)
	for changed_mesh_row_value: Variant in changed_mesh_rows:
		if changed_mesh_row_value is Dictionary:
			var changed_mesh_row: Dictionary = changed_mesh_row_value
			changed_mesh_row["meshBounds"] = changed_mesh.get_aabb()
			changed_mesh_row["localBounds"] = \
				(changed_mesh_row.get("transform", Transform3D.IDENTITY) as Transform3D) \
				* changed_mesh.get_aabb()
	var changed_mesh_prepared: Dictionary = Adapter.prepare_surface_detail(
		_snapshot(changed_mesh_rows), _bindings_with_resources(changed_mesh, null),
		Transform3D.IDENTITY, world_id)
	var original_material_bindings: Dictionary = _bindings()
	var original_material: Material = original_material_bindings.values()[0].get("material")
	var changed_material := original_material.duplicate(true) as StandardMaterial3D
	changed_material.albedo_color = Color(0.26, 0.51, 0.83, 1.0)
	var changed_material_prepared: Dictionary = Adapter.prepare_surface_detail(
		_snapshot(rows), _bindings_with_resources(null, changed_material),
		Transform3D.IDENTITY, world_id)
	var changed_authority_snapshot := _snapshot(rows, "ecology-adapter-contract",
		"detail-producer-revision-2")
	var render_content_payload := {"sourceChunkKey":Vector2i.ZERO,
		"worldTransform":Transform3D.IDENTITY, "meshLocalBounds":AABB(Vector3.ZERO, Vector3.ONE),
		"worldBounds":AABB(Vector3.ZERO, Vector3.ONE),
		"meshContentDigest":"synthetic-mesh-content-v1".sha256_text(),
		"materialContentDigest":"synthetic-material-content-v1".sha256_text(),
		"materialKey":"detailGrass", "renderLayer":"opaque",
		"resourceDescriptorRevision":"synthetic-detail-resource-v1".sha256_text(),
		"customData":Color(0.37, 0.0, 0.0, 1.0), "instanceColor":Color.WHITE,
		"visibilityRangeEnd":64.0}
	var base_member_content_revision := ProducerDomain.static_member_content_revision(
		world_id, "stable-member-source", "surface:-1", "details", render_content_payload)
	var changed_transform_payload: Dictionary = render_content_payload.duplicate(true)
	changed_transform_payload["worldTransform"] = Transform3D(Basis.IDENTITY,
		Vector3(0.25, 0.0, 0.0))
	changed_transform_payload["worldBounds"] = AABB(Vector3(0.25, 0.0, 0.0), Vector3.ONE)
	var changed_transform_revision := ProducerDomain.static_member_content_revision(
		world_id, "stable-member-source", "surface:-1", "details", changed_transform_payload)
	var changed_mesh_payload: Dictionary = render_content_payload.duplicate(true)
	changed_mesh_payload["meshContentDigest"] = "different-mesh-content-v1".sha256_text()
	var changed_mesh_revision := ProducerDomain.static_member_content_revision(
		world_id, "stable-member-source", "surface:-1", "details", changed_mesh_payload)
	var changed_material_payload: Dictionary = render_content_payload.duplicate(true)
	changed_material_payload["materialContentDigest"] = "different-material-content-v1".sha256_text()
	var changed_material_revision := ProducerDomain.static_member_content_revision(
		world_id, "stable-member-source", "surface:-1", "details", changed_material_payload)
	check("section_member_revision_binds_render_content_and_not_domain_revision",
		changed_producer_revision.get("status") == "prepared" \
		and changed_producer_revision.get("sourceRevisions", {}).values()[0] \
			== prepared.get("sourceRevisions", {}).values()[0] \
		and String(changed_authority_snapshot.get("sourceRevision", "")) \
			!= String(snapshot.get("sourceRevision", "")) \
		and changed_transform_prepared.get("status") == "prepared" \
		and changed_mesh_prepared.get("status") == "prepared" \
		and changed_material_prepared.get("status") == "prepared" \
		and String(changed_transform_prepared.get("sourceRevisions", {}).get(
			String(rows[0].sourceId), "")) != String(prepared.get("sourceRevisions", {}).get(
			String(rows[0].sourceId), "")) \
		and String(changed_mesh_prepared.get("sourceRevisions", {}).get(
			String(rows[0].sourceId), "")) != String(prepared.get("sourceRevisions", {}).get(
			String(rows[0].sourceId), "")) \
		and String(changed_material_prepared.get("sourceRevisions", {}).get(
			String(rows[0].sourceId), "")) != String(prepared.get("sourceRevisions", {}).get(
			String(rows[0].sourceId), "")) \
		and base_member_content_revision.length() == 64 \
		and base_member_content_revision != changed_transform_revision \
		and base_member_content_revision != changed_mesh_revision \
		and base_member_content_revision != changed_material_revision)
	var flower_surface_0 := _candidate(
		"ecology-adapter-contract:detail:0,0:flowerBloom:0:surface:0", 10.0,
		Color.WHITE, "flowerBloom")
	flower_surface_0["meshSource"] = "procedural_detail:flowerBloom:surface:0"
	flower_surface_0["materials"] = ["detailGrass"]
	var flower_surface_1 := _candidate(
		"ecology-adapter-contract:detail:0,0:flowerBloom:0:surface:1", 10.0,
	Color.WHITE, "flowerBloom")
	flower_surface_1["meshSource"] = "procedural_detail:flowerBloom:surface:1"
	flower_surface_1["materials"] = ["detailFlower"]
	var flower_surface_prepared := Adapter.prepare_surface_detail(
		_snapshot([flower_surface_0, flower_surface_1]), _flower_surface_bindings(),
		Transform3D.IDENTITY, world_id)
	var flower_mesh_keys: Array = flower_surface_prepared.get("meshBindings", {}).keys()
	var flower_material_keys: Array = flower_surface_prepared.get("materialBindings", {}).keys()
	check("multi_surface_flower_keeps_each_surface_material_and_source_identity",
		flower_surface_prepared.get("status") == "prepared" \
		and flower_surface_prepared.get("inputs", []).size() == 2 \
		and flower_surface_prepared.get("candidateIds", []).has(flower_surface_0.sourceId) \
		and flower_surface_prepared.get("candidateIds", []).has(flower_surface_1.sourceId) \
		and flower_mesh_keys.size() == 2 and flower_material_keys.size() == 2 \
		and flower_surface_prepared.get("partition", {}).get("outputInstanceCount", -1) == 2)
	var mixed_detail_rows: Array = [
		_candidate("ecology-adapter-contract:detail:0,0:grass:3", 9.0, Color.WHITE),
		_candidate("ecology-adapter-contract:detail:0,0:flowerBloom:0", 10.0,
			Color.WHITE, "flowerBloom")]
	var partial_detail: Dictionary = Adapter.prepare_surface_detail(
		_snapshot(mixed_detail_rows), _bindings(), Transform3D.IDENTITY, world_id,
		["flowerBloom"])
	check("unsupported_mesh_owned_flower_materials_are_named_while_other_detail_prepares",
		partial_detail.get("status") == "prepared_partial" \
		and partial_detail.get("partition", {}).get("outputInstanceCount", -1) == 1 \
		and partial_detail.get("unsupportedCandidateIds", []).size() == 1 \
		and partial_detail.get("censusStatus", "") == "pending")
	check("prepared_instance_inputs_are_read_only_and_cutout_layered",
		prepared.get("inputs", []).is_read_only() \
		and prepared.get("inputs", [])[0].get("buffer", []).is_read_only() \
		and prepared.get("compatibilityByKey", {}).values()[0].get("renderLayer", "") == "cutout")
	check("prepared_resources_bind_through_compatibility_keys",
		prepared.get("materialBindings", {}).is_read_only() \
		and prepared.get("meshBindings", {}).is_read_only() \
		and prepared.get("materialBindings", {}).values()[0] is Material \
		and prepared.get("meshBindings", {}).values()[0] is Mesh)
	check("full_ecology_census_stays_pending_for_uncovered_categories",
		prepared.get("censusStatus") == "pending" \
		and prepared.get("missingCategories", []).has("surface_rocks") \
		and prepared.get("missingCategories", []).has("ore") \
		and prepared.get("missingCategories", []).has("forage") \
		and prepared.get("missingCategories", []).has("underground_props"))
	var production_authority := ProductionAuthority.new()
	print("ECOLOGY_SECTION_VALUE_STAGE production-authority setup: support policy and category completeness")
	if production_authority.production_material is ShaderMaterial:
		(production_authority.production_material as ShaderMaterial).set_shader_parameter(
			"base_color", Color(0.62, 0.78, 0.44, 1.0))
	root.add_child(production_authority)
	production_authority.materials["detailGrass"] = production_authority.production_material
	production_authority.set_fixture_rows(Vector2i.ZERO, [
		_synthetic_detail_source_row(
			"%s:detail:0,0:grass:0" % production_authority.seed_text,
			"grass", 2.0, production_authority.production_mesh,
			production_authority.production_material, "detailGrass")])
	var chunk_owner := Node3D.new()
	production_authority.add_child(chunk_owner)
	production_authority.chunks[Vector2i.ZERO] = chunk_owner
	var production_snapshot := _snapshot([
		_candidate("ecology-production-contract:detail:0,0:grass:0", 2.0, Color.WHITE),
	], production_authority.seed_text,
	production_authority._ecology_chunk_source_revision(Vector2i.ZERO))
	production_snapshot["removedPropsRevision"] = production_authority.removed_props_revision
	production_snapshot["contentRevision"] = ""
	production_snapshot.erase("contentRevision")
	production_snapshot["contentRevision"] = Adapter._value_digest(production_snapshot)
	production_snapshot["producerOwnerInstanceId"] = chunk_owner.get_instance_id()
	chunk_owner.set_meta("static_ecology_source_value_snapshot", production_snapshot)
	var production_provider = PumpedAdapter.new()
	var production_world_id := "seed:%s:%d" % [production_authority.seed_text,
		production_authority.seed_hash]
	production_provider.configure(production_world_id)
	production_provider.bind_main_authority(production_authority)
	var missing_categories: Array[String] = ["surface_rocks", "ore", "forage", "underground_props"]
	var incomplete_category_evidence: Dictionary = {}
	for missing_category: String in missing_categories:
		production_authority.incomplete_source_categories = [missing_category]
		var policy_inputs: Dictionary = production_authority.ecology_source_support_policy_inputs(
			production_world_id, Vector2i.ZERO, production_authority.seed_text, {})
		var source_inputs: Dictionary = policy_inputs.get("sourceInputs", {})
		var removed_snapshot := RemovedProps.capture(production_authority)
		var source_domain: Dictionary = production_authority.capture_ecology_source_domain(
			production_world_id, Vector2i.ZERO, production_authority.seed_text,
			source_inputs, removed_snapshot)
		incomplete_category_evidence[missing_category] = \
			source_domain.get("status", "") == "pending" \
			and not source_domain.get("categoriesComplete", []).has(missing_category)
	production_authority.incomplete_source_categories = ["surface_rocks"]
	var incomplete_source_census: Dictionary = production_provider.capture_static_section_sources(
		production_world_id, [Vector3i.ZERO])
	production_authority.incomplete_source_categories.clear()
	# Admit the corrected source once. From here only the normal bounded service
	# lane advances capture and retained preparation; no provider recapture loop
	# is allowed to manufacture progress in this acceptance row.
	var retained_prep_provider: Object = Adapter.new()
	retained_prep_provider.configure(production_world_id)
	retained_prep_provider.bind_main_authority(production_authority)
	var complete_retry: Dictionary = retained_prep_provider.capture_static_section_sources(
		production_world_id, [Vector3i.ZERO])
	var retained_scheduler_at_admission: Dictionary = \
		retained_prep_provider.source_capture_scheduler_snapshot()
	var retained_units_at_admission: int = int(
		retained_prep_provider._source_section_preparation_units)
	var retained_service_calls := 0
	var retained_service_max_advanced := 0
	var retained_service_total_advanced := 0
	var retained_service_failed := false
	var retained_first_service_result: Dictionary = {}
	while retained_service_calls < 512:
		var live_cohort: Dictionary = retained_prep_provider._source_capture_cohorts.get(
			Vector3i.ZERO, {})
		var live_preparation_value: Variant = live_cohort.get("sectionPreparation", null)
		if live_preparation_value is Dictionary \
				and String(live_preparation_value.get("status", "")) == "complete":
			break
		var service_result: Dictionary = retained_prep_provider.advance_source_domain_captures(4)
		if retained_first_service_result.is_empty():
			retained_first_service_result = service_result.duplicate(false)
		retained_service_calls += 1
		var service_count: int = int(service_result.get("advancedCount", 0))
		retained_service_max_advanced = maxi(retained_service_max_advanced, service_count)
		retained_service_total_advanced += service_count
		if String(service_result.get("status", "")) == "failed":
			retained_service_failed = true
			break
		if service_count <= 0:
			break
	var retained_prep_cohort: Dictionary = retained_prep_provider._source_capture_cohorts.get(
		Vector3i.ZERO, {})
	var retained_prep_value: Variant = retained_prep_cohort.get("sectionPreparation", null)
	var retained_prep: Dictionary = retained_prep_value if retained_prep_value is Dictionary else {}
	var retained_final_census: Dictionary = retained_prep.get("census", {})
	var retained_accepted_output: Dictionary = retained_prep_provider.capture_static_section_sources(
		production_world_id, [Vector3i.ZERO])
	check("missing_tree_and_static_prop_categories_keep_common_contribution_retryable",
		incomplete_category_evidence.size() == missing_categories.size() \
		and incomplete_category_evidence.values().all(func(is_missing: bool) -> bool: return is_missing) \
		and incomplete_source_census.get("status") == "pending" \
		and incomplete_source_census.get("reason") in ["ecology_source_capture_queued",
			"ecology_section_preparation_pending"] \
		and (production_provider.pending_source_capture_reason_seen(
			"ecology_requested_family_capture_pending") \
			or incomplete_source_census.get("reason") == \
				"ecology_section_preparation_pending") \
		and complete_retry.get("status", "") == "pending" \
		and complete_retry.get("reason", "") in ["ecology_source_capture_queued",
			"ecology_section_preparation_pending"] \
		and retained_prep.get("status", "") == "complete" \
		and retained_final_census.get("status", "") == "complete")
	var retained_prep_service_diagnostics: Dictionary = {
		"serviceCalls":retained_service_calls,
		"maximumCombinedUnits":retained_service_max_advanced,
		"totalCombinedUnits":retained_service_total_advanced,
		"terminalFailureSeen":retained_service_failed,
		"preparationUnitCount":int(retained_prep.get("unitCount", 0)),
		"cacheHitRows":retained_prep_provider._source_section_preparation_cache_hit_rows,
		"admissionStatus":String(complete_retry.get("status", "")),
		"admissionReason":String(complete_retry.get("reason", "")),
		"preparationUnitsAtAdmission":retained_units_at_admission,
		"readySourceJobsAtAdmission":int(retained_scheduler_at_admission.get(
			"completedSourceJobCount", 0)),
		"pendingSourceJobsAtAdmission":int(retained_scheduler_at_admission.get(
			"pendingSourceJobCount", 0)),
		"firstServiceStatus":String(retained_first_service_result.get("status", "")),
		"firstServiceReason":String(retained_first_service_result.get("reason", "")),
		"firstServiceAdvancedCount":int(retained_first_service_result.get(
			"advancedCount", 0)),
		"acceptedOutputStatus":String(retained_accepted_output.get("status", "")),
		"acceptedOutputReason":String(retained_accepted_output.get("reason", ""))}
	check("retained_section_preparation_advances_real_family_units_within_budget",
		complete_retry.get("status", "") == "pending" \
		and not retained_service_failed \
		and retained_service_calls > 0 and retained_service_calls < 512 \
		and retained_service_max_advanced <= 4 \
		and retained_service_total_advanced >= retained_service_calls \
		and retained_units_at_admission == 0 \
		and int(retained_prep.get("unitCount", 0)) > 0 \
		and int(retained_prep.get("unitCount", 0)) <= retained_service_total_advanced)
	check("retained_section_preparation_returns_accepted_census_after_service",
		retained_accepted_output.get("status", "") == "complete" \
		and retained_accepted_output.get("sections", {}).get(Vector3i.ZERO, {}).get(
			"status", "") in ["complete", "empty"])
	var retained_prep_current_before: Dictionary = \
		retained_prep_provider._source_section_preparation_is_current(
			production_authority, retained_prep) if not retained_prep.is_empty() else {}
	var prior_ecology_world_epoch: int = production_authority.ecology_world_epoch
	production_authority.ecology_world_epoch += 1
	var stale_prep_currentness: Dictionary = \
		retained_prep_provider._source_section_preparation_is_current(
			production_authority, retained_prep) if not retained_prep.is_empty() else {}
	var stale_cached_census: Dictionary = retained_prep_provider.capture_static_section_sources(
		production_world_id, [Vector3i.ZERO])
	production_authority.ecology_world_epoch = prior_ecology_world_epoch
	check("retained_prep_uses_admitted_source_views_and_rejects_stale_cached_census",
		retained_prep.get("status", "") == "complete" \
		and retained_prep.get("census", {}).get("status", "") == "complete" \
		and not retained_prep.get("sourcePlans", []).is_empty() \
		and retained_prep_current_before.get("status", "") == "ready" \
		and stale_prep_currentness.get("status", "") == "stale" \
		and stale_cached_census.get("status", "") == "pending" \
		and stale_cached_census.get("reason", "") \
			== "ecology_section_preparation_stale_requeued")
	var stale_replacement_request: Dictionary = retained_prep_provider.capture_static_section_sources(
		production_world_id, [Vector3i.ZERO])
	var stale_replacement_service_calls := 0
	var stale_replacement_failed := false
	while stale_replacement_service_calls < 512:
		var live_replacement_cohort: Dictionary = retained_prep_provider._source_capture_cohorts.get(
			Vector3i.ZERO, {})
		var live_replacement_prep: Variant = live_replacement_cohort.get("sectionPreparation", null)
		if live_replacement_prep is Dictionary \
				and String(live_replacement_prep.get("status", "")) == "complete":
			break
		var replacement_advance: Dictionary = retained_prep_provider.advance_source_domain_captures(4)
		stale_replacement_service_calls += 1
		if String(replacement_advance.get("status", "")) == "failed" \
				or int(replacement_advance.get("advancedCount", 0)) <= 0:
			stale_replacement_failed = true
			break
	var replacement_cohort: Dictionary = retained_prep_provider._source_capture_cohorts.get(
		Vector3i.ZERO, {})
	var replacement_prep_value: Variant = replacement_cohort.get("sectionPreparation", null)
	var replacement_prep: Dictionary = replacement_prep_value \
		if replacement_prep_value is Dictionary else {}
	var replacement_current: Dictionary = retained_prep_provider._source_section_preparation_is_current(
		production_authority, replacement_prep) if not replacement_prep.is_empty() else {}
	check("stale_shared_source_preparation_releases_and_readmits_current_capture",
		stale_replacement_request.get("status", "") == "pending" \
		and stale_replacement_service_calls > 0 \
		and stale_replacement_service_calls < 512 \
		and not stale_replacement_failed \
		and replacement_prep.get("status", "") == "complete" \
		and replacement_prep.get("census", {}).get("status", "") == "complete" \
		and replacement_current.get("status", "") == "ready" \
		and retained_prep_provider._source_section_preparation_stale_count > 0)
	print("ECOLOGY_SECTION_VALUE_STAGE source capture: category completeness settled")
	var original_content_revision := String(production_snapshot.get("contentRevision", ""))
	production_authority.terrain_revision += 1
	var terrain_edit_capture: Dictionary = production_provider._capture_production_chunk(Vector2i.ZERO)
	check("terrain_edit_keeps_installed_physical_ecology_snapshot_current",
		production_authority.terrain_volume_chunk_revision(Vector2i.ZERO, 28) == 1 \
		and terrain_edit_capture.get("status") == "ready" \
		and String(terrain_edit_capture.get("snapshot", {}).get("contentRevision", "")) == original_content_revision \
		and production_authority._ecology_chunk_source_revision(Vector2i.ZERO) == \
			String(production_snapshot.get("sourceRevision", "")))
	var replacement_owner := Node3D.new()
	production_authority.add_child(replacement_owner)
	replacement_owner.set_meta("static_ecology_source_value_snapshot", production_snapshot.duplicate(true))
	production_authority.chunks[Vector2i.ZERO] = replacement_owner
	var replaced_owner_capture: Dictionary = production_provider._capture_production_chunk(Vector2i.ZERO)
	check("copied_ecology_snapshot_is_rejected_for_replacement_chunk_owner",
		replaced_owner_capture.get("status") == "pending" \
		and int(replaced_owner_capture.get("snapshotProducerOwnerInstanceId", 0)) == \
			chunk_owner.get_instance_id() \
		and int(replaced_owner_capture.get("currentProducerOwnerInstanceId", 0)) == \
			replacement_owner.get_instance_id())
	production_authority.chunks[Vector2i.ZERO] = chunk_owner
	replacement_owner.free()
	production_authority.removed_props["unrelated-removed-prop"] = true
	production_authority.removed_props_revision += 1
	var scoped_removal := RemovedProps.capture_for_ids(production_authority,
		["unrelated-removed-prop", "local-prop"])
	production_authority.removed_props["another-unrelated-prop"] = true
	var scoped_unrelated_current := RemovedProps.is_current_for_ids(production_authority,
		scoped_removal, ["local-prop", "unrelated-removed-prop"])
	production_authority.removed_props.erase("unrelated-removed-prop")
	var scoped_affected_stale := not RemovedProps.is_current_for_ids(production_authority,
		scoped_removal, ["local-prop", "unrelated-removed-prop"])
	production_authority.removed_props["unrelated-removed-prop"] = true
	check("bounded_removal_snapshot_tracks_only_requested_source_ids",
		bool(scoped_removal.get("ok", false)) \
		and scoped_removal.get("scope") == "requested_ids" \
		and scoped_removal.get("ids") == ["unrelated-removed-prop"] \
		and scoped_unrelated_current and scoped_affected_stale)
	var unrelated_removal_capture: Dictionary = production_provider._capture_production_chunk(
		Vector2i.ZERO)
	var second_chunk_owner := Node3D.new()
	production_authority.add_child(second_chunk_owner)
	production_authority.chunks[Vector2i(1, 0)] = second_chunk_owner
	var second_chunk_snapshot := _snapshot([], production_authority.seed_text,
		production_authority._ecology_chunk_source_revision(Vector2i(1, 0)), Vector2i(1, 0))
	second_chunk_snapshot["producerOwnerInstanceId"] = second_chunk_owner.get_instance_id()
	second_chunk_owner.set_meta("static_ecology_source_value_snapshot", second_chunk_snapshot)
	var second_chunk_capture: Dictionary = production_provider._capture_production_chunk(
		Vector2i(1, 0))
	check("unrelated_durable_removal_keeps_resident_chunk_snapshot_current",
		unrelated_removal_capture.get("status") == "ready" \
		and unrelated_removal_capture.get("snapshot", {}).get("contentRevision", "") \
			== original_content_revision \
		and second_chunk_capture.get("status") == "ready" \
		and second_chunk_capture.get("snapshot", {}).get("contentRevision", "") \
			== second_chunk_snapshot.get("contentRevision", ""))
	var removal_aware_candidate := _candidate(
		"ecology-projection-contract:detail:0,0:grass:removed", 5.0, Color.WHITE)
	removal_aware_candidate["propId"] = "removed-prop-in-this-chunk"
	var removal_snapshot := _snapshot([removal_aware_candidate],
		"ecology-projection-contract", "ecology-v2:ecology-projection-contract:0,0:static-props-v1")
	var removal_snapshot_before := Adapter.prepare_surface_detail(removal_snapshot,
		_bindings(), Transform3D.IDENTITY, "world:ecology-projection-contract")
	var removal_snapshot_after := Adapter.prepare_surface_detail(removal_snapshot,
		_bindings(), Transform3D.IDENTITY, "world:ecology-projection-contract", [], true,
		{"removed-prop-in-this-chunk":true})
	check("durable_local_removal_projects_candidate_out_with_stable_source_identity",
		removal_snapshot_before.get("partition", {}).get("inputInstanceCount", -1) == 1 \
		and removal_snapshot_after.get("partition", {}).get("inputInstanceCount", -1) == 0 \
		and removal_snapshot_after.get("sourceRevisions", {}).is_empty())
	production_authority.free()
	var authority_lifetime := ProductionAuthority.new()
	root.add_child(authority_lifetime)
	var provider = PumpedAdapter.new()
	provider.configure("world:ecology-adapter-contract")
	provider.bind_main_authority(authority_lifetime)
	authority_lifetime.free()
	var roster_answer: Dictionary = provider.capture_static_section_sources(
		"world:ecology-adapter-contract", [Vector3i.ZERO])
	check("provider_matches_shared_roster_capture_method",
		provider.has_method("capture_static_section_sources"))
	var partial_authority := ProductionAuthority.new()
	partial_authority.seed_text = "ecology-partial-domain-contract"
	root.add_child(partial_authority)
	partial_authority.incomplete_source_categories = ["details"]
	var partial_world_id := "seed:%s:%d" % [partial_authority.seed_text,
		partial_authority.seed_hash]
	var partial_policy_inputs: Dictionary = partial_authority.ecology_source_support_policy_inputs(
		partial_world_id, Vector2i.ZERO, partial_authority.seed_text, {})
	var partial_source_inputs: Dictionary = partial_policy_inputs.get("sourceInputs", {})
	var partial_domain: Dictionary = partial_authority.capture_ecology_source_domain(
		partial_world_id, Vector2i.ZERO, partial_authority.seed_text,
		partial_source_inputs, RemovedProps.capture(partial_authority))
	var partial_provider = PumpedAdapter.new()
	partial_provider.configure(partial_world_id)
	partial_provider.bind_main_authority(partial_authority)
	var partial_answer: Dictionary = partial_provider.capture_static_section_sources(
		partial_world_id, [Vector3i.ZERO])
	check("partial_source_domain_cannot_claim_explicit_empty_or_complete_census",
		partial_domain.get("status") == "pending" \
		and not partial_domain.get("categoriesComplete", []).has("details") \
		and partial_answer.get("status") == "pending" \
		and partial_answer.get("reason") in ["ecology_source_capture_queued",
			"ecology_section_preparation_pending"] \
		and (partial_provider.pending_source_capture_reason_seen(
			"ecology_requested_family_capture_pending") \
			or partial_answer.get("reason") == "ecology_section_preparation_pending"))
	partial_authority.free()
	var empty_detail_bindings: Dictionary = {}
	empty_detail_bindings.make_read_only()
	var empty_detail_snapshot := _snapshot([])
	var empty_detail_prepared: Dictionary = Adapter.prepare_surface_detail(
		empty_detail_snapshot, empty_detail_bindings, Transform3D.IDENTITY, world_id)
	check("producer_explicit_detail_empty_remains_only_detail_scope",
		empty_detail_prepared.get("status") == "prepared" \
		and empty_detail_prepared.get("partition", {}).get("inputInstanceCount", -1) == 0 \
		and empty_detail_prepared.get("censusStatus", "") == "pending" \
		and not empty_detail_prepared.get("missingCategories", []).has("trees_foliage_geometry") \
		and empty_detail_prepared.get("missingCategories", []).has("surface_rocks"))
	var immutable_provider = PumpedAdapter.new()
	immutable_provider.configure("world:ecology-adapter-contract")
	var immutable_answer: Dictionary = immutable_provider.capture_static_section_sources(
		"world:ecology-adapter-contract", [Vector3i.ZERO])
	check("immutable_values_without_live_production_authority_stay_pending",
		immutable_answer.get("status") == "pending" \
		and immutable_answer.get("reason") == "ecology_nonresident_source_domain_capture_unavailable")
	var producer_snapshot_with_lifecycle_marker := snapshot.duplicate(true)
	producer_snapshot_with_lifecycle_marker["status"] = "ready"
	check("producer_snapshot_digest_ignores_only_postseal_lifecycle_marker",
		Adapter._validate_snapshot(producer_snapshot_with_lifecycle_marker).get("status") == "ready")
	var tinted_rows: Array = [
		_candidate("ecology-adapter-contract:detail:0,0:grass:2", 5.0, Color(0.9, 0.96, 0.82, 1.0))
	]
	var tinted: Dictionary = Adapter.prepare_surface_detail(_snapshot(tinted_rows),
		_bindings(), Transform3D.IDENTITY, world_id)
	var tinted_buffer: Array = tinted.get("inputs", [])[0].get("buffer", []) \
		if tinted.get("status") == "prepared" and not tinted.get("inputs", []).is_empty() else []
	check("shared_instance_abi_preserves_live_multimesh_tint_and_custom_data",
		tinted.get("status") == "prepared" and tinted_buffer.size()==InstanceAttributes.FLOATS_PER_INSTANCE \
		and Color(tinted_buffer[InstanceAttributes.COLOR_OFFSET],tinted_buffer[InstanceAttributes.COLOR_OFFSET+1],
			tinted_buffer[InstanceAttributes.COLOR_OFFSET+2],tinted_buffer[InstanceAttributes.COLOR_OFFSET+3]) \
			.is_equal_approx(Color(0.9,0.96,0.82,1.0)) \
		and Color(tinted_buffer[InstanceAttributes.CUSTOM_DATA_OFFSET],tinted_buffer[InstanceAttributes.CUSTOM_DATA_OFFSET+1],
			tinted_buffer[InstanceAttributes.CUSTOM_DATA_OFFSET+2],tinted_buffer[InstanceAttributes.CUSTOM_DATA_OFFSET+3]) \
			.is_equal_approx(Color(0.37,0.0,0.0,1.0)))
	var empty_bindings: Dictionary = {}
	empty_bindings.make_read_only()
	var missing_binding: Dictionary = Adapter.prepare_surface_detail(snapshot, empty_bindings,
		Transform3D.IDENTITY, world_id)
	check("missing_mesh_material_binding_stays_pending",
		missing_binding.get("status") == "pending" \
		and missing_binding.get("reason") == "surface_detail_mesh_material_binding_missing")
	var mutated_snapshot := snapshot.duplicate(true)
	var mutated_candidate: Dictionary = mutated_snapshot.candidates[0]
	mutated_candidate["transform"] = Transform3D(Basis.IDENTITY, Vector3(16.0, 1.0, 1.0))
	var stale: Dictionary = Adapter.prepare_surface_detail(mutated_snapshot, _bindings(),
		Transform3D.IDENTITY, world_id)
	check("mutated_capture_without_revision_update_is_rejected",
		stale.get("status") == "failed")
	var empty_provider = PumpedAdapter.new()
	empty_provider.configure(world_id)
	var empty_answer: Dictionary = empty_provider.capture_static_section_sources(
		world_id, [Vector3i.ZERO])
	check("provider_without_live_authority_cannot_accept_empty_domain",
		empty_answer.get("status") == "pending")
	print("ECOLOGY_SECTION_VALUE_STAGE realized census: source capture, tombstones, and contribution assembly")
	var realized_assembler_result := _run_realized_prop_assembler_contract()
	print("ECOLOGY_SECTION_VALUE_STAGE realized census complete")
	var uncommitted_tree_result := _tree_without_committed_queue_geometry_stays_pending()
	check("tree_membership_census_matches_partitioned_center_owners",
		_tree_census_center_owner_matches_partitioner())
	check("surface_detail_census_matches_partitioner_at_section_boundary",
		_surface_detail_census_owner_matches_partitioner())
	var overlapping_uncommitted_tree: Dictionary = uncommitted_tree_result.get("overlapping", {})
	var off_section_uncommitted_tree: Dictionary = uncommitted_tree_result.get("offSection", {})
	check("uncertified_tree_band_bounds_stay_pending_before_queue_admission",
		overlapping_uncommitted_tree.get("status") == "pending" \
		and overlapping_uncommitted_tree.get("reason") \
			== "ecology_section_preparation_pending" \
		and overlapping_uncommitted_tree.get("dependency") \
			== "ecology_band_projection_member_bounds_pending" \
		and String(overlapping_uncommitted_tree.get("sourceId", "")) \
			== String(uncommitted_tree_result.get("treeSourceId", "")) \
		and uncommitted_tree_result.get("treeQueueRequestCount", 0) == 0 \
		and uncommitted_tree_result.get("queuedSourceIds", []).is_empty())
	check("uncommitted_tree_outside_requested_section_does_not_block_section_census",
		off_section_uncommitted_tree.get("status") == "complete" \
		and off_section_uncommitted_tree.get("sections", {}).get(Vector3i(1, 0, 0), {}).get(
			"status", "") == "empty")
	check("tree_source_bounds_filter_rejects_off_section_tree",
		not bool(uncommitted_tree_result.get("offSectionBoundsIntersect", true)))
	print("ECOLOGY_SECTION_VALUE_STAGE real tree compiler-to-candidate handoff")
	var real_tree_handoff := await _real_tree_band_handoff_contract()
	check("real_tree_handoff_completed_with_nonempty_checks",
		_tree_handoff_result_passes(real_tree_handoff))
	check("real_tree_handoff_gate_rejects_early_preflight_failure",
		not _tree_handoff_result_passes({"status":"failed",
			"reason":"tree_band_revision_input_preflight_failed"}))
	check("real_tree_handoff_gate_rejects_empty_checks",
		not _tree_handoff_result_passes({"status":"ready", "checks":{}}))
	for check_name: Variant in real_tree_handoff.get("checks", {}):
		check("real_tree_handoff_%s" % String(check_name),
			bool(real_tree_handoff.checks[check_name]))
	print("ECOLOGY_SECTION_VALUE_STAGE real tree compiler-to-candidate handoff complete")
	check("census_rejects_sealed_source_domain_digest_corruption_before_membership",
		realized_assembler_result.get("corruptedSnapshotCensus", {}).get("status") == "pending" \
		and realized_assembler_result.get("corruptedSnapshotCensus", {}).get("reason") \
			== "ecology_source_publication_payload_invalid" \
		and bool(realized_assembler_result.get("corruptedSnapshotCensus", {}).get(
			"retryable", false)) \
		and realized_assembler_result.get("corruptedSnapshotCensus", {}).get(
			"producerStatus", "") == "failed" \
		and not realized_assembler_result.get("corruptedSnapshotCensus", {}).has("sections") \
		and realized_assembler_result.get("corruptedSnapshotWasNotResealed", false))
	var realized_source_pair := _source_part_key(
		String(realized_assembler_result.get("sourceId", "")), "mushroom_cap")
	var underground_source_pair := _source_part_key(
		String(realized_assembler_result.get("undergroundSourceId", "")), "underground_ore")
	check("realized_prop_ids_are_enumerated_into_exact_completed_section_roster",
		realized_assembler_result.get("census", {}).get("status") == "complete" \
		and realized_assembler_result.get("initialInterleavedIds", []).is_empty() \
		and realized_assembler_result.get("exactExpectedIds", []) == \
			realized_assembler_result.get("exactManifestIds", []) \
		and realized_assembler_result.get("expectedSources", []).has(realized_source_pair))
	check("membership_census_does_not_prepare_section_geometry",
		realized_assembler_result.get("directCensus", {}).get("status") == "complete" \
		and realized_assembler_result.get("directCensus", {}).get("preparedSections", {}).is_empty() \
		and realized_assembler_result.get("directCensus", {}).get("sections", {}).has(Vector3i.ZERO) \
		and realized_assembler_result.get("directCensus", {}).get("sourceRevisions", {}).has(
			realized_source_pair))
	var direct_source_revisions: Dictionary = realized_assembler_result.get(
		"directCensus", {}).get("sourceRevisions", {})
	var underground_required_revisions: Dictionary = realized_assembler_result.get(
		"undergroundRequiredCensus", {}).get("sourceRevisions", {})
	var underground_source_id := String(realized_assembler_result.get(
		"undergroundSourceId", ""))
	check("surface_only_census_skips_underground_prop_and_keeps_surface_prop",
		realized_assembler_result.get("directCensus", {}).get("status") == "complete" \
		and direct_source_revisions.has(realized_source_pair) \
		and not direct_source_revisions.has(underground_source_pair))
	check("underground_required_census_includes_underground_and_surface_props",
		realized_assembler_result.get("undergroundRequiredCensus", {}).get("status") == "complete" \
		and underground_required_revisions.has(realized_source_pair) \
		and underground_required_revisions.has(underground_source_pair))
	check("below_ground_underground_mesh_survives_complete_census_and_contribution",
		realized_assembler_result.get("undergroundContributionCensus", {}).get("status") == "complete" \
		and realized_assembler_result.get("undergroundContribution", {}).get("status") == "ready" \
		and realized_assembler_result.get("undergroundContributionInputIds", []).has(underground_source_pair) \
		and realized_assembler_result.get("undergroundMeshBoundsMatch", false) \
		and realized_assembler_result.get("undergroundSectionKey") == Vector3i(0, -2, 0))
	var detail_source_ids: Array = realized_assembler_result.get("detailSourceIds", [])
	var actual_detail_inputs: Array = realized_assembler_result.get("contributionInputIds", [])
	check("actual_surface_detail_mesh_members_survive_complete_contribution",
		realized_assembler_result.get("contribution", {}).get("status") == "ready" \
		and detail_source_ids.size() == 2 \
		and detail_source_ids.all(func(id: String) -> bool: return actual_detail_inputs.has(id)) \
		and realized_assembler_result.get("contributionDetailBoundsMatch", false))
	check("unsupported_flower_keeps_mixed_grass_flower_roster_pending_with_exact_id",
		realized_assembler_result.get("unsupportedCensus", {}).get("status") == "pending" \
		and realized_assembler_result.get("unsupportedProviderCensus", {}).get("status") == "pending" \
		and realized_assembler_result.get("unsupportedProviderCensus", {}).get("dependency") \
			== "ecology_detail_source_resource_unavailable" \
		and realized_assembler_result.get("unsupportedProviderCensus", {}).get(
			"sourceId", "") == String(realized_assembler_result.get(
				"unsupportedDetailIds", [""])[0]) \
		and realized_assembler_result.get("unsupportedDetailPartIds", []).has("surface:-1"))
	check("conflicting_source_revision_cannot_be_silently_omitted_from_census",
		realized_assembler_result.get("firstConflictMemberAccepted", false) \
		and realized_assembler_result.get("conflictingRevisionRejected", false))
	check("realized_prop_resources_reach_shared_section_candidate",
		realized_assembler_result.get("contribution", {}).get("status") == "ready" \
			and realized_assembler_result.get("assembled", {}).get("status") == "ready" \
			and realized_assembler_result.get("manifestIds", []).has(realized_source_pair))
	var empty_tree_authority: Dictionary = realized_assembler_result.get(
		"emptyTreeBandAuthority", {})
	var empty_tree_artifact: Dictionary = realized_assembler_result.get(
		"emptyTreeBandArtifact", {})
	var empty_tree_overlay: Dictionary = realized_assembler_result.get(
		"emptyTreeBandOverlay", {})
	var empty_tree_expected_digest := String(realized_assembler_result.get(
		"emptyTreeBandExpectedDigest", ""))
	check("authoritative_empty_tree_band_installs_before_non_tree_candidate_contribution",
		empty_tree_authority.get("producerSourceIds", null) == [] \
			and String(empty_tree_authority.get("producerDisposition", "")) == "complete_empty" \
			and empty_tree_artifact.is_read_only() \
			and String(empty_tree_artifact.get("schema", "")) \
				== CompiledTreeSectionArtifact.SCHEMA \
			and empty_tree_artifact.get("expectedSourceIds", null) == [] \
			and empty_tree_artifact.get("sourceCompletionManifest", null) == [] \
			and String(empty_tree_artifact.get("disposition", "")) == "complete_empty" \
			and String(empty_tree_artifact.get("sourceCompletionDigest", "")) \
				== empty_tree_expected_digest \
			and String(empty_tree_artifact.get("ownerBatchPayloadDigest", "")) \
				== empty_tree_expected_digest \
			and String(empty_tree_overlay.get("disposition", "")) == "complete_empty" \
			and String(empty_tree_overlay.get("supportDisposition", "")) == "support_empty" \
			and int(empty_tree_overlay.get("sourceCompletionCount", -1)) == 0 \
			and int(empty_tree_overlay.get("ownerMemberCount", -1)) == 0 \
			and int(empty_tree_overlay.get("supportMemberCount", -1)) == 0 \
			and realized_assembler_result.get("census", {}).get("status") == "complete" \
			and realized_assembler_result.get("contribution", {}).get("status") == "ready")
	check("adapter_rechecks_mesh_fingerprint_before_candidate_contribution",
		realized_assembler_result.get("cachedCompiledMeshWasMutated", false) \
		and realized_assembler_result.get("staleResourceContribution", {}).get("status") == "pending" \
		and realized_assembler_result.get("staleResourceContribution", {}).get("reason") \
			== "ecology_contribution_static_geometry_stale")
	check("translucent_material_semantics_remain_pending",
		realized_assembler_result.get("translucentCensus", {}).get("status") == "complete" \
		and realized_assembler_result.get("translucentContribution", {}).get("status") == "pending" \
		and realized_assembler_result.get("translucentContribution", {}).get("reason") \
			== "ecology_contribution_static_geometry_stale" \
		and realized_assembler_result.get("translucentLayerFailsClosed", false))
	check("durable_prop_tombstone_becomes_exact_section_removal",
		realized_assembler_result.get("tombstoneCensus", {}).get("status") == "complete" \
		and realized_assembler_result.get("sectionRemovals", []).any(
			func(row: Dictionary) -> bool:
				return String(row.get("sourceId", "")) == String(
					realized_assembler_result.get("sourceId", "")) \
					and String(row.get("sourcePartId", "")) == "mushroom_cap" \
					and row.get("sectionKey") == Vector3i.ZERO))
	check("dynamic_harvest_projection_removes_only_the_exact_section_source",
		realized_assembler_result.get("dynamicRemovalCensus", {}).get("status") == "complete" \
		and not realized_assembler_result.get("dynamicExpectedSources", []).has(
			_source_part_key(String(realized_assembler_result.get("dynamicRemovalSourceId", "")),
				"mushroom_cap")) \
		and realized_assembler_result.get("dynamicRemovalRows", []).any(
			func(row: Dictionary) -> bool:
				return String(row.get("sourceId", "")) == String(
					realized_assembler_result.get("dynamicRemovalSourceId", "")) \
					and String(row.get("sourcePartId", "")) == "mushroom_cap") \
		and realized_assembler_result.get("unaffectedRevisionsStable", false))
	check("unchanged_member_revision_keeps_content_while_authority_rotates_lease",
		not String(realized_assembler_result.get(
			"unaffectedMemberContentRevision", "")).is_empty() \
		and realized_assembler_result.get("unaffectedMemberContentRevision", "") \
			== realized_assembler_result.get("dynamicUnchangedMemberContentRevision", "") \
		and realized_assembler_result.get("unaffectedAuthorityRotated", false) \
		and realized_assembler_result.get("initialUnchangedMemberDomainRevision", "") \
			!= realized_assembler_result.get("dynamicUnchangedMemberDomainRevision", "") \
		and realized_assembler_result.get("initialUnchangedMemberProducerRevision", "") \
			!= realized_assembler_result.get("dynamicUnchangedMemberProducerRevision", "") \
		and realized_assembler_result.get("initialUnchangedMemberLease", "") \
			!= realized_assembler_result.get("dynamicUnchangedMemberLease", ""))
	check("section_removal_history_survives_interleaved_partial_census",
		realized_assembler_result.get("interleavedCensus", {}).get("status") == "complete" \
		and realized_assembler_result.get("interleavedCensus", {}).get(
			"expectedContributorsBySection", {}).get(
			realized_assembler_result.get("interleavedSectionKey"), []).is_empty() \
		and realized_assembler_result.get("sectionRemovals", []).any(
			func(row: Dictionary) -> bool:
				return String(row.get("sourceId", "")) == String(
					realized_assembler_result.get("sourceId", "")) \
					and String(row.get("sourcePartId", "")) == "mushroom_cap" \
					and row.get("sectionKey") == Vector3i.ZERO))
	print("ECOLOGY_SECTION_VALUE_STAGE partial-removal replay: section-scoped tombstones and receipts")
	var partial_removal := _check_partial_capture_removal_history()
	check("partial_capture_retains_uncaptured_section_removal_rows",
		partial_removal.get("initiallySpansBoth", false) \
		and partial_removal.get("captureAStatus", "") == "complete" \
		and partial_removal.get("rowARetained", false) \
		and partial_removal.get("queryBBeforeCaptureStatus", "") == "pending" \
		and partial_removal.get("queryBBeforeCaptureReason", "") \
			== "ecology_support_source_family_incomplete" \
		and partial_removal.get("queryBBeforeCaptureSupportOwnerDemands", []).is_empty() \
		and partial_removal.get("retainedBPostingBeforeCapture", false) \
		and partial_removal.get("captureBStatus", "") == "complete" \
		and partial_removal.get("rowARetainedAfterB", false) \
		and partial_removal.get("rowBPresent", false) \
		and not partial_removal.get("rowARevision", "").is_empty() \
		and not partial_removal.get("rowBRevision", "").is_empty())
	check("partial_capture_receipt_retires_only_its_section_tombstones",
		partial_removal.get("ackAStatus", "") == "ready" \
		and partial_removal.get("visibleAfterA", false) \
		and partial_removal.get("ackBStatus", "") == "ready" \
		and partial_removal.get("retiredAfterB", false))
	check("source_reappearance_rejects_stale_section_receipt",
		partial_removal.get("reappearedCaptureStatus", "") == "complete" \
		and partial_removal.get("oldRemovalRejected", false) \
		and partial_removal.get("reappearedVisualAndCollisionPreserved", false))
	print("ECOLOGY_SECTION_VALUE_STAGE authority replacement: stale receipt rejection")
	var owner_replacement := _check_source_domain_authority_replacement()
	check("source_domain_authority_replacement_rejects_old_removal_receipt",
		owner_replacement.get("initialStatus", "") == "complete" \
		and owner_replacement.get("captureAStatus", "") == "complete" \
		and owner_replacement.get("captureBStatus", "") == "complete" \
		and owner_replacement.get("removedSourceHasExactSectionTombstone", false) \
		and owner_replacement.get("oldTombstoneHasExactMemberLease", false) \
		and owner_replacement.get("replacementCaptureStatus", "") == "complete" \
		and owner_replacement.get("ownerReplacementDoesNotMergeOldHistory", false) \
		and owner_replacement.get("replacementCoverageChanged", false) \
		and owner_replacement.get("staleAckStatus", "") == "pending" \
		and owner_replacement.get("replacementValueSourceIsCurrent", false))
	check("same_content_catalog_owner_replacement_rotates_provider_authority_only",
		owner_replacement.get("semanticSourceRevisionStable", false) \
		and owner_replacement.get("catalogArtifactReplaced", false) \
		and owner_replacement.get("providerAuthorityRotated", false))
	print("ECOLOGY_SECTION_VALUE_STAGE source capture queue lifecycle")
	var source_capture_lifecycle := _source_capture_queue_lifecycle_contract()
	check("source_capture_dispatch_ages_pending_jobs_before_camera_ties",
		source_capture_lifecycle.get("firstDispatchNear", "") == "near" \
		and source_capture_lifecycle.get("secondDispatchFar", "") == "far")
	check("section_demand_release_detaches_and_discards_unneeded_pending_jobs",
		source_capture_lifecycle.get("detachedJobCount", 0) == 2 \
		and source_capture_lifecycle.get("pendingAfterDetach", 0) == 0 \
		and source_capture_lifecycle.get("queuedAfterDetach", 0) == 0)
	check("superseded_source_capture_payload_is_released_immediately",
		source_capture_lifecycle.get("supersededOldPayloadReleased", false) \
		and source_capture_lifecycle.get("currentReplacementRetained", false))
	check("ready_capture_cache_is_bounded_and_demand_keeps_its_snapshot",
		source_capture_lifecycle.get("idleCacheBounded", false) \
		and source_capture_lifecycle.get("demandedReadyRetained", false) \
		and source_capture_lifecycle.get("demandedReadyIdleCached", false))
	check("source_capture_reset_releases_all_queue_and_snapshot_payloads",
		source_capture_lifecycle.get("resetClearedEverything", false))
	print("ECOLOGY_SECTION_VALUE_STAGE section-scoped source-family projection receipts")
	var band_projection := _source_band_projection_adapter_contract()
	check("source_family_projection_covers_two_y_sections_without_cross_supersession",
		band_projection.get("bothBandsRegistered", false) \
		and band_projection.get("lowerReceiptRetainedAfterUpperRefresh", false) \
		and band_projection.get("sectionKeysAreIndependent", false))
	check("source_family_projection_stays_pending_for_missing_or_stale_proofs",
		band_projection.get("missingProjectionPending", false) \
		and band_projection.get("staleSourcePending", false) \
		and band_projection.get("staleCatalogPending", false) \
		and band_projection.get("staleRemovalPending", false))
	check("source_family_projection_passes_explicit_legacy_family_subset",
		band_projection.get("selectedLegacyFamiliesOnly", false))
	print("ECOLOGY_SECTION_VALUE_STAGE coordinator retries ecology capture after owner revision")
	var coordinator_recovery := _coordinator_retryable_capture_recovery_contract()
	check("coordinator_keeps_failed_source_census_retryable_and_recaptures_changed_owner_revision",
		coordinator_recovery.get("firstFailureStayedWaiting", false) \
		and coordinator_recovery.get("unchangedIdentityFailureStaysLatched", false) \
		and coordinator_recovery.get("mixedReadyFailedIdentityRetained", false) \
		and coordinator_recovery.get("multiPlanRevisionIsDetected", false) \
		and coordinator_recovery.get("terrainStayedUnchanged", false) \
		and coordinator_recovery.get("newOwnerRevisionWasCaptured", false) \
		and coordinator_recovery.get("candidateAdmissionReached", false) \
		and coordinator_recovery.get("cleanupDrained", false))
	var cohort_scheduler := _source_capture_cohort_scheduler_contract()
	check("source_capture_cohorts_bound_active_work_and_age_promotes_far_demand",
		cohort_scheduler.get("initialActiveCount", 0) == Adapter.MAX_ACTIVE_SOURCE_CAPTURE_COHORTS \
		and cohort_scheduler.get("farInitialStatus", "") == "deferred" \
		and cohort_scheduler.get("farEventuallyActive", false) \
		and cohort_scheduler.get("boundedActiveCount", false))
	check("certified_empty_source_closure_releases_its_active_cohort_slot",
		cohort_scheduler.get("emptyClosureSealed", false) \
		and cohort_scheduler.get("emptyClosureDisposition", "") == "complete_empty" \
		and cohort_scheduler.get("emptyClosureStatus", "") == "complete" \
		and cohort_scheduler.get("emptyClosureActiveCountAfterSeal", -1) == 0 \
		and cohort_scheduler.get("missingClosureRemainsActive", false))
	check("source_preparation_scheduler_telemetry_is_bounded_and_identity_scoped",
		cohort_scheduler.get("preparationTelemetryBounded", false) \
			and cohort_scheduler.get("preparationTelemetryHasNoPayload", false))
	check("blocked_retained_preparation_rotates_to_empty_sibling_without_polling_first",
		cohort_scheduler.get("pendingPreparationDoesNotBlockEmptySibling", false))
	check("terminal_retained_preparation_failure_is_surfaced_and_removed_from_scheduler",
		cohort_scheduler.get("terminalPreparationFailurePropagates", false))
	check("terminal_tree_registration_failure_is_persisted_not_wrapped_as_pending",
		cohort_scheduler.get("terminalRegistrationIsNotPending", false))
	check("retained_preparation_classifies_nested_terminal_and_stale_producer_outcomes",
		cohort_scheduler.get("dependencyStatusProtocolsClassified", false))
	check("first_tree_band_poll_terminal_failure_is_not_requeued_as_pending",
		cohort_scheduler.get("firstPollTerminalPropagates", false))
	check("record_backpressure_tree_band_consumer_is_retained_and_queue_full_is_not",
		cohort_scheduler.get("admittedPendingBandConsumerRetainedAndCancelled", false) \
			and cohort_scheduler.get("queueFullProspectiveBandJobNotRetained", false))
	check("terminal_tree_band_admission_detaches_attached_consumer_before_failure",
		cohort_scheduler.get("failedAdmissionBandConsumerDetached", false))
	check("pending_terminal_tree_band_admission_is_classified_before_poll",
		cohort_scheduler.get("pendingTerminalAdmissionIsClassifiedBeforePoll", false))
	check("pending_terminal_family_projection_is_terminal_and_stale_family_result_is_classified",
		cohort_scheduler.get("pendingTerminalFamilyIsTerminal", false) \
			and cohort_scheduler.get("staleHelperRoutePreserved", false) \
			and cohort_scheduler.get("malformedReadyFamilyIsTerminal", false) \
			and cohort_scheduler.get("emptyFamilyRowsRejected", false))
	check("discarded_capture_invalidates_all_sibling_preparation_censuses",
		cohort_scheduler.get("bothIncarnationPreparationsInvalidated", false) \
			and cohort_scheduler.get("siblingRejectsNewCaptureIncarnation", false))
	check("cached_source_rows_are_scanned_in_bounded_batches_without_conversion_units",
		cohort_scheduler.get("boundedCacheScanWithoutConversionUnits", false))
	check("blocked_cohort_yields_without_cancelling_shared_active_source_or_losing_lease",
		cohort_scheduler.get("sharedRetainedForActiveSibling", false) \
		and cohort_scheduler.get("sharedCancelledAfterAllActiveSubscribersYield", false) \
		and cohort_scheduler.get("wideFamilyCursorRetained", false) \
		and cohort_scheduler.get("bothFamilyCursorsReleased", false) \
		and cohort_scheduler.get("leaseRetained", false) \
		and cohort_scheduler.get("blockedRetryAdmitted", false))
	check("cohort_unload_preserves_shared_subscriber_and_reset_retires_scheduler_state",
		cohort_scheduler.get("sharedJobRetainedForB", false) \
		and cohort_scheduler.get("releaseStatus", "") == "released" \
		and cohort_scheduler.get("resetStatus", "") == "reset" \
		and cohort_scheduler.get("resetCohortsEmpty", false))
	check("cached_terminal_failure_survives_full_cohort_capacity_and_rechecks_after_slot_opens",
		cohort_scheduler.get("cachedFailureSurvivesSaturation", false) \
			and cohort_scheduler.get("failedRevisionRecheckAdmitted", false))
	var tree_priming := _tree_compile_priming_lifecycle_contract()
	check("ready_tree_sources_prime_before_other_source_capture_finishes",
		tree_priming.get("primedWhileSiblingPending", false) \
			and tree_priming.get("primingIgnoresUnreadySiblingRecords", false) \
			and tree_priming.get("allSectionDemandsAttached", false) \
			and tree_priming.get("retiredQueueJobReadmitted", false) \
			and tree_priming.get("narrowWideShareCompileJob", false) \
			and tree_priming.get("sharedJobRetainedForSibling", false) \
			and tree_priming.get("replacedQueueRecovered", false))
	check("tree_compile_demands_cancel_on_last_release_supersession_and_reset",
		tree_priming.get("lastSiblingReleaseCancelled", false) \
			and tree_priming.get("supersessionCancelled", false) \
			and tree_priming.get("resetCancelled", false) \
			and tree_priming.get("replacementQueueRetired", false) \
			and tree_priming.get("staleCompletionRejected", false))
	var tree_manifest_binding := _tree_compiler_manifest_binding_contract()
	check("tree_compiler_manifest_preserves_nonzero_chunk_world_transform",
		tree_manifest_binding.get("nonzeroChunkWorldTransformPreserved", false) \
			and tree_manifest_binding.get("mismatchedLocalTransformRejected", false))
	var tree_demand_bookkeeping := _tree_demand_bookkeeping_contract()
	check("tree_demand_bookkeeping_polls_retained_token_and_detaches_on_release",
		tree_demand_bookkeeping.get("polledRetainedToken", false) \
			and tree_demand_bookkeeping.get("exactConsumerDetachedOnUnload", false) \
			and tree_demand_bookkeeping.get("retiredDemandNotRepolled", false))
	check("tree_contribution_unload_detaches_exact_consumer_without_orphan_repoll",
		tree_demand_bookkeeping.get("exactConsumerDetachedOnUnload", false) \
			and tree_demand_bookkeeping.get("retiredDemandNotRepolled", false))
	var tree_band_demand_lifecycle := _tree_band_existing_demand_lifecycle_contract()
	var tree_band_partial_source_admission := \
		_tree_band_partial_source_admission_contract()
	check("same_authority_terminal_tree_band_failure_retains_reason_and_consumer",
		bool(tree_band_demand_lifecycle.get("sameAuthorityFailureRetained", false)))
	check("stale_tree_band_poll_detaches_and_retries_with_original_reason",
		bool(tree_band_demand_lifecycle.get("stalePollRetriesWithDetach", false)))
	check("detached_tree_band_consumer_is_readmitted_after_exact_detach",
		bool(tree_band_demand_lifecycle.get("consumerLostRetriesWithDetach", false)))
	check("missing_tree_band_queue_job_detaches_and_remains_retryable",
		bool(tree_band_demand_lifecycle.get("missingJobRetryable", false)))
	check("changed_tree_band_authority_detaches_old_consumer_before_replacement",
		bool(tree_band_demand_lifecycle.get("changedAuthorityDetached", false)))
	check("malformed_existing_tree_band_poll_fails_closed",
		bool(tree_band_demand_lifecycle.get("malformedPollFailsClosed", false)))
	check("partial_tree_band_source_admission_retains_and_cancels_each_exact_consumer",
		tree_band_partial_source_admission.get("partialStateRetained", false) \
			and tree_band_partial_source_admission.get("exactPartialConsumerCancelled", false) \
			and tree_band_partial_source_admission.get("pendingBeforeAttachmentRetained", false) \
			and tree_band_partial_source_admission.get(
				"pendingBeforeAttachmentCancelledExactly", false))
	print("ECOLOGY_SECTION_VALUE_STAGE legacy visual retirement gate")
	_check_legacy_visual_retirement_receipt_gate()
	print("ECOLOGY_SECTION_VALUE_STAGE report serialization")
	var report := {"schema":"ecology-section-value-adapter-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"retainedSectionPreparationService":retained_prep_service_diagnostics,
		"sourceCaptureCohortDiagnostics":cohort_scheduler,
		"realizedAssemblerAsyncDiagnostics":{
			"corruptedCensusStatus":String(realized_assembler_result.get(
				"corruptedSnapshotCensus", {}).get("status", "")),
			"corruptedCensusReason":String(realized_assembler_result.get(
				"corruptedSnapshotCensus", {}).get("reason", "")),
			"corruptedProducerStatus":String(realized_assembler_result.get(
				"corruptedSnapshotCensus", {}).get("producerStatus", "")),
			"unsupportedRosterStatus":String(realized_assembler_result.get(
				"unsupportedCensus", {}).get("status", "")),
			"unsupportedRosterReason":String(realized_assembler_result.get(
				"unsupportedCensus", {}).get("reason", "")),
			"unsupportedProviderStatus":String(realized_assembler_result.get(
				"unsupportedProviderCensus", {}).get("status", "")),
			"unsupportedProviderReason":String(realized_assembler_result.get(
				"unsupportedProviderCensus", {}).get("reason", "")),
			"unsupportedProviderDependency":String(realized_assembler_result.get(
				"unsupportedProviderCensus", {}).get("dependency", "")),
			"unsupportedProviderSourceId":String(realized_assembler_result.get(
				"unsupportedProviderCensus", {}).get("sourceId", "")),
			"translucentStatus":String(realized_assembler_result.get(
				"translucentCensus", {}).get("status", "")),
			"translucentReason":String(realized_assembler_result.get(
				"translucentCensus", {}).get("reason", "")),
			"tombstoneStatus":String(realized_assembler_result.get(
				"tombstoneCensus", {}).get("status", "")),
			"tombstoneReason":String(realized_assembler_result.get(
				"tombstoneCensus", {}).get("reason", "")),
			"tombstoneProviderReason":String(realized_assembler_result.get(
				"tombstoneCensus", {}).get("providerReason", "")),
			"tombstoneRemovalsCount":(realized_assembler_result.get(
				"sectionRemovals", []) as Array).size()},
		"treeBandDemandLifecycle":tree_band_demand_lifecycle,
		"treeBandPartialSourceAdmission":tree_band_partial_source_admission,
		"syntheticTreeDemandBookkeeping":tree_demand_bookkeeping,
		"treeDemandBookkeepingDoesNotProve":[
			"tree geometry compilation or exact recipe output",
			"accepted section geometry overlay",
			"candidate contribution or native install",
			"tree collision or gameplay traversal"],
		"realTreeBandHandoff":real_tree_handoff,
		"coordinatorRecovery":{
			"firstFailureStayedWaiting":coordinator_recovery.get("firstFailureStayedWaiting", false),
			"firstAdmissionStatus":coordinator_recovery.get("firstAdmission", {}).get("status", ""),
			"firstReason":coordinator_recovery.get("firstReason", ""),
			"firstProducerStatus":coordinator_recovery.get("firstProducerStatus", ""),
			"terrainStayedUnchanged":coordinator_recovery.get("terrainStayedUnchanged", false),
			"newOwnerRevisionWasCaptured":coordinator_recovery.get("newOwnerRevisionWasCaptured", false),
			"candidateAdmissionReached":coordinator_recovery.get("candidateAdmissionReached", false),
			"firstStructureDigest":coordinator_recovery.get("firstStructureDigest", ""),
			"newStructureDigest":coordinator_recovery.get("newStructureDigest", ""),
			"firstCaptureCount":coordinator_recovery.get("firstCaptureCount", 0),
			"totalCaptureCount":coordinator_recovery.get("totalCaptureCount", 0),
			"secondAdmissionStatus":coordinator_recovery.get("secondAdmission", {}).get("status", ""),
			"secondAdmissionReason":coordinator_recovery.get("secondAdmission", {}).get("reason", ""),
			"recoveryAdmissionStatus":coordinator_recovery.get("recoveryAdmission", {}).get("status", ""),
			"recoveryAdmissionReason":coordinator_recovery.get("recoveryAdmission", {}).get("reason", ""),
			"recoveryServiceOpportunities":coordinator_recovery.get("recoveryServiceOpportunities", 0),
			"unchangedIdentityFailureStaysLatched":coordinator_recovery.get(
				"unchangedIdentityFailureStaysLatched", false),
			"unchangedRetryReason":coordinator_recovery.get("unchangedRetryReason", ""),
			"unchangedRetryDemandStage":coordinator_recovery.get(
				"unchangedRetryDemandStage", ""),
			"unchangedRetryDemandRetained":coordinator_recovery.get(
				"unchangedRetryDemandRetained", false),
			"retainedFailurePreparationStatus":coordinator_recovery.get(
				"retainedFailurePreparationStatus", ""),
			"mixedReadyFailedIdentityRetained":coordinator_recovery.get(
				"mixedReadyFailedIdentityRetained", false),
			"multiPlanRevisionIsDetected":coordinator_recovery.get(
				"multiPlanRevisionIsDetected", false),
			"multiPlanRevisionReason":coordinator_recovery.get(
				"multiPlanRevisionReason", ""),
			"secondProviderReason":coordinator_recovery.get("secondProviderReason", ""),
			"secondProviderDetails":coordinator_recovery.get("secondProviderDetails", {}),
			"cleanupDrained":coordinator_recovery.get("cleanupDrained", false)},
		"uncertifiedTreeBandDiagnostics":{
			"overlappingStatus":String(overlapping_uncommitted_tree.get("status", "")),
			"overlappingReason":String(overlapping_uncommitted_tree.get("reason", "")),
			"overlappingDependency":String(overlapping_uncommitted_tree.get("dependency", "")),
			"overlappingSourceId":String(overlapping_uncommitted_tree.get("sourceId", "")),
			"queueRequestCount":int(uncommitted_tree_result.get("treeQueueRequestCount", 0)),
			"queuedSourceIds":uncommitted_tree_result.get("queuedSourceIds", [])},
		"surfaceDetailPartitionOutputs":prepared.get("partition", {}).get("outputInstanceCount", 0),
		"tombstoneCensusStatus":realized_assembler_result.get("tombstoneCensus", {}).get("status", ""),
		"tombstoneCensusReason":realized_assembler_result.get("tombstoneCensus", {}).get("reason", ""),
		"successfulCensusReason":realized_assembler_result.get("census", {}).get("reason", ""),
		"successfulCensusStatus":realized_assembler_result.get("census", {}).get("status", ""),
		"successfulCensusProviderReason":realized_assembler_result.get("census", {}).get(
			"providerReason", ""),
		"successfulCensusProviderDetails":realized_assembler_result.get("census", {}).get(
			"providerDetails", {}),
		"emptyTreeBandProof":{
			"authoritySourceIds":realized_assembler_result.get(
				"emptyTreeBandAuthority", {}).get("producerSourceIds", null),
			"queueReason":String(realized_assembler_result.get(
				"emptyTreeBandQueueReason", "")),
			"artifactDisposition":String(realized_assembler_result.get(
				"emptyTreeBandArtifact", {}).get("disposition", "")),
			"overlayDisposition":String(realized_assembler_result.get(
				"emptyTreeBandOverlay", {}).get("disposition", "")),
			"overlaySupportDisposition":String(realized_assembler_result.get(
				"emptyTreeBandOverlay", {}).get("supportDisposition", ""))},
		"directProviderPending":realized_assembler_result.get("directCensus", {}),
		"directCensusDetails":realized_assembler_result.get("directCensusDetails", {}),
		"preparedRevision":String(prepared.get("sourceRevisions", {}).get(
			String(rows[0].sourceId), "")),
		"changedProducerPreparedStatus":String(changed_producer_revision.get("status", "")),
		"changedProducerRevision":String(changed_producer_revision.get(
			"sourceRevisions", {}).get(String(rows[0].sourceId), "")),
		"changedProducerDomainRevision":String(changed_authority_snapshot.get("sourceRevision", "")),
		"changedTransformPreparedStatus":String(changed_transform_prepared.get("status", "")),
		"changedMeshPreparedStatus":String(changed_mesh_prepared.get("status", "")),
		"changedMeshPreparedReason":String(changed_mesh_prepared.get("reason", "")),
		"changedMaterialPreparedStatus":String(changed_material_prepared.get("status", "")),
		"tombstoneCensusDetails":realized_assembler_result.get("tombstoneCensus", {}).get("details", {}),
		"tombstoneProviderDetails":realized_assembler_result.get("tombstoneCensus", {}).get(
			"providerDetails", {}),
		"assembledCandidateStatus":realized_assembler_result.get("assembled", {}).get(
			"status", ""),
		"assembledCandidateReason":realized_assembler_result.get("assembled", {}).get(
			"reason", ""),
		"assembledCandidateDetails":realized_assembler_result.get("assembled", {}).get(
			"details", {}),
		"incompleteSourceCensusStatus":incomplete_source_census.get("status", ""),
		"incompleteSourceCensusReason":incomplete_source_census.get("reason", ""),
		"incompleteSourceCategoryEvidence":incomplete_category_evidence,
		"corruptedCensusStatus":realized_assembler_result.get(
			"corruptedSnapshotCensus", {}).get("status", ""),
		"corruptedCensusReason":realized_assembler_result.get(
			"corruptedSnapshotCensus", {}).get("reason", ""),
		"corruptedSnapshotValidation":realized_assembler_result.get(
			"corruptedSnapshotCensus", {}).get("snapshotValidation", {}),
		"tombstoneRemovals":realized_assembler_result.get("sectionRemovals", []),
		"undergroundRequiredCensusStatus":realized_assembler_result.get(
			"undergroundRequiredCensus", {}).get("status", ""),
		"undergroundRequiredProviderReason":realized_assembler_result.get(
			"undergroundRequiredCensus", {}).get("providerReason", ""),
		"undergroundRequiredProviderDetails":realized_assembler_result.get(
			"undergroundRequiredCensus", {}).get("providerDetails", {}),
		"undergroundRequiredExpectedSources":realized_assembler_result.get(
			"undergroundRequiredCensus", {}).get("expectedContributorsBySection", {}),
		"undergroundContributionCensusStatus":realized_assembler_result.get(
			"undergroundContributionCensus", {}).get("status", ""),
		"undergroundContributionCensusReason":realized_assembler_result.get(
			"undergroundContributionCensus", {}).get("reason", ""),
		"partialCaptureRemovalHistory":partial_removal,
		"uncommittedTreeStatus":overlapping_uncommitted_tree.get("status", ""),
		"uncommittedTreeReason":overlapping_uncommitted_tree.get("reason", ""),
		"uncommittedTreeSourceId":uncommitted_tree_result.get("treeSourceId", ""),
		"uncommittedTreeQueueSourceIds":uncommitted_tree_result.get("queuedSourceIds", []),
		"offSectionUncommittedTreeStatus":off_section_uncommitted_tree.get("status", ""),
		"offSectionUncommittedTreeReason":off_section_uncommitted_tree.get("reason", ""),
		"offSectionBoundsIntersect":uncommitted_tree_result.get("offSectionBoundsIntersect", true),
		"unsupportedDetailIds":realized_assembler_result.get("unsupportedDetailIds", []),
		"unsupportedCensusReason":realized_assembler_result.get("unsupportedCensus", {}).get("reason", ""),
		"exactExpectedIds":realized_assembler_result.get("exactExpectedIds", []),
		"exactManifestIds":realized_assembler_result.get("exactManifestIds", []),
		"dynamicRemovalCensusStatus":realized_assembler_result.get(
			"dynamicRemovalCensus", {}).get("status", ""),
		"dynamicRemovalSourceId":realized_assembler_result.get("dynamicRemovalSourceId", ""),
		"dynamicRemovalRows":realized_assembler_result.get("dynamicRemovalRows", []),
		"dynamicExpectedSources":realized_assembler_result.get("dynamicExpectedSources", []),
		"unaffectedRevisionsStable":realized_assembler_result.get(
			"unaffectedRevisionsStable", false),
		"unaffectedMemberContentRevision":realized_assembler_result.get(
			"unaffectedMemberContentRevision", ""),
		"dynamicUnchangedMemberContentRevision":realized_assembler_result.get(
			"dynamicUnchangedMemberContentRevision", ""),
		"unaffectedAuthorityRotated":realized_assembler_result.get(
			"unaffectedAuthorityRotated", false),
		"sourceCaptureLifecycle":source_capture_lifecycle,
		"producerLeaseRotated":realized_assembler_result.get("producerLeaseRotated", false),
		"initialSourceRevisions":realized_assembler_result.get("initialSourceRevisions", {}),
		"dynamicSourceRevisions":realized_assembler_result.get("dynamicSourceRevisions", {}),
		"undergroundCaptureStatus":realized_assembler_result.get(
			"undergroundContributionCensus", {}).get("status", ""),
		"undergroundContributionStatus":realized_assembler_result.get(
			"undergroundContribution", {}).get("status", ""),
		"undergroundContributionReason":realized_assembler_result.get(
			"undergroundContribution", {}).get("reason", ""),
		"undergroundContributionDetails":realized_assembler_result.get(
			"undergroundContribution", {}).get("details", {}),
		"undergroundContributionInputs":realized_assembler_result.get(
			"undergroundContributionInputIds", []),
		"undergroundMeshBoundsMatch":realized_assembler_result.get(
			"undergroundMeshBoundsMatch", false),
		"ownerReplacementRemovalHistory":owner_replacement,
		"surfaceDetailContributionStatus":realized_assembler_result.get(
			"contribution", {}).get("status", ""),
		"surfaceDetailContributionReason":realized_assembler_result.get(
			"contribution", {}).get("reason", ""),
		"surfaceDetailContributionDetails":realized_assembler_result.get(
			"contribution", {}).get("details", {}),
		"surfaceDetailContributionInputs":realized_assembler_result.get(
			"contributionInputIds", []),
		"surfaceDetailContributionBoundsMatch":realized_assembler_result.get(
			"contributionDetailBoundsMatch", false),
		"preparedStatus":prepared.get("status", "missing"),
		"preparedReason":prepared.get("reason", ""),
		"tintedStatus":tinted.get("status", "missing"),
		"tintedReason":tinted.get("reason", ""),
		"evidence":"synthetic immutable producer-value contracts, realized static prop census-to-assembler, and real tree queue/native compiler/index-overlay/contribution/candidate handoff; no installed renderer receipt, gameplay, save/replay, or performance acceptance"}
	var report_path := OS.get_environment("ECOLOGY_SECTION_VALUE_ADAPTER_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("ECOLOGY SECTION VALUE ADAPTER ", JSON.stringify(report))
	quit(0 if report.passed else 1)


func _source_band_projection_adapter_contract() -> Dictionary:
	var authority := ProductionAuthority.new()
	root.add_child(authority)
	var world_id := "seed:ecology-adapter-band-projection"
	var source_chunk := Vector2i.ZERO
	var section_lower := Vector3i.ZERO
	var section_upper := Vector3i(0, 1, 0)
	var inputs := authority._canonical_fixture_inputs(world_id, source_chunk,
		authority.seed_text, {"terrainVolumeChunkRevision":"band-terrain-r1",
		"structureAdmissionRevision":"band-structure-r1",
		"structureAdmissionStatus":"ready"})
	var artifact: Dictionary = authority._fixture_artifact_for(inputs)
	var removed_digest := ProducerDomain.digest_value([])
	var family_request := ProducerDomain.build_source_family_request(["details"],
		world_id, authority.seed_text, source_chunk, inputs, removed_digest, artifact)
	var lower_bounds: AABB = ProducerDomain.section_bounds(section_lower)
	var split_y: float = lower_bounds.end.y
	var rows: Array[Dictionary] = [
		{"schema":"ecology.static_source_value.v1", "sourceId":"band-crossing",
			"sourcePartId":"part", "producerFamily":"details",
			"category":"surface_detail", "transform":Transform3D.IDENTITY,
			"localBounds":AABB(Vector3.ZERO, Vector3.ONE),
			"supportProof":{"status":"ready", "family":"details",
				"worldBounds":AABB(Vector3(1.0, split_y - 0.5, 1.0), Vector3.ONE)}},
		{"schema":"ecology.static_source_value.v1", "sourceId":"band-lower-only",
			"sourcePartId":"part", "producerFamily":"details",
			"category":"surface_detail", "transform":Transform3D.IDENTITY,
			"localBounds":AABB(Vector3.ZERO, Vector3.ONE),
			"supportProof":{"status":"ready", "family":"details",
				"worldBounds":AABB(Vector3(2.0, split_y - 2.0, 2.0), Vector3.ONE)}}]
	var source_snapshot := ProducerDomain.seal_source_domain_family_bundle({
		"worldId":world_id, "worldSeed":authority.seed_text,
		"sourceChunkKey":source_chunk, "sourceInputs":inputs,
		"sourceRows":rows, "actorIntentSnapshot":[],
		"categoriesComplete":["details"], "completedFamilies":["details"],
		"familyRequest":family_request,
		"removedSourceProjectionDigest":removed_digest}, artifact)
	var lower_projection := ProducerDomain.project_source_domain_family_bundle_to_band(
		source_snapshot, section_lower, lower_bounds, artifact)
	var upper_projection := ProducerDomain.project_source_domain_family_bundle_to_band(
		source_snapshot, section_upper, ProducerDomain.section_bounds(section_upper), artifact)
	var index := FixtureBandProjectionSupportIndex.new()
	for pair in [[section_lower, lower_projection], [section_upper, upper_projection]]:
		var section_key: Vector3i = pair[0]
		var projection: Dictionary = pair[1]
		var coverage := _band_projection_coverage(projection, "details")
		index.expectations[_band_projection_fixture_key(source_chunk,
			section_key, "details")] = _band_projection_expected(source_snapshot,
			projection, coverage, "details")
	var view := {"sourceChunkKey":source_chunk,
		"sourceRevision":String(source_snapshot.get("sourceRevision", "")),
		"publicationId":"fixture-band-publication",
		"worldId":world_id, "worldEpoch":1,
		"contentDigest":ProducerDomain.digest_value(source_snapshot),
		"payload":source_snapshot}
	var publication_token := "fixture-band-publication-lease"
	var publication_authority := FixtureBandProjectionAuthority.new()
	publication_authority.expected_view = view
	publication_authority.expected_token = publication_token
	publication_authority.catalog_artifact = artifact
	index.publication_authority = publication_authority
	var adapter := Adapter.new()
	adapter.configure(world_id)
	adapter._support_index = index
	var both := adapter._register_source_family_section_band_projections(
		publication_authority, world_id, source_chunk, [section_lower, section_upper],
		source_snapshot, artifact, view, publication_token, ["details"])
	var both_bands_registered := String(both.get("status", "")) == "ready" \
		and index.registrations_by_section.size() == 2 \
		and index.registrations_by_section.has(section_lower) \
		and index.registrations_by_section.has(section_upper)
	var selected_legacy_families_only: bool = \
		index.selected_families_by_section.get(section_lower, []) == ["details"] \
		and index.selected_families_by_section.get(section_upper, []) == ["details"]
	var lower_before: Dictionary = index.registrations_by_section.get(section_lower, {})
	var upper_refresh := adapter._register_source_family_section_band_projections(
		publication_authority, world_id, source_chunk, [section_upper],
		source_snapshot, artifact, view, publication_token, ["details"])
	var lower_retained: bool = index.registrations_by_section.get(section_lower, {}) == lower_before \
		and String(upper_refresh.get("status", "")) == "ready"
	var lower_ids: Array = _band_projection_coverage(lower_before, "details").get(
		"sourceIds", [])
	var upper_ids: Array = _band_projection_coverage(
		index.registrations_by_section.get(section_upper, {}), "details").get(
		"sourceIds", [])
	var section_keys_independent := section_lower != section_upper \
		and lower_ids.has("band-crossing") and lower_ids.has("band-lower-only") \
		and upper_ids == ["band-crossing"]
	var missing_key := _band_projection_fixture_key(source_chunk,
		Vector3i(0, 2, 0), "details")
	index.pending_keys[missing_key] = true
	var missing := adapter._register_source_family_section_band_projections(
		publication_authority, world_id, source_chunk, [Vector3i(0, 2, 0)],
		source_snapshot, artifact, view, publication_token, ["details"])
	var missing_pending := String(missing.get("status", "")) == "pending" \
		and not index.registrations_by_section.has(Vector3i(0, 2, 0))
	var stale_source_key := _band_projection_fixture_key(source_chunk,
		section_lower, "details")
	var baseline_expectation: Dictionary = index.expectations[stale_source_key].duplicate(true)
	var stale_source: Dictionary = baseline_expectation.duplicate(true)
	stale_source["sourceDomainRevision"] = "stale-source-revision"
	index.expectations[stale_source_key] = stale_source
	var stale_source_result := adapter._register_source_family_section_band_projections(
		publication_authority, world_id, source_chunk, [section_lower],
		source_snapshot, artifact, view, publication_token, ["details"])
	var stale_source_pending := String(stale_source_result.get("status", "")) == "pending"
	var stale_catalog: Dictionary = baseline_expectation.duplicate(true)
	stale_catalog["catalogContentDigest"] = "0".repeat(64)
	index.expectations[stale_source_key] = stale_catalog
	var stale_catalog_result := adapter._register_source_family_section_band_projections(
		publication_authority, world_id, source_chunk, [section_lower],
		source_snapshot, artifact, view, publication_token, ["details"])
	var stale_catalog_pending := String(stale_catalog_result.get("status", "")) == "pending"
	var stale_removal: Dictionary = baseline_expectation.duplicate(true)
	stale_removal["removedSourceProjectionDigest"] = "f".repeat(64)
	index.expectations[stale_source_key] = stale_removal
	var stale_removal_result := adapter._register_source_family_section_band_projections(
		publication_authority, world_id, source_chunk, [section_lower],
		source_snapshot, artifact, view, publication_token, ["details"])
	var stale_removal_pending := String(stale_removal_result.get("status", "")) == "pending"
	adapter.reset_source_domain_captures()
	authority.free()
	return {"bothBandsRegistered":both_bands_registered,
		"selectedLegacyFamiliesOnly":selected_legacy_families_only,
		"lowerReceiptRetainedAfterUpperRefresh":lower_retained,
		"sectionKeysAreIndependent":section_keys_independent,
		"missingProjectionPending":missing_pending,
		"staleSourcePending":stale_source_pending,
		"staleCatalogPending":stale_catalog_pending,
		"staleRemovalPending":stale_removal_pending,
		"bothStatus":String(both.get("status", "")),
		"missingReason":String(missing.get("reason", "")),
		"staleSourceReason":String(stale_source_result.get("reason", "")),
		"staleCatalogReason":String(stale_catalog_result.get("reason", "")),
		"staleRemovalReason":String(stale_removal_result.get("reason", ""))}


func _band_projection_coverage(projection: Dictionary, family: String) -> Dictionary:
	for coverage_value: Variant in projection.get("familyCoverage", []):
		if coverage_value is Dictionary and String(coverage_value.get("family", "")) == family:
			return coverage_value
	return {}


func _band_projection_fixture_key(source_chunk: Vector2i, section_key: Vector3i,
		family: String) -> String:
	return "%d,%d|%d,%d,%d|%s" % [source_chunk.x, source_chunk.y,
		section_key.x, section_key.y, section_key.z, family]


func _band_projection_expected(source_snapshot: Dictionary,
		projection: Dictionary, coverage: Dictionary, family: String) -> Dictionary:
	var inputs: Dictionary = source_snapshot.get("sourceInputs", {})
	return {"sourceChunkKey":source_snapshot.get("sourceChunkKey", Vector2i.ZERO),
		"sectionKey":projection.get("bandKey", Vector3i.ZERO),
		"bandBounds":projection.get("bandBounds", AABB()),
		"sourceFamilyRevision":coverage.get("sourceFamilyRevision", ""),
		"sourceFamilyManifestDigest":coverage.get("sourceFamilyManifestDigest", ""),
		"sourceDomainRevision":projection.get("sourceRevision", ""),
		"familyPolicyRevision":coverage.get("familyPolicyRevision", ""),
		"familyPolicyDigest":coverage.get("familyPolicyDigest", ""),
		"catalogArtifactId":projection.get("catalogArtifactId", ""),
		"catalogContentDigest":projection.get("catalogContentDigest", ""),
		"worldEpoch":int(projection.get("worldEpoch", -1)),
		"removedSourceProjectionDigest":projection.get(
			"removedSourceProjectionDigest", ""),
		"expectedSourceIds":coverage.get("sourceIds", []),
		"expectedSourceIdsDigest":coverage.get("sourceIdsDigest", ""),
		"expectedSupportMemberDigest":ProducerDomain.digest_value([
			"fixture-band-support-members", source_snapshot.get("sourceChunkKey", Vector2i.ZERO),
			projection.get("bandKey", Vector3i.ZERO), family]),
		"expectedSupportMemberCount":int(coverage.get("memberCount", 0)),
		"inputsCatalogArtifactId":inputs.get("catalogArtifactId", "")}


func _source_capture_queue_lifecycle_contract() -> Dictionary:
	var section_near := Vector3i.ZERO
	var section_far := Vector3i(80, 0, 0)
	var near_chunk := Vector2i.ZERO
	var far_chunk := Vector2i(100, 0)
	var near_id := "near"
	var far_id := "far"
	var provider = Adapter.new()
	provider.configure("seed:ecology-source-queue-lifecycle:1")
	provider._source_capture_jobs[near_id] = {"identity":near_id,
		"worldId":provider._world_id, "sourceChunkKey":near_chunk,
		"latestIdentityKey":"%s|%d,%d|families:fixture-near" % [provider._world_id,
			near_chunk.x, near_chunk.y],
		"status":"pending", "sections":{section_near:true},
		"lastDispatchSequence":0}
	provider._source_capture_jobs[far_id] = {"identity":far_id,
		"worldId":provider._world_id, "sourceChunkKey":far_chunk,
		"latestIdentityKey":"%s|%d,%d|families:fixture-far" % [provider._world_id,
			far_chunk.x, far_chunk.y],
		"status":"pending", "sections":{section_far:true},
		"lastDispatchSequence":0}
	provider._source_capture_jobs_by_section[section_near] = {near_id:true}
	provider._source_capture_jobs_by_section[section_far] = {far_id:true}
	provider._source_capture_cohorts[section_near] = {"sectionKey":section_near,
		"cohortId":"near", "createdSequence":1, "createdOpportunity":0,
		"priority":0.0, "status":"active", "closureSealed":false,
		"waitOpportunities":0, "blockedUntilOpportunity":-1, "blockedReason":""}
	provider._source_capture_cohorts[section_far] = {"sectionKey":section_far,
		"cohortId":"far", "createdSequence":2, "createdOpportunity":0,
		"priority":10000.0, "status":"active", "closureSealed":false,
		"waitOpportunities":0, "blockedUntilOpportunity":-1, "blockedReason":""}
	provider._source_capture_active_cohort_count = 2
	provider._source_capture_latest_by_chunk[provider._source_capture_jobs[near_id].latestIdentityKey] = near_id
	provider._source_capture_latest_by_chunk[provider._source_capture_jobs[far_id].latestIdentityKey] = far_id
	provider._source_capture_queue.assign([near_id, far_id])
	provider._source_capture_queued = {near_id:true, far_id:true}
	var first_dispatch := provider._take_next_source_capture_job(Vector3.ZERO)
	provider._enqueue_source_capture_job(near_id)
	# The first choice is camera-nearest. Once it is serviced, the untouched far
	# job's older dispatch sequence wins, even though the near one stays pending.
	var second_dispatch := provider._take_next_source_capture_job(Vector3.ZERO)
	provider._source_capture_jobs[near_id]["sections"] = {section_far:true}
	provider._source_capture_jobs[far_id]["sections"] = {section_far:true}
	provider._source_capture_jobs_by_section.erase(section_near)
	provider._source_capture_jobs_by_section[section_far] = {near_id:true, far_id:true}
	provider._source_capture_queue.assign([near_id, far_id])
	provider._source_capture_queued = {near_id:true, far_id:true}
	var released: Dictionary = provider.release_section_capture_demand(section_far)
	var supersede_main := StaleCaptureAuthority.new()
	supersede_main.seed_text = "ecology-source-queue-lifecycle"
	supersede_main.seed_hash = 1
	root.add_child(supersede_main)
	var supersede_provider = Adapter.new()
	var supersede_world := "seed:%s:%d" % [supersede_main.seed_text,
		supersede_main.seed_hash]
	supersede_provider.configure(supersede_world)
	supersede_provider.bind_main_authority(supersede_main)
	var base_inputs := {"terrainVolumeChunkRevision":"synthetic-terrain-r1",
		"structureAdmissionRevision":"synthetic-structure-r1",
		"structureAdmissionStatus":"ready"}
	var source_chunk := Vector2i(5, -3)
	var inputs_a: Dictionary = supersede_main._canonical_fixture_inputs(
		supersede_world, source_chunk, supersede_main.seed_text, base_inputs)
	var removal_snapshot := {"ok":true, "ids":[]}
	var removal_projection := {"status":"ready", "removedIds":[],
		"digest":ProducerDomain.digest_value([])}
	var old_request: Dictionary = supersede_provider.request_source_domain_capture(
		supersede_world, source_chunk, supersede_main.seed_text, inputs_a,
		removal_snapshot, removal_projection, section_near, 0.0)
	var old_identity := String(old_request.get("identity", ""))
	var old_job: Dictionary = supersede_provider._source_capture_jobs.get(old_identity, {})
	var old_cache_identity := String(old_job.get("captureCacheIdentity", ""))
	check("supersession_fixture_admits_initial_source_job",
		not old_identity.is_empty() and not old_job.is_empty() \
		and not old_cache_identity.is_empty())
	supersede_main.capture_domain.set_pending_capture_progress(old_cache_identity, {"state":{"partial":true}})
	var inputs_b := inputs_a.duplicate(true)
	inputs_b["terrainVolumeChunkRevision"] = "synthetic-terrain-r2"
	var replacement_request: Dictionary = supersede_provider.request_source_domain_capture(
		supersede_world, source_chunk, supersede_main.seed_text, inputs_b,
		removal_snapshot, removal_projection, section_near, 0.0)
	var replacement_identity := String(replacement_request.get("identity", ""))
	var replacement_job: Dictionary = supersede_provider._source_capture_jobs.get(
		replacement_identity, {})
	if old_job.is_empty() or replacement_job.is_empty():
		supersede_provider.reset_source_domain_captures()
		supersede_main.free()
		return {"supersededOldPayloadReleased":false,
			"currentReplacementRetained":false,
			"sourceCaptureFixtureDiagnostic":{
				"oldRequest":old_request, "replacementRequest":replacement_request,
				"oldJobFound":not old_job.is_empty(),
				"replacementJobFound":not replacement_job.is_empty()}}
	var superseded_payload_released: bool = not old_identity.is_empty() \
		and old_identity != replacement_identity \
		and not supersede_provider._source_capture_jobs.has(old_identity) \
		and old_identity not in supersede_provider._source_capture_queue
	check("supersession_cancels_exact_old_source_continuation",
		supersede_main.cancelled_capture_keys.has(old_cache_identity) \
		and not supersede_main.capture_domain._pending_capture_progress.has(old_cache_identity))
	var replacement_retained: bool = not replacement_identity.is_empty() \
		and supersede_provider._source_capture_jobs.has(replacement_identity)
	var stale_main := supersede_main
	var wake_recorder := StaleCaptureWakeRecorder.new()
	stale_main.world_static_section_coordinator = wake_recorder
	var stale_cache_identity := String(replacement_job.get("captureCacheIdentity", ""))
	stale_main.capture_domain.set_pending_capture_progress(stale_cache_identity, {"state":{"partial":true}})
	supersede_provider.request_source_domain_capture(supersede_world, source_chunk,
		supersede_main.seed_text, inputs_b, removal_snapshot, removal_projection, section_far, 1.0)
	var stale_advance: Dictionary = supersede_provider.advance_source_domain_captures(1)
	var scopes_after_stale := stale_main.catalog_scope_begins
	supersede_provider.advance_source_domain_captures(1)
	supersede_provider.advance_source_domain_captures(0)
	supersede_provider.capture_static_section_sources(supersede_world, [])
	check("capture_scope_balanced_and_idle_invalid_calls_do_not_capture_catalog",
		scopes_after_stale == 1 and stale_main.catalog_scope_begins == scopes_after_stale \
		and stale_main.catalog_scope_ends == scopes_after_stale and stale_main.catalog_scope_depth == 0)
	var stale_retired: bool = not supersede_provider._source_capture_jobs.has(replacement_identity) \
		and supersede_provider.source_domain_capture_pending_count() == 0 \
		and stale_main.capture_calls == 1 \
		and not stale_main.capture_domain._pending_capture_progress.has(stale_cache_identity) \
		and wake_recorder.sections.has(section_near) and wake_recorder.sections.has(section_far)
	var current_inputs := inputs_b.duplicate(true)
	current_inputs.erase("structureDependencies")
	current_inputs["structureAdmissionRevision"] = "current"
	current_inputs = supersede_main._canonical_fixture_inputs(supersede_world,
		source_chunk, supersede_main.seed_text, current_inputs)
	var recaptured: Dictionary = supersede_provider.request_source_domain_capture(
		supersede_world, source_chunk, supersede_main.seed_text, current_inputs,
		removal_snapshot, removal_projection, section_near, 0.0)
	check("stale_source_capture_retires_old_input_wakes_all_and_readmits_current_identity",
		stale_retired and recaptured.get("status") == "pending" \
		and String(recaptured.get("identity", "")) != replacement_identity \
		and bool(stale_advance.get("results", [{}])[0].get("requiresRecapture", false)))
	stale_main.permanent_failure = true
	supersede_provider.advance_source_domain_captures(1)
	var terminal_retry: Dictionary = supersede_provider.request_source_domain_capture(
		supersede_world, source_chunk, supersede_main.seed_text, current_inputs,
		removal_snapshot, removal_projection, section_near, 0.0)
	check("stable_source_contract_failure_remains_terminal",
		terminal_retry.get("status") == "failed" \
		and terminal_retry.get("reason") == "fixture_unbounded_source" \
		and not bool(terminal_retry.get("retryable", true)))
	var revision_failure_main := StaleCaptureAuthority.new()
	revision_failure_main.seed_text = "ecology-terminal-failure-revision-recovery"
	revision_failure_main.seed_hash = 4
	revision_failure_main.permanent_failure = true
	root.add_child(revision_failure_main)
	var revision_failure_provider = Adapter.new()
	var revision_failure_world := "seed:%s:%d" % [revision_failure_main.seed_text,
		revision_failure_main.seed_hash]
	revision_failure_provider.configure(revision_failure_world)
	revision_failure_provider.bind_main_authority(revision_failure_main)
	var revision_failure_chunk := Vector2i(31, -17)
	var revision_failure_section := Vector3i(31, 0, -17)
	var revision_inputs_a: Dictionary = revision_failure_main._canonical_fixture_inputs(
		revision_failure_world, revision_failure_chunk, revision_failure_main.seed_text,
		{"terrainVolumeChunkRevision":"terminal-input-a",
			"structureAdmissionRevision":"terminal-structure-a",
			"structureAdmissionStatus":"ready"})
	var revision_request_a: Dictionary = revision_failure_provider.request_source_domain_capture(
		revision_failure_world, revision_failure_chunk, revision_failure_main.seed_text,
		revision_inputs_a, removal_snapshot, removal_projection, revision_failure_section, 0.0)
	var revision_identity_a := String(revision_request_a.get("identity", ""))
	revision_failure_provider.advance_source_domain_captures(1)
	var same_revision_failure: Dictionary = revision_failure_provider.request_source_domain_capture(
		revision_failure_world, revision_failure_chunk, revision_failure_main.seed_text,
		revision_inputs_a, removal_snapshot, removal_projection, revision_failure_section, 0.0)
	revision_failure_main.permanent_failure = false
	var revision_inputs_b: Dictionary = revision_inputs_a.duplicate(true)
	revision_inputs_b["terrainVolumeChunkRevision"] = "terminal-input-b"
	revision_inputs_b = revision_failure_main._canonical_fixture_inputs(
		revision_failure_world, revision_failure_chunk, revision_failure_main.seed_text,
		revision_inputs_b)
	var revision_request_b: Dictionary = revision_failure_provider.request_source_domain_capture(
		revision_failure_world, revision_failure_chunk, revision_failure_main.seed_text,
		revision_inputs_b, removal_snapshot, removal_projection, revision_failure_section, 0.0)
	check("changed_source_revision_replaces_cached_terminal_failure",
		same_revision_failure.get("status") == "failed" \
		and same_revision_failure.get("reason") == "fixture_unbounded_source" \
		and revision_request_b.get("status") == "pending" \
		and String(revision_request_b.get("identity", "")) != revision_identity_a)
	revision_failure_provider.reset_source_domain_captures()
	revision_failure_main.free()
	var current_identity := String(recaptured.get("identity", ""))
	var current_cache_identity := String(supersede_provider._source_capture_jobs[current_identity].captureCacheIdentity)
	stale_main.capture_domain.set_pending_capture_progress(current_cache_identity, {"state":{"partial":true}})
	supersede_provider.release_section_capture_demand(section_near)
	check("last_subscriber_release_cancels_source_continuation",
		stale_main.cancelled_capture_keys.has(current_cache_identity) \
		and not stale_main.capture_domain._pending_capture_progress.has(current_cache_identity))
	var reset_request: Dictionary = supersede_provider.request_source_domain_capture(
		supersede_world, source_chunk, supersede_main.seed_text, current_inputs,
		removal_snapshot, removal_projection, section_near, 0.0)
	var reset_identity := String(reset_request.get("identity", ""))
	var reset_cache_identity := String(supersede_provider._source_capture_jobs[reset_identity].captureCacheIdentity)
	stale_main.capture_domain.set_pending_capture_progress(reset_cache_identity, {"state":{"partial":true}})
	stale_main.capture_domain._completed_snapshot_cache[reset_cache_identity] = {"readySentinel":true}
	supersede_provider.reset_source_domain_captures()
	check("queue_reset_cancels_partial_source_state_preserving_completed_cache",
		not stale_main.capture_domain._pending_capture_progress.has(reset_cache_identity) \
		and stale_main.capture_domain._completed_snapshot_cache.has(reset_cache_identity))
	var idle_provider = Adapter.new()
	idle_provider.configure("seed:ecology-source-idle-cache:1")
	var demanded_id := "demanded-ready"
	idle_provider._source_capture_jobs[demanded_id] = {"status":"ready",
		"snapshot":{"sourceRows":[]}, "sections":{section_near:true}}
	idle_provider._source_capture_jobs_by_section[section_near] = {demanded_id:true}
	idle_provider._retire_source_capture_if_unsubscribed(demanded_id)
	var demanded_ready_retained: bool = idle_provider._source_capture_jobs.has(demanded_id) \
		and demanded_id not in idle_provider._source_capture_idle_ready_order
	idle_provider.release_section_capture_demand(section_near)
	var demanded_ready_idle_cached: bool = idle_provider._source_capture_jobs.has(demanded_id) \
		and demanded_id in idle_provider._source_capture_idle_ready_order \
		and idle_provider._source_capture_jobs[demanded_id].get("snapshot", {}).has("sourceRows")
	for index in range(Adapter.MAX_IDLE_READY_SOURCE_CAPTURE_JOBS + 2):
		var idle_id := "idle-%03d" % index
		idle_provider._source_capture_jobs[idle_id] = {"status":"ready",
			"snapshot":{"sourceRows":[]}, "sections":{}}
		idle_provider._retire_source_capture_if_unsubscribed(idle_id)
	var idle_cache_bounded: bool = idle_provider._source_capture_idle_ready_order.size() \
		== Adapter.MAX_IDLE_READY_SOURCE_CAPTURE_JOBS \
		and not idle_provider._source_capture_jobs.has("idle-000") \
		and idle_provider._source_capture_jobs.has("idle-%03d" % (
			Adapter.MAX_IDLE_READY_SOURCE_CAPTURE_JOBS + 1))
	var reset_result: Dictionary = idle_provider.reset_source_domain_captures()
	var reset_cleared: bool = reset_result.get("status") == "reset" \
		and idle_provider._source_capture_jobs.is_empty() \
		and idle_provider._source_capture_latest_by_chunk.is_empty() \
		and idle_provider._source_capture_jobs_by_section.is_empty() \
		and idle_provider._source_capture_queue.is_empty() \
		and idle_provider._source_capture_queued.is_empty() \
		and idle_provider._source_capture_idle_ready_order.is_empty()
	supersede_main.free()
	return {"firstDispatchNear":first_dispatch,
		"secondDispatchFar":second_dispatch,
		"detachedJobCount":int(released.get("detachedJobCount", 0)),
		"pendingAfterDetach":provider.source_domain_capture_pending_count(),
		"queuedAfterDetach":provider._source_capture_queue.size(),
		"supersededOldPayloadReleased":superseded_payload_released,
		"currentReplacementRetained":replacement_retained,
		"demandedReadyRetained":demanded_ready_retained,
		"demandedReadyIdleCached":demanded_ready_idle_cached,
		"idleCacheBounded":idle_cache_bounded,
		"resetClearedEverything":reset_cleared}


func _source_capture_cohort_scheduler_contract() -> Dictionary:
	var provider = Adapter.new()
	provider.configure("seed:ecology-section-cohort-scheduler:1")
	var section_near := Vector3i.ZERO
	var section_second := Vector3i(1, 0, 0)
	var section_far := Vector3i(80, 0, 0)
	provider._upsert_source_capture_cohort(section_near, 1.0)
	provider._upsert_source_capture_cohort(section_second, 16.0)
	provider._upsert_source_capture_cohort(section_far, 1000000.0)
	provider._promote_source_capture_cohorts()
	var initial_snapshot: Dictionary = provider.source_capture_scheduler_snapshot()
	var initial_active_count := int(initial_snapshot.get("activeCohortCount", 0))
	var far_initial_status := String(provider._source_capture_cohorts[section_far].get("status", ""))
	var telemetry_cohort: Dictionary = provider._source_capture_cohorts[section_near]
	var telemetry_prep_key := provider._source_section_preparation_key(
		provider._world_id, section_near)
	telemetry_cohort["preparationKey"] = telemetry_prep_key
	telemetry_cohort["sectionPreparation"] = {
		"preparationKey":telemetry_prep_key, "status":"pending",
		"stage":"source_families", "familyCursor":2,
		"sourceChunkCursor":1, "sourcePlans":[{}, {}],
		"unitCount":3, "pendingReason":"fixture_dependency_pending"}
	provider._source_capture_cohorts[section_near] = telemetry_cohort
	var telemetry_snapshot: Dictionary = provider.source_capture_scheduler_snapshot()
	var telemetry_rows: Array = telemetry_snapshot.get("active", [])
	var telemetry_row: Dictionary = {}
	for telemetry_value: Variant in telemetry_rows:
		if telemetry_value is Dictionary and String(telemetry_value.get(
				"preparationKey", "")) == telemetry_prep_key:
			telemetry_row = telemetry_value
			break
	var preparation_telemetry_bounded: bool = telemetry_rows.size() \
		<= Adapter.MAX_ACTIVE_SOURCE_CAPTURE_COHORTS \
		and String(telemetry_row.get("preparationKey", "")) == telemetry_prep_key \
		and String(telemetry_row.get("preparationStatus", "")) == "pending" \
		and int(telemetry_row.get("preparationSourceChunkCursor", -1)) == 1 \
		and int(telemetry_row.get("preparationFamilyCursor", -1)) == 2 \
		and int(telemetry_row.get("preparationSourceChunkCount", -1)) == 2 \
		and int(telemetry_row.get("preparationUnitCount", -1)) == 3 \
		and JSON.stringify(telemetry_row).length() <= 512
	var preparation_telemetry_row_bytes: int = JSON.stringify(telemetry_row).length()
	var preparation_telemetry_has_no_payload: bool = \
		not telemetry_row.has("sourcePlans") and not telemetry_row.has("census")
	var empty_provider = Adapter.new()
	empty_provider.configure("seed:ecology-certified-empty-closure:1")
	var empty_section := Vector3i(12, 0, -4)
	empty_provider._upsert_source_capture_cohort(empty_section, 0.0)
	empty_provider._promote_source_capture_cohorts()
	empty_provider._seal_source_capture_cohort_closures([empty_section])
	var empty_cohort: Dictionary = empty_provider._source_capture_cohorts[empty_section]
	var empty_closure_sealed: bool = bool(empty_cohort.get("closureSealed", false))
	var empty_closure_disposition := String(empty_cohort.get("closureDisposition", ""))
	var empty_closure_status := String(empty_cohort.get("status", ""))
	var empty_closure_active_after_seal := empty_provider._active_source_capture_cohort_count()
	var missing_provider = Adapter.new()
	missing_provider.configure("seed:ecology-missing-closure:1")
	var missing_section := Vector3i(-12, 0, 4)
	missing_provider._upsert_source_capture_cohort(missing_section, 0.0)
	missing_provider._promote_source_capture_cohorts()
	var missing_closure_remains_active: bool = \
		String(missing_provider._source_capture_cohorts[missing_section].get(
			"closureDisposition", "missing")) == "missing" \
		and String(missing_provider._source_capture_cohorts[missing_section].get(
			"status", "")) == "active" \
		and missing_provider._active_source_capture_cohort_count() == 1
	var fair_main := StaleCaptureAuthority.new()
	fair_main.seed_text = "ecology-section-preparation-fairness"
	fair_main.seed_hash = 4
	var fair_provider := FairSchedulerAdapter.new()
	fair_provider.configure("seed:%s:%d" % [fair_main.seed_text, fair_main.seed_hash])
	fair_provider.bind_main_authority(fair_main)
	var blocked_preparation_section := Vector3i(20, 0, 0)
	var empty_preparation_section := Vector3i(21, 0, 0)
	fair_provider._upsert_source_capture_cohort(blocked_preparation_section, 1.0)
	fair_provider._upsert_source_capture_cohort(empty_preparation_section, 2.0)
	fair_provider._promote_source_capture_cohorts()
	var blocked_preparation_key := fair_provider._source_section_preparation_key(
		fair_provider._world_id, blocked_preparation_section)
	var empty_preparation_key := fair_provider._source_section_preparation_key(
		fair_provider._world_id, empty_preparation_section)
	var blocked_preparation := {"preparationKey":blocked_preparation_key,
		"sectionKey":blocked_preparation_section, "status":"pending",
		"sourcePlans":[{"captureIdentity":"pending-source-capture",
			"sourceChunkKey":Vector2i.ZERO, "requestedFamilies":["trees"]}],
		"sourceChunkCursor":0, "familyCursor":0}
	var empty_preparation := {"preparationKey":empty_preparation_key,
		"sectionKey":empty_preparation_section, "status":"pending",
		"sourcePlans":[], "sourceChunkCursor":0, "familyCursor":0}
	fair_provider._source_capture_cohorts[blocked_preparation_section][
		"preparationKey"] = blocked_preparation_key
	fair_provider._source_capture_cohorts[blocked_preparation_section][
		"sectionPreparation"] = blocked_preparation
	fair_provider._source_capture_cohorts[empty_preparation_section][
		"preparationKey"] = empty_preparation_key
	fair_provider._source_capture_cohorts[empty_preparation_section][
		"sectionPreparation"] = empty_preparation
	fair_provider._source_section_preparations[blocked_preparation_key] = blocked_preparation
	fair_provider._source_section_preparations[empty_preparation_key] = empty_preparation
	fair_provider._source_section_preparation_order = [blocked_preparation_key,
		empty_preparation_key]
	fair_provider._source_capture_jobs["pending-source-capture"] = {
		"identity":"pending-source-capture", "status":"pending",
		"sourceChunkKey":Vector2i.ZERO}
	var fair_advance := fair_provider._advance_source_domain_captures_in_scope(2, Vector3.ZERO)
	var pending_first_did_not_block_empty_completion: bool = \
		fair_advance.get("status", "") == "advanced" \
		and fair_provider.sealed_sections == [empty_preparation_section] \
		and fair_provider._source_section_preparations.has(blocked_preparation_key) \
		and not fair_provider._source_section_preparations.has(empty_preparation_key) \
		and String(fair_provider._source_capture_cohorts[blocked_preparation_section].get(
			"status", "")) == "active" \
		and String(fair_provider._source_capture_cohorts[empty_preparation_section].get(
			"sectionPreparation", {}).get("status", "")) == "complete"
	var failed_scheduler := TerminalFailureSchedulerAdapter.new()
	failed_scheduler.configure("seed:ecology-terminal-preparation-failure:1")
	var terminal_main := ProductionAuthority.new()
	terminal_main.seed_text = "ecology-terminal-preparation-failure"
	terminal_main.seed_hash = 1
	root.add_child(terminal_main)
	failed_scheduler.bind_main_authority(terminal_main)
	var terminal_section := Vector3i(22, 0, 2)
	var terminal_key: String = failed_scheduler._source_section_preparation_key(
		failed_scheduler._world_id, terminal_section)
	var terminal_prep: Dictionary = {"preparationKey":terminal_key,
		"sectionKey":terminal_section, "status":"pending", "sourcePlans":[],
		"sourceChunkCursor":0, "familyCursor":0}
	failed_scheduler._source_section_preparations[terminal_key] = terminal_prep
	failed_scheduler._source_section_preparation_order = [terminal_key]
	failed_scheduler._source_capture_cohorts[terminal_section] = {
		"status":"active", "preparationKey":terminal_key,
		"sectionPreparation":terminal_prep}
	var terminal_advance: Dictionary = \
		failed_scheduler._advance_source_domain_captures_in_scope(1, Vector3.ZERO)
	var terminal_stored: Dictionary = failed_scheduler._source_capture_cohorts[
		terminal_section].get("sectionPreparation", {})
	var terminal_failure_propagates: bool = \
		String(terminal_advance.get("status", "")) == "failed" \
		and String(terminal_advance.get("reason", "")) \
			== "fixture_terminal_preparation_failure" \
		and String(terminal_stored.get("status", "")) == "failed" \
		and failed_scheduler._source_section_preparation_order.is_empty()
	var terminal_advance_status := String(terminal_advance.get("status", ""))
	var terminal_advance_reason := String(terminal_advance.get("reason", ""))
	terminal_main.free()
	var registration_scheduler := TerminalRegistrationSchedulerAdapter.new()
	registration_scheduler.configure("seed:ecology-terminal-registration-failure:1")
	var registration_queue := FixtureBandPollQueue.new()
	registration_queue.poll_result = {"status":"failed",
		"reason":"fixture_terminal_tree_band_failure"}
	var registration_section := Vector3i(23, 0, 2)
	var registration_demand: Dictionary = {"jobKey":"fixture-band-job",
		"consumerToken":"fixture-band-consumer", "authorityDigest":"fixture-authority",
		"queueRef":weakref(registration_queue)}
	registration_scheduler.band_queue = registration_queue
	registration_scheduler.band_demand = registration_demand
	registration_scheduler.band_section = registration_section
	registration_scheduler.band_source_chunk = Vector2i.ZERO
	registration_scheduler.band_consumer_token = "fixture-band-consumer"
	registration_scheduler.band_authority_digest = "fixture-authority"
	var registration_key := registration_scheduler._source_section_preparation_key(
		registration_scheduler._world_id, registration_section)
	var registration_prep: Dictionary = {"preparationKey":registration_key,
		"sectionKey":registration_section, "status":"pending", "sourcePlans":[],
		"sourceChunkCursor":0, "familyCursor":0}
	registration_scheduler._source_section_preparations[registration_key] = registration_prep
	registration_scheduler._source_section_preparation_order = [registration_key]
	registration_scheduler._source_capture_cohorts[registration_section] = {
		"status":"active", "preparationKey":registration_key,
		"sectionPreparation":registration_prep}
	var registration_advance: Dictionary = \
		registration_scheduler._advance_next_source_section_preparation(
			PreparationCurrentAuthority.new())
	var registration_stored: Dictionary = registration_scheduler._source_capture_cohorts[
		registration_section].get("sectionPreparation", {})
	var terminal_registration_is_not_pending: bool = \
		String(registration_advance.get("status", "")) == "failed" \
		and String(registration_advance.get("reason", "")) \
			== "fixture_terminal_tree_band_failure" \
		and String(registration_stored.get("status", "")) == "failed" \
		and registration_scheduler._source_section_preparation_order.is_empty() \
		and registration_queue.poll_calls == 1 \
		and registration_queue.last_polled_job_key == "fixture-band-job" \
		and registration_queue.last_polled_consumer == "fixture-band-consumer"
	var nested_terminal_pending_shape: Dictionary = \
		registration_scheduler._classify_retained_preparation_outcome({
			"status":"pending", "registration":{"disposition":"terminal",
				"result":{"status":"pending",
					"reason":"fixture_nested_terminal_pending",
					"terminalFailure":true, "retryable":false}}})
	var stale_member_absent: Dictionary = \
		registration_scheduler._classify_retained_preparation_outcome({
			"status":"failed", "reason":"ecology_source_publication_member_absent"})
	var stale_member_alias: Dictionary = \
		registration_scheduler._classify_retained_preparation_outcome({
			"status":"failed", "reason":"ecology_source_publication_member_alias_mismatch"})
	var stale_slice_view: Dictionary = \
		registration_scheduler._classify_retained_preparation_outcome({
			"status":"failed", "reason":"ecology_band_slice_view_not_admitted"})
	var stale_slice_lease: Dictionary = \
		registration_scheduler._classify_retained_preparation_outcome({
			"status":"pending", "reason":"ecology_band_slice_catalog_lease_stale",
			"retryable":true})
	var dependency_status_protocols_classified: bool = \
		String(nested_terminal_pending_shape.get("status", "")) == "failed" \
		and String(nested_terminal_pending_shape.get("reason", "")) \
			== "fixture_nested_terminal_pending" \
		and String(stale_member_absent.get("status", "")) == "stale" \
		and String(stale_member_alias.get("status", "")) == "stale" \
		and String(stale_slice_view.get("status", "")) == "stale" \
		and String(stale_slice_lease.get("status", "")) == "stale"
	var first_poll_scheduler := TerminalRegistrationSchedulerAdapter.new()
	first_poll_scheduler.configure("seed:ecology-first-poll-terminal:1")
	first_poll_scheduler.use_first_poll = true
	first_poll_scheduler.band_section = Vector3i(24, 0, 2)
	first_poll_scheduler.band_source_chunk = Vector2i(0, 0)
	var first_poll_queue := FixtureBandPollQueue.new()
	first_poll_scheduler.band_queue = first_poll_queue
	first_poll_queue.poll_result = {"status":"pending",
		"reason":"fixture_first_poll_tree_band_failure",
		"terminalFailure":true, "retryable":false}
	var first_poll_authority := FixtureTreeBandAdmissionIndex.new()
	var first_poll_band_authority: Dictionary = {
		"schema":"ecology-tree-source-family-band-authority/v1",
		"authorityDigest":"fixture-first-poll-authority",
		"sectionKey":first_poll_scheduler.band_section,
		"sourceChunkKey":first_poll_scheduler.band_source_chunk,
		"sourceRevision":"fixture-source-revision",
		"producerSourceIds":[]}
	first_poll_band_authority.make_read_only()
	first_poll_authority.authority = first_poll_band_authority
	first_poll_scheduler._support_index = first_poll_authority
	var first_poll_main := FixtureTreeAdmissionMain.new()
	first_poll_main.tree_publication_queue = first_poll_queue
	var first_poll_wake_coordinator := FixturePreparationWakeCoordinator.new()
	first_poll_main.world_static_section_coordinator = first_poll_wake_coordinator
	first_poll_scheduler.first_poll_main = first_poll_main
	first_poll_scheduler._main_authority_ref = weakref(first_poll_main)
	first_poll_scheduler.first_poll_snapshot = {"status":"ready",
		"sourceChunkKey":first_poll_scheduler.band_source_chunk,
		"sourceRevision":"fixture-source-revision"}
	first_poll_scheduler.first_poll_snapshot.make_read_only()
	first_poll_scheduler.first_poll_bundle = {}
	first_poll_scheduler.first_poll_publication_view = {
		"publicationId":"fixture-first-poll-publication",
		"familyResultsById":{"trees":{"status":"ready",
			"familyRevision":"fixture-tree-family-revision",
			"sourceManifestDigest":"f".repeat(64)}}}
	first_poll_scheduler.first_poll_lease_token = "fixture-first-poll-lease"
	var first_poll_key := first_poll_scheduler._source_section_preparation_key(
		first_poll_scheduler._world_id, first_poll_scheduler.band_section)
	var first_poll_prep: Dictionary = {"preparationKey":first_poll_key,
		"sectionKey":first_poll_scheduler.band_section, "status":"pending",
		"sourcePlans":[], "sourceChunkCursor":0, "familyCursor":0}
	first_poll_scheduler._source_section_preparations[first_poll_key] = first_poll_prep
	first_poll_scheduler._source_section_preparation_order = [first_poll_key]
	first_poll_scheduler._source_capture_cohorts[
		first_poll_scheduler.band_section] = {"status":"active",
			"preparationKey":first_poll_key, "sectionPreparation":first_poll_prep}
	var first_poll_advance: Dictionary = \
		first_poll_scheduler._advance_next_source_section_preparation(
			PreparationCurrentAuthority.new())
	var first_poll_stored: Dictionary = first_poll_scheduler._source_capture_cohorts[
		first_poll_scheduler.band_section].get("sectionPreparation", {})
	var first_poll_terminal_propagates: bool = \
		String(first_poll_advance.get("status", "")) == "failed" \
		and String(first_poll_advance.get("reason", "")) \
			== "fixture_first_poll_tree_band_failure" \
		and String(first_poll_stored.get("status", "")) == "failed" \
		and first_poll_scheduler._source_section_preparation_order.is_empty() \
		and first_poll_queue.request_calls == 1 \
		and first_poll_queue.poll_calls == 1 \
		and first_poll_queue.last_polled_job_key == "fixture-first-poll-job" \
		and first_poll_wake_coordinator.wakes.size() == 1 \
		and first_poll_wake_coordinator.wakes[0].get("reason", "") \
			== "fixture_first_poll_tree_band_failure"
	# Production request shape: the queue has admitted a band consumer but its
	# worker is still running. The adapter must retain that exact token so unload
	# can detach the ownership it just acquired.
	first_poll_scheduler._source_capture_jobs.clear()
	var admitted_pending_queue := FixtureBandPollQueue.new()
	admitted_pending_queue.request_status = "pending"
	admitted_pending_queue.request_reason = "tree_source_record_compile_backpressure"
	admitted_pending_queue.request_job_key = "fixture-admitted-pending-job"
	admitted_pending_queue.poll_result = {"status":"pending",
		"reason":"tree_source_record_projection_waiting", "retryable":true}
	first_poll_main.tree_publication_queue = admitted_pending_queue
	var admitted_pending_result: Dictionary = \
		first_poll_scheduler._admit_compile_register_tree_band(first_poll_main,
			first_poll_scheduler._world_id, "fixture-first-poll-capture",
			first_poll_scheduler.band_source_chunk, first_poll_scheduler.band_section,
			first_poll_scheduler.first_poll_snapshot,
			first_poll_scheduler.first_poll_bundle,
			first_poll_scheduler.first_poll_publication_view,
			first_poll_scheduler.first_poll_lease_token)
	var admitted_pending_job: Dictionary = first_poll_scheduler._source_capture_jobs.get(
		"fixture-first-poll-capture", {})
	var admitted_pending_demands_value: Variant = admitted_pending_job.get(
		"treeCompileDemands", {})
	var admitted_pending_demands: Dictionary = admitted_pending_demands_value \
		if admitted_pending_demands_value is Dictionary else {}
	var admitted_pending_demand: Dictionary = admitted_pending_demands.values()[0] \
		if not admitted_pending_demands.is_empty() else {}
	var admitted_pending_token := String(admitted_pending_demand.get(
		"consumerToken", ""))
	first_poll_scheduler._cancel_tree_compile_demand(admitted_pending_demand)
	var admitted_pending_consumer_retained_and_cancelled: bool = \
		String(admitted_pending_result.get("status", "")) == "pending" \
		and String(admitted_pending_result.get("reason", "")) \
			== "tree_source_record_projection_waiting" \
		and admitted_pending_queue.request_reason == \
			"tree_source_record_compile_backpressure" \
		and String(admitted_pending_demand.get("jobKey", "")) \
			== "fixture-admitted-pending-job" \
		and not admitted_pending_token.is_empty() \
		and admitted_pending_token == admitted_pending_queue.last_requested_consumer \
		and admitted_pending_queue.poll_calls == 1 \
		and admitted_pending_queue.cancel_calls.size() == 1 \
		and admitted_pending_queue.cancel_calls[0].get("jobKey", "") \
			== "fixture-admitted-pending-job" \
		and admitted_pending_queue.cancel_calls[0].get("consumerToken", "") \
			== admitted_pending_token
	# Queue-full is a prospective key only: no consumer was attached, so it must
	# not become a retained demand or be cancelled as though a job existed.
	first_poll_scheduler._source_capture_jobs.clear()
	var queue_full_pending := FixtureBandPollQueue.new()
	queue_full_pending.request_status = "pending"
	queue_full_pending.request_reason = "tree_source_band_queue_full"
	queue_full_pending.request_job_key = "fixture-prospective-full-key"
	queue_full_pending.attach_request_consumer = false
	first_poll_main.tree_publication_queue = queue_full_pending
	var queue_full_result: Dictionary = \
		first_poll_scheduler._admit_compile_register_tree_band(first_poll_main,
			first_poll_scheduler._world_id, "fixture-first-poll-capture",
			first_poll_scheduler.band_source_chunk, first_poll_scheduler.band_section,
			first_poll_scheduler.first_poll_snapshot,
			first_poll_scheduler.first_poll_bundle,
			first_poll_scheduler.first_poll_publication_view,
			first_poll_scheduler.first_poll_lease_token)
	var queue_full_job: Dictionary = first_poll_scheduler._source_capture_jobs.get(
		"fixture-first-poll-capture", {})
	var queue_full_demands_value: Variant = queue_full_job.get("treeCompileDemands", {})
	var queue_full_demands: Dictionary = queue_full_demands_value \
		if queue_full_demands_value is Dictionary else {}
	var queue_full_not_retained: bool = \
		String(queue_full_result.get("status", "")) == "pending" \
		and String(queue_full_result.get("reason", "")) == "tree_source_band_queue_full" \
		and queue_full_pending.poll_calls == 0 \
		and queue_full_pending.cancel_calls.is_empty() \
		and queue_full_demands.is_empty()
	first_poll_scheduler._source_capture_jobs.clear()
	var failed_admission_queue := FixtureBandPollQueue.new()
	failed_admission_queue.request_status = "failed"
	failed_admission_queue.request_reason = "tree_source_record_compile_failed"
	failed_admission_queue.request_job_key = "fixture-failed-admitted-job"
	first_poll_main.tree_publication_queue = failed_admission_queue
	var failed_admission_result: Dictionary = \
		first_poll_scheduler._admit_compile_register_tree_band(first_poll_main,
			first_poll_scheduler._world_id, "fixture-first-poll-capture",
			first_poll_scheduler.band_source_chunk, first_poll_scheduler.band_section,
			first_poll_scheduler.first_poll_snapshot,
			first_poll_scheduler.first_poll_bundle,
			first_poll_scheduler.first_poll_publication_view,
			first_poll_scheduler.first_poll_lease_token)
	var failed_admission_detached: bool = \
		String(failed_admission_result.get("status", "")) == "failed" \
		and String(failed_admission_result.get("reason", "")) \
			== "tree_source_record_compile_failed" \
		and failed_admission_queue.cancel_calls.size() == 1 \
		and failed_admission_queue.cancel_calls[0].get("jobKey", "") \
			== "fixture-failed-admitted-job" \
		and failed_admission_queue.cancel_calls[0].get("consumerToken", "") \
			== failed_admission_queue.last_requested_consumer
	var failed_admission_capture: Dictionary = first_poll_scheduler._source_capture_jobs.get(
		"fixture-first-poll-capture", {})
	var failed_admission_demands_value: Variant = failed_admission_capture.get(
		"treeCompileDemands", {})
	var failed_admission_demands: Dictionary = failed_admission_demands_value \
		if failed_admission_demands_value is Dictionary else {}
	failed_admission_detached = failed_admission_detached \
		and failed_admission_demands.is_empty()
	first_poll_scheduler._source_capture_jobs.clear()
	var pending_terminal_admission_queue := FixtureBandPollQueue.new()
	pending_terminal_admission_queue.request_status = "pending"
	pending_terminal_admission_queue.request_reason = "fixture_terminal_admission_failure"
	pending_terminal_admission_queue.request_job_key = "fixture-terminal-admitted-job"
	pending_terminal_admission_queue.request_terminal_failure = true
	pending_terminal_admission_queue.request_retryable = false
	first_poll_main.tree_publication_queue = pending_terminal_admission_queue
	var pending_terminal_admission_result: Dictionary = \
		first_poll_scheduler._admit_compile_register_tree_band(first_poll_main,
			first_poll_scheduler._world_id, "fixture-first-poll-capture",
			first_poll_scheduler.band_source_chunk, first_poll_scheduler.band_section,
			first_poll_scheduler.first_poll_snapshot,
			first_poll_scheduler.first_poll_bundle,
			first_poll_scheduler.first_poll_publication_view,
			first_poll_scheduler.first_poll_lease_token)
	var pending_terminal_admission_cancelled: bool = \
		String(pending_terminal_admission_result.get("status", "")) == "pending" \
		and String(pending_terminal_admission_result.get("reason", "")) \
			== "fixture_terminal_admission_failure" \
		and bool(pending_terminal_admission_result.get("terminalFailure", false)) \
		and not bool(pending_terminal_admission_result.get("retryable", true)) \
		and pending_terminal_admission_queue.poll_calls == 0 \
		and pending_terminal_admission_queue.cancel_calls.size() == 1 \
		and pending_terminal_admission_queue.cancel_calls[0].get("jobKey", "") \
			== "fixture-terminal-admitted-job" \
		and pending_terminal_admission_queue.cancel_calls[0].get("consumerToken", "") \
			== pending_terminal_admission_queue.last_requested_consumer
	var pending_terminal_family_adapter := Adapter.new()
	var pending_terminal_family := {"status":"pending",
		"reason":"fixture_pending_terminal_family_projection",
		"terminalFailure":true, "retryable":false}
	var pending_terminal_family_result: Dictionary = \
		pending_terminal_family_adapter._prepare_retained_source_family(
			PreparationCurrentAuthority.new(), {}, {"sourceChunkKey":Vector2i.ZERO},
			{}, {"familyResultsById":{"trees":pending_terminal_family}},
			"fixture-lease", "trees", {"sourceId":"fixture-tree-source"})
	var pending_terminal_family_outcome: Dictionary = \
		pending_terminal_family_adapter._classify_retained_preparation_outcome(
			pending_terminal_family_result)
	var pending_terminal_family_is_terminal: bool = \
		String(pending_terminal_family_result.get("status", "")) == "pending" \
		and not bool(pending_terminal_family_result.get("retryable", true)) \
		and String(pending_terminal_family_outcome.get("status", "")) == "failed" \
		and String(pending_terminal_family_outcome.get("reason", "")) \
			== "fixture_pending_terminal_family_projection"
	var malformed_ready_family_adapter := Adapter.new()
	var malformed_ready_family: Dictionary = \
		malformed_ready_family_adapter._prepare_retained_source_family(
			PreparationCurrentAuthority.new(), {}, {"sourceChunkKey":Vector2i.ZERO},
			{}, {"familyResultsById":{"trees":{"status":"ready",
				"disposition":"incomplete"}}}, "fixture-lease", "trees",
			{"sourceId":"fixture-tree-source"})
	var malformed_ready_family_is_terminal: bool = \
		String(malformed_ready_family.get("status", "")) == "failed" \
		and String(malformed_ready_family.get("reason", "")) \
			== "ecology_section_preparation_family_receipt_invalid"
	var empty_family_with_rows: Dictionary = \
		malformed_ready_family_adapter._validate_retained_family_receipt({
			"status":"ready", "disposition":"complete_empty",
			"sourceRows":[{"sourceId":"must-not-exist"}]}, "trees", Vector2i.ZERO)
	var empty_family_rows_rejected: bool = \
		String(empty_family_with_rows.get("status", "")) == "failed" \
		and String(empty_family_with_rows.get("reason", "")) \
			== "ecology_section_preparation_family_receipt_rows_disagree"
	var stale_family_adapter := Adapter.new()
	var stale_family_row := {"status":"failed",
		"reason":"ecology_band_slice_view_not_admitted"}
	var stale_family_result: Dictionary = stale_family_adapter._prepare_retained_source_family(
		PreparationCurrentAuthority.new(), {}, {"sourceChunkKey":Vector2i.ZERO}, {},
		{"familyResultsById":{"trees":stale_family_row}}, "fixture-lease", "trees",
		{"sourceId":"fixture-tree-source"})
	var stale_helper_route_preserved: bool = \
		String(stale_family_result.get("reason", "")) \
			== "ecology_band_slice_view_not_admitted" \
		and String(stale_family_adapter._classify_retained_preparation_outcome(
			stale_family_result).get("status", "")) == "stale"
	var incarnation_provider := Adapter.new()
	incarnation_provider.configure("seed:ecology-capture-incarnation-discard:1")
	var incarnation_main := PreparationCurrentAuthority.new()
	incarnation_main.seed_text = "ecology-capture-incarnation-discard"
	var incarnation_section_a := Vector3i(30, 1, 0)
	var incarnation_section_b := Vector3i(31, 1, 0)
	var incarnation_capture_id := "same-deterministic-capture-identity"
	var old_snapshot: Dictionary = {"sourceRevision":"incarnation-rev-old",
		"sourceChunkKey":Vector2i(4, 6)}
	old_snapshot.make_read_only()
	var old_view: Dictionary = {"schema":"ecology-source-publication-view/v1",
		"payload":old_snapshot, "sourceDomainRevision":"incarnation-rev-old",
		"contentDigest":"a".repeat(64), "publicationId":"publication-old",
		"familyResultsById":{}}
	old_view.make_read_only()
	var sibling_prep_key := incarnation_provider._source_section_preparation_key(
		incarnation_provider._world_id, incarnation_section_b)
	var sibling_prep: Dictionary = {"preparationKey":sibling_prep_key,
		"sectionKey":incarnation_section_b, "worldId":incarnation_provider._world_id,
		"worldSeed":incarnation_main.seed_text, "status":"complete",
		"stage":"complete", "census":{"status":"complete",
			"sourceRevision":"incarnation-rev-old"},
		"sourcePlans":[{"captureIdentity":incarnation_capture_id,
			"sourceChunkKey":Vector2i(4, 6), "sourcePublicationId":"publication-old",
			"sourcePublicationLeaseToken":"lease-old", "requestedFamilies":[]}]}
	var first_prep_key := incarnation_provider._source_section_preparation_key(
		incarnation_provider._world_id, incarnation_section_a)
	var first_prep: Dictionary = {"preparationKey":first_prep_key,
		"sectionKey":incarnation_section_a, "worldId":incarnation_provider._world_id,
		"worldSeed":incarnation_main.seed_text, "status":"pending",
		"sourcePlans":[{"captureIdentity":incarnation_capture_id,
			"sourceChunkKey":Vector2i(4, 6), "requestedFamilies":[]}]}
	incarnation_provider._source_section_preparations[first_prep_key] = first_prep
	incarnation_provider._source_section_preparations[sibling_prep_key] = sibling_prep
	incarnation_provider._source_section_preparation_order = [first_prep_key,
		sibling_prep_key]
	incarnation_provider._source_capture_cohorts[incarnation_section_a] = {
		"status":"active", "closureSealed":true,
		"preparationKey":first_prep_key, "sectionPreparation":first_prep}
	incarnation_provider._source_capture_cohorts[incarnation_section_b] = {
		"status":"complete", "closureSealed":true,
		"preparationKey":sibling_prep_key, "sectionPreparation":sibling_prep,
		"completedSequence":7}
	incarnation_provider._source_capture_jobs[incarnation_capture_id] = {
		"identity":incarnation_capture_id, "status":"ready",
		"sourceChunkKey":Vector2i(4, 6), "snapshot":old_snapshot,
		"sourcePublicationView":old_view, "sourcePublicationId":"publication-old",
		"sourcePublicationLeaseToken":"lease-old",
		"sections":{incarnation_section_a:true, incarnation_section_b:true},
		"treeCompileDemands":{}, "catalogLeaseReleased":true}
	incarnation_provider._source_capture_jobs_by_section[incarnation_section_a] = {
		incarnation_capture_id:true}
	incarnation_provider._source_capture_jobs_by_section[incarnation_section_b] = {
		incarnation_capture_id:true}
	incarnation_provider._discard_source_capture_job(incarnation_capture_id)
	var both_incarnation_preparations_invalidated: bool = \
		not incarnation_provider._source_section_preparations.has(first_prep_key) \
		and not incarnation_provider._source_section_preparations.has(sibling_prep_key) \
		and incarnation_provider._source_section_preparation_order.is_empty() \
		and not incarnation_provider._source_capture_cohorts[incarnation_section_a].has(
			"sectionPreparation") \
		and not incarnation_provider._source_capture_cohorts[incarnation_section_b].has(
			"sectionPreparation") \
		and not bool(incarnation_provider._source_capture_cohorts[
			incarnation_section_b].get("closureSealed", true))
	var new_snapshot: Dictionary = {"sourceRevision":"incarnation-rev-new",
		"sourceChunkKey":Vector2i(4, 6)}
	new_snapshot.make_read_only()
	var new_view: Dictionary = {"schema":"ecology-source-publication-view/v1",
		"payload":new_snapshot, "sourceDomainRevision":"incarnation-rev-new",
		"contentDigest":"b".repeat(64), "publicationId":"publication-new",
		"familyResultsById":{}}
	new_view.make_read_only()
	incarnation_provider._source_capture_jobs[incarnation_capture_id] = {
		"identity":incarnation_capture_id, "status":"ready",
		"sourceChunkKey":Vector2i(4, 6), "snapshot":new_snapshot,
		"sourcePublicationView":new_view, "sourcePublicationId":"publication-new",
		"sourcePublicationLeaseToken":"lease-new", "sections":{},
		"treeCompileDemands":{}, "catalogLeaseReleased":true}
	var old_sibling_after_readmit: Dictionary = \
		incarnation_provider._source_section_preparation_is_current(
			incarnation_main, sibling_prep)
	var sibling_rejects_new_incarnation: bool = \
		String(old_sibling_after_readmit.get("status", "")) == "stale" \
		and String(old_sibling_after_readmit.get("reason", "")) \
			== "ecology_section_preparation_capture_incarnation_changed"
	var cache_scan_main: PreparationCurrentAuthority = PreparationCurrentAuthority.new()
	var cache_scan_provider: CachedRowScanAdapter = CachedRowScanAdapter.new()
	cache_scan_provider.configure("seed:section-preparation-cache-scan:1")
	var cache_scan_section: Vector3i = Vector3i(22, 0, 0)
	var cache_scan_key: String = cache_scan_provider._source_section_preparation_key(
		cache_scan_provider._world_id, cache_scan_section)
	var cache_scan_rows: Array[Dictionary] = []
	for index: int in range(20):
		cache_scan_rows.append({"sourceId":"cached-source-%02d" % index,
			"producerFamily":"surface_rocks"})
	var cache_scan_snapshot: Dictionary = {"worldId":cache_scan_provider._world_id,
		"sourceChunkKey":Vector2i.ZERO,
		"sourceRevision":"cache-scan-source-r1",
		"sourceDomainRevision":"cache-scan-source-r1"}
	cache_scan_snapshot.make_read_only()
	var cache_scan_families: Dictionary = {"surface_rocks":{"status":"ready",
		"disposition":"complete_nonempty", "sourceRows":cache_scan_rows}}
	var cache_scan_view: Dictionary = {"schema":"ecology-source-publication-view/v1",
		"payload":cache_scan_snapshot,
		"sourceDomainRevision":"cache-scan-source-r1",
		"contentDigest":"e".repeat(64), "publicationId":"cache-scan-publication-r1",
		"familyResultsById":cache_scan_families}
	cache_scan_view.make_read_only()
	var cache_scan_preparation: Dictionary = {"preparationKey":cache_scan_key,
		"sectionKey":cache_scan_section, "status":"pending",
		"worldId":cache_scan_provider._world_id,
		"worldSeed":cache_scan_main.seed_text,
		"sourcePlans":[{"captureIdentity":"cache-scan-capture-r1",
			"sourceChunkKey":Vector2i.ZERO, "requestedFamilies":["surface_rocks"]}],
		"sourceChunkCursor":0, "familyCursor":0, "activeFamily":{}, "unitCount":0}
	cache_scan_provider._source_section_preparations[cache_scan_key] = cache_scan_preparation
	cache_scan_provider._source_section_preparation_order = [cache_scan_key]
	cache_scan_provider._source_capture_cohorts[cache_scan_section] = {
		"status":"active", "preparationKey":cache_scan_key,
		"sectionPreparation":cache_scan_preparation}
	cache_scan_provider._source_capture_jobs["cache-scan-capture-r1"] = {
		"identity":"cache-scan-capture-r1",
		"worldId":cache_scan_provider._world_id,
		"worldSeed":cache_scan_main.seed_text,
		"sourceChunkKey":Vector2i.ZERO,
		"requestedFamilies":["surface_rocks"],
		"status":"ready", "snapshot":cache_scan_snapshot,
		"sourcePublicationView":cache_scan_view,
		"sourcePublicationId":"cache-scan-publication-r1",
		"sourcePublicationLeaseToken":"cache-scan-lease-r1"}
	var cache_scan_result: Dictionary = cache_scan_provider._advance_next_source_section_preparation(
		cache_scan_main)
	var cache_scan_active: Dictionary = cache_scan_preparation.get("activeFamily", {})
	var bounded_cache_scan_without_conversion_units: bool = \
		cache_scan_result.get("status", "") == "advanced" \
		and cache_scan_result.get("stage", "") == "cached_source_rows_scanned" \
		and int(cache_scan_result.get("cacheHitRows", 0)) == 16 \
		and cache_scan_provider.cached_rows_visited == 16 \
		and int(cache_scan_active.get("sourceCursor", 0)) == 16 \
		and int(cache_scan_preparation.get("unitCount", -1)) == 0 \
		and cache_scan_provider._source_section_preparation_units == 0
	# Keep adding newer, closer work. The original far demand retains its age and
	# must receive a slot once its bounded service-age promotion is reached.
	for index in range(Adapter.SOURCE_CAPTURE_FAIR_AGE_OPPORTUNITIES + 2):
		var new_near := Vector3i(0, 0, index + 10)
		provider._upsert_source_capture_cohort(new_near, float(index + 1))
	for _opportunity in range(Adapter.SOURCE_CAPTURE_FAIR_AGE_OPPORTUNITIES + 2):
		provider._source_capture_service_opportunities += 1
		for section_value: Variant in provider._source_capture_cohorts:
			var cohort: Dictionary = provider._source_capture_cohorts[section_value]
			if String(cohort.get("status", "")) == "deferred":
				cohort["waitOpportunities"] = int(cohort.get("waitOpportunities", 0)) + 1
	provider._set_source_capture_cohort_status(section_near,
		provider._source_capture_cohorts[section_near], "complete")
	provider._promote_source_capture_cohorts()
	var far_eventually_active := String(provider._source_capture_cohorts[section_far].get(
		"status", "")) == "active"
	var bounded_active_count := provider._active_source_capture_cohort_count() \
		<= Adapter.MAX_ACTIVE_SOURCE_CAPTURE_COHORTS

	var shared_main := StaleCaptureAuthority.new()
	shared_main.seed_text = "ecology-section-cohort-shared-cancel"
	shared_main.seed_hash = 2
	root.add_child(shared_main)
	var shared_provider = Adapter.new()
	shared_provider.configure("seed:%s:%d" % [shared_main.seed_text, shared_main.seed_hash])
	shared_provider.bind_main_authority(shared_main)
	var blocked_a := Vector3i.ZERO
	var blocked_b := Vector3i(1, 0, 0)
	var deferred_c := Vector3i(2, 0, 0)
	shared_provider._upsert_source_capture_cohort(blocked_a, 1.0)
	shared_provider._upsert_source_capture_cohort(blocked_b, 2.0)
	shared_provider._upsert_source_capture_cohort(deferred_c, 3.0)
	shared_provider._promote_source_capture_cohorts()
	var shared_job := {"identity":"shared", "worldId":shared_provider._world_id,
		"sourceChunkKey":Vector2i.ZERO, "status":"pending",
		"captureCacheIdentity":"shared-capture-continuation",
		"catalogLeaseToken":"retained-lease",
		"sections":{blocked_a:true, blocked_b:true}}
	shared_provider._source_capture_jobs["shared"] = shared_job
	shared_provider._source_capture_jobs_by_section[blocked_a] = {"shared":true}
	shared_provider._source_capture_jobs_by_section[blocked_b] = {"shared":true}
	shared_provider._source_capture_latest_by_chunk["%s|0,0" % shared_provider._world_id] = "shared"
	shared_provider._yield_source_capture_cohort(blocked_a, "fixture_dependency_blocked")
	var shared_retained_for_active_sibling: bool = shared_main.cancelled_capture_keys.is_empty() \
		and shared_provider._source_capture_jobs.has("shared")
	shared_provider._yield_source_capture_cohort(blocked_b, "fixture_dependency_blocked")
	var shared_cancelled_after_all_active_subscribers_yield: bool = \
		shared_main.cancelled_capture_keys.size() == 1 \
		and shared_main.cancelled_capture_keys[0] == "shared-capture-continuation"
	var family_shared_main := StaleCaptureAuthority.new()
	family_shared_main.seed_text = "ecology-family-cohort-shared-cancel"
	family_shared_main.seed_hash = 3
	root.add_child(family_shared_main)
	var family_shared_provider = Adapter.new()
	family_shared_provider.configure("seed:%s:%d" % [family_shared_main.seed_text,
		family_shared_main.seed_hash])
	family_shared_provider.bind_main_authority(family_shared_main)
	var narrow_section := Vector3i(4, 0, 0)
	var wide_section := Vector3i(5, 0, 0)
	family_shared_provider._upsert_source_capture_cohort(narrow_section, 1.0)
	family_shared_provider._upsert_source_capture_cohort(wide_section, 2.0)
	family_shared_provider._promote_source_capture_cohorts()
	family_shared_provider._source_capture_jobs["narrow-family"] = {
		"identity":"narrow-family", "status":"pending",
		"captureCacheIdentity":"shared-family-session", "catalogLeaseToken":"narrow-lease",
		"sections":{narrow_section:true}}
	family_shared_provider._source_capture_jobs["wide-family"] = {
		"identity":"wide-family", "status":"pending",
		"captureCacheIdentity":"shared-family-session", "catalogLeaseToken":"wide-lease",
		"sections":{wide_section:true}}
	family_shared_provider._source_capture_jobs_by_section[narrow_section] = {"narrow-family":true}
	family_shared_provider._source_capture_jobs_by_section[wide_section] = {"wide-family":true}
	family_shared_provider._yield_source_capture_cohort(narrow_section,
		"fixture_narrow_family_blocked")
	var wide_family_cursor_retained: bool = family_shared_main.cancelled_capture_keys.size() == 1 \
		and family_shared_main.cancelled_capture_lease_tokens == ["narrow-lease"] \
		and String(family_shared_provider._source_capture_cohorts[wide_section].get(
			"status", "")) == "active" \
		and String(family_shared_provider._source_capture_jobs["wide-family"].get(
			"status", "")) == "pending"
	family_shared_provider._yield_source_capture_cohort(wide_section,
		"fixture_wide_family_blocked")
	var both_family_cursors_released: bool = family_shared_main.cancelled_capture_keys.size() == 2 \
		and family_shared_main.cancelled_capture_lease_tokens == ["narrow-lease", "wide-lease"]
	var lease_retained: bool = String(shared_provider._source_capture_jobs.get("shared", {}) \
		.get("catalogLeaseToken", "")) == "retained-lease"
	for _opportunity in range(Adapter.SOURCE_CAPTURE_BLOCKED_RETRY_OPPORTUNITIES):
		shared_provider._source_capture_service_opportunities += 1
		shared_provider._promote_source_capture_cohorts()
	var blocked_retry_admitted: bool = String(shared_provider._source_capture_cohorts[blocked_a].get(
		"status", "")) == "active" or String(shared_provider._source_capture_cohorts[blocked_b].get(
		"status", "")) == "active"
	var release_a: Dictionary = shared_provider.release_section_capture_demand(blocked_a)
	var shared_job_retained_for_b: bool = shared_provider._source_capture_jobs.has("shared") \
		and shared_provider._source_capture_jobs_by_section.has(blocked_b)
	var reset: Dictionary = shared_provider.reset_source_domain_captures()
	var reset_cohorts_empty: bool = shared_provider._source_capture_cohorts.is_empty() \
		and shared_provider._source_capture_active_cohort_count == 0
	var failed_section := Vector3i(7, 0, 0)
	shared_provider._upsert_source_capture_cohort(failed_section, 7.0)
	shared_provider._promote_source_capture_cohorts()
	var failed_cohort: Dictionary = shared_provider._source_capture_cohorts[failed_section]
	shared_provider._set_source_capture_cohort_status(failed_section, failed_cohort, "failed")
	failed_cohort = shared_provider._source_capture_cohorts[failed_section]
	failed_cohort["blockedReason"] = "fixture_terminal_failure"
	shared_provider._source_capture_cohorts[failed_section] = failed_cohort
	shared_provider._source_capture_jobs["failure-sentinel"] = {
		"identity":"failure-sentinel", "status":"failed",
		"failure":{"status":"failed", "reason":"fixture_terminal_failure"}}
	var saturated_a := Vector3i(8, 0, 0)
	var saturated_b := Vector3i(9, 0, 0)
	shared_provider._upsert_source_capture_cohort(saturated_a, 1.0)
	shared_provider._upsert_source_capture_cohort(saturated_b, 2.0)
	shared_provider._promote_source_capture_cohorts()
	shared_provider._upsert_source_capture_cohort(failed_section, 7.0)
	shared_provider._promote_source_capture_cohorts()
	var cached_failure := shared_provider._cached_source_capture_failure([failed_section])
	var cached_failure_survives_saturation: bool = cached_failure.get("status", "") == "pending" \
		and cached_failure.get("reason", "") == "fixture_terminal_failure" \
		and bool(cached_failure.get("retryable", false)) \
		and cached_failure.get("producerStatus", "") == "failed" \
		and bool(cached_failure.get("cachedSourceCaptureFailure", false)) \
		and String(shared_provider._source_capture_cohorts[failed_section].get(
			"status", "")) == "deferred" \
		and shared_provider._active_source_capture_cohort_count() \
			== Adapter.MAX_ACTIVE_SOURCE_CAPTURE_COHORTS \
		and shared_provider._source_capture_jobs.has("failure-sentinel")
	shared_provider._set_source_capture_cohort_status(saturated_a,
		shared_provider._source_capture_cohorts[saturated_a], "complete")
	shared_provider._promote_source_capture_cohorts()
	var failed_revision_recheck_admitted: bool = String(shared_provider._source_capture_cohorts[
		failed_section].get("status", "")) == "active" \
		and String(shared_provider._source_capture_cohorts[failed_section].get(
			"cachedFailureReason", "")) == ""
	shared_main.free()
	family_shared_main.free()
	fair_main.free()
	return {"initialActiveCount":initial_active_count,
		"farInitialStatus":far_initial_status,
		"emptyClosureSealed":empty_closure_sealed,
		"emptyClosureDisposition":empty_closure_disposition,
		"emptyClosureStatus":empty_closure_status,
		"emptyClosureActiveCountAfterSeal":empty_closure_active_after_seal,
		"missingClosureRemainsActive":missing_closure_remains_active,
		"pendingPreparationDoesNotBlockEmptySibling":pending_first_did_not_block_empty_completion,
		"terminalPreparationFailurePropagates":terminal_failure_propagates,
		"terminalAdvanceStatus":terminal_advance_status,
		"terminalAdvanceReason":terminal_advance_reason,
		"terminalRegistrationIsNotPending":terminal_registration_is_not_pending,
		"dependencyStatusProtocolsClassified":dependency_status_protocols_classified,
		"firstPollTerminalPropagates":first_poll_terminal_propagates,
		"admittedPendingBandConsumerRetainedAndCancelled": \
			admitted_pending_consumer_retained_and_cancelled,
		"queueFullProspectiveBandJobNotRetained":queue_full_not_retained,
		"failedAdmissionBandConsumerDetached":failed_admission_detached,
		"pendingTerminalAdmissionIsClassifiedBeforePoll": \
			pending_terminal_admission_cancelled,
		"pendingTerminalFamilyIsTerminal":pending_terminal_family_is_terminal,
		"malformedReadyFamilyIsTerminal":malformed_ready_family_is_terminal,
		"emptyFamilyRowsRejected":empty_family_rows_rejected,
		"staleHelperRoutePreserved":stale_helper_route_preserved,
		"bothIncarnationPreparationsInvalidated":both_incarnation_preparations_invalidated,
		"siblingRejectsNewCaptureIncarnation":sibling_rejects_new_incarnation,
		"boundedCacheScanWithoutConversionUnits":bounded_cache_scan_without_conversion_units,
		"preparationTelemetryBounded":preparation_telemetry_bounded,
		"preparationTelemetryRowBytes":preparation_telemetry_row_bytes,
		"preparationTelemetryFieldNames":telemetry_row.keys(),
		"preparationTelemetryHasNoPayload":preparation_telemetry_has_no_payload,
		"farEventuallyActive":far_eventually_active,
		"boundedActiveCount":bounded_active_count,
		"sharedRetainedForActiveSibling":shared_retained_for_active_sibling,
		"sharedCancelledAfterAllActiveSubscribersYield":shared_cancelled_after_all_active_subscribers_yield,
		"wideFamilyCursorRetained":wide_family_cursor_retained,
		"bothFamilyCursorsReleased":both_family_cursors_released,
		"leaseRetained":lease_retained,
		"blockedRetryAdmitted":blocked_retry_admitted,
		"sharedJobRetainedForB":shared_job_retained_for_b,
		"releaseStatus":String(release_a.get("status", "")),
		"resetStatus":String(reset.get("status", "")),
		"resetCohortsEmpty":reset_cohorts_empty,
		"cachedFailureSurvivesSaturation":cached_failure_survives_saturation,
		"failedRevisionRecheckAdmitted":failed_revision_recheck_admitted}


func _tree_compile_priming_lifecycle_contract() -> Dictionary:
	var main := ProductionAuthority.new()
	main.name = "TreePrimingLifecycleAuthority"
	root.add_child(main)
	var queue := main.tree_publication_queue as FixtureTreeQueue
	var provider := Adapter.new()
	provider.configure("seed:ecology-tree-prime-lifecycle:1")
	provider._main_authority_ref = weakref(main)
	var source_chunk := Vector2i.ZERO
	var sibling_chunk := Vector2i(1, 0)
	var section_a := Vector3i.ZERO
	var section_b := Vector3i(1, 0, 0)
	var pending_section := Vector3i(8, 0, 0)
	var tree_rows: Array[Dictionary] = [{"producerFamily":"trees",
		"sourceId":"fixture-tree-source", "sourcePartId":"trunk"}]
	var snapshot: Dictionary = {"schema":"ecology-source-domain-family-bundle/v2",
		"status":"ready", "worldId":provider._world_id,
		"sourceChunkKey":source_chunk, "sourceRevision":"fixture-source-r1",
		"sourceRows":tree_rows}
	snapshot.make_read_only()
	var tree_result := {"status":"ready", "disposition":"complete_nonempty",
		"familyRevision":"fixture-tree-family-r1",
		"sourceManifestDigest":"a".repeat(64), "sourceRows":tree_rows}
	var publication_view: Dictionary = {"schema":"ecology-source-publication-view/v1",
		"publicationId":"fixture-publication-tree-prime",
		"sourceDomainRevision":"fixture-source-r1",
		"contentDigest":"b".repeat(64), "payload":snapshot,
		"familyResultsById":{"trees":tree_result}}
	publication_view.make_read_only()
	var pending_sibling_capture := {"status":"pending",
		"reason":"ecology_requested_family_capture_pending"}
	var narrow_identity := "fixture-narrow-capture"
	var wide_identity := "fixture-wide-capture"
	provider._source_capture_jobs[narrow_identity] = {"identity":narrow_identity,
		"status":"ready", "snapshot":snapshot,
		"sourcePublicationView":publication_view,
		"sections":{section_a:true, section_b:true}, "treeCompileDemands":{}}
	provider._source_capture_jobs[wide_identity] = {"identity":wide_identity,
		"status":"ready", "snapshot":snapshot,
		"sourcePublicationView":publication_view,
		"sections":{section_a:true}, "treeCompileDemands":{}}
	provider._source_capture_jobs_by_section[section_a] = {
		narrow_identity:true, wide_identity:true}
	provider._source_capture_jobs_by_section[section_b] = {narrow_identity:true}
	var ready_capture := {"status":"ready", "identity":narrow_identity,
		"snapshot":snapshot, "sourcePublicationView":publication_view,
		"sourcePublicationId":String(publication_view.get("publicationId", "")),
		"sourcePublicationLeaseToken":"synthetic-tree-publication-lease"}
	var ready_capture_by_chunk := {source_chunk:ready_capture,
		sibling_chunk:pending_sibling_capture}
	var tree_sections_by_chunk := {source_chunk:[section_a, section_b],
		sibling_chunk:[pending_section]}
	var primed := provider._prime_ready_tree_source_compiles(main, queue,
		ready_capture_by_chunk, tree_sections_by_chunk)
	var narrow_demands: Dictionary = provider._source_capture_jobs[
		narrow_identity].get("treeCompileDemands", {})
	var primed_while_sibling_pending: bool = pending_sibling_capture.get(
		"status", "") == "pending" and primed.get("status", "") == "ready" \
		and int(primed.get("primedCount", 0)) == 2 \
		and queue.request_count == 2
	var failed_sibling_capture := {"status":"failed",
		"reason":"ecology_sibling_capture_failed"}
	var primed_before_failed_sibling_report: Dictionary = provider._prime_ready_tree_source_compiles(
		main, queue, {source_chunk:ready_capture, sibling_chunk:failed_sibling_capture},
		{source_chunk:[section_a, section_b], sibling_chunk:[pending_section]})
	var priming_ignores_unready_sibling_records: bool = \
		failed_sibling_capture.get("status", "") == "failed" \
		and primed_before_failed_sibling_report.get("status", "") == "ready" \
		and int(primed_before_failed_sibling_report.get("primedCount", 0)) == 0 \
		and provider._source_capture_jobs[narrow_identity].get(
			"treeCompileDemands", {}).size() == 2
	var all_section_demands_attached: bool = narrow_demands.has(section_a) \
		and narrow_demands.has(section_b) \
		and queue.consumers_by_job.get("synthetic-pending-tree-job", {}).size() == 2
	queue.pending_reason = "ecology_source_compile_job_missing"
	var readmission := provider._prime_ready_tree_source_compiles(main, queue,
		ready_capture_by_chunk, tree_sections_by_chunk)
	var retired_queue_job_readmitted: bool = readmission.get("status", "") == "ready" \
		and int(readmission.get("primedCount", 0)) == 2 \
		and queue.request_count == 4 \
		and queue.consumers_by_job.get("synthetic-pending-tree-job", {}).size() == 2
	queue.pending_reason = "ecology_tree_queue_geometry_not_committed"
	var wide_capture := {"status":"ready", "identity":wide_identity,
		"snapshot":snapshot, "sourcePublicationView":publication_view,
		"sourcePublicationId":String(publication_view.get("publicationId", "")),
		"sourcePublicationLeaseToken":"synthetic-tree-publication-lease"}
	var wide_prime := provider._prime_ready_tree_source_compiles(main, queue,
		{sibling_chunk:wide_capture}, {sibling_chunk:[section_a]})
	var narrow_wide_share_compile_job: bool = wide_prime.get(
		"status", "") == "ready" \
		and queue.consumers_by_job.get("synthetic-pending-tree-job", {}).size() == 3
	var stale_demand := provider._tree_compile_demand_for_capture(narrow_identity,
		[section_a])
	queue.poll_status = "failed"
	queue.pending_reason = "ecology_tree_family_identity_changed"
	var stale_completion := provider._poll_tree_compile_demand(queue, stale_demand)
	var stale_completion_rejected: bool = stale_completion.get("status", "") == "failed" \
		and stale_completion.get("reason", "") == "ecology_tree_family_identity_changed" \
		and not stale_completion.has("artifact")
	var release_a: Dictionary = provider.release_section_capture_demand(section_a)
	var sibling_b_consumer: Dictionary = narrow_demands.get(section_b, {})
	var shared_after_a: Dictionary = queue.consumers_by_job.get(
		"synthetic-pending-tree-job", {})
	var shared_job_retained_for_sibling: bool = release_a.get("status", "") == "released" \
		and shared_after_a.has(String(sibling_b_consumer.get("consumerToken", ""))) \
		and shared_after_a.size() == 1
	var release_b: Dictionary = provider.release_section_capture_demand(section_b)
	var last_sibling_release_cancelled: bool = release_b.get("status", "") == "released" \
		and queue.consumers_by_job.get("synthetic-pending-tree-job", {}).is_empty() \
		and queue.cancellations.size() == 5
	var supersede_identity := "fixture-superseded-tree-capture"
	provider._source_capture_jobs[supersede_identity] = {"identity":supersede_identity,
		"status":"ready", "treeCompileDemands":{section_a:{
			"jobKey":"synthetic-pending-tree-job", "consumerToken":"superseded-token"}}}
	provider._discard_source_capture_job(supersede_identity)
	var supersession_cancelled: bool = queue.cancellations.size() == 6 \
		and not queue.consumers_by_job.get("synthetic-pending-tree-job", {}).has(
			"superseded-token")
	var reset_identity := "fixture-reset-tree-capture"
	provider._source_capture_jobs[reset_identity] = {"identity":reset_identity,
		"status":"ready", "treeCompileDemands":{section_a:{
			"jobKey":"synthetic-pending-tree-job", "consumerToken":"reset-token"}}}
	provider.reset_source_domain_captures()
	var reset_cancelled: bool = queue.cancellations.size() == 7 \
		and not queue.consumers_by_job.get("synthetic-pending-tree-job", {}).has(
			"reset-token")
	var old_queue := queue
	var replacement_queue := FixtureTreeQueue.new()
	replacement_queue.name = "ReplacementSyntheticTreePublicationQueue"
	main.add_child(replacement_queue)
	var replacement_provider := Adapter.new()
	replacement_provider.configure("seed:ecology-tree-queue-replacement:1")
	replacement_provider._main_authority_ref = weakref(main)
	var replacement_identity := "fixture-queue-replacement-capture"
	replacement_provider._source_capture_jobs[replacement_identity] = {
		"identity":replacement_identity, "status":"ready", "snapshot":snapshot,
		"sourcePublicationView":publication_view, "sections":{section_a:true},
		"treeCompileDemands":{}}
	replacement_provider._source_capture_jobs_by_section[section_a] = {
		replacement_identity:true}
	var replacement_capture := {"status":"ready", "identity":replacement_identity,
		"snapshot":snapshot, "sourcePublicationView":publication_view,
		"sourcePublicationId":String(publication_view.get("publicationId", "")),
		"sourcePublicationLeaseToken":"synthetic-tree-publication-lease"}
	main.tree_publication_queue = replacement_queue
	var old_queue_primed := replacement_provider._prime_ready_tree_source_compiles(
		main, old_queue, {source_chunk:replacement_capture}, {source_chunk:[section_a]})
	var replacement_demand: Dictionary = replacement_provider._source_capture_jobs[
		replacement_identity].get("treeCompileDemands", {}).get(section_a, {})
	var new_queue_primed := replacement_provider._prime_ready_tree_source_compiles(
		main, replacement_queue, {source_chunk:replacement_capture}, {source_chunk:[section_a]})
	var replaced_queue_recovered: bool = old_queue_primed.get("status", "") == "ready" \
		and new_queue_primed.get("status", "") == "ready" \
		and old_queue.consumers_by_job.get("synthetic-pending-tree-job", {}).is_empty() \
		and old_queue.cancellations.size() == 8 \
		and replacement_queue.consumers_by_job.get("synthetic-pending-tree-job", {}).has(
			String(replacement_demand.get("consumerToken", "")))
	replacement_provider.release_section_capture_demand(section_a)
	var replacement_queue_retired: bool = replacement_queue.cancellations.size() == 1 \
		and replacement_queue.consumers_by_job.get("synthetic-pending-tree-job", {}).is_empty()
	main.queue_free()
	replacement_provider = null
	return {"primedWhileSiblingPending":primed_while_sibling_pending,
		"primingIgnoresUnreadySiblingRecords":priming_ignores_unready_sibling_records,
		"allSectionDemandsAttached":all_section_demands_attached,
		"retiredQueueJobReadmitted":retired_queue_job_readmitted,
		"narrowWideShareCompileJob":narrow_wide_share_compile_job,
		"sharedJobRetainedForSibling":shared_job_retained_for_sibling,
		"lastSiblingReleaseCancelled":last_sibling_release_cancelled,
		"supersessionCancelled":supersession_cancelled,
		"resetCancelled":reset_cancelled,
		"replacedQueueRecovered":replaced_queue_recovered,
		"replacementQueueRetired":replacement_queue_retired,
		"staleCompletionRejected":stale_completion_rejected}


func _tree_compiler_manifest_binding_contract() -> Dictionary:
	var provider := Adapter.new()
	var source_chunk := Vector2i(7, -5)
	var local_transform := Transform3D(Basis(Vector3.UP, 0.37), Vector3(8.25, 14.0, -3.5))
	var chunk_origin := Vector3(float(source_chunk.x) * Grid.STREAM_CHUNK_SIZE_METERS,
		0.0, float(source_chunk.y) * Grid.STREAM_CHUNK_SIZE_METERS)
	var world_transform: Transform3D = Transform3D(Basis.IDENTITY, chunk_origin) * local_transform
	var source_row := {"sourceId":"fixture-tree-nonzero", "propId":"tree-nonzero",
		"transform":local_transform, "sourceOrigin":world_transform.origin}
	var snapshot := {"sourceChunkKey":source_chunk, "sourceDomainRevision":"domain-r1",
		"terrainVolumeChunkRevision":"terrain-r1", "structureAdmissionRevision":"structure-r1",
		"removedSourceProjectionDigest":"a".repeat(64),
		"influencePolicyRevision":"ecology-support-v3",
		"influencePolicyDigest":"b".repeat(64)}
	var tree_family := {"familyRevision":"family-r1", "familyPolicyRevision":"tree-policy-r1",
		"familyPolicyDigest":"c".repeat(64), "sourceManifestDigest":"d".repeat(64)}
	var compiled_manifest := {"sourceId":"fixture-tree-nonzero",
		"sourceChunkKey":source_chunk, "bodyGlobalTransform":world_transform}
	var bound := provider._bind_tree_compiler_manifest_to_source(compiled_manifest,
		source_row, source_chunk, snapshot, tree_family)
	var bound_manifest: Dictionary = bound.get("manifest", {})
	var nonzero_chunk_world_transform_preserved: bool = String(bound.get("status", "")) == "ready" \
		and bound_manifest.get("bodyGlobalTransform", null) is Transform3D \
		and (bound_manifest.bodyGlobalTransform as Transform3D).is_equal_approx(world_transform) \
		and bound_manifest.get("sourceOrigin", Vector3.ZERO).is_equal_approx(world_transform.origin)
	var wrong_local_transform_manifest := compiled_manifest.duplicate(true)
	wrong_local_transform_manifest["bodyGlobalTransform"] = local_transform
	var wrong_binding := provider._bind_tree_compiler_manifest_to_source(
		wrong_local_transform_manifest, source_row, source_chunk, snapshot, tree_family)
	var mismatched_local_transform_rejected := String(wrong_binding.get("status", "")) == "pending" \
		and String(wrong_binding.get("reason", "")) == "ecology_tree_compile_body_transform_mismatch"
	return {"nonzeroChunkWorldTransformPreserved":nonzero_chunk_world_transform_preserved,
		"mismatchedLocalTransformRejected":mismatched_local_transform_rejected,
		"expectedWorldTransform":world_transform,
		"boundWorldTransform":bound_manifest.get("bodyGlobalTransform", Transform3D.IDENTITY)}


func _check_detail_source_resource_digests() -> void:
	var inputs := {
		"worldId":"detail-digest-contract-world", "worldSeed":"detail-digest-contract-seed",
		"sourceChunkKey":"0,0", "chunkX":0, "chunkZ":0, "chunkOrigin":Vector3.ZERO,
		"revisions":{"terrain":"terrain-r1", "structure":"structure-r1", "details":"details-r1"},
		"generationStatus":"complete", "batchesComplete":true}
	var batches := {"grass":[Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 2.0))]}
	var resolvers := {
		"mesh":Callable(self, "_detail_digest_contract_mesh"),
		"meshSurface":Callable(self, "_detail_digest_contract_surface"),
		"materialKey":Callable(self, "_detail_digest_contract_material_key"),
		"material":Callable(self, "_detail_digest_contract_material"),
		"renderLayer":Callable(self, "_detail_digest_contract_layer"),
		"meshContentDigest":Callable(self, "_detail_digest_contract_mesh_digest"),
		"materialContentDigest":Callable(self, "_detail_digest_contract_material_digest"),
		"instanceColor":Callable(self, "_detail_digest_contract_color"),
		"instancePhase":Callable(self, "_detail_digest_contract_phase"),
		"visibilityRangeEnd":Callable(self, "_detail_digest_contract_visibility")}
	var first: Dictionary = DetailSourceValues.build_rows(inputs, batches, resolvers)
	var second: Dictionary = DetailSourceValues.build_rows(inputs, batches, resolvers)
	var rows: Array = first.get("rows", [])
	var row: Dictionary = rows[0] if not rows.is_empty() else {}
	check("detail_source_rows_seal_mesh_and_material_content_digests",
		String(first.get("status", "")) == "ready" \
		and String(row.get("meshContentDigest", "")).length() == 64 \
		and String(row.get("materialContentDigest", "")).length() == 64 \
		and String(row.get("resourceContentIdentitySchema", "")) == "ecology-render-member-content/v1")
	check("detail_source_resource_digests_and_manifest_are_stable",
		first.get("sourceManifestDigest", "") == second.get("sourceManifestDigest", "") \
		and row.get("meshContentDigest", "") == second.rows[0].get("meshContentDigest", "") \
		and row.get("materialContentDigest", "") == second.rows[0].get("materialContentDigest", ""))
	var missing_material_digest: Dictionary = resolvers.duplicate()
	missing_material_digest.erase("materialContentDigest")
	var rejected: Dictionary = DetailSourceValues.build_rows(inputs, batches, missing_material_digest)
	check("detail_source_rows_fail_closed_without_material_digest_authority",
		String(rejected.get("status", "")) == "failed" \
		and String(rejected.get("reason", "")) == "detail_source_resolver_unavailable")


func _detail_digest_contract_mesh(_detail_type: String) -> Mesh:
	return BoxMesh.new()


func _detail_digest_contract_surface(_detail_type: String, _surface_index: int) -> Mesh:
	return BoxMesh.new()


func _detail_digest_contract_material_key(_detail_type: String, _surface_index: int) -> String:
	return "contract_material"


func _detail_digest_contract_material(_detail_type: String, _surface_index: int) -> Material:
	return StandardMaterial3D.new()


func _detail_digest_contract_layer(_material: Material, _detail_type: String,
		_surface_index: int) -> String:
	return "opaque"


func _detail_digest_contract_mesh_digest(_mesh: Mesh) -> String:
	return "a".repeat(64)


func _detail_digest_contract_material_digest(_material: Material) -> String:
	return "b".repeat(64)


func _detail_digest_contract_color(_detail_type: String, _transform: Transform3D,
		_index: int) -> Color:
	return Color.WHITE


func _detail_digest_contract_phase(_detail_type: String, _transform: Transform3D,
		_index: int) -> float:
	return 0.25


func _detail_digest_contract_visibility(_detail_type: String) -> float:
	return 32.0


func _tree_band_existing_demand_lifecycle_contract() -> Dictionary:
	var adapter := Adapter.new()
	var queue := FixtureBandPollQueue.new()
	var section_key := Vector3i(0, 0, 0)
	var consumer_token := "fixture-band-consumer"
	var demand := {"compileKind":"tree_band", "jobKey":"fixture-band-job",
		"consumerToken":consumer_token, "authorityDigest":"authority-a",
		"queueRef":weakref(queue), "sectionKey":section_key}
	queue.poll_result = {"status":"pending",
		"reason":"fixture_terminal_tree_band_failure",
		"terminalFailure":true, "retryable":false}
	var first_failure: Dictionary = adapter._resolve_existing_tree_band_demand(
		queue, demand, "authority-a", consumer_token, Vector2i.ZERO, section_key)
	var repeated_failure: Dictionary = adapter._resolve_existing_tree_band_demand(
		queue, demand, "authority-a", consumer_token, Vector2i.ZERO, section_key)
	var first_failure_result: Dictionary = first_failure.get("result", {})
	var repeated_failure_result: Dictionary = repeated_failure.get("result", {})
	var same_authority_failure_retained := \
		String(first_failure.get("disposition", "")) == "terminal" \
		and String(repeated_failure.get("disposition", "")) == "terminal" \
		and String(first_failure_result.get("reason", "")) \
			== "fixture_terminal_tree_band_failure" \
		and String(repeated_failure_result.get("reason", "")) \
			== "fixture_terminal_tree_band_failure" \
		and not bool(repeated_failure_result.get("retryable", true)) \
		and int(queue.poll_calls) == 2 and queue.cancel_calls.is_empty() \
		and queue.last_polled_job_key == "fixture-band-job" \
		and queue.last_polled_consumer == consumer_token
	queue.cancel_calls.clear()
	queue.poll_result = {"status":"pending",
		"reason":"ecology_band_slice_catalog_lease_stale", "retryable":true}
	var stale_poll: Dictionary = adapter._resolve_existing_tree_band_demand(
		queue, demand, "authority-a", consumer_token, Vector2i.ZERO, section_key)
	var stale_poll_retries_with_detach: bool = \
		String(stale_poll.get("disposition", "")) == "retry" \
		and String(stale_poll.get("result", {}).get("reason", "")) \
			== "ecology_band_slice_catalog_lease_stale" \
		and queue.cancel_calls.size() == 1 \
		and queue.cancel_calls[0].get("jobKey", "") == "fixture-band-job" \
		and queue.cancel_calls[0].get("consumerToken", "") == consumer_token
	queue.cancel_calls.clear()
	queue.poll_result = {"status":"failed",
		"reason":"tree_source_band_consumer_not_attached"}
	var consumer_lost_poll: Dictionary = adapter._resolve_existing_tree_band_demand(
		queue, demand, "authority-a", consumer_token, Vector2i.ZERO, section_key)
	var consumer_lost_retries_with_detach: bool = \
		String(consumer_lost_poll.get("disposition", "")) == "retry" \
		and String(consumer_lost_poll.get("result", {}).get("reason", "")) \
			== "tree_source_band_consumer_not_attached" \
		and queue.cancel_calls.size() == 1 \
		and queue.cancel_calls[0].get("jobKey", "") == "fixture-band-job" \
		and queue.cancel_calls[0].get("consumerToken", "") == consumer_token
	queue.poll_result = {"status":"pending",
		"reason":"tree_source_band_compile_job_missing", "retryable":true}
	queue.cancel_calls.clear()
	var missing_job: Dictionary = adapter._resolve_existing_tree_band_demand(
		queue, demand, "authority-a", consumer_token, Vector2i.ZERO, section_key)
	var missing_job_retryable: bool = String(missing_job.get("disposition", "")) == "retry" \
		and queue.cancel_calls.size() == 1 \
		and queue.cancel_calls[0].get("jobKey", "") == "fixture-band-job" \
		and queue.cancel_calls[0].get("consumerToken", "") == consumer_token
	queue.cancel_calls.clear()
	var changed_authority: Dictionary = adapter._resolve_existing_tree_band_demand(
		queue, demand, "authority-b", consumer_token, Vector2i.ZERO, section_key)
	var changed_authority_detached: bool = \
		String(changed_authority.get("disposition", "")) == "retry" \
		and queue.poll_calls == 5 and queue.cancel_calls.size() == 1 \
		and queue.cancel_calls[0].get("jobKey", "") == "fixture-band-job" \
		and queue.cancel_calls[0].get("consumerToken", "") == consumer_token
	queue.cancel_calls.clear()
	queue.poll_result = null
	var malformed_poll: Dictionary = adapter._resolve_existing_tree_band_demand(
		queue, demand, "authority-a", consumer_token, Vector2i.ZERO, section_key)
	var malformed_poll_fails_closed: bool = \
		String(malformed_poll.get("disposition", "")) == "terminal" \
		and String(malformed_poll.get("result", {}).get("status", "")) == "failed" \
		and String(malformed_poll.get("result", {}).get("reason", "")) \
			== "ecology_tree_band_compile_poll_invalid" \
		and queue.cancel_calls.size() == 1
	return {"sameAuthorityFailureRetained":same_authority_failure_retained,
		"stalePollRetriesWithDetach":stale_poll_retries_with_detach,
		"consumerLostRetriesWithDetach":consumer_lost_retries_with_detach,
		"missingJobRetryable":missing_job_retryable,
		"changedAuthorityDetached":changed_authority_detached,
		"malformedPollFailsClosed":malformed_poll_fails_closed,
		"pollCalls":queue.poll_calls,
		"sameAuthorityCancelCount":0,
		"missingJobCancelCount":1,
		"changedAuthorityCancelCount":queue.cancel_calls.size()}


func _tree_band_partial_source_admission_contract() -> Dictionary:
	var queue := PartialSourceAdmissionQueue.new()
	var source_chunk := Vector2i.ZERO
	var section_key := Vector3i(3, 0, 0)
	var band_key := "fixture-partial-admission-band"
	var band_consumer := "fixture-partial-admission-consumer"
	var rows: Array = [
		{"sourceId":"source-a", "producerFamily":"trees"},
		{"sourceId":"source-b", "producerFamily":"trees"}]
	var records_by_id: Dictionary = {"source-a":rows[0], "source-b":rows[1]}
	var expected_ids: Array[String] = ["source-a", "source-b"]
	queue.ecology_tree_band_compile_jobs[band_key] = {
		"key":band_key, "status":"queued", "authorityDigest":"fixture-authority",
		"worldId":"fixture-world", "sourceChunkKey":source_chunk,
		"sectionKey":section_key, "expectedSourceIds":expected_ids,
		"records":rows, "recordsById":records_by_id,
		"recordJobKeys":{}, "sourceArtifactsById":{},
		"recordConsumerTokensByConsumer":{}, "artifactHolder":{},
		"consumers":{"existing-sibling-consumer":true}}
	var snapshot: Dictionary = {"status":"ready", "worldId":"fixture-world",
		"sourceChunkKey":source_chunk, "sourceRevision":"fixture-source-revision"}
	snapshot.make_read_only()
	var publication_view: Dictionary = {"familyResultsById":{"trees":{
		"status":"ready", "familyRevision":"fixture-tree-revision",
		"sourceManifestDigest":"a".repeat(64), "sourceRows":rows}}}
	var authority: Dictionary = {"authorityDigest":"fixture-authority"}
	var admitted: Dictionary = queue._request_tree_source_record_band_projection(
		FixtureTreeAdmissionMain.new(), snapshot, publication_view, section_key,
		authority, expected_ids, rows, band_key, band_consumer, 0.0)
	var source_a_token := ""
	for request: Dictionary in queue.source_requests:
		if String(request.get("sourceId", "")) == "source-a":
			source_a_token = String(request.get("consumerToken", ""))
	var pending_maps: Dictionary = queue.ecology_tree_band_compile_jobs[
		band_key].get("recordConsumerTokensByConsumer", {})
	var pending_token_map: Dictionary = pending_maps.get(band_consumer, {})
	var pending_job_keys: Dictionary = queue.ecology_tree_band_compile_jobs[
		band_key].get("recordJobKeys", {})
	var partial_state_retained: bool = \
		String(admitted.get("status", "")) == "failed" \
		and String(admitted.get("reason", "")) == "tree_source_record_compile_failed" \
		and String(admitted.get("consumerToken", "")) == band_consumer \
		and queue.source_requests.size() == 2 \
		and String(pending_job_keys.get("source-a", "")) == "source-job-a" \
		and String(pending_token_map.get("source-a", "")) == source_a_token \
		and not source_a_token.is_empty() \
		and not pending_token_map.has("source-b")
	queue.cancel_ecology_tree_source_band_compile(band_key, band_consumer)
	var exact_partial_consumer_cancelled: bool = \
		queue.source_cancellations.size() == 1 \
		and queue.source_cancellations[0].get("jobKey", "") == "source-job-a" \
		and queue.source_cancellations[0].get("consumerToken", "") == source_a_token \
		and queue.ecology_tree_band_compile_jobs[band_key].get(
			"consumers", {}).has("existing-sibling-consumer")
	queue.ecology_tree_band_compile_jobs.erase(band_key)
	var backpressure_queue := PartialSourceAdmissionQueue.new()
	backpressure_queue.source_b_pending_before_attachment = true
	backpressure_queue.ecology_tree_band_compile_jobs[band_key] = {
		"key":band_key, "status":"queued", "authorityDigest":"fixture-authority",
		"worldId":"fixture-world", "sourceChunkKey":source_chunk,
		"sectionKey":section_key, "expectedSourceIds":expected_ids,
		"records":rows, "recordsById":records_by_id,
		"recordJobKeys":{}, "sourceArtifactsById":{},
		"recordConsumerTokensByConsumer":{}, "artifactHolder":{},
		"consumers":{"existing-sibling-consumer":true}}
	var backpressure_result: Dictionary = \
		backpressure_queue._request_tree_source_record_band_projection(
			FixtureTreeAdmissionMain.new(), snapshot, publication_view, section_key,
			authority, expected_ids, rows, band_key, band_consumer, 0.0)
	var backpressure_job: Dictionary = backpressure_queue.ecology_tree_band_compile_jobs[
		band_key]
	var backpressure_job_keys: Dictionary = backpressure_job.get("recordJobKeys", {})
	var backpressure_token_maps: Dictionary = backpressure_job.get(
		"recordConsumerTokensByConsumer", {})
	var backpressure_token_map: Dictionary = backpressure_token_maps.get(band_consumer, {})
	var backpressure_source_a_token := ""
	for request: Dictionary in backpressure_queue.source_requests:
		if String(request.get("sourceId", "")) == "source-a":
			backpressure_source_a_token = String(request.get("consumerToken", ""))
	var pending_before_attachment_retained: bool = \
		String(backpressure_result.get("status", "")) == "pending" \
		and String(backpressure_result.get("reason", "")) \
			== "tree_source_value_retirement_backpressure" \
		and String(backpressure_result.get("consumerToken", "")) == band_consumer \
		and String(backpressure_job_keys.get("source-a", "")) == "source-job-a" \
		and String(backpressure_token_map.get("source-a", "")) \
			== backpressure_source_a_token \
		and not backpressure_job_keys.has("source-b") \
		and not backpressure_token_map.has("source-b")
	backpressure_queue.cancel_ecology_tree_source_band_compile(band_key, band_consumer)
	var pending_before_attachment_cancelled_exactly: bool = \
		backpressure_queue.source_cancellations.size() == 1 \
		and backpressure_queue.source_cancellations[0].get("jobKey", "") \
			== "source-job-a" \
		and backpressure_queue.source_cancellations[0].get("consumerToken", "") \
			== backpressure_source_a_token
	backpressure_queue.ecology_tree_band_compile_jobs.erase(band_key)
	var result := {"partialStateRetained":partial_state_retained,
		"exactPartialConsumerCancelled":exact_partial_consumer_cancelled,
		"pendingBeforeAttachmentRetained":pending_before_attachment_retained,
		"pendingBeforeAttachmentCancelledExactly":pending_before_attachment_cancelled_exactly,
		"sourceRequestCount":queue.source_requests.size(),
		"sourceCancellationCount":queue.source_cancellations.size(),
		"sourceAConsumerToken":source_a_token}
	queue.free()
	backpressure_queue.free()
	return result


func _tree_without_committed_queue_geometry_stays_pending() -> Dictionary:
	var section_key := Vector3i.ZERO
	var off_section_key := Vector3i(1, 0, 0)
	var main := ProductionAuthority.new()
	main.seed_text = "ecology-uncommitted-tree-contract"
	main.seed_hash = 89
	root.add_child(main)
	var provider = PumpedAdapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	provider.configure(world_id)
	provider.bind_main_authority(main)
	provider.pump_retained_preparation = true
	var tree_source_id := "%s:tree:uncommitted-tree" % main.seed_text
	var tree_origin := Vector3(2.0, 0.0, 2.0)
	var tree_row := {"schema":"ecology.static_source_value.v1",
		"sourceId":tree_source_id, "propId":"uncommitted-tree",
		"producerFamily":"trees", "kind":"trees_foliage",
		"sourceOrigin":tree_origin, "transform":Transform3D(Basis.IDENTITY, tree_origin),
		"runtimeSpec":{"family":"broadleaf", "height":1.0,
			"crownRadius":1.0, "trunkRadius":0.1}}
	main.set_fixture_rows(Vector2i.ZERO, [tree_row])
	var overlapping_result: Dictionary = provider.capture_static_section_sources(
		world_id, [section_key])
	var queue := main.tree_publication_queue as FixtureTreeQueue
	var queued_source_ids: Array = queue.last_source_ids.duplicate()
	var overlapping_queue_request_count := queue.request_count
	var overlapping_last_request_reason := queue.last_band_request_reason
	var tree_bounds := AABB(Vector3(60.0, 0.0, 60.0), Vector3.ONE)
	var off_section_bounds_intersect := Adapter._tree_candidate_bounds_intersect_sections(
		tree_bounds, [off_section_key])
	var far_chunk := Vector2i(40, 40)
	main.fixture_rows_by_chunk.clear()
	main.set_fixture_rows(far_chunk, [tree_row])
	# Use a fresh provider so this second assertion observes the revised fixture
	# population, rather than replaying the first request's accepted cache entry.
	var far_provider = PumpedAdapter.new()
	far_provider.configure(world_id)
	far_provider.bind_main_authority(main)
	far_provider.pump_retained_preparation = true
	var off_section_result: Dictionary = far_provider.capture_static_section_sources(
		world_id, [off_section_key])
	var off_section_queued_source_ids: Array = queue.last_source_ids.duplicate()
	var off_section_queue_request_count := queue.request_count
	var queue_request_count := queue.request_count
	main.free()
	return {"overlapping":overlapping_result, "offSection":off_section_result,
		"treeSourceId":tree_source_id, "queuedSourceIds":queued_source_ids,
		"overlappingQueueRequestCount":overlapping_queue_request_count,
		"overlappingLastRequestReason":overlapping_last_request_reason,
		"offSectionQueuedSourceIds":off_section_queued_source_ids,
		"offSectionQueueRequestCount":off_section_queue_request_count,
		"treeQueueRequestCount":queue_request_count,
		"offSectionBoundsIntersect":off_section_bounds_intersect}


func _first_failed_tree_band_job_snapshot(queue: Object, provider: Adapter,
		source_chunk: Vector2i, section_key: Vector3i) -> Dictionary:
	if not is_instance_valid(queue):
		return {}
	var jobs_value: Variant = queue.get("ecology_tree_band_compile_jobs")
	if not jobs_value is Dictionary:
		return {}
	var ordered_keys: Array = jobs_value.keys()
	ordered_keys.sort()
	for key_value: Variant in ordered_keys:
		var job_value: Variant = jobs_value.get(key_value, null)
		if not job_value is Dictionary:
			continue
		var job: Dictionary = job_value
		if String(job.get("status", "")) != "failed" \
				or job.get("sourceChunkKey", null) != source_chunk \
				or job.get("sectionKey", null) != section_key:
			continue
		var compiler: Variant = job.get("compiler", null)
		var progress: Dictionary = job.get("lastProgress", {})
		if is_instance_valid(compiler) and compiler.has_method("progress_snapshot"):
			var progress_value: Variant = compiler.call("progress_snapshot")
			if progress_value is Dictionary:
				progress = progress_value
		var snapshot: Dictionary = job.get("snapshot", {})
		var publication_view: Dictionary = job.get("publicationView", {})
		var consumers: Dictionary = job.get("consumers", {})
		var linked_demands: Array[Dictionary] = []
		for capture_identity_value: Variant in provider._source_capture_jobs:
			var capture_job: Dictionary = provider._source_capture_jobs.get(
				capture_identity_value, {})
			var demands: Dictionary = capture_job.get("treeCompileDemands", {})
			for demand_key_value: Variant in demands:
				var demand: Dictionary = demands[demand_key_value]
				if String(demand.get("jobKey", "")) == String(key_value):
					linked_demands.append({
						"captureIdentity":String(capture_identity_value),
						"demandKey":String(demand_key_value),
						"consumerToken":String(demand.get("consumerToken", "")),
						"authorityDigest":String(demand.get("authorityDigest", ""))})
		return {"jobKey":String(key_value), "status":"failed",
			"reason":String(job.get("reason", "")),
			"ageUsec":maxi(0, Time.get_ticks_usec() - int(job.get("enqueuedUsec", 0))),
			"sourceChunkKey":source_chunk, "sectionKey":section_key,
			"authorityDigest":String(job.get("authorityDigest", "")),
			"sourceRevision":String(snapshot.get("sourceRevision", "")),
			"publicationId":String(publication_view.get("publicationId", "")),
			"publicationContentDigest":String(publication_view.get("contentDigest", "")),
			"treeFamilyRevision":String(job.get("publicationView", {}).get(
				"familyResultsById", {}).get("trees", {}).get("familyRevision", "")),
			"consumerCount":consumers.size(),
			"consumerTokens":consumers.keys(), "expectedSourceIds":job.get(
				"expectedSourceIds", []), "compilerProgress":progress,
			"linkedAdapterDemands":linked_demands}
	return {}


func _freeze_tree_band_artifact_in_place(value: Variant) -> void:
	if value is Dictionary:
		for key: Variant in value:
			_freeze_tree_band_artifact_in_place(value[key])
		(value as Dictionary).make_read_only()
	elif value is Array:
		for nested: Variant in value:
			_freeze_tree_band_artifact_in_place(nested)
		(value as Array).make_read_only()


func _tree_handoff_result_passes(result: Dictionary) -> bool:
	if String(result.get("status", "")) != "ready": return false
	var checks_value: Variant = result.get("checks", null)
	if not checks_value is Dictionary or checks_value.is_empty(): return false
	for check_value: Variant in checks_value.values():
		if check_value != true: return false
	return true


func _real_tree_band_handoff_contract() -> Dictionary:
	var helper_started_msec := Time.get_ticks_msec()
	var helper_stage_msec := helper_started_msec
	var helper_timings: Dictionary = {}
	var revision_diagnostic_probe := _tree_band_revision_digest_sample({
		"sectionKey":Vector3i.ZERO, "sourceChunkKey":Vector2i.ZERO,
		"sourceRevision":"diagnostic-revision",
		"sourceManifest":{"sourceId":"diagnostic-source",
			"sourcePartId":"diagnostic-part", "sourceRevision":"diagnostic-revision",
			"geometryOwnership":[], "compiledAttributeDigest":"digest"},
		"artifact":{
			"sourceCompletionDigest":"c".repeat(64),
			"ownerBatchPayloadDigest":"d".repeat(64),
			"batches":[{
				"sectionKey":Vector3i.ZERO, "batchKey":"diagnostic-batch",
				"role":"bole", "instanceCount":1,
				"contributors":{"diagnostic-member":{}}}
			]
		}
	}, "diagnostic-band", "diagnostic-identity")
	var revision_diagnostic_contract_ready: bool = \
		String(revision_diagnostic_probe.get("cachedSourceRevision", "")) \
			== "diagnostic-revision" \
		and String(revision_diagnostic_probe.get("sourceCompletionDigest", "")).length() == 64 \
		and String(revision_diagnostic_probe.get("ownerBatchPayloadDigest", "")).length() == 64 \
		and String(revision_diagnostic_probe.get("batchOrderDigest", "")).length() == 64 \
		and int(revision_diagnostic_probe.get("batchCount", 0)) == 1 \
		and (revision_diagnostic_probe.get("batchOrderSample", []) as Array).size() == 1
	if not revision_diagnostic_contract_ready:
		return {"status":"failed", "reason":"tree_band_revision_diagnostic_contract_invalid",
			"diagnosticProbe":revision_diagnostic_probe}
	var revision_input_probe := _tree_band_revision_input_diagnostic_contract()
	if not bool(revision_input_probe.get("preflightPassed", false)):
		return {"status":"failed", "reason":"tree_band_revision_input_preflight_failed",
			"diagnosticProbe":revision_diagnostic_probe,
			"inputProbe":revision_input_probe}
	var recipe_identity_probe := _immutable_recipe_content_identity_contract()
	if not bool(recipe_identity_probe.get("passed", false)):
		return {"status":"failed", "reason":"tree_recipe_content_identity_contract_failed",
			"diagnosticProbe":revision_diagnostic_probe,
			"inputProbe":revision_input_probe,
			"recipeIdentityProbe":recipe_identity_probe}
	print("TREE_HANDOFF_TIMING stage=start run_elapsed_msec=",
		Time.get_ticks_msec() - _contract_run_started_msec)
	var main := ProductionAuthority.new()
	main.seed_text = "ecology-real-tree-band-handoff-contract"
	main.seed_hash = 1067
	main.underground_required = false
	root.add_child(main)
	# Use the full production profile catalog for recipe admission, matching the
	# real tree source contract instead of the compact profile used by other rows.
	var catalog := BiomeCatalog.new()
	if not catalog.setup():
		main.free()
		return {"status":"failed", "reason":"tree_handoff_biome_catalog_setup_failed"}
	var captured_profiles := BiomeSnapshot.capture(catalog)
	if not bool(captured_profiles.get("ok", false)):
		main.free()
		return {"status":"failed", "reason":"tree_handoff_profile_capture_failed"}
	main._profile_snapshot = {"schemaVersion":int(captured_profiles.get("schemaVersion", -1)),
		"fallbackId":String(captured_profiles.get("fallbackId", "")),
		"contentIdentity":String(captured_profiles.get("contentIdentity", "")),
		"profiles":(captured_profiles.get("profiles", []) as Array).duplicate(true)}
	main._tree_request_envelope = ProducerDomain.derive_tree_request_envelope(
		main._profile_snapshot)
	main._tree_support_envelope = ProducerDomain.derive_tree_grammar_support_envelope(
		main._profile_snapshot)
	helper_timings["profileCaptureMsec"] = Time.get_ticks_msec() - helper_stage_msec
	helper_stage_msec = Time.get_ticks_msec()
	print("TREE_HANDOFF_TIMING stage=profile_capture elapsed_msec=",
		helper_timings["profileCaptureMsec"], " run_elapsed_msec=",
		Time.get_ticks_msec() - _contract_run_started_msec)
	var rock_digest := ProducerDomain.digest_value(["synthetic-rock-catalog-v1",
		main._profile_snapshot.contentIdentity])
	main._rock_envelope["profileCatalogRevision"] = main._profile_snapshot.contentIdentity
	main._rock_envelope["eligibleAssetSetDigest"] = rock_digest
	main._rock_envelope["digest"] = rock_digest
	main._rock_envelope["assetSetDigest"] = rock_digest
	var fixture_queue: Node = main.tree_publication_queue
	if is_instance_valid(fixture_queue):
		main.remove_child(fixture_queue)
		fixture_queue.free()
	var queue := TreeQueueScript.new()
	main.add_child(queue)
	queue.set_process(true)
	queue.publication_service.prewarm_visuals()
	main.tree_publication_queue = queue
	helper_timings["queueSetupMsec"] = Time.get_ticks_msec() - helper_stage_msec
	helper_stage_msec = Time.get_ticks_msec()
	print("TREE_HANDOFF_TIMING stage=queue_setup elapsed_msec=",
		helper_timings["queueSetupMsec"], " run_elapsed_msec=",
		Time.get_ticks_msec() - _contract_run_started_msec)
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	var source_chunk := Vector2i.ZERO
	var source_origin := Vector3(15.4, 0.0, 5.0)
	var policy_input: Dictionary = main.ecology_source_support_policy_inputs(
		world_id, source_chunk, main.seed_text, {})
	if String(policy_input.get("status", "")) != "ready":
		main.free()
		return {"status":"failed", "reason":"tree_handoff_support_policy_unavailable",
			"detail":policy_input}
	var request := CertifiedTreeRequestFixture.prepare_or_fail({
		"treeId":"real-tree-band-handoff", "worldSeed":main.seed_text,
		"biome":"forest", "architecture":"broadleaf",
		"speciesGrammar":"bushy_oak", "growthStage":0.80,
		"canopyDensity":0.82, "presentation":"runtime"})
	request["worldSeed"] = main.seed_text
	request["treeWorldPosition"] = source_origin
	request["renderLodTier"] = "near"
	var service := TreeSpawnServiceScript.new()
	var normalized: Dictionary = service.normalize_request(request)
	var recipe: Dictionary = service.build_recipe(normalized)
	var tree_transform := Transform3D(Basis.IDENTITY, source_origin)
	var envelope := TreeCompilerScript.certify_recipe_support_envelope(recipe,
		tree_transform)
	var source_bounds: Variant = envelope.get("value", {}).get("worldBounds", null)
	var support_proof := ProducerDomain.validate_source_bounds("trees", source_origin,
		source_bounds if source_bounds is AABB else AABB(),
		policy_input.get("supportPolicy", {}))
	if source_bounds is AABB:
		support_proof["worldBounds"] = source_bounds
		support_proof["sourceOrigin"] = source_origin
	helper_timings["recipeAndSupportCertificationMsec"] = Time.get_ticks_msec() - helper_stage_msec
	helper_stage_msec = Time.get_ticks_msec()
	print("TREE_HANDOFF_TIMING stage=recipe_support_certification elapsed_msec=",
		helper_timings["recipeAndSupportCertificationMsec"], " status=",
		String(envelope.get("status", "")), " support_status=",
		String(support_proof.get("status", "")), " run_elapsed_msec=",
		Time.get_ticks_msec() - _contract_run_started_msec)
	var source_id := "%s:tree:real-tree-band-handoff" % main.seed_text
	var source_row := {"schema":"ecology.static_source_value.v1",
		"sourceId":source_id, "propId":"real-tree-band-handoff",
		"producerFamily":"trees", "kind":"trees_foliage", "recipeVersion":2,
		"biome":"forest", "sourceOrigin":source_origin,
		"transform":tree_transform, "runtimeSpec":normalized,
		"legacySpec":{"height":float(recipe.get("height", 8.0)),
			"trunk_radius":float(recipe.get("trunkRadius", 0.4)),
			"canopy_radius":float(recipe.get("canopyRadius", 3.0))},
		"supportProof":support_proof}
	main.set_fixture_rows(source_chunk, [source_row])
	var provider := Adapter.new()
	provider.configure(world_id)
	provider.bind_main_authority(main)
	var target_section := Vector3i(0, 0, 0)
	var support_only_section := Vector3i(-9999, -9999, -9999)
	var support_only_selected := false
	var support_only_selection: Dictionary = {
		"status":"pending", "reason":"waiting_for_target_band_artifact"}
	var requested_sections: Array[Vector3i] = [target_section]
	var roster := Roster.new()
	var roster_bound: Dictionary = roster.bind_world(world_id, [Adapter.PROVIDER_ID])
	var roster_registered: Dictionary = roster.register_provider(Adapter.PROVIDER_ID,
		provider, "capture_static_section_sources")
	helper_timings["authorityAndRosterSetupMsec"] = Time.get_ticks_msec() - helper_stage_msec
	helper_stage_msec = Time.get_ticks_msec()
	print("TREE_HANDOFF_TIMING stage=authority_roster_setup elapsed_msec=",
		helper_timings["authorityAndRosterSetupMsec"], " bind=",
		String(roster_bound.get("status", "")), " register=",
		String(roster_registered.get("status", "")), " run_elapsed_msec=",
		Time.get_ticks_msec() - _contract_run_started_msec)
	var capture: Dictionary = {}
	var capture_started_msec := Time.get_ticks_msec()
	var capture_elapsed_msec := 0
	var max_capture_call_msec := 0
	var max_source_advance_call_msec := 0
	var total_source_advance_msec := 0
	var source_advance_count := 0
	var source_jobs_advanced := 0
	var capture_frame_count := 0
	var next_capture_frame := 0
	var first_failed_band_job: Dictionary = {}
	var latest_source_advance: Dictionary = {}
	for frame_index in range(1800):
		if not support_only_selected:
			var target_band_artifact := _tree_band_artifact_for_section(queue,
				source_chunk, target_section)
			if not target_band_artifact.is_empty():
				support_only_selection = _select_ownerless_tree_support_section(
					target_band_artifact, target_section)
				if String(support_only_selection.get("status", "")) == "ready":
					support_only_section = support_only_selection.sectionKey
					support_only_selected = true
					requested_sections = [target_section, support_only_section]
		first_failed_band_job = _first_failed_tree_band_job_snapshot(queue, provider,
			source_chunk, target_section)
		if not first_failed_band_job.is_empty():
			capture = {"status":"pending",
				"reason":"tree_source_band_job_failed_before_provider_retry",
				"retryable":true}
			print("TREE_HANDOFF_TIMING stage=first_failed_band_job frame=",
				frame_index + 1, " diagnostic=", JSON.stringify(first_failed_band_job))
			break
		if frame_index >= next_capture_frame:
			var capture_call_started_msec := Time.get_ticks_msec()
			capture = roster.capture_sections(requested_sections)
			var capture_call_elapsed_msec := Time.get_ticks_msec() - capture_call_started_msec
			max_capture_call_msec = maxi(max_capture_call_msec, capture_call_elapsed_msec)
			capture_frame_count += 1
			if capture_frame_count == 1 or capture_frame_count % 8 == 0:
				print("TREE_HANDOFF_TIMING stage=capture_loop frame=", frame_index + 1,
					" call_msec=", capture_call_elapsed_msec,
					" max_call_msec=", max_capture_call_msec,
					" elapsed_msec=", Time.get_ticks_msec() - capture_started_msec,
					" status=", String(capture.get("status", "")),
					" reason=", String(capture.get("reason", "")))
			if String(capture.get("status", "")) == "complete":
				break
			var continuation_value: Variant = capture.get("continuationHint", null)
			var has_continuation: bool = continuation_value is Dictionary \
				and continuation_value.is_read_only() \
				and String(continuation_value.get("schema", "")) \
					== "static-section-provider-continuation/v1"
			next_capture_frame = frame_index + 1 if has_continuation else \
				frame_index + SectionCoordinator.VISIBLE_SECTION_DEMAND_RETRY_FRAMES
		capture_elapsed_msec = Time.get_ticks_msec() - capture_started_msec
		if capture_elapsed_msec >= 25000:
			break
		var source_advance_started_msec := Time.get_ticks_msec()
		var source_advance: Dictionary = provider.advance_source_domain_captures(8,
			source_origin)
		latest_source_advance = source_advance.duplicate(false)
		var source_advance_elapsed_msec := Time.get_ticks_msec() - source_advance_started_msec
		max_source_advance_call_msec = maxi(max_source_advance_call_msec,
			source_advance_elapsed_msec)
		total_source_advance_msec += source_advance_elapsed_msec
		source_advance_count += 1
		source_jobs_advanced += int(source_advance.get("advancedCount", 0))
		if source_advance_count == 1 or source_advance_count % 4 == 0:
			print("TREE_HANDOFF_TIMING stage=source_capture_advance frame=",
				frame_index + 1, " call_msec=", source_advance_elapsed_msec,
				" max_call_msec=", max_source_advance_call_msec,
				" advanced_jobs=", source_advance.get("advancedCount", 0),
				" total_jobs=", source_jobs_advanced,
				" status=", String(source_advance.get("status", "")),
				" reason=", String(source_advance.get("reason", "")))
		capture_elapsed_msec = Time.get_ticks_msec() - capture_started_msec
		if capture_elapsed_msec >= 25000:
			break
		await process_frame
	capture_elapsed_msec = Time.get_ticks_msec() - capture_started_msec
	helper_timings["captureLoopMsec"] = capture_elapsed_msec
	helper_timings["captureLoopFrames"] = capture_frame_count
	helper_timings["captureCallMaxMsec"] = max_capture_call_msec
	helper_timings["sourceAdvanceCount"] = source_advance_count
	helper_timings["sourceAdvanceMaxCallMsec"] = max_source_advance_call_msec
	helper_timings["sourceAdvanceTotalMsec"] = total_source_advance_msec
	helper_timings["sourceJobsAdvanced"] = source_jobs_advanced
	helper_stage_msec = Time.get_ticks_msec()
	print("TREE_HANDOFF_TIMING stage=capture_loop_complete elapsed_msec=",
		capture_elapsed_msec, " frames=", capture_frame_count,
		" max_call_msec=", max_capture_call_msec,
		" status=", String(capture.get("status", "")), " run_elapsed_msec=",
		Time.get_ticks_msec() - _contract_run_started_msec)
	var band_authorities: Dictionary = provider._support_index._tree_source_family_band_authorities.get(
		source_chunk, {})
	var authority: Dictionary = band_authorities.get(target_section, {})
	var overlays: Dictionary = provider._support_index._tree_section_geometry_overlays.get(
		source_chunk, {})
	var overlay: Dictionary = overlays.get(target_section, {})
	var support_only_overlay: Dictionary = overlays.get(support_only_section, {}) \
		if support_only_selected else {}
	var band_jobs: Array[Dictionary] = []
	var support_band_jobs: Array[Dictionary] = []
	for job_value: Variant in queue.ecology_tree_band_compile_jobs.values():
		if job_value is Dictionary and job_value.get("sourceChunkKey", null) == source_chunk:
			if job_value.get("sectionKey", null) == target_section:
				band_jobs.append(job_value)
			elif support_only_selected \
					and job_value.get("sectionKey", null) == support_only_section:
				support_band_jobs.append(job_value)
	var preparation_failure_diagnostic: Dictionary = {}
	if String(capture.get("status", "")) != "complete" or band_jobs.is_empty():
		var scheduler_snapshot: Dictionary = provider.source_capture_scheduler_snapshot()
		var preparing_rows: Array = scheduler_snapshot.get("preparing", [])
		var target_preparation_rows: Array[Dictionary] = []
		for row_value: Variant in preparing_rows:
			if row_value is Dictionary and row_value.get("sectionKey", null) == target_section:
				target_preparation_rows.append(row_value)
		preparation_failure_diagnostic = {"captureStatus":String(capture.get("status", "")),
			"captureReason":String(capture.get("reason", "")),
			"latestAdvanceStatus":String(latest_source_advance.get("status", "")),
			"latestAdvanceReason":String(latest_source_advance.get("reason", "")),
			"latestAdvanceCount":int(latest_source_advance.get("advancedCount", 0)),
			"latestAdvanceResults":latest_source_advance.get("results", []).slice(0, 4),
			"schedulerCounts":{"activeCohorts":int(scheduler_snapshot.get("activeCohortCount", 0)),
				"deferredCohorts":int(scheduler_snapshot.get("deferredCohortCount", 0)),
				"pendingSourceJobs":int(scheduler_snapshot.get("pendingSourceJobCount", 0)),
				"readySourceJobs":int(scheduler_snapshot.get("completedSourceJobCount", 0)),
				"preparationUnits":int(scheduler_snapshot.get("sectionPreparationUnits", 0)),
				"preparationCompletions":int(scheduler_snapshot.get("sectionPreparationCompletions", 0))},
			"targetPreparation":target_preparation_rows.slice(0, 2),
			"matchingTreeBandJobs":band_jobs.size(),
			"matchingTreeSourceJobs":queue.ecology_source_compile_jobs.size()}
		print("TREE_HANDOFF_DIAGNOSTIC stage=bounded_incomplete_capture ",
			JSON.stringify(preparation_failure_diagnostic))
	var artifact: Dictionary = queue._tree_artifact_holder_view(
		band_jobs[0].get("artifactHolder", {})) if not band_jobs.is_empty() else {}
	var support_only_artifact := _tree_band_artifact_for_section(queue,
		source_chunk, support_only_section, "complete_empty") \
		if support_only_selected else {}
	var batches_value: Variant = artifact.get("batches", [])
	var batches: Array = batches_value if batches_value is Array else []
	var supports_neighbor_owner := false
	for row_value: Variant in overlay.get("supportRows", []):
		if row_value is Dictionary and row_value.get("geometryOwnerSection", null) != target_section \
			and target_section in row_value.get("supportSectionKeys", []):
			supports_neighbor_owner = true
	var support_only_rows_are_ownerless := not support_only_overlay.is_empty() \
		and int(support_only_overlay.get("ownerMemberCount", -1)) == 0 \
		and int(support_only_overlay.get("supportMemberCount", 0)) > 0 \
		and String(support_only_overlay.get("supportDisposition", "")) == "support_only"
	var contributions_by_section: Dictionary = {}
	var assembled_by_section: Dictionary = {}
	var contribution_capture_ok := String(roster_bound.get("status", "")) == "ready" \
		and String(roster_registered.get("status", "")) == "ready" \
		and String(capture.get("status", "")) == "complete"
	var contribution_sections: Array[Vector3i] = [target_section]
	if support_only_selected:
		contribution_sections.append(support_only_section)
	if contribution_capture_ok:
		for section_key: Vector3i in contribution_sections:
			var contribution_result: Dictionary = roster.capture_section_contributions(
				capture, section_key)
			contributions_by_section[section_key] = contribution_result
			if String(contribution_result.get("status", "")) == "complete":
				var contribution_values: Array = contribution_result.get("contributions", [])
				assembled_by_section[section_key] = Assembler.assemble(capture,
					section_key, contribution_values, 1)
	helper_timings["contributionAndAssemblyMsec"] = Time.get_ticks_msec() - helper_stage_msec
	helper_stage_msec = Time.get_ticks_msec()
	print("TREE_HANDOFF_TIMING stage=contribution_assembly elapsed_msec=",
		helper_timings["contributionAndAssemblyMsec"], " capture_ok=",
		contribution_capture_ok, " run_elapsed_msec=",
		Time.get_ticks_msec() - _contract_run_started_msec)
	var primary_contribution: Dictionary = contributions_by_section.get(target_section, {})
	var primary_candidate: Dictionary = assembled_by_section.get(target_section, {})
	var primary_candidate_payload: Dictionary = primary_candidate.get("candidate", {})
	var primary_replacement: Dictionary = primary_candidate_payload.get("candidate", {})
	var primary_manifest: Array = primary_replacement.get("snapshot", {}).get("manifest", [])
	var tree_buffer_handoff: Dictionary = _tree_band_buffer_handoff_contract(
		artifact, primary_contribution, source_id, target_section)
	var tree_buffer_count_guard: Dictionary = _tree_band_buffer_count_guard_contract(
		primary_contribution, source_id)
	var demanded_tree_source_ids: Dictionary = {}
	var source_artifact_digest_by_id: Dictionary = {}
	var projection_band_job_count := 0
	var captured_source_alias_count := 0
	for band_job_value: Variant in band_jobs + support_band_jobs:
		if not band_job_value is Dictionary:
			continue
		var projection_job: Dictionary = band_job_value
		if String(projection_job.get("artifactKind", "")) != "tree_source_record_projection" \
				or String(projection_job.get("status", "")) != "complete":
			continue
		projection_band_job_count += 1
		var expected_ids_value: Variant = projection_job.get("expectedSourceIds", null)
		if expected_ids_value is Array:
			for expected_id_value: Variant in expected_ids_value:
				demanded_tree_source_ids[String(expected_id_value)] = true
		var held_artifacts: Variant = projection_job.get("sourceArtifactsById", null)
		if held_artifacts is Dictionary:
			captured_source_alias_count += held_artifacts.size()
		var projected_artifact: Dictionary = queue._tree_artifact_holder_view(
			projection_job.get("artifactHolder", {}))
		for digest_value: Variant in projected_artifact.get("sourceArtifactDigests", []):
			if not digest_value is Dictionary:
				continue
			var digest_source_id := String(digest_value.get("sourceId", ""))
			if source_artifact_digest_by_id.has(digest_source_id) \
					and String(source_artifact_digest_by_id[digest_source_id]) \
					!= String(digest_value.get("sourceArtifactDigest", "")):
				source_artifact_digest_by_id[digest_source_id] = "conflict"
			else:
				source_artifact_digest_by_id[digest_source_id] = String(
					digest_value.get("sourceArtifactDigest", ""))
	var shared_source_digest := String(source_artifact_digest_by_id.get(source_id, ""))
	var candidate_has_tree_source := false
	for manifest_value: Variant in primary_manifest:
		if manifest_value is Dictionary and String(manifest_value.get("sourceId", "")) == source_id:
			candidate_has_tree_source = true
	var support_only_contribution: Dictionary = contributions_by_section.get(
		support_only_section, {})
	var support_only_candidate: Dictionary = assembled_by_section.get(support_only_section, {})
	var support_only_candidate_payload: Dictionary = support_only_candidate.get("candidate", {})
	var support_only_contribution_values: Array = support_only_contribution.get(
		"contributions", [])
	var support_only_contribution_payload: Dictionary = \
		support_only_contribution_values[0] \
		if not support_only_contribution_values.is_empty() else {}
	var support_only_ranges: Dictionary = support_only_contribution_payload.get(
		"supportRangesBySource", {})
	var support_only_has_tree_range := false
	for range_values: Variant in support_only_ranges.values():
		if not range_values is Array:
			continue
		for range_value: Variant in range_values:
			if range_value is Dictionary and String(range_value.get("sourceId", "")) == source_id \
					and range_value.get("geometryOwnerSection", null) != support_only_section \
					and range_value.get("supportSectionKey", null) == support_only_section:
					support_only_has_tree_range = true
	var support_only_completion: Dictionary = {}
	for completion_value: Variant in support_only_artifact.get(
		"sourceCompletionManifest", []):
		if completion_value is Dictionary and String(completion_value.get("sourceId", "")) \
				== source_id:
			support_only_completion = completion_value
			break
	var support_only_candidate_has_identity := false
	for coverage_value: Variant in support_only_candidate_payload.get("supportCoverageIdentities", []):
		if coverage_value is Dictionary and String(coverage_value.get("providerId", "")) \
				== Adapter.PROVIDER_ID and coverage_value.get("sectionKey", null) == support_only_section:
			support_only_candidate_has_identity = true
	var band_slice_diagnostics: Dictionary = main._catalog_store.source_publication_diagnostics_snapshot()
	var support_index_band_profile: Dictionary = provider._support_index.source_band_registration_profile_snapshot()
	var band_slice_prepare_calls := int(main.band_slice_prepare_calls)
	var band_slice_resolve_calls := int(main.band_slice_resolve_calls)
	var band_slice_exact_alias_resolutions := int(
		main.band_slice_exact_alias_resolutions)
	var completion_manifest_value: Variant = artifact.get("sourceCompletionManifest", null)
	var owner_payload_value: Variant = artifact.get("ownerBatchContributors", null)
	var support_set_sections: Array[Vector3i] = [target_section]
	var support_set_overlays := {target_section:overlay}
	if support_only_selected:
		support_set_sections.append(support_only_section)
		support_set_overlays[support_only_section] = support_only_overlay
	var support_set_diagnostic := _tree_band_support_set_diagnostic(
		artifact, support_set_sections, support_set_overlays)
	var source_band_revision_diagnostics := _tree_band_revision_diagnostic_by_source(
		provider, source_id)
	var source_band_revision_input_comparison := _tree_band_revision_input_comparison(
		queue, source_band_revision_diagnostics, source_chunk)
	var native_source_artifact_proof := _tree_band_native_source_artifact_proof(
		queue, band_jobs[0], source_id, artifact) if not band_jobs.is_empty() else {}
	var manifest_member_contract := _tree_manifest_member_binding_contract(
		provider, target_section)
	var revision_probe := Adapter.new()
	var revision_probe_key := "source-part-probe"
	var revision_probe_revisions := {revision_probe_key:"revision-a"}
	var revision_probe_sections := {revision_probe_key:Vector3i(1, 2, 3)}
	var same_revision_details: Dictionary = revision_probe._source_revision_conflict_details(
		"source-probe", "part-probe", revision_probe_key, "revision-a",
		Vector3i(2, 2, 3), revision_probe_revisions, revision_probe_sections)
	var changed_revision_details: Dictionary = revision_probe._source_revision_conflict_details(
		"source-probe", "part-probe", revision_probe_key, "revision-b",
		Vector3i(2, 2, 3), revision_probe_revisions, revision_probe_sections)
	var revision_conflict_contract: bool = same_revision_details.is_empty() \
		and String(changed_revision_details.get("reason", "")) \
			== "ecology_support_source_revision_conflict" \
		and changed_revision_details.get("firstSectionKey", null) == Vector3i(1, 2, 3) \
		and String(changed_revision_details.get("firstSourceRevision", "")) == "revision-a" \
		and changed_revision_details.get("conflictingSectionKey", null) == Vector3i(2, 2, 3) \
		and String(changed_revision_details.get("conflictingSourceRevision", "")) == "revision-b"
	var completion_array_types_preserved := completion_manifest_value is Array[Dictionary]
	if completion_manifest_value is Array:
		for completion_row_value: Variant in completion_manifest_value:
			if completion_row_value is Dictionary:
				if not completion_row_value.get("ownerMemberIds", null) is Array[String] \
						or not completion_row_value.get("supportMemberIds", null) is Array[String]:
					completion_array_types_preserved = false
	var checks := {
		"real_source_capture_ready":String(capture.get("status", "")) == "complete" \
			and capture_elapsed_msec < 25000,
		"real_native_nonempty_band_artifact":String(artifact.get("schema", "")) \
			== CompiledTreeSectionArtifact.SCHEMA \
			and String(artifact.get("disposition", "")) == "complete_nonempty" \
			and artifact.get("expectedSourceIds", []) == [source_id] \
			and not batches.is_empty() \
			and String(native_source_artifact_proof.get("status", "")) == "ready" \
			and int(native_source_artifact_proof.get(
				"nativeTreePackAcceptedInstances", 0)) > 0,
		"queue_admitted_source_completion_digest_matches_shipped_value": \
			completion_manifest_value is Array and completion_manifest_value.is_read_only() \
			and String(artifact.get("sourceCompletionDigest", "")) \
				== _test_var_bytes_digest(completion_manifest_value),
		"queue_admitted_source_completion_typed_arrays_are_preserved": \
			completion_array_types_preserved,
		"queue_admitted_owner_payload_digest_matches_shipped_value": \
			owner_payload_value is Array and owner_payload_value.is_read_only() \
			and String(artifact.get("ownerBatchPayloadDigest", "")) \
				== _test_var_bytes_digest(owner_payload_value),
		"real_adapter_registered_index_overlay":String(overlay.get("schema", "")) \
			== "ecology-tree-section-geometry-overlay/v1" \
			and String(overlay.get("authorityDigest", "")) \
			== String(authority.get("authorityDigest", "")) \
			and String(overlay.get("compiledArtifactDigest", "")).length() == 64 \
			and String(overlay.get("sourceCompletionDigest", "")) \
			== String(artifact.get("sourceCompletionDigest", "")) \
			and String(overlay.get("ownerBatchPayloadDigest", "")) \
			== String(artifact.get("ownerBatchPayloadDigest", "")),
		"cross_section_owner_support_row_survives":supports_neighbor_owner \
			and int(overlay.get("supportMemberCount", 0)) > 0,
		"real_overlay_support_set_matches_compiler_manifest": \
			int(support_set_diagnostic.get("missingMemberCount", -1)) == 0 \
			and int(support_set_diagnostic.get("extraMemberCount", -1)) == 0,
		"aggregate_source_manifest_binds_exact_geometry_member": \
			String(manifest_member_contract.get("status", "")) == "ready" \
			and int(manifest_member_contract.get("matchingOwnershipCount", 0)) == 1 \
			and String(manifest_member_contract.get("manifestMemberId", "")) \
				== String(manifest_member_contract.get("supportMemberId", "")) \
			and int(manifest_member_contract.get("canonicalSupportRowCount", 0)) == 1 \
			and bool(manifest_member_contract.get("cachedCanonicalMatches", false)) \
			and bool(manifest_member_contract.get("aggregateManifestHasNoPartId", false)),
		"aggregate_source_manifest_rejects_missing_or_duplicate_member": \
			String(manifest_member_contract.get("missingMemberStatus", "")) == "pending" \
			and String(manifest_member_contract.get("duplicateMemberStatus", "")) == "pending",
		"census_rejects_conflicting_source_revisions_with_both_sections": \
			revision_conflict_contract,
		"source_band_revision_diagnostic_fields_validated_before_capture": \
			revision_diagnostic_contract_ready,
		"source_band_revision_input_comparison_probe_validated_before_capture": \
			bool(revision_input_probe.get("preflightPassed", false)),
		"source_band_revision_input_introspection_preflight": \
			bool(source_band_revision_input_comparison.get("preflightPassed", false)),
		"recipe_content_identity_excludes_only_timing_telemetry": \
			bool(recipe_identity_probe.get("passed", false)),
		"real_band_recipe_values_match_or_differ_only_by_timing": \
			_tree_revision_differences_only_timing(
				source_band_revision_input_comparison.get("recursiveDifferences", [])),
		"real_band_content_revision_is_shared": \
			_tree_band_content_revision_is_shared(source_band_revision_input_comparison),
		"real_band_compiled_geometry_identity_is_shared": \
			_tree_band_compiled_geometry_is_shared(source_band_revision_input_comparison),
		"artifact_exposes_ownerless_supported_section":support_only_selected,
		"adjacent_support_only_overlay_is_explicit":support_only_rows_are_ownerless,
		"index_accepts_source_with_support_but_no_owned_geometry": \
			String(support_only_artifact.get("schema", "")) \
				== CompiledTreeSectionArtifact.SCHEMA \
			and String(support_only_artifact.get("disposition", "")) == "complete_empty" \
			and support_only_artifact.get("expectedSourceIds", []) == [source_id] \
			and int(support_only_completion.get("ownerMemberCount", -1)) == 0 \
			and int(support_only_completion.get("supportMemberCount", 0)) > 0 \
			and String(support_only_overlay.get("schema", "")) \
				== "ecology-tree-section-geometry-overlay/v1" \
			and int(support_only_overlay.get("ownerMemberCount", -1)) == 0 \
			and int(support_only_overlay.get("supportMemberCount", 0)) > 0,
		"real_adapter_contribution_assembles_owner_candidate": \
			String(primary_contribution.get("status", "")) == "complete" \
			and String(primary_candidate.get("status", "")) == "ready" \
			and int(primary_candidate.get("inputCount", 0)) > 0 and candidate_has_tree_source,
		"real_owner_buffers_are_typed_readonly_aliases_with_exact_membership": \
			String(tree_buffer_handoff.get("status", "")) == "ready" \
			and int(tree_buffer_handoff.get("artifactMemberCount", 0)) > 0 \
			and int(tree_buffer_handoff.get("adapterInputCount", -1)) \
				== int(tree_buffer_handoff.get("artifactMemberCount", 0)) \
			and int(tree_buffer_handoff.get("aliasCount", -1)) \
				== int(tree_buffer_handoff.get("artifactMemberCount", 0)) \
			and bool(tree_buffer_handoff.get("typedReadonlyAndCountValid", false)),
		"real_owner_input_count_mismatch_is_rejected": \
			String(tree_buffer_count_guard.get("reason", "")) \
			== "invalid_instance_count_or_buffer_length",
		"neighboring_bands_reuse_one_per_tree_geometry_compile": \
			projection_band_job_count == 2 \
			and demanded_tree_source_ids.size() == 1 \
			and queue.ecology_tree_source_record_compile_start_count \
				== demanded_tree_source_ids.size() \
			and queue.ecology_tree_source_record_cache_reuse_count > 0 \
			and captured_source_alias_count == demanded_tree_source_ids.size() \
				* projection_band_job_count \
			and shared_source_digest.length() == 64,
		"support_only_section_assembles_without_duplicate_owner_geometry": \
			String(support_only_contribution.get("status", "")) == "complete" \
			and String(support_only_candidate.get("status", "")) == "ready" \
			and int(support_only_candidate.get("inputCount", -1)) == 0 \
			and support_only_has_tree_range and support_only_candidate_has_identity,
		"production_adapter_uses_main_delegated_owner_slices": \
			main.band_slice_prepare_calls > 0 \
			and main.band_slice_resolve_calls > 0 \
			and main.band_slice_exact_alias_resolutions == main.band_slice_resolve_calls \
			and int(band_slice_diagnostics.get("bandSlicePublicationValidationCount", 0)) > 0 \
			and int(band_slice_diagnostics.get("bandSliceProjectionCount", 0)) > 0,
		"production_census_reuses_owner_slices_across_recaptures": \
			int(band_slice_diagnostics.get("bandSliceReuseCount", 0)) > 0,
		"compiler_revision_schema_stays_separate":TreeCompilerScript.SCHEMA \
			== "tree-recipe-section-compiler/v1"}
	var queue_currentness := {"status":"missing"}
	if not band_jobs.is_empty():
		var job: Dictionary = band_jobs[0]
		var consumer_tokens: Array = job.get("consumers", {}).keys()
		if not consumer_tokens.is_empty():
			main.ecology_world_epoch += 1
			queue_currentness = queue.poll_ecology_tree_source_band_compile(
				String(job.get("key", "")), String(consumer_tokens[0]))
			main.ecology_world_epoch -= 1
	checks["stale_publication_owner_is_rejected_after_worker_completion"] = \
		String(queue_currentness.get("status", "")) == "failed" \
		and String(queue_currentness.get("reason", "")).contains("stale")
	var tampered_identity := artifact.duplicate(true)
	if not tampered_identity.is_empty():
		tampered_identity["authorityDigest"] = "f".repeat(64)
		_freeze_tree_band_artifact_in_place(tampered_identity)
	var rejected_identity: Dictionary = provider._support_index.register_tree_section_geometry_overlay(
		world_id, source_chunk, target_section, artifact.get("expectedSourceIds", []),
		tampered_identity, overlay.get("supportRows", [])) if not tampered_identity.is_empty() else {}
	checks["index_rejects_replaced_band_authority_identity"] = \
		String(rejected_identity.get("reason", "")) \
		== "tree_section_overlay_compile_identity_mismatch"
	var forged_empty_with_real_owners := artifact.duplicate(true)
	if not forged_empty_with_real_owners.is_empty():
		forged_empty_with_real_owners["disposition"] = "complete_empty"
		_freeze_tree_band_artifact_in_place(forged_empty_with_real_owners)
	var rejected_forged_empty: Dictionary = \
		provider._support_index.register_tree_section_geometry_overlay(world_id,
			source_chunk, target_section, artifact.get("expectedSourceIds", []),
			forged_empty_with_real_owners, overlay.get("supportRows", [])) \
		if not forged_empty_with_real_owners.is_empty() else {}
	checks["index_rejects_empty_disposition_when_real_owner_geometry_exists"] = \
		String(rejected_forged_empty.get("reason", "")) \
		== "tree_overlay_artifact_disposition_mismatch" \
		and int(rejected_forged_empty.get("expectedOwnerMemberCount", 0)) > 0 \
		and String(provider._support_index._tree_section_geometry_overlays.get(
			source_chunk, {}).get(target_section, {}).get("compiledArtifactDigest", "")) \
		== String(overlay.get("compiledArtifactDigest", ""))
	var invalid_completion_digest_artifact := artifact.duplicate(true)
	if not invalid_completion_digest_artifact.is_empty():
		invalid_completion_digest_artifact["sourceCompletionDigest"] = "f".repeat(64)
		_freeze_tree_band_artifact_in_place(invalid_completion_digest_artifact)
	var rejected_completion_digest: Dictionary = provider._support_index.register_tree_section_geometry_overlay(
		world_id, source_chunk, target_section, artifact.get("expectedSourceIds", []),
		invalid_completion_digest_artifact, overlay.get("supportRows", [])) \
		if not invalid_completion_digest_artifact.is_empty() else {}
	checks["index_rejects_tampered_real_source_completion_digest"] = \
		String(rejected_completion_digest.get("reason", "")) \
		== "tree_overlay_artifact_completion_digest_mismatch" \
		and String(provider._support_index._tree_section_geometry_overlays.get(
			source_chunk, {}).get(target_section, {}).get("sourceCompletionDigest", "")) \
		== String(overlay.get("sourceCompletionDigest", ""))
	var invalid_owner_payload_digest_artifact := artifact.duplicate(true)
	if not invalid_owner_payload_digest_artifact.is_empty():
		invalid_owner_payload_digest_artifact["ownerBatchPayloadDigest"] = "f".repeat(64)
		_freeze_tree_band_artifact_in_place(invalid_owner_payload_digest_artifact)
	var rejected_owner_payload_digest: Dictionary = provider._support_index.register_tree_section_geometry_overlay(
		world_id, source_chunk, target_section, artifact.get("expectedSourceIds", []),
		invalid_owner_payload_digest_artifact, overlay.get("supportRows", [])) \
		if not invalid_owner_payload_digest_artifact.is_empty() else {}
	checks["index_rejects_tampered_real_owner_payload_digest"] = \
		String(rejected_owner_payload_digest.get("reason", "")) \
		== "tree_overlay_artifact_owner_batch_digest_mismatch" \
		and String(provider._support_index._tree_section_geometry_overlays.get(
			source_chunk, {}).get(target_section, {}).get("ownerBatchPayloadDigest", "")) \
		== String(overlay.get("ownerBatchPayloadDigest", ""))
	var mutated_owner_buffer_result := _mutate_first_tree_band_owner_buffer(artifact)
	var mutated_owner_buffer_artifact: Dictionary = mutated_owner_buffer_result.get(
		"artifact", {})
	var rejected_mutated_owner_buffer: Dictionary = \
		provider._support_index.register_tree_section_geometry_overlay(world_id,
			source_chunk, target_section, artifact.get("expectedSourceIds", []),
			mutated_owner_buffer_artifact, overlay.get("supportRows", [])) \
		if bool(mutated_owner_buffer_result.get("mutated", false)) else {}
	checks["index_rejects_semantically_mutated_real_owner_buffer"] = \
		bool(mutated_owner_buffer_result.get("mutated", false)) \
		and String(rejected_mutated_owner_buffer.get("reason", "")) \
		== "tree_overlay_artifact_owner_batch_digest_mismatch" \
		and String(provider._support_index._tree_section_geometry_overlays.get(
			source_chunk, {}).get(target_section, {}).get("compiledArtifactDigest", "")) \
		== String(overlay.get("compiledArtifactDigest", ""))
	var repeated_compatible_batch: Dictionary = _tree_repeated_compatible_contributor_contract(
		provider, world_id, source_chunk, target_section, artifact,
		overlay.get("supportRows", []))
	checks["compatible_contributor_offsets_cover_batch_union_exactly_once"] = \
		String(repeated_compatible_batch.get("status", "")) == "ready" \
		and int(repeated_compatible_batch.get("contributorCount", 0)) >= 2 \
		and String(repeated_compatible_batch.get("positiveStatus", "")) == "ready" \
		and String(repeated_compatible_batch.get("negativeReason", "")) \
			== "tree_overlay_artifact_contributor_offset_invalid" \
		and bool(repeated_compatible_batch.get("sameSourceRevision", false)) \
		and bool(repeated_compatible_batch.get("distinctMemberIdentities", false)) \
		and bool(repeated_compatible_batch.get("overlayRetained", false))
	var missing_completion := artifact.duplicate(true)
	if not missing_completion.is_empty():
		missing_completion["sourceCompletionManifest"] = []
		_freeze_tree_band_artifact_in_place(missing_completion)
	var rejected_completion: Dictionary = provider._support_index.register_tree_section_geometry_overlay(
		world_id, source_chunk, target_section, artifact.get("expectedSourceIds", []),
		missing_completion, overlay.get("supportRows", [])) if not missing_completion.is_empty() else {}
	checks["index_rejects_missing_real_source_completion_rows"] = \
		String(rejected_completion.get("reason", "")) \
		== "tree_overlay_artifact_source_completion_manifest_incomplete"
	var missing_binding := artifact.duplicate(true)
	if not missing_binding.is_empty():
		var bindings: Dictionary = missing_binding.get("resourceBindings", {}).duplicate()
		if not batches.is_empty():
			var batch_value: Dictionary = batches[0]
			bindings.erase(String(batch_value.get("meshKey", "")))
			bindings.make_read_only()
			missing_binding["resourceBindings"] = bindings
			_freeze_tree_band_artifact_in_place(missing_binding)
	var rejected_binding: Dictionary = provider._support_index.register_tree_section_geometry_overlay(
		world_id, source_chunk, target_section, artifact.get("expectedSourceIds", []),
		missing_binding, overlay.get("supportRows", [])) if not missing_binding.is_empty() \
			and not batches.is_empty() else {}
	checks["index_rejects_removed_real_resource_binding"] = \
		String(rejected_binding.get("reason", "")) \
		== "tree_overlay_artifact_batch_resource_binding_mismatch"
	var source_cache_lifecycle: Dictionary = await _tree_source_artifact_cache_lifecycle_contract(
		queue, provider, main, world_id, source_chunk, target_section,
		support_only_section, source_id, band_jobs, support_band_jobs, overlay, authority)
	checks["detached_consumer_cannot_poll_resurrect_source_job"] = \
		bool(source_cache_lifecycle.get("detachedSourcePollRejected", false))
	checks["canceled_band_consumer_cannot_poll_resurrect_demand"] = \
		bool(source_cache_lifecycle.get("canceledBandPollRejected", false))
	checks["canceling_one_band_preserves_neighbor_band_artifact"] = \
		bool(source_cache_lifecycle.get("neighborBandRemainsReady", false))
	checks["source_cache_eviction_retains_band_and_index_proofs"] = \
		bool(source_cache_lifecycle.get("sourceCacheEvicted", false)) \
		and bool(source_cache_lifecycle.get("bandArtifactRemainsReady", false)) \
		and bool(source_cache_lifecycle.get("indexOverlayRemainsCurrent", false))
	checks["source_artifact_value_graph_retires_off_main_after_ack"] = \
		bool(source_cache_lifecycle.get("sourceValueRetirementReleasedOffMain", false))
	checks["partial_source_compiler_cancel_detaches_refcounted_handle_until_ack"] = \
		bool(source_cache_lifecycle.get("partialCompilerCanceledThroughRetirement", false)) \
		and bool(source_cache_lifecycle.get("sourceHandleHeldUntilAck", false))
	checks["legacy_body_unload_transfers_partial_compiler_values"] = \
		bool(source_cache_lifecycle.get("legacyBodyUnloadRetiredOffMain", false)) \
		and bool(source_cache_lifecycle.get("legacyRetirementDiagnostics", {}).get(
			"sealedActiveRecordPreserved", false))
	var over_capacity_projection: Dictionary = await \
		_tree_band_over_capacity_projection_contract(queue, band_jobs[0], source_id) \
		if not band_jobs.is_empty() else {"status":"skipped_missing_real_band_job",
			"reason":"real_tree_band_handoff_not_ready"}
	checks["band_projection_resumes_source_admission_above_cache_capacity"] = \
		String(over_capacity_projection.get("status", "")) == "ready" \
		and bool(over_capacity_projection.get("capacityPressureObserved", false)) \
		and bool(over_capacity_projection.get("allCapacitySlotsPinned", false)) \
		and bool(over_capacity_projection.get("exactCapacitySlotReleased", false)) \
		and bool(over_capacity_projection.get("realSourceRecordAdmittedAfterRelease", false)) \
		and bool(over_capacity_projection.get("cancelledRecipeReadmissionSafe", false)) \
		and bool(over_capacity_projection.get("projectionComplete", false)) \
		and int(over_capacity_projection.get("expectedUniqueSourceCount", 0)) \
			== TreeQueueScript.MAX_ECOLOGY_SOURCE_COMPILE_JOBS + 1 \
		and int(over_capacity_projection.get("capturedSourceArtifactCount", 0)) \
			== int(over_capacity_projection.get("expectedUniqueSourceCount", -1)) \
		and int(over_capacity_projection.get("sourceCachePeakCount", 0)) \
			<= TreeQueueScript.MAX_ECOLOGY_SOURCE_COMPILE_JOBS
	var provider_scheduler_before_cleanup: Dictionary = \
		provider.source_capture_scheduler_snapshot()
	var tree_queue_rows: Array[Dictionary] = []
	for job_key_value: Variant in queue.ecology_tree_band_compile_order:
		var queued_job: Dictionary = queue.ecology_tree_band_compile_jobs.get(
			String(job_key_value), {})
		if queued_job.is_empty() or queued_job.get("sourceChunkKey", null) != source_chunk \
				or queued_job.get("sectionKey", null) not in [target_section, support_only_section]:
			continue
		var queued_compiler: Object = queued_job.get("compiler")
		var compiler_progress: Dictionary = queued_compiler.progress_snapshot() \
			if is_instance_valid(queued_compiler) and queued_compiler.has_method("progress_snapshot") else {}
		var queued_artifact: Dictionary = queue._tree_artifact_holder_view(
			queued_job.get("artifactHolder", {}))
		var queued_consumers: Variant = queued_job.get("consumers", {})
		var queue_row := {"jobKey":String(job_key_value),
			"sourceChunkKey":queued_job.get("sourceChunkKey", Vector2i.ZERO),
			"sectionKey":queued_job.get("sectionKey", Vector3i.ZERO),
			"status":String(queued_job.get("status", "")),
			"reason":String(queued_job.get("reason", "")),
			"expectedSourceCount":(queued_job.get("expectedSourceIds", []) as Array).size(),
			"consumerCount":queued_consumers.size() if queued_consumers is Dictionary else 0,
			"artifactSchema":String(queued_artifact.get("schema", "")),
			"artifactDisposition":String(queued_artifact.get("disposition", "")),
			"compilerProgress":compiler_progress}
		tree_queue_rows.append(queue_row)
		if tree_queue_rows.size() >= 8:
			break
	var tree_queue_before_cleanup := {"pendingOrderCount":queue.ecology_tree_band_compile_order.size(),
		"matchingJobs":tree_queue_rows}
	# This fixture mutates its own publication context to prove scope semantics.
	# Run it only after every assertion that depends on the real handoff authority.
	var catalog_scope_checks := _fixture_catalog_scope_contract(main, world_id,
		source_chunk)
	for check_name: Variant in catalog_scope_checks:
		checks[String(check_name)] = bool(catalog_scope_checks[check_name])
	helper_timings["negativeChecksMsec"] = Time.get_ticks_msec() - helper_stage_msec
	helper_stage_msec = Time.get_ticks_msec()
	print("TREE_HANDOFF_TIMING stage=negative_checks elapsed_msec=",
		helper_timings["negativeChecksMsec"], " run_elapsed_msec=",
		Time.get_ticks_msec() - _contract_run_started_msec)
	queue.reset_ecology_source_compilers()
	main.free()
	helper_timings["cleanupMsec"] = Time.get_ticks_msec() - helper_stage_msec
	helper_timings["totalMsec"] = Time.get_ticks_msec() - helper_started_msec
	print("TREE_HANDOFF_TIMING stage=cleanup elapsed_msec=",
		helper_timings["cleanupMsec"], " total_msec=", helper_timings["totalMsec"],
		" run_elapsed_msec=", Time.get_ticks_msec() - _contract_run_started_msec)
	return {"status":"ready" if checks.values().all(func(value: bool) -> bool: return value) \
		else "failed", "checks":checks, "capture":capture, "timings":helper_timings,
		"providerSchedulerBeforeCleanup":provider_scheduler_before_cleanup,
		"treeQueueBeforeCleanup":tree_queue_before_cleanup,
		"sourceId":source_id, "targetSection":target_section,
		"supportOnlySection":support_only_section,
		"captureElapsedMsec":capture_elapsed_msec,
		"sourceRowSupportProofStatus":String(support_proof.get("status", "")),
		"recipeSupportEnvelopeStatus":String(envelope.get("status", "")),
		"authorityDigest":String(authority.get("authorityDigest", "")),
		"artifactSchema":String(artifact.get("schema", "")),
		"artifactDisposition":String(artifact.get("disposition", "")),
		"nativeTreePackAcceptedInstances":int(native_source_artifact_proof.get(
			"nativeTreePackAcceptedInstances", 0)),
		"nativeSourcePackAcceptedInstances":int(native_source_artifact_proof.get(
			"nativeTreePackAcceptedInstances", 0)),
		"batchCount":batches.size(),
		"sourceCompletionCount":artifact.get("sourceCompletionManifest", []).size(),
		"overlaySupportMemberCount":int(overlay.get("supportMemberCount", 0)),
		"overlayOwnerMemberCount":int(overlay.get("ownerMemberCount", 0)),
		"supportOnlyOverlaySupportMemberCount":int(support_only_overlay.get("supportMemberCount", 0)),
		"supportOnlyArtifactDisposition":String(support_only_artifact.get("disposition", "")),
		"supportOnlyArtifactExpectedSourceCount":(support_only_artifact.get(
			"expectedSourceIds", []) as Array).size(),
		"supportOnlyCompletionOwnerCount":int(support_only_completion.get(
			"ownerMemberCount", -1)),
		"supportOnlyCompletionSupportCount":int(support_only_completion.get(
			"supportMemberCount", 0)),
		"primaryCandidateStatus":String(primary_candidate.get("status", "")),
		"primaryCandidateInputCount":int(primary_candidate.get("inputCount", 0)),
		"supportOnlyCandidateStatus":String(support_only_candidate.get("status", "")),
		"supportOnlyCandidateInputCount":int(support_only_candidate.get("inputCount", -1)),
		"supportOnlySelectionStatus":String(support_only_selection.get("status", "")),
		"supportOnlySelectionReason":String(support_only_selection.get("reason", "")),
		"supportOnlySelectionCandidates":support_only_selection.get("candidates", []),
		"supportOnlySectionOwnerDistribution":support_only_selection.get(
			"sectionOwnerDistribution", []),
		"primaryContributionStatus":String(primary_contribution.get("status", "")),
		"primaryContributionReason":String(primary_contribution.get("reason", "")),
		"primaryContributionKeys":_bounded_dictionary_keys(primary_contribution, 12),
		"primaryProviderContributionSummary":_provider_contribution_summary(
			primary_contribution),
		"primaryContributionStalenessDiagnostic":_tree_contribution_staleness_diagnostic(
			provider, capture, target_section, primary_contribution),
		"primaryCandidateReason":String(primary_candidate.get("reason", "")),
		"primaryCandidateKeys":_bounded_dictionary_keys(primary_candidate, 12),
		"treeBufferHandoff":tree_buffer_handoff,
		"treeBufferCountGuard":tree_buffer_count_guard,
		"supportOnlyContributionStatus":String(support_only_contribution.get("status", "")),
		"supportOnlyContributionReason":String(support_only_contribution.get("reason", "")),
		"supportOnlyProviderContributionSummary":_provider_contribution_summary(
			support_only_contribution),
		"supportOnlyContributionStalenessDiagnostic":_tree_contribution_staleness_diagnostic(
			provider, capture, support_only_section, support_only_contribution),
		"supportOnlyCandidateReason":String(support_only_candidate.get("reason", "")),
		"supportOnlyCandidateKeys":_bounded_dictionary_keys(support_only_candidate, 12),
		"supportOnlyOverlayOwnerMemberCount":int(support_only_overlay.get("ownerMemberCount", -1)),
		"supportOnlyOverlayDisposition":String(support_only_overlay.get("supportDisposition", "")),
		"supportOnlyRangeFound":support_only_has_tree_range,
		"sourceBandRevisionDiagnostics":source_band_revision_diagnostics,
		"sourceBandRevisionInputComparison":source_band_revision_input_comparison,
		"nativeSourceArtifactProof":native_source_artifact_proof,
		"recipeContentIdentityContract":recipe_identity_probe,
		"bandSliceDiagnostics":band_slice_diagnostics,
		"supportIndexBandProfile":support_index_band_profile,
		"repeatedCompatibleContributorBatch":repeated_compatible_batch,
		"bandSlicePrepareCalls":band_slice_prepare_calls,
		"bandSliceResolveCalls":band_slice_resolve_calls,
		"bandSliceExactAliasResolutions":band_slice_exact_alias_resolutions,
		"firstFailedBandJob":first_failed_band_job,
		"queueCurrentness":queue_currentness,
		"identityRejection":rejected_identity,
		"completionRejection":rejected_completion,
		"mutatedOwnerBufferResult":mutated_owner_buffer_result,
		"mutatedOwnerBufferRejection":rejected_mutated_owner_buffer,
		"resourceBindingRejection":rejected_binding,
		"sourceArtifactCacheLifecycle":source_cache_lifecycle,
		"overCapacityProjection":over_capacity_projection,
		"preparationFailureDiagnostic":preparation_failure_diagnostic,
		"supportSetDiagnostic":support_set_diagnostic}


func _tree_source_compiler_partial_resource(queue: Object, job_key: String) -> Dictionary:
	var source_job: Dictionary = queue.ecology_source_compile_jobs.get(job_key, {})
	var compiler: Object = source_job.get("compiler") as Object
	if not is_instance_valid(compiler): return {"observed":false}
	var compiler_job: Variant = compiler.get("_job")
	if not compiler_job is Dictionary: return {"observed":false}
	for field: String in ["factory", "nativeTreeGeometryDispatcher"]:
		var direct_value: Variant = compiler_job.get(field, null)
		if direct_value is RefCounted and is_instance_valid(direct_value):
			return {"observed":true, "field":"job.%s" % field,
				"type":direct_value.get_class(), "reference":weakref(direct_value)}
	for state_key: String in ["buildState", "compileState", "roleValues"]:
		var state_value: Variant = compiler_job.get(state_key, null)
		if not state_value is Dictionary: continue
		for field_value: Variant in state_value:
			var field := String(field_value)
			var field_item: Variant = state_value[field_value]
			if field_item is Dictionary:
				for nested_key: String in ["surface", "mesh", "multiMesh", "material",
						"nativeDispatcher", "nativePackDispatcher"]:
					var nested_value: Variant = field_item.get(nested_key, null)
					if nested_value is RefCounted and is_instance_valid(nested_value):
						return {"observed":true, "field":"%s.%s.%s" % [
							state_key, field, nested_key], "type":nested_value.get_class(),
							"reference":weakref(nested_value)}
			if field_item is RefCounted and is_instance_valid(field_item):
				return {"observed":true, "field":"%s.%s" % [state_key, field],
					"type":field_item.get_class(), "reference":weakref(field_item)}
	return {"observed":false}


func _tree_retirement_contains_weakref(owner: Object, reference: WeakRef) -> bool:
	if not is_instance_valid(owner) or reference == null: return false
	var expected: Object = reference.get_ref() as Object
	if not is_instance_valid(expected): return false
	for state_value: Variant in owner._outstanding:
		if not is_instance_valid(state_value): continue
		for keepalive_value: RefCounted in state_value.main_refcounted_keepalives:
			if is_same(keepalive_value, expected): return true
	return false


func _tree_prepare_legacy_body_retirement(queue: Object, owner: Object) -> Dictionary:
	var saved_compiler: Object = queue.tree_recipe_section_compiler
	var probe: Object = TreeCompilerScript.new()
	var body := StaticBody3D.new()
	var surface := SurfaceTool.new()
	var body_reference: WeakRef = weakref(body)
	var surface_reference: WeakRef = weakref(surface)
	var input: Dictionary = {"sourceId":"synthetic-legacy-retirement",
		"body":body_reference, "sealedPayload":{"sample":Vector3.ONE}}
	input.sealedPayload.make_read_only()
	input.make_read_only()
	probe._job = {"status":"pending", "mode":"legacy_section",
		"records":[input], "buildState":{"surface":surface,
			"stage":"synthetic_partial"}, "compileState":{}, "roleValues":{},
		"sectionBatches":{}, "bindings":{}, "manifest":[]}
	queue.tree_recipe_section_compiler = probe
	var sealed_active_record: Dictionary = {
		"bodyInstanceId":body.get_instance_id(), "body":body_reference,
		"sourceId":"synthetic-legacy-retirement"}
	sealed_active_record.make_read_only()
	queue.active_tree_section_compile_record = sealed_active_record
	queue._remove_tree_section_recipe_input_record_for_body(body)
	var queued: bool = queue.legacy_tree_compiler_retirement_pending \
		and queue._advance_legacy_tree_compiler_retirement()
	var state: Variant = owner._outstanding.back() \
		if queued and not owner._outstanding.is_empty() else null
	var record_excludes_body: bool = false
	if state is Object:
		for root_value: Variant in state.value_roots:
			if not root_value is Dictionary: continue
			var records_value: Variant = root_value.get("records", null)
			if records_value is Array and not records_value.is_empty() \
					and records_value[0] is Dictionary:
				record_excludes_body = not records_value[0].has("body")
	var surface_held_until_ack: bool = queued \
		and _tree_retirement_contains_weakref(owner, surface_reference)
	var sealed_active_record_preserved: bool = \
		String(sealed_active_record.get("sourceId", "")) == "synthetic-legacy-retirement" \
		and sealed_active_record.is_read_only() \
		and queue.active_tree_section_compile_record.is_empty()
	queue.tree_recipe_section_compiler = saved_compiler
	queue.active_tree_section_compile_record = {}
	body.free()
	# This frame owns the only fixture SurfaceTool alias; returning leaves only
	# the retirement state's Main keepalive and the caller's WeakRef.
	surface = null
	return {"queued":queued, "recordExcludesBody":record_excludes_body,
		"surfaceHeldUntilAck":surface_held_until_ack,
		"sealedActiveRecordPreserved":sealed_active_record_preserved,
		"surfaceReference":surface_reference}


func _tree_source_artifact_cache_lifecycle_contract(queue: Object,
		provider: Adapter, main: Object, world_id: String, source_chunk: Vector2i,
		target_section: Vector3i, support_section: Vector3i, source_id: String,
		target_jobs: Array[Dictionary], support_jobs: Array[Dictionary],
		target_overlay: Dictionary, target_authority: Dictionary) -> Dictionary:
	if target_jobs.is_empty() or support_jobs.is_empty():
		return {"status":"failed", "reason":"neighboring_band_jobs_unavailable"}
	var target_job: Dictionary = target_jobs[0]
	var support_job: Dictionary = support_jobs[0]
	var target_consumers: Array = target_job.get("consumers", {}).keys()
	var support_consumers: Array = support_job.get("consumers", {}).keys()
	if target_consumers.is_empty() or support_consumers.is_empty():
		return {"status":"failed", "reason":"neighboring_band_consumers_unavailable"}
	var target_token := String(target_consumers[0])
	var support_token := String(support_consumers[0])
	var source_job_key := String(target_job.get("recordJobKeys", {}).get(source_id, ""))
	var source_job: Dictionary = queue.ecology_source_compile_jobs.get(source_job_key, {})
	if source_job_key.is_empty() or source_job.is_empty():
		return {"status":"failed", "reason":"source_record_cache_entry_unavailable"}
	var source_consumer_token := "tree-band-source:%s:%s" % [
		queue._source_recipe_digest([String(target_job.get("key", "")), target_token, source_id]),
		source_id]
	var source_snapshot: Dictionary = target_job.get("snapshot", {})
	var source_view: Dictionary = target_job.get("publicationView", {})
	var source_record: Dictionary = target_job.get("recordsById", {}).get(source_id, {})
	var explicitly_attached: Dictionary = queue.request_ecology_tree_source_record_compile(main,
		source_snapshot, source_record, source_view, source_consumer_token, INF)
	var attached_source_job: Dictionary = queue.ecology_source_compile_jobs.get(source_job_key, {})
	var attached_before_cancel: bool = attached_source_job.get("consumers", {}).has(
		source_consumer_token)
	queue.cancel_ecology_tree_source_compile(source_job_key, source_consumer_token)
	var detached_poll: Dictionary = queue.poll_ecology_tree_source_record_compile(
		source_job_key, source_consumer_token)
	queue.cancel_ecology_tree_source_band_compile(String(target_job.get("key", "")),
		target_token)
	var canceled_band_poll: Dictionary = queue.poll_ecology_tree_source_band_compile(
		String(target_job.get("key", "")), target_token)
	var neighbor_poll: Dictionary = queue.poll_ecology_tree_source_band_compile(
		String(support_job.get("key", "")), support_token)
	var source_cache_evicted: bool = false
	var index_current: bool = false
	var owner: Object = queue.tree_value_retirement_owner
	var retirement_before: Dictionary = owner.snapshot()
	var retirement_completed_before := int(retirement_before.get("completedCount", 0))
	var overlay_lease: Dictionary = provider._support_index._tree_overlay_publication_leases \
		.get(source_chunk, {}).get(target_section, {})
	if String(explicitly_attached.get("jobKey", "")) == source_job_key \
			and attached_before_cancel \
			and String(detached_poll.get("status", "")) == "failed" \
			and String(detached_poll.get("reason", "")) \
				== "tree_source_record_consumer_not_attached" \
			and String(canceled_band_poll.get("status", "")) == "failed" \
			and String(canceled_band_poll.get("reason", "")) \
				== "tree_source_band_consumer_not_attached" \
			and String(neighbor_poll.get("status", "")) == "ready":
		var cache_job: Dictionary = queue.ecology_source_compile_jobs.get(source_job_key, {})
		if String(cache_job.get("artifactKind", "")) == "tree_source_record_geometry" \
				and String(cache_job.get("status", "")) == "complete" \
				and cache_job.get("consumers", {}).is_empty() \
				and is_same(cache_job.get("resultHolder", {}),
					support_job.get("sourceArtifactsById", {}).get(source_id, {})):
			source_cache_evicted = queue._retire_tree_source_cache_job(source_job_key,
				cache_job)
		var current_overlay: Dictionary = provider._support_index._tree_section_geometry_overlays \
			.get(source_chunk, {}).get(target_section, {})
		index_current = provider._support_index._tree_section_overlay_current(
			target_authority, current_overlay, overlay_lease, world_id,
			source_chunk, target_section)
	var neighbor_after_eviction: Dictionary = queue.poll_ecology_tree_source_band_compile(
		String(support_job.get("key", "")), support_token)
	var source_retirement_drain: Dictionary = owner.drain() if source_cache_evicted else {}
	var source_retirement_after: Dictionary = owner.snapshot()
	var source_retirement_last: Dictionary = source_retirement_after.get("last", {})
	var source_value_retired_off_main := source_cache_evicted \
		and String(source_retirement_drain.get("status", "")) == "ready" \
		and int(source_retirement_after.get("completedCount", 0)) \
			> retirement_completed_before \
		and int(source_retirement_last.get("releasedOnThread", \
			OS.get_thread_caller_id())) != OS.get_thread_caller_id()
	var was_processing: bool = queue.is_processing()
	queue.set_process(false)
	var cancel_consumer := "tree-retirement-inflight-cancel:" + source_id
	var cancel_request: Dictionary = queue.request_ecology_tree_source_record_compile(main,
		support_job.get("snapshot", {}), support_job.get("recordsById", {}).get(source_id, {}),
		support_job.get("publicationView", {}), cancel_consumer, INF)
	var cancel_job_key := String(cancel_request.get("jobKey", ""))
	var partial_compiler_observed := false
	var source_partial_handle_reference: WeakRef
	var source_partial_handle_field := ""
	var source_partial_handle_type := ""
	var canceled_compiler_resource_retained := false
	var source_lifecycle_frames := 0
	for _advance_index in range(600):
		source_lifecycle_frames = _advance_index + 1
		queue._process(0.0)
		if cancel_job_key.is_empty() or not queue.ecology_source_compile_jobs.has(cancel_job_key):
			break
		var partial_handle: Dictionary = _tree_source_compiler_partial_resource(
			queue, cancel_job_key)
		if bool(partial_handle.get("observed", false)):
			source_partial_handle_reference = partial_handle.get("reference", null) as WeakRef
			source_partial_handle_field = String(partial_handle.get("field", ""))
			source_partial_handle_type = String(partial_handle.get("type", ""))
			partial_compiler_observed = true
			break
		var current_source_job: Dictionary = queue.ecology_source_compile_jobs.get(
			cancel_job_key, {})
		if String(current_source_job.get("status", "")) in ["complete", "failed"]:
			break
		await process_frame
	var pending_before_cancel: Dictionary = queue.ecology_source_compile_jobs.get(cancel_job_key, {})
	var compiler_before_cancel: Object = pending_before_cancel.get("compiler") as Object
	var compiler_pending_before_cancel: bool = is_instance_valid(compiler_before_cancel) \
		and String(pending_before_cancel.get("status", "")) in ["queued", "active"]
	if not cancel_job_key.is_empty():
		queue.cancel_ecology_tree_source_compile(cancel_job_key, cancel_consumer)
		var handle_in_keepalives: bool = _tree_retirement_contains_weakref(
			owner, source_partial_handle_reference)
		canceled_compiler_resource_retained = partial_compiler_observed \
			and source_partial_handle_reference != null \
			and source_partial_handle_reference.get_ref() != null \
			and handle_in_keepalives
		var canceled_job_absent: bool = not queue.ecology_source_compile_jobs.has(cancel_job_key)
		var canceled_poll: Dictionary = queue.poll_ecology_tree_source_record_compile(
			cancel_job_key, cancel_consumer)
		var cancel_drain: Dictionary = owner.drain()
		var canceled_handle_released: bool = source_partial_handle_reference == null \
			or source_partial_handle_reference.get_ref() == null
		partial_compiler_observed = compiler_pending_before_cancel \
			and canceled_job_absent \
			and String(canceled_poll.get("reason", "")) \
			== "tree_source_record_compile_job_missing" \
			and String(cancel_drain.get("status", "")) == "ready"
		canceled_compiler_resource_retained = canceled_compiler_resource_retained \
			and canceled_handle_released
	else:
		partial_compiler_observed = false
	var legacy_owner_completed_before := int(owner.snapshot().get("completedCount", 0))
	var legacy_setup: Dictionary = _tree_prepare_legacy_body_retirement(queue, owner)
	var legacy_unload_queued: bool = bool(legacy_setup.get("queued", false))
	var legacy_unload_drain: Dictionary = owner.drain() if legacy_unload_queued else {}
	var legacy_surface_reference: WeakRef = legacy_setup.get("surfaceReference", null) as WeakRef
	var legacy_surface_released: bool = legacy_surface_reference == null \
		or legacy_surface_reference.get_ref() == null
	var legacy_retirement_after: Dictionary = owner.snapshot()
	var legacy_retirement_last: Dictionary = legacy_retirement_after.get("last", {})
	var legacy_surface_released_off_main: bool = legacy_surface_released \
		and int(legacy_retirement_after.get("completedCount", 0)) > legacy_owner_completed_before \
		and int(legacy_retirement_last.get("releasedOnThread", \
			OS.get_thread_caller_id())) != OS.get_thread_caller_id()
	queue.set_process(was_processing)
	return {"status":"ready" if source_cache_evicted and index_current \
			and String(neighbor_after_eviction.get("status", "")) == "ready" else "failed",
		"detachedSourcePollRejected":String(detached_poll.get("reason", "")) \
			== "tree_source_record_consumer_not_attached",
		"canceledBandPollRejected":String(canceled_band_poll.get("reason", "")) \
			== "tree_source_band_consumer_not_attached",
		"neighborBandRemainsReady":String(neighbor_poll.get("status", "")) == "ready" \
			and String(neighbor_after_eviction.get("status", "")) == "ready",
		"sourceCacheEvicted":source_cache_evicted,
		"sourceValueRetirementReleasedOffMain":source_value_retired_off_main,
		"sourceRetirementDrain":source_retirement_drain,
		"partialCompilerCanceledThroughRetirement":partial_compiler_observed,
		"sourceHandleHeldUntilAck":canceled_compiler_resource_retained,
		"sourcePartialHandleField":source_partial_handle_field,
		"sourcePartialHandleType":source_partial_handle_type,
		"sourceLifecycleFrames":source_lifecycle_frames,
		"legacyBodyUnloadRetiredOffMain":legacy_unload_queued \
			and bool(legacy_setup.get("recordExcludesBody", false)) \
			and bool(legacy_setup.get("surfaceHeldUntilAck", false)) \
			and bool(legacy_setup.get("sealedActiveRecordPreserved", false)) \
			and legacy_surface_released_off_main \
			and String(legacy_unload_drain.get("status", "")) == "ready",
		"legacyRetirementDiagnostics":{"queued":legacy_unload_queued,
			"recordExcludesBody":bool(legacy_setup.get("recordExcludesBody", false)),
			"surfaceHeldUntilAck":bool(legacy_setup.get("surfaceHeldUntilAck", false)),
			"sealedActiveRecordPreserved":bool(legacy_setup.get(
				"sealedActiveRecordPreserved", false)),
			"surfaceReleased":legacy_surface_released,
			"releasedOnWorker":legacy_surface_released_off_main,
			"drainStatus":String(legacy_unload_drain.get("status", "")),
			"releaseThreadId":int(legacy_retirement_last.get("releasedOnThread", -1)),
			"mainThreadId":OS.get_thread_caller_id()},
		"cancelRequestStatus":String(cancel_request.get("status", "")),
		"cancelRequestReason":String(cancel_request.get("reason", "")),
		"bandArtifactRemainsReady":String(neighbor_after_eviction.get("status", "")) == "ready",
		"indexOverlayRemainsCurrent":index_current,
		"explicitAttachStatus":String(explicitly_attached.get("status", "")),
		"detachedSourcePoll":detached_poll,
		"canceledBandPoll":canceled_band_poll,
		"neighborPoll":neighbor_after_eviction}


func _tree_cancelled_recipe_readmission_contract(queue: Object, main: Object,
		base_job: Dictionary, source_id: String) -> Dictionary:
	var artifact_map: Variant = base_job.get("sourceArtifactsById", null)
	var holder: Variant = artifact_map.get(source_id, null) if artifact_map is Dictionary else null
	var compiler_roots: Variant = holder.get("compilerValueRoots", {}) \
		if holder is Dictionary else {}
	var records_value: Variant = compiler_roots.get("records", []) \
		if compiler_roots is Dictionary else []
	var prepared_record: Dictionary = {}
	if records_value is Array:
		for record_value: Variant in records_value:
			if record_value is Dictionary \
					and String(record_value.get("sourceId", "")) == source_id:
				prepared_record = record_value
				break
	var publication_view: Dictionary = base_job.get("publicationView", {})
	if prepared_record.is_empty() or not is_instance_valid(main) \
			or not is_same(prepared_record.get("sourceProvenance", null),
				publication_view.get("payload", {})):
		return {"passed":false, "reason":"cancel_readmission_fixture_inputs_missing"}
	var base_request: Dictionary = prepared_record.get("request", {})
	var request_input: Dictionary = base_request.duplicate(true)
	request_input["worldRotationY"] = float(request_input.get("worldRotationY", 0.0)) + 0.001
	var request_service := TreeSpawnServiceScript.new()
	var request: Dictionary = request_service.normalize_request(request_input)
	if request.is_empty():
		return {"passed":false, "reason":"cancel_readmission_probe_request_invalid"}
	var request_digest: String = queue._source_recipe_digest(request)
	var record_digest := String(prepared_record.get("sourceRecordDigest", ""))
	var provenance_digest := String(publication_view.get("contentDigest", ""))
	var key: String = queue._source_recipe_job_key(source_id,
		String(prepared_record.get("sourceRevision", "")),
		String(prepared_record.get("producerRevision", "")), request_digest,
		record_digest, provenance_digest) + "|owner:" + str(main.get_instance_id()) \
		+ "|publication:" + String(publication_view.get("publicationId", ""))
	var old_job: Variant = queue.source_recipe_jobs.get(key, null)
	var old_completed: Variant = queue.source_recipe_completed.get(key, null)
	var old_pending_order: Array[String] = queue.source_recipe_pending_order.duplicate()
	var old_completed_order: Array[String] = queue.source_recipe_completed_order.duplicate()
	for worker_value: Variant in queue.source_recipe_workers:
		if worker_value is Dictionary and String(worker_value.get("key", "")) == key:
			return {"passed":false, "reason":"cancel_readmission_recipe_worker_already_active"}
	queue.source_recipe_jobs.erase(key)
	queue.source_recipe_completed.erase(key)
	queue.source_recipe_pending_order.erase(key)
	queue.source_recipe_completed_order.erase(key)
	var canceled_task: Dictionary = {"key":key, "main":weakref(main),
		"sourceId":source_id, "sourceRevision":String(prepared_record.get(
			"sourceRevision", "")), "producerRevision":String(prepared_record.get(
			"producerRevision", "")), "request":request,
		"record":prepared_record.get("sourceRecord", {}),
		"provenance":prepared_record.get("sourceProvenance", {}),
		"status":"cancelled", "cancelled":true, "consumers":{},
		"publicationLeaseToken":""}
	queue.source_recipe_jobs[key] = canceled_task
	queue.source_recipe_workers.append({"key":key, "thread":null})
	var replacement_consumer: String = "cancel-readmission-replacement:%s" % source_id
	var during_drain: Dictionary = queue.request_ecology_source_recipe(main,
		prepared_record.get("sourceRecord", {}), prepared_record.get("sourceProvenance", {}),
		request, replacement_consumer, publication_view)
	var job_during_drain: Dictionary = queue.source_recipe_jobs.get(key, {})
	var rejected_canceled_owner: bool = \
		String(during_drain.get("status", "")) == "pending" \
		and String(during_drain.get("reason", "")) \
			== "ecology_tree_recipe_cancellation_draining" \
		and String(during_drain.get("jobKey", "")).is_empty() \
		and job_during_drain.get("cancelled", false) \
		and job_during_drain.get("consumers", {}).is_empty()
	queue.source_recipe_workers.pop_back()
	queue._retire_source_recipe_job(key)
	var retried: Dictionary = queue.request_ecology_source_recipe(main,
		prepared_record.get("sourceRecord", {}), prepared_record.get("sourceProvenance", {}),
		request, replacement_consumer, publication_view)
	var fresh_job: Dictionary = queue.source_recipe_jobs.get(key, {})
	var fresh_incarnation_admitted: bool = \
		String(retried.get("status", "")) == "pending" \
		and String(retried.get("jobKey", "")) == key \
		and not fresh_job.is_empty() \
		and not bool(fresh_job.get("cancelled", true)) \
		and bool(fresh_job.get("consumers", {}).get(replacement_consumer, false))
	if fresh_incarnation_admitted:
		queue.cancel_ecology_source_recipe(key, replacement_consumer)
	queue.source_recipe_jobs.erase(key)
	queue.source_recipe_completed.erase(key)
	queue.source_recipe_pending_order.erase(key)
	queue.source_recipe_completed_order.erase(key)
	if old_job is Dictionary:
		queue.source_recipe_jobs[key] = old_job
	if old_completed is Dictionary:
		queue.source_recipe_completed[key] = old_completed
	queue.source_recipe_pending_order = old_pending_order
	queue.source_recipe_completed_order = old_completed_order
	return {"passed":rejected_canceled_owner and fresh_incarnation_admitted,
		"sameKey":key, "cancelledRequestReason":String(during_drain.get("reason", "")),
		"cancelledRequestHasNoJobKey":String(during_drain.get("jobKey", "")).is_empty(),
		"cancelledTaskConsumersStayEmpty":job_during_drain.get("consumers", {}).is_empty(),
		"freshIncarnationAdmitted":fresh_incarnation_admitted,
		"freshTaskCanceled":bool(fresh_job.get("cancelled", false))}


func _tree_band_over_capacity_projection_contract(queue: Object,
		base_job: Dictionary, live_source_id: String) -> Dictionary:
	var capacity := TreeQueueScript.MAX_ECOLOGY_SOURCE_COMPILE_JOBS
	var main_ref: WeakRef = base_job.get("main") as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	var live_record: Dictionary = base_job.get("recordsById", {}).get(live_source_id, {})
	if capacity < 1 or not is_instance_valid(main) or live_record.is_empty():
		return {"status":"failed", "reason":"over_capacity_fixture_authority_missing"}
	var canceled_recipe_readmission: Dictionary = \
		_tree_cancelled_recipe_readmission_contract(queue, main, base_job, live_source_id)
	var expected_ids: Array[String] = []
	var captured_artifacts: Dictionary = {}
	var filler_source_ids: Array[String] = []
	var existing_pin_tokens: Dictionary = {}
	var prior_live_job_keys: Array[String] = []
	for source_key_value: Variant in queue.ecology_source_compile_jobs.keys():
		var source_key := String(source_key_value)
		var existing_job: Dictionary = queue.ecology_source_compile_jobs.get(source_key, {})
		if String(existing_job.get("artifactKind", "")) == "tree_source_record_geometry" \
				and String(existing_job.get("sourceId", "")) == live_source_id:
			if not existing_job.get("consumers", {}).is_empty():
				return {"status":"failed", "reason":"over_capacity_live_source_is_pinned"}
			prior_live_job_keys.append(source_key)
	for prior_key: String in prior_live_job_keys:
		var prior_job: Dictionary = queue.ecology_source_compile_jobs.get(prior_key, {})
		if not queue._retire_tree_source_cache_job(prior_key, prior_job):
			return {"status":"failed", "reason":"over_capacity_live_source_retirement_blocked"}
	var existing_cache_count := int(queue.ecology_source_compile_jobs.size())
	if existing_cache_count > capacity:
		return {"status":"failed", "reason":"over_capacity_existing_cache_exceeds_bound",
			"existingCacheCount":existing_cache_count, "capacity":capacity}
	for index in range(capacity):
		var filler_id := "synthetic-over-capacity-tree:%03d" % index
		filler_source_ids.append(filler_id)
		expected_ids.append(filler_id)
		var record_digest := ProducerDomain.digest_value(["synthetic-source-record", filler_id])
		var source_manifest := {"sourceId":filler_id,
			"sourceRecordDigest":record_digest,
			"recipeArtifactRevision":"synthetic-recipe-revision",
			"recipeSignature":"synthetic-recipe-signature",
			"sourceRevision":String(base_job.get("snapshot", {}).get(
				"sourceRevision", "")),
			"geometryOwnership":[]}
		var source_artifact := {"status":"ready",
			"schema":CompiledTreeSectionArtifact.SOURCE_RECORD_GEOMETRY_SCHEMA,
			"worldId":String(base_job.get("snapshot", {}).get("worldId", "")),
			"sourceChunkKey":base_job.get("snapshot", {}).get("sourceChunkKey", Vector2i.ZERO),
			"sourceRevision":String(base_job.get("snapshot", {}).get("sourceRevision", "")),
			"treeFamilyRevision":String(base_job.get("publicationView", {}) \
				.get("familyResultsById", {}).get("trees", {}).get("familyRevision", "")),
			"treeFamilyManifestDigest":String(base_job.get("publicationView", {}) \
				.get("familyResultsById", {}).get("trees", {}).get("sourceManifestDigest", "")),
			"sourceId":filler_id, "sourceRecordDigest":record_digest,
			"sourceArtifactDigest":ProducerDomain.digest_value([
				"synthetic-source-artifact", filler_id]),
			"sources":[source_manifest], "batches":[], "resourceBindings":{}}
		_freeze_tree_band_artifact_in_place(source_artifact)
		captured_artifacts[filler_id] = queue._tree_artifact_holder(source_artifact)
	expected_ids.append(live_source_id)
	expected_ids.sort()
	var filler_cache_keys: Array[String] = []
	var filler_consumer_tokens: Dictionary = {}
	for source_key_value: Variant in queue.ecology_source_compile_jobs.keys():
		var source_key := String(source_key_value)
		var existing_job: Dictionary = queue.ecology_source_compile_jobs.get(source_key, {})
		if String(existing_job.get("status", "")) != "complete": continue
		var pin_token := "synthetic-existing-cache-pin:" + source_key
		var consumers: Dictionary = existing_job.get("consumers", {})
		consumers[pin_token] = true
		existing_job["consumers"] = consumers
		queue.ecology_source_compile_jobs[source_key] = existing_job
		existing_pin_tokens[source_key] = pin_token
	var filler_count := capacity - existing_cache_count
	for index in range(filler_count):
		var filler_key := "synthetic-over-capacity-cache:%03d" % index
		filler_cache_keys.append(filler_key)
		var filler_consumer := "synthetic-over-capacity-pinned-consumer:%03d" % index
		filler_consumer_tokens[filler_key] = filler_consumer
		queue.ecology_source_compile_jobs[filler_key] = {
			"key":filler_key, "artifactKind":"tree_source_record_geometry",
			"sourceId":"synthetic-cache-row:%03d" % index,
			"memberDigest":ProducerDomain.digest_value(["cache-row", index]),
			"status":"complete", "consumers":{filler_consumer:true}, "result":{},
			"publicationLeaseToken":""}
		queue.ecology_source_compile_order.append(filler_key)
	var all_cache_slots_pinned := true
	for source_key_value: Variant in queue.ecology_source_compile_jobs.keys():
		var pinned_job: Dictionary = queue.ecology_source_compile_jobs.get(
			String(source_key_value), {})
		if String(pinned_job.get("status", "")) == "complete" \
				and pinned_job.get("consumers", {}).is_empty():
			all_cache_slots_pinned = false
	var pinned_admission: Dictionary = queue.request_ecology_tree_source_record_compile(
		main, base_job.get("snapshot", {}), live_record,
		base_job.get("publicationView", {}), "synthetic-over-capacity-probe", INF)
	var pinned_queue_full: bool = all_cache_slots_pinned \
		and queue.ecology_source_compile_jobs.size() == capacity \
		and String(pinned_admission.get("status", "")) == "pending" \
		and String(pinned_admission.get("reason", "")) \
		== "ecology_source_compile_queue_full" \
		and String(pinned_admission.get("jobKey", "")).is_empty()
	var released_filler_key := filler_cache_keys[0] if not filler_cache_keys.is_empty() \
		else String(existing_pin_tokens.keys()[0]) if not existing_pin_tokens.is_empty() else ""
	var released_filler_consumer := String(filler_consumer_tokens.get(released_filler_key,
		existing_pin_tokens.get(released_filler_key, "")))
	if not released_filler_key.is_empty():
		queue.cancel_ecology_tree_source_compile(released_filler_key,
			released_filler_consumer)
	var exact_slot_released: bool = queue.ecology_source_compile_jobs.get(
		released_filler_key, {}).get("consumers", {}).is_empty() \
		and not released_filler_key.is_empty()
	var band_key := "synthetic-over-capacity-band:%s" % live_source_id
	var band_consumer := "synthetic-over-capacity-consumer"
	var token_map_by_consumer: Dictionary = {band_consumer:{}}
	var band_job := {"key":band_key, "artifactKind":"tree_source_record_projection",
		"status":"active", "reason":"synthetic-over-capacity-regression",
		"worldId":String(base_job.get("worldId", "")),
		"sourceChunkKey":base_job.get("sourceChunkKey", Vector2i.ZERO),
		"sectionKey":base_job.get("sectionKey", Vector3i.ZERO),
		"authority":base_job.get("authority", {}),
		"authorityDigest":String(base_job.get("authorityDigest", "")),
		"snapshot":base_job.get("snapshot", {}),
		"publicationView":base_job.get("publicationView", {}),
		"expectedSourceIds":expected_ids,
		"records":[live_record], "recordsById":{live_source_id:live_record},
		"recordJobKeys":{}, "sourceArtifactsById":captured_artifacts,
		"recordConsumerTokensByConsumer":token_map_by_consumer,
		"artifact":{}, "main":weakref(main),
		"consumers":{band_consumer:true}, "priorityDistanceSquared":INF,
		"enqueuedUsec":Time.get_ticks_usec(), "projectionCount":0,
		"projectionUsec":0}
	queue.ecology_tree_band_compile_jobs[band_key] = band_job
	queue.ecology_tree_band_compile_order.append(band_key)
	var was_processing: bool = queue.is_processing()
	queue.set_process(false)
	var observed_capacity_pressure: bool = \
		queue.ecology_source_compile_jobs.size() == capacity
	var peak_cache_count := int(queue.ecology_source_compile_jobs.size())
	var terminal_status := "pending"
	for _frame_index in range(600):
		queue._process(0.0)
		var current_job: Dictionary = queue.ecology_tree_band_compile_jobs.get(band_key, {})
		peak_cache_count = maxi(peak_cache_count, queue.ecology_source_compile_jobs.size())
		terminal_status = String(current_job.get("status", "pending"))
		if terminal_status in ["complete", "failed"]:
			break
		await process_frame
	queue.set_process(was_processing)
	var final_job: Dictionary = queue.ecology_tree_band_compile_jobs.get(band_key, {})
	var final_artifact: Dictionary = queue._tree_artifact_holder_view(
		final_job.get("artifactHolder", {}))
	var captured_count := int(final_job.get("sourceArtifactsById", {}).size())
	var failure_reason := String(final_job.get("reason", ""))
	var live_source_job_key := String(final_job.get("recordJobKeys", {}).get(
		live_source_id, ""))
	var live_source_job: Dictionary = queue.ecology_source_compile_jobs.get(
		live_source_job_key, {})
	var live_record_admitted := not live_source_job_key.is_empty() \
		and String(live_source_job.get("artifactKind", "")) \
		== "tree_source_record_geometry" \
		and String(live_source_job.get("sourceId", "")) == live_source_id
	var live_compiler: Object = live_source_job.get("compiler") as Object
	var live_compiler_progress: Dictionary = live_compiler.progress_snapshot() \
		if is_instance_valid(live_compiler) and live_compiler.has_method("progress_snapshot") else {}
	var live_compiler_state: Variant = live_compiler.get("_job") \
		if is_instance_valid(live_compiler) else {}
	var live_compiler_records: Variant = live_compiler_state.get("records", []) \
		if live_compiler_state is Dictionary else []
	var live_recipe_job_key := ""
	if live_compiler_records is Array:
		for record_value: Variant in live_compiler_records:
			if record_value is Dictionary \
					and String(record_value.get("sourceId", "")) == live_source_id:
				live_recipe_job_key = String(record_value.get("recipeJobKey", ""))
				break
	var live_recipe_job: Dictionary = queue.source_recipe_jobs.get(
		live_recipe_job_key, {})
	var final_token_maps: Dictionary = final_job.get("recordConsumerTokensByConsumer", {})
	for token_map_value: Variant in final_token_maps.values():
		if not token_map_value is Dictionary:
			continue
		var source_job_key := String(final_job.get("recordJobKeys", {}).get(
			live_source_id, ""))
		var source_token := String(token_map_value.get(live_source_id, ""))
		if not source_job_key.is_empty() and not source_token.is_empty():
			queue.cancel_ecology_tree_source_compile(source_job_key, source_token)
	queue.ecology_tree_band_compile_jobs.erase(band_key)
	queue.ecology_tree_band_compile_order.erase(band_key)
	for filler_key: String in filler_cache_keys:
		queue.ecology_source_compile_jobs.erase(filler_key)
		queue.ecology_source_compile_order.erase(filler_key)
	return {"status":"ready" if terminal_status == "complete" else "failed",
		"reason":failure_reason, "capacityPressureObserved":observed_capacity_pressure,
		"allCapacitySlotsPinned":pinned_queue_full,
		"exactCapacitySlotReleased":exact_slot_released,
		"realSourceRecordAdmittedAfterRelease":live_record_admitted,
		"projectionComplete":terminal_status == "complete" \
			and String(final_artifact.get("status", "")) == "ready" \
			and final_artifact.get("expectedSourceIds", []).size() == capacity + 1,
		"expectedUniqueSourceCount":expected_ids.size(),
		"capturedSourceArtifactCount":captured_count,
		"sourceCachePeakCount":peak_cache_count,
		"sourceCacheCapacity":capacity,
		"cancelledRecipeReadmissionSafe":bool(
			canceled_recipe_readmission.get("passed", false)),
		"cancelledRecipeReadmission":canceled_recipe_readmission,
		"liveSourceJobKey":live_source_job_key, "liveSourceId":live_source_id,
		"liveSourceCompileJobStatus":String(live_source_job.get("status", "missing")),
		"liveSourceCompileJobReason":String(live_source_job.get("reason", "")),
		"liveCompilerProgress":live_compiler_progress,
		"liveRecipeJobKeyDigest":_test_var_bytes_digest(live_recipe_job_key),
		"liveRecipeJobStatus":String(live_recipe_job.get("status", "missing")),
		"liveRecipeJobReason":String(live_recipe_job.get("reason", "")),
		"liveRecipeJobExists":not live_recipe_job.is_empty(),
		"liveRecipeArtifactCached":queue.source_recipe_completed.has(live_recipe_job_key),
		"projectionStatus":terminal_status,
		"sourceArtifactDigestCount":final_artifact.get("sourceArtifactDigests", []).size()}


func _test_var_bytes_digest(value: Variant) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(value)) != OK:
		return ""
	return context.finish().hex_encode()


func _tree_band_artifact_for_section(queue: Object, source_chunk: Vector2i,
		section_key: Vector3i, required_disposition := "complete_nonempty") -> Dictionary:
	for job_value: Variant in queue.ecology_tree_band_compile_jobs.values():
		if not job_value is Dictionary:
			continue
		var job: Dictionary = job_value
		if job.get("sourceChunkKey", null) != source_chunk \
				or job.get("sectionKey", null) != section_key \
				or String(job.get("status", "")) != "complete":
			continue
		var artifact_value: Variant = queue._tree_artifact_holder_view(
			job.get("artifactHolder", {}))
		if artifact_value is Dictionary and String(artifact_value.get("schema", "")) \
				== CompiledTreeSectionArtifact.SCHEMA \
				and String(artifact_value.get("disposition", "")) == required_disposition:
			return artifact_value
	return {}


func _select_ownerless_tree_support_section(artifact: Dictionary,
		excluded_section: Vector3i) -> Dictionary:
	var sources_value: Variant = artifact.get("sources", null)
	if not sources_value is Array:
		return {"status":"pending", "reason":"artifact_source_manifest_unavailable",
			"candidates":[]}
	var counts_by_section: Dictionary = {}
	for source_value: Variant in sources_value:
		if not source_value is Dictionary:
			continue
		var source: Dictionary = source_value
		var source_id := String(source.get("sourceId", ""))
		var members_value: Variant = source.get("geometryOwnership", null)
		if source_id.is_empty() or not members_value is Array:
			continue
		for member_value: Variant in members_value:
			if not member_value is Dictionary:
				continue
			var member: Dictionary = member_value
			var member_id := String(member.get("memberId", ""))
			var owner_value: Variant = member.get("ownedSectionKey",
				member.get("geometryOwnerSectionKey", null))
			var support_value: Variant = member.get("supportSectionKeys", null)
			if member_id.is_empty() or not owner_value is Vector3i \
					or not support_value is Array:
				continue
			var identity := source_id + "|" + member_id
			for section_value: Variant in support_value:
				if not section_value is Vector3i:
					continue
				var section_key: Vector3i = section_value
				if not counts_by_section.has(section_key):
					counts_by_section[section_key] = {"owners":{}, "supports":{}}
				var counts: Dictionary = counts_by_section[section_key]
				var support_ids: Dictionary = counts["supports"]
				support_ids[identity] = true
				if owner_value == section_key:
					var owner_ids: Dictionary = counts["owners"]
					owner_ids[identity] = true
	var candidate_sections: Array[Vector3i] = []
	for section_value: Variant in counts_by_section:
		if section_value is Vector3i:
			var section_key: Vector3i = section_value
			var counts: Dictionary = counts_by_section[section_key]
			if section_key != excluded_section and counts["owners"].is_empty() \
					and not counts["supports"].is_empty():
				candidate_sections.append(section_key)
	candidate_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var a_distance := absi(a.x - excluded_section.x) + absi(a.y - excluded_section.y) \
			+ absi(a.z - excluded_section.z)
		var b_distance := absi(b.x - excluded_section.x) + absi(b.y - excluded_section.y) \
			+ absi(b.z - excluded_section.z)
		if a_distance != b_distance:
			return a_distance < b_distance
		if a.x != b.x:
			return a.x < b.x
		if a.y != b.y:
			return a.y < b.y
		return a.z < b.z)
	var candidate_rows: Array[Dictionary] = []
	for section_key: Vector3i in candidate_sections:
		var counts: Dictionary = counts_by_section[section_key]
		candidate_rows.append({"sectionKey":section_key,
			"ownerMemberCount":counts["owners"].size(),
			"supportMemberCount":counts["supports"].size()})
	var distribution_sections: Array[Vector3i] = []
	for section_value: Variant in counts_by_section:
		if section_value is Vector3i:
			distribution_sections.append(section_value)
	distribution_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var a_distance := absi(a.x - excluded_section.x) + absi(a.y - excluded_section.y) \
			+ absi(a.z - excluded_section.z)
		var b_distance := absi(b.x - excluded_section.x) + absi(b.y - excluded_section.y) \
			+ absi(b.z - excluded_section.z)
		if a_distance != b_distance:
			return a_distance < b_distance
		if a.x != b.x:
			return a.x < b.x
		if a.y != b.y:
			return a.y < b.y
		return a.z < b.z)
	var distribution_rows: Array[Dictionary] = []
	for section_key: Vector3i in distribution_sections:
		var counts: Dictionary = counts_by_section[section_key]
		distribution_rows.append({"sectionKey":section_key,
			"ownerMemberCount":counts["owners"].size(),
			"supportMemberCount":counts["supports"].size(),
			"ownerlessSupport":counts["owners"].is_empty() \
				and not counts["supports"].is_empty()})
	return {"status":"ready" if not candidate_sections.is_empty() else "failed",
		"reason":"" if not candidate_sections.is_empty() \
			else "artifact_has_no_ownerless_supported_section",
		"sectionKey":candidate_sections[0] if not candidate_sections.is_empty() \
			else Vector3i.ZERO,
		"candidates":candidate_rows.slice(0, 8),
		"sectionOwnerDistribution":distribution_rows.slice(0, 8)}


func _bounded_dictionary_keys(value: Dictionary, limit: int) -> Array[String]:
	var keys: Array[String] = []
	for key_value: Variant in value:
		keys.append(String(key_value))
	keys.sort()
	return keys.slice(0, maxi(0, limit))


func _provider_contribution_summary(contribution_result: Dictionary) -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	var contributions_value: Variant = contribution_result.get("contributions", null)
	if not contributions_value is Array:
		return summaries
	for contribution_value: Variant in contributions_value:
		if not contribution_value is Dictionary:
			continue
		var contribution: Dictionary = contribution_value
		var ranges_value: Variant = contribution.get("supportRangesBySource", {})
		var range_count := 0
		var source_ids: Array[String] = []
		if ranges_value is Dictionary:
			for source_id_value: Variant in ranges_value:
				source_ids.append(String(source_id_value))
				var rows_value: Variant = ranges_value[source_id_value]
				if rows_value is Array:
					range_count += rows_value.size()
		source_ids.sort()
		summaries.append({"providerId":String(contribution.get("providerId", "")),
			"sectionKey":contribution.get("sectionKey", Vector3i.ZERO),
			"inputCount":(contribution.get("inputs", []) as Array).size(),
			"supportRangeSourceCount":source_ids.size(),
			"supportRangeCount":range_count,
			"supportRangeSourceIds":source_ids.slice(0, 8),
			"supportRangeKeys":_bounded_dictionary_keys(ranges_value, 8) \
				if ranges_value is Dictionary else []})
		if summaries.size() >= 8:
			break
	return summaries


func _tree_band_buffer_handoff_contract(artifact: Dictionary,
		contribution_result: Dictionary, source_id: String,
		section_key: Vector3i) -> Dictionary:
	var expected_buffers: Dictionary = {}
	var errors: Array[Dictionary] = []
	var identity_service := Adapter.new()
	for batch_value: Variant in artifact.get("batches", []):
		if not batch_value is Dictionary or batch_value.get("sectionKey", null) != section_key:
			continue
		var contributors_value: Variant = batch_value.get("contributors", null)
		if not contributors_value is Dictionary:
			return {"status":"failed", "reason":"artifact_member_contributors_missing"}
		for identity_value: Variant in contributors_value:
			var member_value: Variant = contributors_value[identity_value]
			if not member_value is Dictionary or String(member_value.get("sourceId", "")) != source_id:
				continue
			var member: Dictionary = member_value
			var part_id := String(member.get("sourcePartId", ""))
			var identity := String(identity_value)
			var member_buffer: Variant = member.get("instanceAttributes", null)
			var member_count := int(member.get("instanceCount", -1))
			if identity != identity_service._source_part_identity_key(source_id, part_id) \
					or not member_buffer is Array \
					or member_buffer.get_typed_builtin() != TYPE_FLOAT \
					or not member_buffer.is_read_only() or member_count <= 0 \
					or member_buffer.size() \
					!= member_count * InstanceAttributes.FLOATS_PER_INSTANCE \
					or expected_buffers.has(identity):
				errors.append({"sourcePartId":part_id,
					"reason":"invalid_or_duplicate_canonical_owner_buffer"})
				continue
			expected_buffers[identity] = {"buffer":member_buffer,
				"instanceCount":member_count}
	var observed_input_count := 0
	var alias_count := 0
	var typed_readonly_and_count_valid := true
	var seen_inputs: Dictionary = {}
	for contribution_value: Variant in contribution_result.get("contributions", []):
		if not contribution_value is Dictionary:
			continue
		var contribution: Dictionary = contribution_value
		for input_value: Variant in contribution.get("inputs", []):
			if not input_value is Dictionary:
				continue
			var input: Dictionary = input_value
			if String(input.get("sourceId", "")) != source_id:
				continue
			observed_input_count += 1
			var part_id := String(input.get("sourcePartId", ""))
			var identity := identity_service._source_part_identity_key(source_id, part_id)
			var buffer: Variant = input.get("buffer", null)
			var expected: Dictionary = expected_buffers.get(identity, {})
			var buffer_valid: bool = input.is_read_only() and buffer is Array \
				and buffer.get_typed_builtin() == TYPE_FLOAT and buffer.is_read_only() \
				and int(input.get("instanceCount", -1)) \
				== int(expected.get("instanceCount", -2)) \
				and buffer.size() == int(input.get("instanceCount", -1)) \
				* InstanceAttributes.FLOATS_PER_INSTANCE \
				and expected.has("buffer") and is_same(buffer, expected.get("buffer", null)) \
				and buffer == expected.get("buffer", [])
			if not buffer_valid or seen_inputs.has(identity):
				typed_readonly_and_count_valid = false
				errors.append({"sourcePartId":part_id,
					"reason":"adapter_buffer_did_not_preserve_canonical_owner_payload"})
				continue
			seen_inputs[identity] = true
			alias_count += 1
	if errors.size() > 8:
		errors.resize(8)
	var expected_count := expected_buffers.size()
	return {"status":"ready" if errors.is_empty() \
		and expected_count == observed_input_count else "failed",
		"reason":"" if errors.is_empty() else "owner_buffer_handoff_mismatch",
		"artifactMemberCount":expected_count,
		"adapterInputCount":observed_input_count, "aliasCount":alias_count,
		"typedReadonlyAndCountValid":typed_readonly_and_count_valid,
		"errors":errors}


func _tree_band_buffer_count_guard_contract(contribution_result: Dictionary,
		source_id: String) -> Dictionary:
	for contribution_value: Variant in contribution_result.get("contributions", []):
		if not contribution_value is Dictionary:
			continue
		var contribution: Dictionary = contribution_value
		for input_value: Variant in contribution.get("inputs", []):
			if not input_value is Dictionary:
				continue
			var input: Dictionary = input_value
			if String(input.get("sourceId", "")) != source_id:
				continue
			var invalid_input: Dictionary = input.duplicate(false)
			invalid_input["instanceCount"] = int(input.get("instanceCount", 0)) + 1
			invalid_input.make_read_only()
			var invalid_inputs: Array[Dictionary] = [invalid_input]
			invalid_inputs.make_read_only()
			var result: Dictionary = Partitioner.partition(invalid_inputs)
			return {"status":String(result.get("status", "")),
				"reason":String(result.get("reason", "")),
				"sourcePartId":String(input.get("sourcePartId", ""))}
	return {"status":"missing", "reason":"tree_owner_input_missing"}


func _mutate_first_tree_band_owner_buffer(artifact: Dictionary) -> Dictionary:
	var mutated_artifact: Dictionary = artifact.duplicate(true)
	var batches_value: Variant = mutated_artifact.get("batches", null)
	if not batches_value is Array:
		return {"mutated":false, "reason":"artifact_batches_missing"}
	var batches: Array = batches_value.duplicate()
	for batch_index: int in range(batches.size()):
		var batch_value: Variant = batches[batch_index]
		if not batch_value is Dictionary:
			continue
		var batch: Dictionary = batch_value.duplicate(false)
		var contributors_value: Variant = batch.get("contributors", null)
		if not contributors_value is Dictionary:
			continue
		var contributors: Dictionary = contributors_value.duplicate()
		for identity_value: Variant in contributors:
			var contributor_value: Variant = contributors[identity_value]
			if not contributor_value is Dictionary:
				continue
			var contributor: Dictionary = contributor_value.duplicate(false)
			var source_buffer: Variant = contributor.get("instanceAttributes", null)
			if not source_buffer is Array or source_buffer.is_empty():
				continue
			var changed_buffer: Array[float] = []
			for component_value: Variant in source_buffer:
				if not component_value is float or not is_finite(float(component_value)):
					return {"mutated":false, "reason":"owner_buffer_component_invalid"}
				changed_buffer.append(float(component_value))
			changed_buffer[0] = changed_buffer[0] + 0.125
			changed_buffer.make_read_only()
			var aggregate_value: Variant = batch.get("instanceAttributes", null)
			var offsets_value: Variant = contributor.get("instanceAttributeOffsets", null)
			if not aggregate_value is Array or aggregate_value.get_typed_builtin() != TYPE_FLOAT \
					or not offsets_value is Array or offsets_value.is_empty() \
					or not offsets_value[0] is int:
				return {"mutated":false, "reason":"aggregate_owner_buffer_or_offset_missing"}
			var aggregate_buffer: Array[float] = []
			for component_value: Variant in aggregate_value:
				if not component_value is float or not is_finite(float(component_value)):
					return {"mutated":false, "reason":"aggregate_owner_component_invalid"}
				aggregate_buffer.append(float(component_value))
			var aggregate_offset := int(offsets_value[0]) * InstanceAttributes.FLOATS_PER_INSTANCE
			if aggregate_offset < 0 or aggregate_offset >= aggregate_buffer.size():
				return {"mutated":false, "reason":"aggregate_owner_offset_out_of_range"}
			aggregate_buffer[aggregate_offset] += 0.125
			aggregate_buffer.make_read_only()
			contributor["instanceAttributes"] = changed_buffer
			contributor.make_read_only()
			contributors[identity_value] = contributor
			contributors.make_read_only()
			batch["contributors"] = contributors
			batch["instanceAttributes"] = aggregate_buffer
			batch.make_read_only()
			batches[batch_index] = batch
			batches.make_read_only()
			mutated_artifact["batches"] = batches
			_freeze_tree_band_artifact_in_place(mutated_artifact)
			return {"mutated":true, "artifact":mutated_artifact,
				"sourcePartId":String(contributor.get("sourcePartId", ""))}
	return {"mutated":false, "reason":"owner_buffer_not_found"}


func _tree_repeated_compatible_contributor_contract(provider: Adapter,
		world_id: String, source_chunk: Vector2i, section_key: Vector3i,
		artifact: Dictionary, support_rows: Array) -> Dictionary:
	var batches_value: Variant = artifact.get("batches", null)
	var expected_ids: Variant = artifact.get("expectedSourceIds", null)
	if not batches_value is Array or not expected_ids is Array:
		return {"status":"missing", "reason":"real_band_artifact_incomplete"}
	var batches: Array = batches_value
	var selected_index := -1
	var selected_batch_key := ""
	var selected_left_identity := ""
	var selected_right_identity := ""
	var selected_left_offset := -1
	var selected_right_offsets: Array = []
	for batch_index: int in range(batches.size()):
		var batch_value: Variant = batches[batch_index]
		if not batch_value is Dictionary: continue
		var batch: Dictionary = batch_value
		var contributors_value: Variant = batch.get("contributors", null)
		if not contributors_value is Dictionary or contributors_value.size() < 2: continue
		var identities: Array[String] = []
		for identity_value: Variant in contributors_value:
			identities.append(String(identity_value))
		identities.sort()
		for left_index: int in range(identities.size()):
			var left_value: Variant = contributors_value.get(identities[left_index], null)
			if not left_value is Dictionary: continue
			var left_offsets: Variant = left_value.get("instanceAttributeOffsets", null)
			if not left_offsets is Array or left_offsets.is_empty(): continue
			for right_index: int in range(left_index + 1, identities.size()):
				var right_value: Variant = contributors_value.get(identities[right_index], null)
				if not right_value is Dictionary: continue
				var right_offsets: Variant = right_value.get("instanceAttributeOffsets", null)
				if not right_offsets is Array or right_offsets.is_empty(): continue
				if int(left_offsets[0]) == int(right_offsets[0]): continue
				selected_index = batch_index
				selected_batch_key = String(batch.get("batchKey", ""))
				selected_left_identity = identities[left_index]
				selected_right_identity = identities[right_index]
				selected_left_offset = int(left_offsets[0])
				selected_right_offsets = right_offsets.duplicate()
				break
			if selected_index >= 0: break
		if selected_index >= 0: break
	if selected_index < 0:
		return {"status":"missing", "reason":"real_compatible_multi_contributor_batch_missing"}
	var index: Object = provider._support_index
	var positive: Dictionary = index.register_tree_section_geometry_overlay(
		world_id, source_chunk, section_key, expected_ids, artifact, support_rows)
	var revision_after_positive: int = index._section_revision(section_key)
	var positive_overlay: Dictionary = index._tree_section_geometry_overlays.get(
		source_chunk, {}).get(section_key, {})
	var changed_artifact: Dictionary = artifact.duplicate(false)
	var changed_batches: Array = batches.duplicate()
	var changed_batch: Dictionary = batches[selected_index].duplicate(false)
	var changed_contributors: Dictionary = changed_batch.get("contributors", {}).duplicate()
	var left_contributor: Dictionary = changed_contributors[selected_left_identity]
	var changed_right: Dictionary = changed_contributors[selected_right_identity].duplicate(false)
	selected_right_offsets[0] = selected_left_offset
	selected_right_offsets.make_read_only()
	changed_right["instanceAttributeOffsets"] = selected_right_offsets
	changed_right.make_read_only()
	changed_contributors[selected_right_identity] = changed_right
	changed_contributors.make_read_only()
	changed_batch["contributors"] = changed_contributors
	changed_batch.make_read_only()
	changed_batches[selected_index] = changed_batch
	changed_batches.make_read_only()
	changed_artifact["batches"] = changed_batches
	_freeze_tree_band_artifact_in_place(changed_artifact)
	var negative: Dictionary = index.register_tree_section_geometry_overlay(
		world_id, source_chunk, section_key, expected_ids, changed_artifact, support_rows)
	var retained_overlay: Dictionary = index._tree_section_geometry_overlays.get(
		source_chunk, {}).get(section_key, {})
	return {"status":"ready", "batchKey":selected_batch_key,
		"contributorCount":changed_contributors.size(),
		"leftIdentity":selected_left_identity, "rightIdentity":selected_right_identity,
		"sameSourceRevision":String(left_contributor.get("sourceRevision", "")) \
			== String(changed_right.get("sourceRevision", "")),
		"distinctMemberIdentities":selected_left_identity != selected_right_identity,
		"positiveStatus":String(positive.get("status", "")),
		"negativeReason":String(negative.get("reason", "")),
		"overlayRetained":String(retained_overlay.get("compiledArtifactDigest", "")) \
			== String(positive_overlay.get("compiledArtifactDigest", "")) \
			and index._section_revision(section_key) == revision_after_positive}


func _tree_manifest_member_binding_contract(provider: Object,
		section_key: Vector3i) -> Dictionary:
	var by_section: Variant = provider.get("_latest_support_ranges_by_section")
	var cache: Variant = provider.get("_canonical_tree_band_artifact_by_member_section")
	if not by_section is Dictionary or not cache is Dictionary:
		return {"status":"pending", "reason":"member_binding_fixture_state_missing"}
	var support_by_identity: Variant = by_section.get(section_key, null)
	if not support_by_identity is Dictionary:
		return {"status":"pending", "reason":"member_binding_support_rows_missing"}
	for identity_value: Variant in support_by_identity:
		var identity_key := String(identity_value)
		var support_rows_value: Variant = support_by_identity[identity_value]
		if not support_rows_value is Array or support_rows_value.is_empty():
			continue
		var support_row: Variant = support_rows_value[0]
		if not support_row is Dictionary:
			continue
		var source_part_id := String(support_row.get("sourcePartId", ""))
		var band_key := identity_key + "|%d,%d,%d" % [section_key.x,
			section_key.y, section_key.z]
		var compiled_value: Variant = cache.get(band_key, null)
		if source_part_id.is_empty() or not compiled_value is Dictionary:
			continue
		var source_manifest_value: Variant = compiled_value.get("sourceManifest", null)
		if not source_manifest_value is Dictionary:
			continue
		var source_manifest: Dictionary = source_manifest_value
		var ownership_value: Variant = source_manifest.get("geometryOwnership", null)
		if not ownership_value is Array:
			continue
		var matching_ownership_count := 0
		var exact_member: Dictionary = {}
		var exact_index := -1
		for index in range(ownership_value.size()):
			var member_value: Variant = ownership_value[index]
			if member_value is Dictionary and String(member_value.get("memberId", "")) \
					== source_part_id:
				matching_ownership_count += 1
				exact_member = member_value
				exact_index = index
		var projected_value: Variant = provider.call(
			"tree_support_rows_from_manifest", source_manifest)
		var projected_result: Dictionary = projected_value \
			if projected_value is Dictionary else {}
		if String(projected_result.get("status", "")) != "ready":
			return {"status":"pending", "reason":"member_binding_projection_failed",
				"projectionReason":String(projected_result.get("reason", ""))}
		var canonical_rows: Array = []
		var raw_member_row: Dictionary = {}
		for raw_row_value: Variant in projected_result.get("rows", []):
			if not raw_row_value is Dictionary or String(raw_row_value.get(
					"sourcePartId", "")) != source_part_id:
				continue
			if section_key not in raw_row_value.get("conservativeSupportSectionKeys", []):
				continue
			raw_member_row = raw_row_value
			var canonical_value: Variant = provider.call("_canonical_support_range",
				raw_member_row, section_key)
			var canonical_row: Dictionary = canonical_value \
				if canonical_value is Dictionary else {}
			if not canonical_row.is_empty():
				canonical_rows.append(canonical_row)
		var projected_match_value: Variant = provider.call(
			"_tree_source_manifest_has_exact_member", source_manifest,
			source_part_id, section_key, canonical_rows)
		var projected_match: Dictionary = projected_match_value \
			if projected_match_value is Dictionary else {}
		var cached_match_value: Variant = provider.call(
			"_tree_source_manifest_has_exact_member", source_manifest,
			source_part_id, section_key, support_rows_value)
		var cached_match: Dictionary = cached_match_value \
			if cached_match_value is Dictionary else {}
		# The live row includes admitted domain/support policy evidence which the
		# compiler manifest does not own. Compare both rows through the exact
		# source-member validator instead of requiring unrelated extension fields
		# to be byte-for-byte equal.
		var cached_canonical_matches: bool = canonical_rows.size() == 1 \
			and support_rows_value.size() == 1 \
			and String(projected_match.get("status", "")) == "ready" \
			and String(cached_match.get("status", "")) == "ready" \
			and int(cached_match.get("instanceIndex", -1)) == int(
				exact_member.get("instanceIndex", -2)) \
			and cached_match.get("geometryOwnerSection", null) \
				== exact_member.get("geometryOwnerSectionKey", null)
		var missing_manifest: Dictionary = source_manifest.duplicate(true)
		var missing_ownership: Array = ownership_value.duplicate(true)
		if exact_index >= 0:
			missing_ownership.remove_at(exact_index)
		missing_manifest["geometryOwnership"] = missing_ownership
		var missing_result_value: Variant = provider.call(
			"_tree_source_manifest_has_exact_member", missing_manifest,
			source_part_id, section_key, support_rows_value)
		var missing_result: Dictionary = missing_result_value \
			if missing_result_value is Dictionary else {}
		var duplicate_manifest: Dictionary = source_manifest.duplicate(true)
		var duplicate_ownership: Array = ownership_value.duplicate(true)
		if not exact_member.is_empty():
			duplicate_ownership.append(exact_member.duplicate(true))
		duplicate_manifest["geometryOwnership"] = duplicate_ownership
		var duplicate_result_value: Variant = provider.call(
			"_tree_source_manifest_has_exact_member", duplicate_manifest,
			source_part_id, section_key, support_rows_value)
		var duplicate_result: Dictionary = duplicate_result_value \
			if duplicate_result_value is Dictionary else {}
		return {"status":String(cached_match.get("status", "")),
			"reason":String(cached_match.get("reason", "")),
			"sourceId":String(support_row.get("sourceId", "")),
			"manifestMemberId":String(exact_member.get("memberId", "")),
			"supportMemberId":source_part_id,
			"matchingOwnershipCount":matching_ownership_count,
			"canonicalSupportRowCount":canonical_rows.size(),
			"cachedSupportRowCount":support_rows_value.size(),
			"cachedCanonicalMatches":cached_canonical_matches,
			"aggregateManifestHasNoPartId":not source_manifest.has("sourcePartId"),
			"missingMemberStatus":String(missing_result.get("status", "")),
			"duplicateMemberStatus":String(duplicate_result.get("status", ""))}
	return {"status":"pending", "reason":"member_binding_band_source_missing"}


func _tree_contribution_staleness_diagnostic(provider: Object, census: Dictionary,
		section_key: Vector3i, contribution_result: Dictionary) -> Dictionary:
	var expected_by_section: Variant = census.get("expectedContributorsBySection", {})
	var source_provider_ids: Dictionary = census.get("sourceProviderIds", {})
	var source_identities: Dictionary = census.get("sourceIdentities", {})
	var source_revisions: Dictionary = census.get("sourceRevisions", {})
	var latest_support: Variant = provider.get("_latest_support_ranges_by_section").get(
		section_key, {})
	var band_cache: Dictionary = provider.get(
		"_canonical_tree_band_artifact_by_member_section")
	var band_cache_keys: Array[String] = []
	for band_cache_key_value: Variant in band_cache.keys():
		band_cache_keys.append(String(band_cache_key_value))
	band_cache_keys.sort()
	var expected_member_count := 0
	var support_member_count := 0
	var missing_support_count := 0
	var support_mismatch_count := 0
	var compiled_member_count := 0
	var missing_compiled_count := 0
	var compiled_mismatch_count := 0
	var support_samples: Array[Dictionary] = []
	var compiled_samples: Array[Dictionary] = []
	var band_revision_samples: Array[Dictionary] = []
	var expected_values: Variant = expected_by_section.get(section_key, []) \
		if expected_by_section is Dictionary else []
	if latest_support is Dictionary and expected_values is Array:
		for identity_value: Variant in expected_values:
			var identity_key := String(identity_value)
			if String(source_provider_ids.get(identity_key, "")) != Adapter.PROVIDER_ID:
				continue
			expected_member_count += 1
			var source_identity: Dictionary = source_identities.get(identity_key, {})
			var source_id := String(source_identity.get("sourceId", ""))
			var part_id := String(source_identity.get("sourcePartId", ""))
			var expected_revision := String(source_revisions.get(identity_key, ""))
			var support_value: Variant = latest_support.get(identity_key, null)
			if not support_value is Array or support_value.is_empty():
				missing_support_count += 1
			else:
				support_member_count += 1
				for support_row_value: Variant in support_value:
					var support_row: Dictionary = support_row_value \
						if support_row_value is Dictionary else {}
					var mismatches: Array[String] = []
					if String(support_row.get("sourceId", "")) != source_id:
						mismatches.append("sourceId")
					if String(support_row.get("sourcePartId", "")) != part_id:
						mismatches.append("sourcePartId")
					if String(support_row.get("sourceRevision", "")) != expected_revision:
						mismatches.append("sourceRevision")
					if not mismatches.is_empty():
						support_mismatch_count += 1
						if support_samples.size() < 4:
							support_samples.append({"identityKey":identity_key,
								"expectedSourceId":source_id, "expectedSourcePartId":part_id,
								"expectedSourceRevision":expected_revision,
								"actualSourceId":String(support_row.get("sourceId", "")),
								"actualSourcePartId":String(support_row.get("sourcePartId", "")),
								"actualSourceRevision":String(support_row.get("sourceRevision", "")),
								"sourceOwnerChunk":support_row.get("sourceOwnerChunk", null),
								"supportSectionKeys":support_row.get(
									"conservativeSupportSectionKeys", []),
								"mismatchedFields":mismatches})
			var band_key := identity_key + "|%d,%d,%d" % [
				section_key.x, section_key.y, section_key.z]
			var compiled_value: Variant = provider.get(
				"_canonical_tree_band_artifact_by_member_section").get(band_key, null)
			if not compiled_value is Dictionary:
				missing_compiled_count += 1
				continue
			compiled_member_count += 1
			var compiled: Dictionary = compiled_value
			var source_chunk: Variant = support_value[0].get("sourceOwnerChunk", null) \
				if support_value is Array and not support_value.is_empty() \
					and support_value[0] is Dictionary else null
			var compiled_mismatches: Array[String] = []
			if compiled.get("sectionKey", null) != section_key:
				compiled_mismatches.append("sectionKey")
			if compiled.get("sourceChunkKey", null) != source_chunk:
				compiled_mismatches.append("sourceChunkKey")
			if String(compiled.get("sourceRevision", "")) != expected_revision:
				compiled_mismatches.append("sourceRevision")
			if not compiled_mismatches.is_empty():
				compiled_mismatch_count += 1
				if compiled_samples.size() < 4:
					compiled_samples.append({"identityKey":identity_key,
						"expectedSourceRevision":expected_revision,
						"actualSourceRevision":String(compiled.get("sourceRevision", "")),
						"expectedSectionKey":section_key,
						"actualSectionKey":compiled.get("sectionKey", null),
						"expectedSourceChunkKey":source_chunk,
						"actualSourceChunkKey":compiled.get("sourceChunkKey", null),
						"overlayReceiptSchema":String(compiled.get(
							"overlayReceipt", {}).get("schema", "")),
						"mismatchedFields":compiled_mismatches})
			if band_revision_samples.size() < 8:
				band_revision_samples.append(_tree_band_revision_digest_sample(
					compiled, band_key, identity_key))
			for other_band_key: String in band_cache_keys:
				if band_revision_samples.size() >= 8:
					break
				if other_band_key == band_key or not other_band_key.begins_with(
						identity_key + "|"):
					continue
				var other_compiled_value: Variant = band_cache.get(other_band_key, null)
				if other_compiled_value is Dictionary:
					band_revision_samples.append(_tree_band_revision_digest_sample(
						other_compiled_value, other_band_key, identity_key))
	return {"sectionKey":section_key,
		"contributionStatus":String(contribution_result.get("status", "")),
		"contributionReason":String(contribution_result.get("reason", "")),
		"resultSourceId":String(contribution_result.get("sourceId", "")),
		"resultSourcePartId":String(contribution_result.get("sourcePartId", "")),
		"resultSectionKey":contribution_result.get("sectionKey", null),
		"expectedProviderMemberCount":expected_member_count,
		"supportIndexedMemberCount":support_member_count,
		"missingSupportMemberCount":missing_support_count,
		"supportRevisionMismatchCount":support_mismatch_count,
		"compiledBandMemberCount":compiled_member_count,
		"missingCompiledBandCount":missing_compiled_count,
		"compiledBandIdentityMismatchCount":compiled_mismatch_count,
		"supportMismatchSamples":support_samples,
		"compiledBandMismatchSamples":compiled_samples,
		"bandRevisionDigestSamples":band_revision_samples}


func _tree_band_revision_diagnostic_by_source(provider: Object,
		source_id: String) -> Dictionary:
	var cache_value: Variant = provider.get(
		"_canonical_tree_band_artifact_by_member_section")
	if not cache_value is Dictionary:
		return {"status":"pending", "reason":"tree_band_revision_cache_missing",
			"sampleRows":[]}
	var cache: Dictionary = cache_value
	var cache_keys: Array[String] = []
	for key_value: Variant in cache.keys():
		cache_keys.append(String(key_value))
	cache_keys.sort()
	var rows_by_part: Dictionary = {}
	for band_key: String in cache_keys:
		var compiled_value: Variant = cache.get(band_key, null)
		if not compiled_value is Dictionary:
			continue
		var compiled: Dictionary = compiled_value
		if String(compiled.get("sourceId", "")) != source_id:
			continue
		var source_part_id := String(compiled.get("sourcePartId", ""))
		if source_part_id.is_empty():
			continue
		if not rows_by_part.has(source_part_id):
			rows_by_part[source_part_id] = []
		var samples: Array = rows_by_part[source_part_id]
		var sample := _tree_band_revision_digest_sample(compiled, band_key,
			"%s|%s" % [source_id, source_part_id])
		var duplicate_sample := false
		for existing_value: Variant in samples:
			if not existing_value is Dictionary:
				continue
			var existing: Dictionary = existing_value
			if existing.get("sectionKey", null) == sample.get("sectionKey", null) \
					and String(existing.get("cachedSourceRevision", "")) \
					== String(sample.get("cachedSourceRevision", "")) \
					and String(existing.get("compiledAttributeDigest", "")) \
					== String(sample.get("compiledAttributeDigest", "")) \
					and String(existing.get("batchOrderDigest", "")) \
					== String(sample.get("batchOrderDigest", "")):
				duplicate_sample = true
				break
		if not duplicate_sample:
			samples.append(sample)
	var part_ids: Array[String] = []
	for part_id_value: Variant in rows_by_part.keys():
		part_ids.append(String(part_id_value))
	part_ids.sort()
	var selected_part_id := ""
	var selected_rows: Array = []
	var selected_revision_count := 0
	for part_id: String in part_ids:
		var part_rows: Array = rows_by_part[part_id]
		var revisions: Dictionary = {}
		for row_value: Variant in part_rows:
			if row_value is Dictionary:
				revisions[String(row_value.get("cachedSourceRevision", ""))] = true
		if revisions.size() > selected_revision_count:
			selected_part_id = part_id
			selected_rows = part_rows
			selected_revision_count = revisions.size()
		if revisions.size() > 1:
			break
	var bounded_rows: Array[Dictionary] = []
	for row_value: Variant in selected_rows:
		if bounded_rows.size() >= 8:
			break
		if row_value is Dictionary:
			bounded_rows.append(row_value)
	return {"status":"ready" if not bounded_rows.is_empty() else "pending",
		"reason":"" if not bounded_rows.is_empty() else "tree_band_source_revision_rows_missing",
		"sourceId":source_id, "sourcePartId":selected_part_id,
		"distinctRevisionCount":selected_revision_count,
		"hasRevisionConflict":selected_revision_count > 1,
		"sampleCount":bounded_rows.size(), "sampleRows":bounded_rows}


func _immutable_recipe_content_identity_contract() -> Dictionary:
	var request: Dictionary = {"worldSeed":"identity-test", "renderLodTier":"near"}
	var envelope: Dictionary = {"worldBounds":AABB(Vector3.ZERO, Vector3.ONE),
		"certifiedEnvelopeDigest":"identity-envelope"}
	var recipe: Dictionary = {"signature":"tree-v10-identity",
		"branches":[{"start":Vector3.ZERO, "end":Vector3.UP, "radius":0.2}],
		"foliage":[{"center":Vector3.UP, "radius":0.5}],
		"stats":{"nodeCount":2,
			"timingUsec":{"scaffold":5, "total":8}}}
	_freeze_tree_band_artifact_in_place(request)
	_freeze_tree_band_artifact_in_place(envelope)
	_freeze_tree_band_artifact_in_place(recipe)
	var base_revision: String = TreeCompilerScript.immutable_source_content_revision(
		"domain-rev", "source-rev", "producer-rev", "source-digest",
		"publication-digest", "recipe-signature", request, recipe, envelope)
	var timing_recipe: Dictionary = recipe.duplicate(true)
	var timing_stats: Dictionary = timing_recipe.get("stats", {})
	var timing_values: Dictionary = timing_stats.get("timingUsec", {})
	timing_values["scaffold"] = 98765
	timing_values["total"] = 123456
	timing_stats["timingUsec"] = timing_values
	timing_recipe["stats"] = timing_stats
	_freeze_tree_band_artifact_in_place(timing_recipe)
	var timing_revision: String = TreeCompilerScript.immutable_source_content_revision(
		"domain-rev", "source-rev", "producer-rev", "source-digest",
		"publication-digest", "recipe-signature", request, timing_recipe, envelope)
	var geometry_recipe: Dictionary = recipe.duplicate(true)
	var geometry_branches: Array = geometry_recipe.get("branches", [])
	var first_branch: Dictionary = geometry_branches[0]
	first_branch["radius"] = float(first_branch.get("radius", 0.0)) + 0.1
	geometry_branches[0] = first_branch
	geometry_recipe["branches"] = geometry_branches
	_freeze_tree_band_artifact_in_place(geometry_recipe)
	var geometry_revision: String = TreeCompilerScript.immutable_source_content_revision(
		"domain-rev", "source-rev", "producer-rev", "source-digest",
		"publication-digest", "recipe-signature", request, geometry_recipe, envelope)
	var stats_recipe: Dictionary = recipe.duplicate(true)
	var stats_value: Dictionary = stats_recipe.get("stats", {})
	stats_value["nodeCount"] = int(stats_value.get("nodeCount", 0)) + 1
	stats_recipe["stats"] = stats_value
	_freeze_tree_band_artifact_in_place(stats_recipe)
	var stats_revision: String = TreeCompilerScript.immutable_source_content_revision(
		"domain-rev", "source-rev", "producer-rev", "source-digest",
		"publication-digest", "recipe-signature", request, stats_recipe, envelope)
	var changed_request: Dictionary = request.duplicate(true)
	changed_request["renderLodTier"] = "mid"
	_freeze_tree_band_artifact_in_place(changed_request)
	var request_revision: String = TreeCompilerScript.immutable_source_content_revision(
		"domain-rev", "source-rev", "producer-rev", "source-digest",
		"publication-digest", "recipe-signature", changed_request, recipe, envelope)
	var changed_envelope: Dictionary = envelope.duplicate(true)
	changed_envelope["worldBounds"] = AABB(Vector3.ZERO, Vector3(2.0, 1.0, 1.0))
	_freeze_tree_band_artifact_in_place(changed_envelope)
	var envelope_revision: String = TreeCompilerScript.immutable_source_content_revision(
		"domain-rev", "source-rev", "producer-rev", "source-digest",
		"publication-digest", "recipe-signature", request, recipe, changed_envelope)
	var timing_only_excluded: bool = not base_revision.is_empty() \
		and base_revision == timing_revision
	var timing_data_preserved: bool = int((recipe.get("stats", {}) as Dictionary) \
		.get("timingUsec", {}).get("scaffold", -1)) == 5 \
		and int((timing_recipe.get("stats", {}) as Dictionary) \
			.get("timingUsec", {}).get("scaffold", -1)) == 98765
	var semantic_inputs_change_revision: bool = not geometry_revision.is_empty() \
		and geometry_revision != base_revision \
		and not stats_revision.is_empty() and stats_revision != base_revision \
		and not request_revision.is_empty() and request_revision != base_revision \
		and not envelope_revision.is_empty() and envelope_revision != base_revision
	return {"passed":timing_only_excluded and timing_data_preserved \
			and semantic_inputs_change_revision,
		"timingOnlyExcluded":timing_only_excluded,
		"timingDataPreserved":timing_data_preserved,
		"semanticInputsChangeRevision":semantic_inputs_change_revision,
		"geometryMutationChangesRevision":geometry_revision != base_revision,
		"nonTimingStatsMutationChangesRevision":stats_revision != base_revision,
		"requestMutationChangesRevision":request_revision != base_revision,
		"envelopeMutationChangesRevision":envelope_revision != base_revision,
		"baseRevision":base_revision,
		"timingVariantRevision":timing_revision,
		"geometryVariantRevision":geometry_revision,
		"requestVariantRevision":request_revision,
		"envelopeVariantRevision":envelope_revision}


func _tree_revision_differences_only_timing(differences_value: Variant) -> bool:
	if not differences_value is Array:
		return false
	for difference_value: Variant in differences_value:
		if not difference_value is Dictionary \
				or not String(difference_value.get("path", "")).begins_with(
					"recipeSnapshot/stats/timingUsec/"):
			return false
	return true


func _tree_band_content_revision_is_shared(comparison: Dictionary) -> bool:
	var records_value: Variant = comparison.get("records", null)
	if not records_value is Array or (records_value as Array).size() != 2:
		return false
	var records: Array = records_value
	var first: Dictionary = records[0] if records[0] is Dictionary else {}
	var second: Dictionary = records[1] if records[1] is Dictionary else {}
	return String(comparison.get("status", "")) == "ready" \
		and int(comparison.get("distinctContentRevisionCount", 0)) == 1 \
		and String(first.get("recordContentRevision", "")) == String(
			second.get("recordContentRevision", "")) \
		and String(first.get("recipeArtifactRevision", "")) == String(
			second.get("recipeArtifactRevision", "")) \
		and String(first.get("sourceArtifactDigest", "")) == String(
			second.get("sourceArtifactDigest", "")) \
		and String(first.get("sourceJobKeyDigest", "")) == String(
			second.get("sourceJobKeyDigest", ""))


func _tree_band_compiled_geometry_is_shared(comparison: Dictionary) -> bool:
	var records_value: Variant = comparison.get("records", null)
	if not records_value is Array or (records_value as Array).size() != 2:
		return false
	var records: Array = records_value
	var first: Dictionary = records[0] if records[0] is Dictionary else {}
	var second: Dictionary = records[1] if records[1] is Dictionary else {}
	var digest_a: String = String(first.get("compiledAttributeDigest", ""))
	var digest_b: String = String(second.get("compiledAttributeDigest", ""))
	var ownership_a: String = String(first.get("geometryOwnershipDigest", ""))
	var ownership_b: String = String(second.get("geometryOwnershipDigest", ""))
	return not digest_a.is_empty() and digest_a == digest_b \
		and not ownership_a.is_empty() and ownership_a == ownership_b \
		and int(first.get("geometryOwnershipCount", -1)) \
			== int(second.get("geometryOwnershipCount", -2)) \
		and String(first.get("sourceArtifactDigest", "")) == String(
			second.get("sourceArtifactDigest", "")) \
		and int(first.get("nativeTreePackAcceptedInstances", 0)) > 0 \
		and int(second.get("nativeTreePackAcceptedInstances", 0)) > 0


func _tree_band_native_source_artifact_proof(queue: Object,
		band_job: Dictionary, source_id: String, projected_artifact: Dictionary) -> Dictionary:
	var source_id_job_keys: Variant = band_job.get("recordJobKeys", null)
	if not source_id_job_keys is Dictionary:
		return {"status":"pending", "reason":"band_source_record_job_key_missing"}
	var source_job_key := String(source_id_job_keys.get(source_id, ""))
	var source_job_value: Variant = queue.ecology_source_compile_jobs.get(
		source_job_key, null) if not source_job_key.is_empty() else null
	if not source_job_value is Dictionary:
		return {"status":"pending", "reason":"source_record_compile_job_missing"}
	var source_job: Dictionary = source_job_value
	if String(source_job.get("artifactKind", "")) != "tree_source_record_geometry" \
			or String(source_job.get("status", "")) != "complete" \
			or String(source_job.get("sourceId", "")) != source_id:
		return {"status":"pending", "reason":"source_record_compile_job_not_complete"}
	var source_artifact: Dictionary = queue._tree_artifact_holder_view(
		source_job.get("resultHolder", {}))
	if String(source_artifact.get("schema", "")) \
			!= CompiledTreeSectionArtifact.SOURCE_RECORD_GEOMETRY_SCHEMA \
			or String(source_artifact.get("sourceId", "")) != source_id:
		return {"status":"pending", "reason":"source_record_artifact_identity_invalid"}
	var source_digest := String(source_artifact.get("sourceArtifactDigest", ""))
	var projection_bound: bool = false
	for digest_value: Variant in projected_artifact.get("sourceArtifactDigests", []):
		if digest_value is Dictionary \
				and String(digest_value.get("sourceId", "")) == source_id \
				and String(digest_value.get("sourceArtifactDigest", "")) == source_digest:
			projection_bound = true
			break
	var accepted_instances := int(source_artifact.get(
		"nativeTreePackAcceptedInstances", 0))
	return {"status":"ready" if source_digest.length() == 64 and projection_bound \
		and accepted_instances > 0 else "pending",
		"reason":"" if projection_bound else "projected_band_source_digest_mismatch",
		"sourceJobKeyDigest":_test_var_bytes_digest(source_job_key),
		"sourceArtifactDigest":source_digest,
		"projectionBoundToSourceArtifact":projection_bound,
		"nativeTreePackAcceptedInstances":accepted_instances,
		"nativeTreePackAcceptanceUsec":int(source_artifact.get(
			"nativeTreePackAcceptanceUsec", 0)),
		"sourceGeometryDisposition":String(source_artifact.get(
			"sourceGeometryDisposition", "")),
		"sourceBatchCount":(source_artifact.get("batches", []) as Array).size()}


func _tree_band_revision_input_comparison(queue: Object,
		diagnostic: Dictionary, source_chunk: Vector2i) -> Dictionary:
	var samples_value: Variant = diagnostic.get("sampleRows", null)
	var source_id: String = String(diagnostic.get("sourceId", ""))
	var source_part_id: String = String(diagnostic.get("sourcePartId", ""))
	if not is_instance_valid(queue) or not samples_value is Array \
			or source_id.is_empty() or source_part_id.is_empty():
		return {"status":"pending", "preflightPassed":false,
			"reason":"tree_revision_input_diagnostic_identity_missing",
			"sampleCount":0, "recordCount":0, "records":[], "differences":[]}
	var band_jobs_value: Variant = queue.get("ecology_tree_band_compile_jobs")
	if not band_jobs_value is Dictionary:
		return {"status":"pending", "preflightPassed":false,
			"reason":"tree_revision_input_band_jobs_missing",
			"sampleCount":samples_value.size(), "recordCount":0,
			"records":[], "differences":[]}
	var band_jobs: Dictionary = band_jobs_value
	var records: Array[Dictionary] = []
	var preflight_failures: Array[String] = []
	for sample_value: Variant in samples_value:
		if not sample_value is Dictionary:
			preflight_failures.append("sample_invalid")
			continue
		var sample: Dictionary = sample_value
		var section_value: Variant = sample.get("sectionKey", null)
		if not section_value is Vector3i:
			preflight_failures.append("section_key_missing")
			continue
		var matched_job: Dictionary = {}
		var source_job: Dictionary = {}
		var matched_manifest: Dictionary = {}
		var source_artifact: Dictionary = {}
		var ordered_job_keys: Array = band_jobs.keys()
		ordered_job_keys.sort()
		for job_key_value: Variant in ordered_job_keys:
			var job_value: Variant = band_jobs.get(job_key_value, null)
			if not job_value is Dictionary:
				continue
			var candidate: Dictionary = job_value
			if candidate.get("sourceChunkKey", null) != source_chunk \
					or candidate.get("sectionKey", null) != section_value \
					or String(candidate.get("status", "")) != "complete":
				continue
			var record_job_keys: Variant = candidate.get("recordJobKeys", null)
			if not record_job_keys is Dictionary:
				continue
			var source_job_key := String(record_job_keys.get(source_id, ""))
			var source_job_value: Variant = queue.ecology_source_compile_jobs.get(
				source_job_key, null) if not source_job_key.is_empty() else null
			if not source_job_value is Dictionary:
				continue
			var candidate_source_job: Dictionary = source_job_value
			if String(candidate_source_job.get("artifactKind", "")) \
					!= "tree_source_record_geometry" \
					or String(candidate_source_job.get("status", "")) != "complete" \
					or String(candidate_source_job.get("sourceId", "")) != source_id:
				continue
			var artifact_value: Variant = queue.call("_tree_artifact_holder_view",
				candidate_source_job.get("resultHolder", {}))
			if not artifact_value is Dictionary \
					or String(artifact_value.get("schema", "")) \
					!= CompiledTreeSectionArtifact.SOURCE_RECORD_GEOMETRY_SCHEMA:
				continue
			var manifest_found: bool = false
			for manifest_value: Variant in artifact_value.get("sources", []):
				if manifest_value is Dictionary \
						and String(manifest_value.get("sourceId", "")) == source_id \
						and String(manifest_value.get("sourceRevision", "")) \
						== String(sample.get("cachedSourceRevision", "")):
					matched_manifest = manifest_value
					manifest_found = true
					break
			if manifest_found:
				matched_job = candidate
				source_job = candidate_source_job
				source_artifact = artifact_value
				break
		if matched_job.is_empty() or source_job.is_empty() or source_artifact.is_empty():
			preflight_failures.append("completed_source_artifact_not_retained:%s" % [
				str(section_value)])
			continue
		var admitted_source_row: Variant = source_job.get("sourceRecord", null)
		var source_holder: Variant = source_job.get("resultHolder", null)
		var compiler_roots: Variant = source_holder.get("compilerValueRoots", {}) \
			if source_holder is Dictionary else {}
		var prepared_records: Variant = compiler_roots.get("records", []) \
			if compiler_roots is Dictionary else []
		var source_record: Dictionary = {}
		if prepared_records is Array:
			for prepared_record_value: Variant in prepared_records:
				if prepared_record_value is Dictionary \
						and String(prepared_record_value.get("sourceId", "")) == source_id \
						and is_same(prepared_record_value.get("sourceRecord", null),
							admitted_source_row):
					source_record = prepared_record_value
					break
		if source_record.is_empty():
			preflight_failures.append("prepared_source_record_not_retained:%s" % [
				str(section_value)])
			continue
		var content_values: Array = [String(source_record.get("schema", "")),
			String(source_record.get("sourceDomainRevision", "")),
			String(source_record.get("sourceRevision", "")),
			String(source_record.get("producerRevision", "")),
			String(source_record.get("sourceRecordDigest", "")),
			String(source_record.get("sourceProvenanceDigest", "")),
			String(source_record.get("recipeSignature", "")),
			source_record.get("request", null),
			source_record.get("recipeSnapshot", null),
			source_record.get("supportEnvelope", null)]
		var raw_content_input_digest: String = _test_var_bytes_digest(content_values)
		var recomputed_revision: String = \
			TreeCompilerScript.immutable_source_content_revision(
				String(source_record.get("sourceDomainRevision", "")),
				String(source_record.get("sourceRevision", "")),
				String(source_record.get("producerRevision", "")),
				String(source_record.get("sourceRecordDigest", "")),
				String(source_record.get("sourceProvenanceDigest", "")),
				String(source_record.get("recipeSignature", "")),
				source_record.get("request", {}),
				source_record.get("recipeSnapshot", {}),
				source_record.get("supportEnvelope", {}))
		var publication_view: Dictionary = source_job.get("publicationView", {})
		var publication_payload: Variant = publication_view.get("payload", null)
		var source_provenance: Variant = source_record.get("sourceProvenance", null)
		var source_record_aliases_publication_row: bool = false
		var tree_family: Dictionary = publication_view.get("familyResultsById", {}).get(
			"trees", {})
		for publication_row_value: Variant in tree_family.get("sourceRows", []):
			if publication_row_value is Dictionary and is_same(
					source_record.get("sourceRecord", null), publication_row_value):
				source_record_aliases_publication_row = true
				break
		var recipe_job_key: String = String(source_record.get("recipeJobKey", ""))
		var recipe_job_key_parts: PackedStringArray = recipe_job_key.split("|", false)
		var completed_recipes_value: Variant = queue.get("source_recipe_completed")
		var completed_recipes: Dictionary = completed_recipes_value \
			if completed_recipes_value is Dictionary else {}
		var recipe_artifact_value: Variant = source_record.get("recipeArtifact", null)
		var completed_recipe_value: Variant = completed_recipes.get(recipe_job_key, null)
		if not completed_recipe_value is Dictionary and recipe_artifact_value is Dictionary:
			completed_recipe_value = recipe_artifact_value
		var recipe_artifact: Dictionary = completed_recipe_value \
			if completed_recipe_value is Dictionary else {}
		var input_rows: Array[Dictionary] = []
		var input_names: Array[String] = ["schema", "sourceDomainRevision",
			"sourceRevision", "producerRevision", "sourceRecordDigest",
			"sourceProvenanceDigest", "recipeSignature", "request",
			"recipeSnapshot", "supportEnvelope"]
		for input_index in input_names.size():
			var input_name: String = input_names[input_index]
			var input_value: Variant = content_values[input_index]
			input_rows.append({"name":input_name,
				"digest":_test_var_bytes_digest(input_value),
				"shape":_tree_revision_value_shape(input_value)})
		var recipe_key_components: Dictionary = {"sourceId":String(source_record.get("sourceId", "")),
			"sourceRevision":String(source_record.get("sourceRevision", "")),
			"producerRevision":String(source_record.get("producerRevision", "")),
			"requestDigest":String(source_record.get("requestDigest", "")),
			"sourceRecordDigest":String(source_record.get("sourceRecordDigest", "")),
			"provenanceDigest":String(source_record.get("sourceProvenanceDigest", "")),
			"recipeJobKeyDigest":_test_var_bytes_digest(recipe_job_key),
			"ownerSuffix":recipe_job_key_parts[-2] if recipe_job_key_parts.size() >= 2 else "",
			"publicationSuffix":recipe_job_key_parts[-1] \
				if recipe_job_key_parts.size() >= 1 else "",
			"completedArtifactPresent":completed_recipe_value is Dictionary,
			"recipeSignature":String(recipe_artifact.get("recipeSignature", "")),
			"artifactRequestDigest":String(recipe_artifact.get("requestDigest", "")),
			"artifactSourceRecordDigest":String(recipe_artifact.get("sourceRecordDigest", "")),
			"artifactProvenanceDigest":String(recipe_artifact.get("provenanceDigest", ""))}
		var row: Dictionary = {"sectionKey":section_value,
			"bandJobKeyDigest":_test_var_bytes_digest(String(matched_job.get("key", ""))),
			"sourceJobKeyDigest":_test_var_bytes_digest(String(source_job.get("key", ""))),
			"sourceArtifactDigest":String(source_artifact.get("sourceArtifactDigest", "")),
			"nativeTreePackAcceptedInstances":int(source_artifact.get(
				"nativeTreePackAcceptedInstances", 0)),
			"publicationId":String(publication_view.get("publicationId", "")),
			"publicationContentDigest":String(publication_view.get("contentDigest", "")),
			"publicationSourceDomainRevision":String(publication_view.get(
				"sourceDomainRevision", "")),
			"recordProvenanceAliasesPublicationPayload":is_same(source_provenance,
				publication_payload),
			"sourceRecordAliasesPublicationRow":source_record_aliases_publication_row,
			"recordProvenanceDigestMatchesPublication":String(source_record.get(
				"sourceProvenanceDigest", "")) == String(publication_view.get(
				"contentDigest", "")),
			"recordDomainRevisionMatchesPublication":String(source_record.get(
				"sourceDomainRevision", "")) == String(publication_view.get(
				"sourceDomainRevision", "")),
			"requestDigestMatchesRequest":String(source_record.get("requestDigest", "")) \
				== _test_var_bytes_digest(source_record.get("request", null)),
			"recipeArtifactRequestMatchesRecord":recipe_artifact.get("request", null) \
				== source_record.get("request", null),
			"recipeArtifactRecipeMatchesRecord":recipe_artifact.get("recipe", null) \
				== source_record.get("recipeSnapshot", null),
			"recipeArtifactProvenanceAliasesPublicationPayload":is_same(
				recipe_artifact.get("provenance", null), publication_payload),
		"sourceRecordDigestMatchesManifest":String(source_record.get(
			"sourceRecordDigest", "")) == String(matched_manifest.get(
			"sourceRecordDigest", "")),
			"compiledAttributeDigest":String(matched_manifest.get(
				"compiledAttributeDigest", "")),
			"geometryOwnershipDigest":_test_var_bytes_digest(
				matched_manifest.get("geometryOwnership", [])),
			"geometryOwnershipCount":(matched_manifest.get(
				"geometryOwnership", []) as Array).size(),
			"recipeArtifactRevision":String(matched_manifest.get(
				"recipeArtifactRevision", "")),
			"recordContentRevision":String(source_record.get("contentRevision", "")),
			"rawContentInputDigest":raw_content_input_digest,
			"rawDigestDiffersFromCanonical":raw_content_input_digest != recomputed_revision,
			"recomputedContentRevision":recomputed_revision,
			"contentRevisionMatches":recomputed_revision == String(
				source_record.get("contentRevision", "")),
			"manifestRevisionMatches":String(matched_manifest.get(
				"recipeArtifactRevision", "")) == String(
				source_record.get("contentRevision", "")),
			"recipeJobKey":recipe_key_components,
			"contentInputs":input_rows,
			"_comparisonValues":content_values}
		records.append(row)
	var differences: Array[Dictionary] = []
	if records.size() >= 2:
		var left_values: Array = records[0].get("_comparisonValues", [])
		var right_values: Array = records[1].get("_comparisonValues", [])
		var labels: Array[String] = ["schema", "sourceDomainRevision",
			"sourceRevision", "producerRevision", "sourceRecordDigest",
			"sourceProvenanceDigest", "recipeSignature", "request",
			"recipeSnapshot", "supportEnvelope"]
		for input_index in mini(left_values.size(), right_values.size()):
			_tree_revision_value_differences(left_values[input_index],
				right_values[input_index], labels[input_index], differences, 16)
		for row_value: Variant in records:
			if row_value is Dictionary:
				(row_value as Dictionary).erase("_comparisonValues")
	var revisions: Array[String] = []
	var recipe_keys: Array[String] = []
	var publication_ids: Array[String] = []
	for row_value: Variant in records:
		if not row_value is Dictionary:
			continue
		var row_record: Dictionary = row_value
		revisions.append(String(row_record.get("recordContentRevision", "")))
		recipe_keys.append(String(row_record.get("recipeJobKey", {}).get("recipeJobKeyDigest", "")))
		publication_ids.append(String(row_record.get("publicationId", "")))
	var unique_revisions: Dictionary = {}
	for revision: String in revisions:
		unique_revisions[revision] = true
	var unique_recipe_keys: Dictionary = {}
	for recipe_key_digest: String in recipe_keys:
		unique_recipe_keys[recipe_key_digest] = true
	var unique_publication_ids: Dictionary = {}
	for publication_id: String in publication_ids:
		unique_publication_ids[publication_id] = true
	var preflight_passed: bool = records.size() == samples_value.size() \
		and records.size() >= 2 and preflight_failures.is_empty()
	for record_value: Variant in records:
		if not record_value is Dictionary \
				or not bool(record_value.get("contentRevisionMatches", false)) \
				or not bool(record_value.get("manifestRevisionMatches", false)) \
				or not bool(record_value.get("recordProvenanceAliasesPublicationPayload", false)) \
				or not bool(record_value.get("sourceRecordAliasesPublicationRow", false)) \
				or not bool(record_value.get("recordProvenanceDigestMatchesPublication", false)) \
				or not bool(record_value.get("recordDomainRevisionMatchesPublication", false)) \
				or not bool(record_value.get("requestDigestMatchesRequest", false)) \
				or not bool(record_value.get("recipeArtifactRequestMatchesRecord", false)) \
				or not bool(record_value.get("recipeArtifactRecipeMatchesRecord", false)) \
				or not bool(record_value.get(
					"recipeArtifactProvenanceAliasesPublicationPayload", false)):
			preflight_passed = false
	return {"status":"ready" if preflight_passed else "pending",
		"preflightPassed":preflight_passed,
		"reason":"" if preflight_passed else "tree_revision_input_preflight_incomplete",
		"sourceId":source_id, "sourcePartId":source_part_id,
		"sourceChunkKey":source_chunk, "sampleCount":samples_value.size(),
		"recordCount":records.size(), "preflightFailures":preflight_failures,
		"distinctContentRevisionCount":unique_revisions.size(),
		"sharedRecipeJobKey":unique_recipe_keys.size() == 1,
		"sharedPublicationId":unique_publication_ids.size() == 1,
		"records":records, "recursiveDifferences":differences}


func _tree_band_revision_input_diagnostic_contract() -> Dictionary:
	var queue: Object = TreeQueueScript.new()
	var payload: Dictionary = {"schema":"diagnostic-publication-payload"}
	var publication_view: Dictionary = {"publicationId":"diagnostic-publication",
		"contentDigest":"diagnostic-publication-digest",
		"sourceDomainRevision":"diagnostic-domain-revision", "payload":payload,
		"familyResultsById":{"trees":{"sourceRows":[{
			"sourceId":"diagnostic-source"}]}}}
	var publication_tree_family: Dictionary = publication_view.get(
		"familyResultsById", {}).get("trees", {})
	var publication_tree_rows: Array = publication_tree_family.get("sourceRows", [])
	var producer_row: Dictionary = publication_tree_rows[0]
	var sample_rows: Array[Dictionary] = []
	var sections: Array[Vector3i] = [Vector3i(0, -1, 0), Vector3i.ZERO]
	var recipe_keys: Array[String] = []
	for section_index in sections.size():
		var request: Dictionary = {"biome":"forest", "sourceInputRevision":"request-a"}
		if section_index == 1:
			request["sourceInputRevision"] = "request-b"
		var content_values: Array = ["ecology.static_source_value.v1",
			"diagnostic-domain-revision", "diagnostic-source-revision",
			"diagnostic-producer-revision", "diagnostic-source-record-digest",
			"diagnostic-publication-digest", "diagnostic-recipe-signature",
			request, {"signature":"diagnostic-recipe-signature"},
			{"certifiedEnvelopeDigest":"diagnostic-envelope-digest"}]
		var record: Dictionary = {"schema":content_values[0],
			"sourceId":"diagnostic-source", "sourcePartId":"diagnostic-part",
			"sourceDomainRevision":content_values[1],
			"sourceRevision":content_values[2],
			"producerRevision":content_values[3],
			"sourceRecordDigest":content_values[4],
			"sourceProvenanceDigest":content_values[5],
			"recipeSignature":content_values[6], "request":content_values[7],
			"recipeSnapshot":content_values[8], "supportEnvelope":content_values[9],
			"sourceRecord":producer_row, "sourceProvenance":payload,
			"requestDigest":_test_var_bytes_digest(request),
			"recipeJobKey":"diagnostic-source|%d" % [section_index],
			"contentRevision":TreeCompilerScript.immutable_source_content_revision(
				String(content_values[1]), String(content_values[2]),
				String(content_values[3]), String(content_values[4]),
				String(content_values[5]), String(content_values[6]),
				content_values[7], content_values[8], content_values[9])}
		recipe_keys.append(String(record.recipeJobKey))
		var recipe_artifact: Dictionary = {
			"request":record.request, "recipe":record.recipeSnapshot,
			"provenance":payload, "requestDigest":String(record.requestDigest),
			"sourceRecordDigest":String(record.sourceRecordDigest),
			"provenanceDigest":String(record.sourceProvenanceDigest),
			"recipeSignature":String(record.recipeSignature)}
		record["recipeArtifact"] = recipe_artifact
		queue.source_recipe_completed[String(record.recipeJobKey)] = recipe_artifact
		var manifest: Dictionary = {"sourceId":"diagnostic-source",
			"sourceRevision":"diagnostic-compiled-revision",
			"sourceRecordDigest":String(record.sourceRecordDigest),
			"recipeArtifactRevision":String(record.contentRevision)}
		var source_artifact: Dictionary = {
			"schema":CompiledTreeSectionArtifact.SOURCE_RECORD_GEOMETRY_SCHEMA,
			"sourceId":"diagnostic-source",
			"sourceRecordDigest":String(record.sourceRecordDigest),
			"sourceArtifactDigest":"a".repeat(64), "sources":[manifest],
			"resourceBindings":{}}
		var holder: Dictionary = queue.call("_tree_artifact_holder", source_artifact)
		holder["compilerValueRoots"] = {"records":[record]}
		var source_job_key: String = "diagnostic-source-job:%d" % [section_index]
		queue.ecology_source_compile_jobs[source_job_key] = {
			"key":source_job_key, "artifactKind":"tree_source_record_geometry",
			"sourceId":"diagnostic-source", "status":"complete",
			"sourceRecord":producer_row, "publicationView":publication_view,
			"resultHolder":holder}
		var job_key: String = "diagnostic-band:%d" % [section_index]
		queue.ecology_tree_band_compile_jobs[job_key] = {
			"key":job_key, "status":"complete", "sourceChunkKey":Vector2i.ZERO,
			"sectionKey":sections[section_index],
			"recordJobKeys":{"diagnostic-source":source_job_key},
			"publicationView":publication_view,
			"artifact":{"sources":[manifest]}}
		sample_rows.append({"sectionKey":sections[section_index],
			"cachedSourceRevision":"diagnostic-compiled-revision"})
	var probe: Dictionary = _tree_band_revision_input_comparison(queue,
		{"sourceId":"diagnostic-source", "sourcePartId":"diagnostic-part",
			"sampleRows":sample_rows}, Vector2i.ZERO)
	var differences: Array = probe.get("recursiveDifferences", [])
	var request_difference_found: bool = false
	for difference_value: Variant in differences:
		if difference_value is Dictionary and String(difference_value.get("path", "")) \
				.begins_with("request/"):
			request_difference_found = true
			break
	var passed: bool = bool(probe.get("preflightPassed", false)) \
		and int(probe.get("recordCount", 0)) == 2 \
		and int(probe.get("distinctContentRevisionCount", 0)) == 2 \
		and not bool(probe.get("sharedRecipeJobKey", true)) \
		and bool(probe.get("sharedPublicationId", false)) \
		and request_difference_found \
		and recipe_keys[0] != recipe_keys[1]
	queue.free()
	return {"status":"ready" if passed else "failed",
		"preflightPassed":passed,
		"recordCount":int(probe.get("recordCount", 0)),
		"distinctContentRevisionCount":int(probe.get(
			"distinctContentRevisionCount", 0)),
		"recursiveDifferenceCount":differences.size(),
		"requestDifferenceFound":request_difference_found,
		"reason":"" if passed else "tree_revision_input_comparison_probe_mismatch"}


func _tree_revision_value_shape(value: Variant) -> Dictionary:
	var shape: Dictionary = {"type":type_string(typeof(value))}
	if value is Dictionary:
		var keys: Array = value.keys()
		shape["readOnly"] = value.is_read_only()
		shape["keyCount"] = keys.size()
		shape["keyOrderDigest"] = _test_var_bytes_digest(keys)
	elif value is Array:
		var array_value: Array = value
		shape["readOnly"] = array_value.is_read_only()
		shape["size"] = array_value.size()
		shape["typed"] = array_value.is_typed()
		if array_value.is_typed():
			shape["typedBuiltin"] = type_string(array_value.get_typed_builtin())
			shape["typedClass"] = array_value.get_typed_class_name()
			var typed_script: Script = array_value.get_typed_script()
			shape["typedScriptPath"] = typed_script.resource_path if typed_script != null else ""
	return shape


func _tree_revision_value_differences(left: Variant, right: Variant,
		path: String, differences: Array[Dictionary], limit: int) -> void:
	if differences.size() >= limit:
		return
	var left_shape: Dictionary = _tree_revision_value_shape(left)
	var right_shape: Dictionary = _tree_revision_value_shape(right)
	if typeof(left) != typeof(right):
		differences.append({"path":path, "kind":"variant_type",
			"left":left_shape, "right":right_shape,
			"leftDigest":_test_var_bytes_digest(left),
			"rightDigest":_test_var_bytes_digest(right)})
		return
	if left is Dictionary and right is Dictionary:
		var left_keys: Array = left.keys()
		var right_keys: Array = right.keys()
		if left_keys != right_keys and differences.size() < limit:
			differences.append({"path":path, "kind":"dictionary_key_order_or_membership",
				"leftKeyCount":left_keys.size(), "rightKeyCount":right_keys.size(),
				"leftKeyDigest":_test_var_bytes_digest(left_keys),
				"rightKeyDigest":_test_var_bytes_digest(right_keys)})
		var common_keys: Array = []
		for key: Variant in left_keys:
			if right.has(key):
				common_keys.append(key)
		for key: Variant in common_keys:
			if differences.size() >= limit:
				break
			_tree_revision_value_differences(left[key], right[key],
				"%s/%s" % [path, str(key)], differences, limit)
		return
	if left is Array and right is Array:
		var left_array: Array = left
		var right_array: Array = right
		if left_array.is_typed() != right_array.is_typed() \
				or left_shape.get("typedBuiltin", -1) != right_shape.get("typedBuiltin", -1) \
				or left_shape.get("typedClass", "") != right_shape.get("typedClass", "") \
				or left_shape.get("typedScriptPath", "") != right_shape.get("typedScriptPath", ""):
			differences.append({"path":path, "kind":"array_typedness",
				"left":left_shape, "right":right_shape})
		if left_array.size() != right_array.size() and differences.size() < limit:
			differences.append({"path":path, "kind":"array_size",
				"leftSize":left_array.size(), "rightSize":right_array.size()})
		for index in range(mini(left_array.size(), right_array.size())):
			if differences.size() >= limit:
				break
			_tree_revision_value_differences(left_array[index], right_array[index],
				"%s[%d]" % [path, index], differences, limit)
		return
	var values_equal: bool = left == right
	if left is float and right is float:
		values_equal = is_equal_approx(float(left), float(right))
	if not values_equal:
		differences.append({"path":path, "kind":"value",
			"left":left_shape, "right":right_shape,
			"leftDigest":_test_var_bytes_digest(left),
			"rightDigest":_test_var_bytes_digest(right)})


func _tree_band_revision_digest_sample(compiled: Dictionary, band_key: String,
		identity_key: String) -> Dictionary:
	var artifact_value: Variant = compiled.get("artifact", {})
	var artifact: Dictionary = artifact_value if artifact_value is Dictionary else {}
	var source_manifest_value: Variant = compiled.get("sourceManifest", {})
	var source_manifest: Dictionary = source_manifest_value \
		if source_manifest_value is Dictionary else {}
	var ownership_value: Variant = source_manifest.get("geometryOwnership", [])
	var ownership_digest: String = _test_var_bytes_digest(ownership_value)
	var batch_order_rows: Array = []
	for batch_value: Variant in artifact.get("batches", []):
		if not batch_value is Dictionary:
			batch_order_rows.append(["invalid_batch"])
			continue
		var batch: Dictionary = batch_value
		var contributors_value: Variant = batch.get("contributors", {})
		var contributor_ids: Array[String] = []
		if contributors_value is Dictionary:
			for contributor_id_value: Variant in contributors_value:
				contributor_ids.append(String(contributor_id_value))
		contributor_ids.sort()
		var section: Variant = batch.get("sectionKey", null)
		var section_row: Array = [section.x, section.y, section.z] \
			if section is Vector3i else []
		batch_order_rows.append([section_row, String(batch.get("batchKey", "")),
			String(batch.get("role", "")), int(batch.get("instanceCount", -1)),
			contributor_ids.size(), _test_var_bytes_digest(contributor_ids)])
	var batch_order_sample: Array = []
	for row_value: Variant in batch_order_rows:
		if batch_order_sample.size() >= 8:
			break
		batch_order_sample.append(row_value)
	return {"identityKey":identity_key, "bandKey":band_key,
		"cachedSourceId":String(compiled.get("sourceId", "")),
		"cachedSourcePartId":String(compiled.get("sourcePartId", "")),
		"sectionKey":compiled.get("sectionKey", null),
		"sourceChunkKey":compiled.get("sourceChunkKey", null),
		"cachedSourceRevision":String(compiled.get("sourceRevision", "")),
		"manifestSourceId":String(source_manifest.get("sourceId", "")),
		"manifestHasPartId":source_manifest.has("sourcePartId"),
		"manifestPartId":String(source_manifest.get("sourcePartId", "")),
		"manifestSourceRevision":String(source_manifest.get("sourceRevision", "")),
		"sourceDomainRevision":String(source_manifest.get("sourceDomainRevision", "")),
		"sourceRecordDigest":String(source_manifest.get("sourceRecordDigest", "")),
		"recipeArtifactRevision":String(source_manifest.get("recipeArtifactRevision", "")),
		"compiledAttributeDigest":String(source_manifest.get("compiledAttributeDigest", "")),
		"geometryOwnershipCount":ownership_value.size() \
			if ownership_value is Array else -1,
		"geometryOwnershipDigest":ownership_digest,
		"sourceCompletionDigest":String(artifact.get("sourceCompletionDigest", "")),
		"ownerBatchPayloadDigest":String(artifact.get("ownerBatchPayloadDigest", "")),
		"batchCount":batch_order_rows.size(),
		"batchOrderDigest":_test_var_bytes_digest(batch_order_rows),
		"batchOrderSample":batch_order_sample}


func _tree_band_support_set_diagnostic(artifact: Dictionary,
		section_keys: Array[Vector3i], overlays_by_section: Dictionary) -> Dictionary:
	var expected_by_section: Dictionary = {}
	for source_value: Variant in artifact.get("sources", []):
		if not source_value is Dictionary:
			continue
		var source: Dictionary = source_value
		var source_id := String(source.get("sourceId", ""))
		for member_value: Variant in source.get("geometryOwnership", []):
			if not member_value is Dictionary:
				continue
			var member: Dictionary = member_value
			var member_id := String(member.get("memberId", ""))
			var supports: Variant = member.get("supportSectionKeys", null)
			if source_id.is_empty() or member_id.is_empty() or not supports is Array:
				continue
			var identity := source_id + "|" + member_id
			for section_value: Variant in supports:
				if not section_value is Vector3i:
					continue
				var section_key: Vector3i = section_value
				if not expected_by_section.has(section_key):
					expected_by_section[section_key] = []
				(expected_by_section[section_key] as Array).append(identity)
	var section_rows: Array[Dictionary] = []
	var all_missing_ids: Array[String] = []
	var all_extra_ids: Array[String] = []
	var expected_section_names: Array[String] = []
	var actual_section_names: Array[String] = []
	var target_expected_count := 0
	var target_actual_count := 0
	for section_key: Vector3i in section_keys:
		var expected_ids: Array = expected_by_section.get(section_key, []).duplicate()
		expected_ids.sort()
		var overlay: Dictionary = overlays_by_section.get(section_key, {})
		var actual_ids: Array[String] = []
		for row_value: Variant in overlay.get("supportRows", []):
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			var source_id := String(row.get("sourceId", ""))
			var member_id := String(row.get("sourcePartId", ""))
			if not source_id.is_empty() and not member_id.is_empty():
				actual_ids.append(source_id + "|" + member_id)
		actual_ids.sort()
		var missing_ids: Array[String] = []
		var extra_ids: Array[String] = []
		for identity_value: Variant in expected_ids:
			var identity := String(identity_value)
			if not identity in actual_ids:
				missing_ids.append(identity)
		for identity: String in actual_ids:
			if not identity in expected_ids:
				extra_ids.append(identity)
		var section_name := "%d,%d,%d" % [section_key.x, section_key.y,
			section_key.z]
		if not expected_ids.is_empty(): expected_section_names.append(section_name)
		if not actual_ids.is_empty(): actual_section_names.append(section_name)
		for identity: String in missing_ids:
			all_missing_ids.append(section_name + "|" + identity)
		for identity: String in extra_ids:
			all_extra_ids.append(section_name + "|" + identity)
		if section_rows.size() < 8:
			section_rows.append({"sectionKey":section_name,
				"expectedCount":expected_ids.size(), "actualCount":actual_ids.size(),
				"missingCount":missing_ids.size(), "extraCount":extra_ids.size(),
				"missingIdsSample":missing_ids.slice(0, 8),
				"extraIdsSample":extra_ids.slice(0, 8)})
		if section_key == section_keys[0]:
			target_expected_count = expected_ids.size()
			target_actual_count = actual_ids.size()
	expected_section_names.sort()
	actual_section_names.sort()
	all_missing_ids.sort()
	all_extra_ids.sort()
	return {"targetSection":"%d,%d,%d" % [section_keys[0].x,
			section_keys[0].y, section_keys[0].z],
		"expectedMemberCount":target_expected_count,
		"actualMemberCount":target_actual_count,
		"missingMemberCount":all_missing_ids.size(),
		"extraMemberCount":all_extra_ids.size(),
		"missingMemberIdsAndSectionsSample":all_missing_ids.slice(0, 8),
		"extraMemberIdsAndSectionsSample":all_extra_ids.slice(0, 8),
		"expectedSupportSections":expected_section_names,
		"actualSupportSections":actual_section_names,
		"sectionRows":section_rows,
		"adapterFilterField":"supportSectionKeys",
		"converterOutputField":"conservativeSupportSectionKeys"}


func _fixture_catalog_scope_contract(main: ProductionAuthority,
		world_id: String, source_chunk: Vector2i) -> Dictionary:
	var original_profile: Dictionary = main._profile_snapshot.duplicate(true)
	var initial_interns := main.catalog_scope_artifact_interns
	var outer := main.begin_ecology_source_catalog_context_scope()
	var first: Dictionary = main._canonical_fixture_inputs(world_id,
		source_chunk, main.seed_text, {"terrainVolumeChunkRevision":"scope-source-a"})
	var nested := main.begin_ecology_source_catalog_context_scope()
	main._profile_snapshot["contentIdentity"] = String(
		main._profile_snapshot.get("contentIdentity", "")) + "-nested-mutation"
	var second_chunk := source_chunk + Vector2i(1, 0)
	var second: Dictionary = main._canonical_fixture_inputs(world_id,
		second_chunk, main.seed_text,
		{"terrainVolumeChunkRevision":"scope-source-b"})
	var nested_ended := main.end_ecology_source_catalog_context_scope(nested)
	var third: Dictionary = main._canonical_fixture_inputs(world_id,
		source_chunk, main.seed_text,
		{"terrainVolumeChunkRevision":"scope-source-c"})
	var outer_ended := main.end_ecology_source_catalog_context_scope(outer)
	var between_scopes := main.begin_ecology_source_catalog_context_scope()
	var recaptured: Dictionary = main._canonical_fixture_inputs(world_id,
		second_chunk, main.seed_text,
		{"terrainVolumeChunkRevision":"scope-source-b"})
	var between_scopes_ended := main.end_ecology_source_catalog_context_scope(
		between_scopes)
	main._profile_snapshot = original_profile.duplicate(true)
	var scope_alias_reused: bool = first.get("catalogArtifactId", "") \
		== second.get("catalogArtifactId", "") \
		and first.get("catalogContentDigest", "") \
		== third.get("catalogContentDigest", "") \
		and String(third.get("terrainVolumeChunkRevision", "")) == "scope-source-c" \
		and main.catalog_scope_artifact_interns - initial_interns == 2
	var per_source_fields_rebuilt: bool = second.get("sourceChunkKey", null) == second_chunk \
		and String(second.get("terrainVolumeChunkRevision", "")) == "scope-source-b" \
		and first.get("sourceChunkKey", null) == source_chunk \
		and String(first.get("terrainVolumeChunkRevision", "")) == "scope-source-a"
	var nested_profile_mutation_seen_at_next_scope: bool = recaptured.get(
		"catalogArtifactId", "") != first.get("catalogArtifactId", "")
	var scope_protocol_balanced := String(outer.get("status", "")) == "ready" \
		and String(nested.get("status", "")) == "ready" \
		and String(nested_ended.get("status", "")) == "ready" \
		and String(outer_ended.get("status", "")) == "ready" \
		and String(between_scopes_ended.get("status", "")) == "ready" \
		and main.catalog_scope_depth == 0
	var prior_snapshot_by_chunk: Variant = main.fixture_snapshots_by_chunk.get(
		source_chunk, null)
	var prior_families_by_chunk: Variant = main.fixture_snapshots_by_chunk_family.get(
		source_chunk, null)
	var prior_publication_sequence := main.publication_sequence
	var prior_publication_identities: Dictionary = \
		main.publication_identity_by_id.duplicate(true)
	var prior_last_captured_snapshot: Dictionary = \
		main.last_captured_source_domain_snapshot
	var prior_capture_call_count := main.source_domain_capture_calls
	var prior_structure_dependency_digests: Array[String] = \
		main.captured_structure_dependency_digests.duplicate()
	var prior_corrupt_next := main.corrupt_next_source_domain_snapshot
	var prior_corruption_applied := main.source_domain_corruption_applied
	var prior_corrupted_snapshot: Dictionary = \
		main.corrupted_source_domain_snapshot
	var source_capture := main.capture_ecology_source_domain(world_id,
		source_chunk, main.seed_text, first, RemovedProps.capture(main))
	var publication_view: Dictionary = source_capture.get("sourcePublicationView", {})
	var publication_lease := String(source_capture.get(
		"sourcePublicationLeaseToken", ""))
	var valid_scope := main.begin_ecology_source_catalog_context_scope()
	var current_before_change := main.ecology_source_publication_local_is_current(
		publication_view, publication_lease)
	var original_latest_by_family: Dictionary = main.fixture_snapshots_by_chunk_family.get(
		source_chunk, {}).duplicate(true)
	var latest_by_family: Dictionary = original_latest_by_family.duplicate(true)
	var latest_snapshot: Dictionary = latest_by_family.get("trees", {}).duplicate(true)
	var latest_coverage: Array = latest_snapshot.get("familyCoverage", []).duplicate(true)
	for index in range(latest_coverage.size()):
		var coverage: Dictionary = latest_coverage[index]
		if String(coverage.get("family", "")) == "trees":
			coverage["familyRevision"] = String(coverage.get("familyRevision", "")) \
				+ "-changed-during-scope"
			latest_coverage[index] = coverage
	latest_snapshot["familyCoverage"] = latest_coverage
	latest_by_family["trees"] = latest_snapshot
	main.fixture_snapshots_by_chunk_family[source_chunk] = latest_by_family
	var current_after_change := main.ecology_source_publication_local_is_current(
		publication_view, publication_lease)
	var invalid_restore := main.end_ecology_source_catalog_context_scope(valid_scope)
	main.fixture_snapshots_by_chunk_family[source_chunk] = original_latest_by_family
	main._profile_snapshot["contentIdentity"] = String(
		main._profile_snapshot.get("contentIdentity", "")) + "-between-scope-mutation"
	var profile_change_result := main.ecology_source_publication_local_is_current(
		publication_view, publication_lease)
	main._profile_snapshot = original_profile.duplicate(true)
	if not publication_lease.is_empty():
		main.release_ecology_source_publication(publication_lease)
	if prior_snapshot_by_chunk == null:
		main.fixture_snapshots_by_chunk.erase(source_chunk)
	else:
		main.fixture_snapshots_by_chunk[source_chunk] = prior_snapshot_by_chunk
	if prior_families_by_chunk == null:
		main.fixture_snapshots_by_chunk_family.erase(source_chunk)
	else:
		main.fixture_snapshots_by_chunk_family[source_chunk] = prior_families_by_chunk
	main.publication_sequence = prior_publication_sequence
	main.publication_identity_by_id = prior_publication_identities
	main.last_captured_source_domain_snapshot = prior_last_captured_snapshot
	main.source_domain_capture_calls = prior_capture_call_count
	main.captured_structure_dependency_digests = prior_structure_dependency_digests
	main.corrupt_next_source_domain_snapshot = prior_corrupt_next
	main.source_domain_corruption_applied = prior_corruption_applied
	main.corrupted_source_domain_snapshot = prior_corrupted_snapshot
	var all_scopes_balanced := main.catalog_scope_depth == 0 \
		and main.catalog_scope_begins == main.catalog_scope_ends
	return {
		"catalog_scope_nested_calls_share_exact_artifact":scope_alias_reused,
		"catalog_scope_rebuilds_source_chunk_revision_fields":per_source_fields_rebuilt,
		"catalog_scope_detects_profile_mutation_at_next_outer_scope": \
			nested_profile_mutation_seen_at_next_scope,
		"catalog_scope_begin_end_are_balanced":scope_protocol_balanced,
		"catalog_scope_rejects_source_family_replacement_in_active_scope": \
			String(current_before_change.get("status", "")) == "ready" \
			and String(current_after_change.get("status", "")) == "failed" \
			and String(current_after_change.get("reason", "")) \
			== "synthetic_source_record_replaced" \
			and String(invalid_restore.get("status", "")) == "ready",
		"catalog_scope_rejects_profile_mutation_between_scopes": \
			String(profile_change_result.get("status", "")) == "failed" \
			and String(profile_change_result.get("reason", "")) \
			== "synthetic_source_revision_stale",
		"catalog_scope_currentness_calls_balance_scope_lifecycle":all_scopes_balanced,
		"catalog_scope_source_publication_capture_ready": \
			String(source_capture.get("status", "")) == "ready" \
			and not publication_view.is_empty() and not publication_lease.is_empty()
		}


func _tree_census_center_owner_matches_partitioner() -> bool:
	var mesh := BoxMesh.new()
	var body := StaticBody3D.new()
	root.add_child(body)
	body.position = Vector3(18.0, 2.0, -4.0)
	var transforms: Array[Transform3D] = [
		Transform3D(Basis.IDENTITY, Vector3(-20.0, 0.0, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(20.0, 0.0, 24.0))]
	var colors: Array[Color] = [Color.WHITE, Color.WHITE, Color.WHITE]
	var custom_data: Array[Color] = [Color.TRANSPARENT, Color.TRANSPARENT, Color.TRANSPARENT]
	transforms.make_read_only()
	colors.make_read_only()
	custom_data.make_read_only()
	var member := {"mesh":mesh, "localTransform":Transform3D.IDENTITY,
		"transforms":transforms, "colors":colors, "customData":custom_data}
	member.make_read_only()
	var members: Array[Dictionary] = [member]
	members.make_read_only()
	var publication := {"body":body,
		"record":{"sectionValueMembers":members}}
	var actual: Array[Vector3i] = Adapter.new()._tree_census_section_keys(publication)
	var buffer: Array[float] = []
	for transform: Transform3D in transforms:
		buffer.append_array(InstanceAttributes.encode(transform, Color.TRANSPARENT, Color.WHITE))
	buffer.make_read_only()
	var input := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"sourceId":"tree-census-partition-parity", "sourcePartId":"tree-census-partition-parity",
		"sourceRevision":"tree-census-r1", "ownerCell":Vector2i.ZERO,
		"batchKey":"tree-census-partition-batch", "segmentId":"tree-census-segment",
		"sourceToWorld":body.global_transform, "meshLocalBounds":mesh.get_aabb(),
		"buffer":buffer, "instanceCount":transforms.size()}
	input.make_read_only()
	var inputs: Array[Dictionary] = [input]
	inputs.make_read_only()
	var partition := Partitioner.partition(inputs)
	if partition.get("status") != "ready":
		return false
	var expected: Array[Vector3i] = []
	for output_value: Variant in partition.get("result", {}).get("outputs", []):
		var key := Vector3i(output_value.get("sectionKey", Vector3i.ZERO))
		if key not in expected:
			expected.append(key)
	actual.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	expected.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	body.free()
	return actual == expected and expected.size() >= 2


func _check_census_resource_fingerprint_cache() -> void:
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3.ZERO, Vector3(0.2, 0.8, 0.0), Vector3(0.0, 0.8, 0.2)])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	var adapter = Adapter.new()
	var cache := {"resources":{"mesh":{}, "material":{}},
		"stats":{"meshHits":0, "meshMisses":0,
			"materialHits":0, "materialMisses":0}}
	var direct_mesh := MeshFingerprint.inspect(mesh)
	var direct_material := Adapter._material_digest(material)
	var first_mesh := adapter._resource_fingerprint_for_census(mesh, cache, "mesh")
	var reused_mesh := adapter._resource_fingerprint_for_census(mesh, cache, "mesh")
	var first_material := adapter._resource_fingerprint_for_census(material, cache, "material")
	var reused_material := adapter._resource_fingerprint_for_census(material, cache, "material")
	var equal_geometry_new_owner := ArrayMesh.new()
	equal_geometry_new_owner.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var distinct_resource := adapter._resource_fingerprint_for_census(
		equal_geometry_new_owner, cache, "mesh")
	var stats: Dictionary = cache.get("stats", {})
	check("census_fingerprint_cache_reuses_only_same_live_resource",
		first_mesh == direct_mesh and reused_mesh == direct_mesh \
		and first_material.get("contentDigest", "") == direct_material \
		and reused_material == first_material \
		and distinct_resource.get("contentDigest", "") == first_mesh.get("contentDigest", "") \
		and stats.get("meshHits", 0) == 1 and stats.get("meshMisses", 0) == 2 \
		and stats.get("materialHits", 0) == 1 and stats.get("materialMisses", 0) == 1)


func _surface_detail_census_owner_matches_partitioner() -> bool:
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0.0, 0.2, 0.0), Vector3(0.2, 0.8, 0.0), Vector3(0.0, 0.8, 0.2)])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var source_to_world := Transform3D(Basis.IDENTITY, Vector3(-16.0, 0.0, 0.0))
	var local_transform := Transform3D(Basis.from_euler(Vector3(0.17, 0.31, -0.23)) \
		.scaled(Vector3(1.3, 0.8, 1.1)), Vector3(31.5, 15.0, -0.5))
	var expected := Adapter._surface_detail_census_section_key(
		mesh, source_to_world, local_transform)
	var buffer: Array[float] = []
	buffer.append_array(InstanceAttributes.encode(local_transform, Color.TRANSPARENT, Color.WHITE))
	buffer.make_read_only()
	var input := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"sourceId":"detail-boundary-parity", "sourcePartId":"detail-boundary-parity",
		"sourceRevision":"detail-boundary-r1", "ownerCell":Vector2i.ZERO,
		"batchKey":"detail-boundary-batch", "segmentId":"detail-boundary-segment",
		"sourceToWorld":source_to_world, "meshLocalBounds":mesh.get_aabb(),
		"buffer":buffer, "instanceCount":1}
	input.make_read_only()
	var inputs: Array[Dictionary] = [input]
	inputs.make_read_only()
	var partition := Partitioner.partition(inputs)
	if partition.get("status") != "ready":
		return false
	var outputs: Array = partition.get("result", {}).get("outputs", [])
	return outputs.size() == 1 and Vector3i(outputs[0].get("sectionKey", Vector3i.ZERO)) == expected
