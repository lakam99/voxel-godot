extends RefCounted
## Read-only, bounded snapshot of the ecology-to-section admission pipeline.
## It inspects already-published jobs and receipts; it never captures providers,
## queries the support index, admits work, or infers empty coverage.

const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const MAX_DETAIL_ROWS := 8

class _StubRoster extends RefCounted:
	var _required_provider_ids: Array = ["terrain"]
	var _providers: Dictionary = {"terrain":true}

class _StubCoordinator extends RefCounted:
	var _source_roster := _StubRoster.new()
	var _visible_section_demands: Dictionary = {}
	var _section_compile_jobs: Dictionary = {}
	var _production_candidate_jobs: Dictionary = {}
	var _production_candidates_by_section: Dictionary = {}
	var _production_candidate_receipts: Dictionary = {}
	var forbidden_calls := 0

	func installed_section_receipt_is_current(_section_key: Vector3i, receipt: Dictionary) -> bool:
		return String(receipt.get("status", "")) == "installed"

	func admit_section(_section_key: Vector3i) -> Dictionary:
		forbidden_calls += 1
		return {"status":"failed"}

class _StubProvider extends RefCounted:
	var _support_index := _StubSupportIndex.new()
	var _source_capture_jobs: Dictionary = {}
	var forbidden_calls := 0

	func source_capture_scheduler_snapshot() -> Dictionary:
		return {"activeCohortCount":0, "deferredCohortCount":0,
			"blockedCohortCount":0, "pendingSourceJobCount":0}

	func capture_sections(_sections: Array) -> Dictionary:
		forbidden_calls += 1
		return {"status":"failed"}

class _StubSupportIndex extends RefCounted:
	var _tree_source_family_band_authorities: Dictionary = {}
	var _tree_section_geometry_overlays: Dictionary = {}
	var _family_band_receipts: Dictionary = {}
	var _source_census_certificate_by_section: Dictionary = {}
	var _required_families_by_section: Dictionary = {}
	var forbidden_calls := 0

	func query_section(_section_key: Vector3i) -> Dictionary:
		forbidden_calls += 1
		return {"status":"failed"}

class _StubTreeQueue extends RefCounted:
	var ecology_source_compile_jobs: Dictionary = {}
	var ecology_tree_band_compile_jobs: Dictionary = {}
	var compiled_tree_section_records: Array = []

	func startup_tree_section_compile_diagnostics() -> Dictionary:
		return {"startedCount":0, "completedCount":0, "staleCount":0,
			"compiler":{"status":"idle", "reason":"not_active"}}

class _StubMain extends RefCounted:
	var world_static_section_coordinator := _StubCoordinator.new()
	var ecology_static_section_provider := _StubProvider.new()
	var tree_publication_queue := _StubTreeQueue.new()
	var player: Node3D = null


static func snapshot(main: Object, target_section: Variant = null,
		max_detail_rows := MAX_DETAIL_ROWS) -> Dictionary:
	if not is_instance_valid(main):
		return {"schema":"static-section-admission-diagnostics/v1",
			"status":"unavailable", "reason":"main_owner_missing"}
	var limit := clampi(max_detail_rows, 1, MAX_DETAIL_ROWS)
	if target_section != null and not target_section is Vector3i:
		return {"schema":"static-section-admission-diagnostics/v1",
			"status":"unavailable", "reason":"target_section_identity_invalid"}
	var coordinator := _object_property(main, "world_static_section_coordinator")
	var provider := _object_property(main, "ecology_static_section_provider")
	var tree_queue := _object_property(main, "tree_publication_queue")
	var roster := _object_property(coordinator, "_source_roster")
	var support_index := _object_property(provider, "_support_index")
	var demands := _dictionary_property(coordinator, "_visible_section_demands")
	var source_jobs := _dictionary_property(provider, "_source_capture_jobs")
	var tree_source_jobs := _dictionary_property(tree_queue, "ecology_source_compile_jobs")
	var band_jobs := _dictionary_property(tree_queue, "ecology_tree_band_compile_jobs")
	var compiled_tree_records := _array_property(tree_queue, "compiled_tree_section_records")
	var support_authorities := _dictionary_property(support_index,
		"_tree_source_family_band_authorities")
	var support_overlays := _dictionary_property(support_index,
		"_tree_section_geometry_overlays")
	var family_band_receipts := _dictionary_property(support_index, "_family_band_receipts")
	var support_census := _dictionary_property(support_index,
		"_source_census_certificate_by_section")
	var required_families := _dictionary_property(support_index,
		"_required_families_by_section")
	var player_position := Vector3.ZERO
	var player_value: Variant = main.get("player")
	if player_value is Node3D and is_instance_valid(player_value):
		player_position = (player_value as Node3D).global_position
	var sections := _candidate_sections(target_section, demands, source_jobs,
		tree_source_jobs, band_jobs, compiled_tree_records, support_authorities,
		support_overlays, player_position)
	var examples: Array[Dictionary] = []
	for section_key: Vector3i in _bounded_rows(sections, limit):
		examples.append(_section_row(section_key, player_position, demands,
			source_jobs, tree_source_jobs, band_jobs, compiled_tree_records,
			support_authorities, support_overlays, family_band_receipts,
			support_census, required_families, coordinator))
	var required_provider_ids: Array = _array_property(roster, "_required_provider_ids")
	var registered_providers := _dictionary_property(roster, "_providers")
	var demand_stages := _status_counts(demands, "stage")
	var source_capture_scheduler: Dictionary = {}
	if is_instance_valid(provider) and provider.has_method("source_capture_scheduler_snapshot"):
		var scheduler_value: Variant = provider.call("source_capture_scheduler_snapshot")
		if scheduler_value is Dictionary:
			source_capture_scheduler = scheduler_value
	var tree_compile_progress: Dictionary = {}
	if is_instance_valid(tree_queue) and tree_queue.has_method(
			"startup_tree_section_compile_diagnostics"):
		var progress_value: Variant = tree_queue.call(
			"startup_tree_section_compile_diagnostics")
		if progress_value is Dictionary:
			tree_compile_progress = progress_value
	return {"schema":"static-section-admission-diagnostics/v1", "status":"ready",
		"targetSection":target_section if target_section is Vector3i else null,
		"capturedFrame":Engine.get_process_frames(), "detailLimit":limit,
		"readOnlyObservation":true,
		"sourceCapture":{"available":is_instance_valid(provider),
			"jobCount":source_jobs.size(), "statusCounts":_status_counts(source_jobs, "status"),
			"scheduler":_select_scalars(source_capture_scheduler,
				["activeCohortCount", "deferredCohortCount", "blockedCohortCount",
				"completedCohortCount", "failedCohortCount", "pendingSourceJobCount",
				"queuedSourceJobCount", "activeSourceJobCount", "deferredSourceJobCount",
				"completedSourceJobCount", "oldestDeferredWaitOpportunities"])},
		"treeCompile":{"available":is_instance_valid(tree_queue),
			"sourceJobCount":tree_source_jobs.size(),
			"sourceJobStatusCounts":_status_counts(tree_source_jobs, "status"),
			"compiledTreeRecordCount":compiled_tree_records.size(),
			"progress":_tree_progress_summary(tree_compile_progress)},
		"bandArtifact":{"available":is_instance_valid(tree_queue),
			"jobCount":band_jobs.size(), "statusCounts":_status_counts(band_jobs, "status"),
			"readyArtifactCount":_ready_artifact_count(band_jobs)},
		"supportIndexRegistration":{"available":is_instance_valid(support_index),
			"sourceCensusCertificateCount":support_census.size(),
			"requiredFamilySectionCount":required_families.size(),
			"treeBandAuthorityCount":_nested_count(support_authorities),
			"familyBandReceiptCount":_nested_count(family_band_receipts),
			"treeGeometryOverlayCount":_nested_count(support_overlays)},
		"providerRoster":{"available":is_instance_valid(roster),
			"requiredProviderIds":required_provider_ids.duplicate(),
			"registeredProviderIds":_sorted_string_keys(registered_providers),
			"registeredProviderCount":registered_providers.size(),
			"requiredProviderCount":required_provider_ids.size()},
		"coordinatorAdmission":{"available":is_instance_valid(coordinator),
			"visibleDemandCount":demands.size(), "demandStageCounts":demand_stages,
			"nativeCompileJobCount":_dictionary_property(coordinator,
				"_section_compile_jobs").size(),
			"candidateJobCount":_dictionary_property(coordinator,
				"_production_candidate_jobs").size(),
			"installedCandidateCount":_dictionary_property(coordinator,
				"_production_candidates_by_section").size(),
			"installedReceiptCount":_dictionary_property(coordinator,
				"_production_candidate_receipts").size()},
		"examples":examples}


static func _candidate_sections(target_section: Variant, demands: Dictionary,
		source_jobs: Dictionary, tree_source_jobs: Dictionary, band_jobs: Dictionary,
		compiled_tree_records: Array, authorities: Dictionary, overlays: Dictionary,
		player_position: Vector3) -> Array[Vector3i]:
	var found: Dictionary = {}
	if target_section is Vector3i:
		found[target_section] = true
	else:
		for value: Variant in demands.keys():
			if value is Vector3i: found[value] = true
		for job_value: Variant in band_jobs.values():
			if job_value is Dictionary and job_value.get("sectionKey") is Vector3i:
				found[job_value.sectionKey] = true
		for source_job_value: Variant in source_jobs.values():
			if not source_job_value is Dictionary: continue
			var sections_value: Variant = source_job_value.get("sections", {})
			if sections_value is Dictionary:
				for section_value: Variant in sections_value.keys():
					if section_value is Vector3i: found[section_value] = true
			var demands_value: Variant = source_job_value.get("treeCompileDemands", {})
			if demands_value is Dictionary:
				for demand_value: Variant in (demands_value as Dictionary).values():
					if demand_value is Dictionary and demand_value.get("sectionKey") is Vector3i:
						found[demand_value.sectionKey] = true
		for compiled_value: Variant in compiled_tree_records:
			if not compiled_value is Dictionary: continue
			for source_value: Variant in compiled_value.get("compiled", {}).get("sources", []):
				if source_value is Dictionary:
					for section_value: Variant in source_value.get("sectionKeys", []):
						if section_value is Vector3i: found[section_value] = true
		_add_nested_section_keys(found, authorities)
		_add_nested_section_keys(found, overlays)
	var keys: Array[Vector3i] = []
	for key_value: Variant in found.keys():
		if key_value is Vector3i: keys.append(key_value)
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var demand_a: Dictionary = demands.get(a, {})
		var demand_b: Dictionary = demands.get(b, {})
		var active_a := not demand_a.is_empty() and String(demand_a.get("stage", "")) \
			in ["waiting", "candidate_queued", "candidate_pending", "blocked"]
		var active_b := not demand_b.is_empty() and String(demand_b.get("stage", "")) \
			in ["waiting", "candidate_queued", "candidate_pending", "blocked"]
		if active_a != active_b: return active_a
		var distance_a := Grid.origin_for_key(a).distance_squared_to(player_position)
		var distance_b := Grid.origin_for_key(b).distance_squared_to(player_position)
		if not is_equal_approx(distance_a, distance_b): return distance_a < distance_b
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	return keys


static func _section_row(section_key: Vector3i, player_position: Vector3,
		demands: Dictionary, source_jobs: Dictionary, tree_source_jobs: Dictionary,
		band_jobs: Dictionary, compiled_tree_records: Array, authorities: Dictionary,
		overlays: Dictionary, family_band_receipts: Dictionary,
		support_census: Dictionary, required_families: Dictionary,
		coordinator: Object) -> Dictionary:
	var demand: Dictionary = demands.get(section_key, {})
	var admission_details := _selected_admission_details(demand.get("lastAdmissionDetails", {}))
	var capture_rows: Array[Dictionary] = []
	for job_value: Variant in source_jobs.values():
		if not job_value is Dictionary: continue
		var job: Dictionary = job_value
		var sections_value: Variant = job.get("sections", {})
		var tree_demands: Variant = job.get("treeCompileDemands", {})
		if not sections_value is Dictionary: sections_value = {}
		if not tree_demands is Dictionary: tree_demands = {}
		if not sections_value.has(section_key) and not tree_demands.has(section_key): continue
		var snapshot: Dictionary = job.get("snapshot", {})
		var publication_view: Dictionary = job.get("sourcePublicationView", {})
		capture_rows.append({"status":String(job.get("status", "unknown")),
			"reason":String(job.get("reason", job.get("failure", {}).get("reason", ""))),
			"sourceChunkKey":job.get("sourceChunkKey", null),
			"sourceRevision":String(snapshot.get("sourceRevision", "")),
			"publicationId":String(job.get("sourcePublicationId",
				publication_view.get("publicationId", ""))),
			"sourceIds":_tree_source_ids(snapshot, publication_view, 4),
			"sourcePartIds":_tree_source_part_ids(snapshot, publication_view, 4),
			"sectionKey":section_key})
		if capture_rows.size() >= 4: break
	var band_rows: Array[Dictionary] = []
	for key_value: Variant in band_jobs.keys():
		var job_value: Variant = band_jobs[key_value]
		if not job_value is Dictionary or job_value.get("sectionKey") != section_key: continue
		var job: Dictionary = job_value
		var artifact: Dictionary = job.get("artifact", {})
		band_rows.append({"jobKey":String(key_value), "status":String(job.get("status", "")),
			"reason":String(job.get("reason", "")),
			"sourceChunkKey":job.get("sourceChunkKey", null),
			"sourceRevision":String(job.get("snapshot", {}).get("sourceRevision", "")),
			"authorityDigest":String(job.get("authorityDigest", "")),
			"artifactStatus":String(artifact.get("status", "missing")),
			"artifactState":_artifact_state(artifact),
			"artifactRevision":String(artifact.get("sourceRevision", "")),
			"expectedSourceCount":(job.get("expectedSourceIds", []) as Array).size()})
		if band_rows.size() >= 4: break
	var compiled_rows: Array[Dictionary] = []
	for record_value: Variant in compiled_tree_records:
		if not record_value is Dictionary: continue
		var record: Dictionary = record_value
		var compiled: Dictionary = record.get("compiled", {})
		var matching_sections: Array = []
		for source_value: Variant in compiled.get("sources", []):
			if source_value is Dictionary and section_key in source_value.get("sectionKeys", []):
				matching_sections.append({"sourceId":String(source_value.get("sourceId", "")),
					"sourceRevision":String(source_value.get("sourceRevision", "")),
					"sectionKey":section_key})
		if not matching_sections.is_empty():
			compiled_rows.append({"status":"compiled", "sources":matching_sections.slice(0, 4)})
		if compiled_rows.size() >= 4: break
	var authority_rows := _support_rows_for_section(authorities, section_key, "authority")
	var overlay_rows := _support_rows_for_section(overlays, section_key, "overlay")
	var band_receipt_rows := _family_receipt_rows_for_section(family_band_receipts, section_key)
	var compile_job: Dictionary = _dictionary_property(coordinator,
		"_section_compile_jobs").get(section_key, {})
	var candidate_job: Dictionary = _dictionary_property(coordinator,
		"_production_candidate_jobs").get(section_key, {})
	var queued_candidate: Dictionary = candidate_job.get("candidate", {})
	var installed_candidate: Dictionary = _dictionary_property(coordinator,
		"_production_candidates_by_section").get(section_key, {})
	var receipt: Dictionary = _dictionary_property(coordinator,
		"_production_candidate_receipts").get(section_key, {})
	var census: Dictionary = compile_job.get("census", {})
	var receipt_current := not receipt.is_empty() and is_instance_valid(coordinator) \
		and coordinator.has_method("installed_section_receipt_is_current") \
		and bool(coordinator.call("installed_section_receipt_is_current", section_key, receipt))
	var captured_revision := String(admission_details.get("snapshotSourceRevision", ""))
	var current_revision := String(admission_details.get("currentSourceRevision", ""))
	return {"sectionKey":section_key,
		"distanceFromPlayerMeters":sqrt(Grid.origin_for_key(section_key).distance_squared_to(player_position)),
		"sourceCapture":{"jobCount":_section_capture_job_count(source_jobs, section_key),
			"rows":capture_rows},
		"compiledTree":{"recordCount":_section_compiled_record_count(compiled_tree_records, section_key),
			"rows":compiled_rows},
		"bandArtifact":{"jobCount":_section_band_job_count(band_jobs, section_key),
			"rows":band_rows},
		"supportIndexRegistration":{"censusCertificatePresent":support_census.has(section_key),
			"censusCertificatePresence":"present" if support_census.has(section_key) else "absent",
			"requiredFamilyKeys":_string_keys(required_families.get(section_key, {})),
			"treeBandAuthorities":authority_rows,
			"familyBandReceipts":band_receipt_rows,
			"treeGeometryOverlays":overlay_rows},
		"completeCensus":{"lastProviderStatus":String(demand.get("lastStatus", "")),
			"lastAdmissionReason":String(demand.get("lastReason", "")),
			"nativeCompileJobStatus":String(compile_job.get("status", "")),
			"nativeCompileCensusStatus":String(census.get("status", "missing")),
			"nativeCompileCensusDigest":String(census.get("censusDigest", "")),
			"queuedCandidateCensusDigest":String(queued_candidate.get("censusDigest", "")),
			"installedCandidateCensusDigest":String(installed_candidate.get("censusDigest", "")),
			"installedReceiptCensusDigest":String(receipt.get("censusDigest", "unavailable")),
			"providerCoverageCount":(queued_candidate.get("providerCoverage", []) as Array).size()
				if queued_candidate.get("providerCoverage", []) is Array else 0},
		"coordinatorAdmission":{"stage":String(demand.get("stage", "missing")),
			"attempts":int(demand.get("attempts", 0)),
			"lastStatus":String(demand.get("lastStatus", "")),
			"lastReason":String(demand.get("lastReason", "")),
			"lastAdmissionDetails":admission_details,
			"sourceRevisionRelation":_revision_relation(captured_revision, current_revision),
			"compileJobGeneration":int(compile_job.get("generation", 0)),
			"candidateJobStage":String(candidate_job.get("stage", "")),
			"installedGeneration":int(installed_candidate.get("generation", 0)),
			"receiptStatus":String(receipt.get("status", "missing")),
			"receiptCurrent":receipt_current}}


static func _selected_admission_details(value: Variant) -> Dictionary:
	if not value is Dictionary: return {}
	var result := {}
	for key: String in ["providerId", "providerReason", "sourceChunkKey", "sourceId",
			"sourcePartId", "sourceRevision", "sourcePartRevision", "snapshotSourceRevision",
			"currentSourceRevision", "requestedSection", "ownedSection", "captureProgress",
			"producerStatus", "continuationStage", "continuationCursor"]:
		if value.has(key): result[key] = value[key]
	return result


static func synthetic_contract() -> Dictionary:
	var main := _StubMain.new()
	var coordinator := main.world_static_section_coordinator as _StubCoordinator
	var provider := main.ecology_static_section_provider as _StubProvider
	var support := provider._support_index as _StubSupportIndex
	var tree_queue := main.tree_publication_queue as _StubTreeQueue
	for x: int in range(12):
		coordinator._visible_section_demands[Vector3i(x, 0, 0)] = {
			"stage":"blocked", "lastReason":"synthetic_pending",
			"lastAdmissionDetails":{"snapshotSourceRevision":"r1",
				"currentSourceRevision":"r1", "sourceId":"tree-1",
				"sourcePartId":"trunk-1", "requestedSection":Vector3i(x, 0, 0)}}
	tree_queue.ecology_tree_band_compile_jobs["stub-band"] = {
		"sectionKey":Vector3i.ZERO, "status":"complete", "artifact":{}}
	var before_first_observation := _stub_inputs(main)
	var first: Dictionary = snapshot(main)
	var after_first_observation := _stub_inputs(main)
	var absent_row: Dictionary = snapshot(main, Vector3i.ZERO).get("examples", [])[0]
	var after_absent_observation := _stub_inputs(main)
	var before_revision_replacement := _stub_inputs(main)
	coordinator._visible_section_demands[Vector3i.ZERO]["lastAdmissionDetails"][
		"currentSourceRevision"] = "r2"
	support._source_census_certificate_by_section[Vector3i.ZERO] = {}
	tree_queue.ecology_tree_band_compile_jobs["stub-band"]["artifact"] = {
		"status":"ready", "disposition":"complete_empty"}
	var before_replaced_observation := _stub_inputs(main)
	var replaced_row: Dictionary = snapshot(main, Vector3i.ZERO).get("examples", [])[0]
	var after_replaced_observation := _stub_inputs(main)
	var forbidden_calls := {"capture":provider.forbidden_calls,
		"admission":coordinator.forbidden_calls, "supportQuery":support.forbidden_calls}
	var checks := {
		"detailOutputBounded":first.get("examples", []).size() == MAX_DETAIL_ROWS \
			and int(first.get("detailLimit", 0)) == MAX_DETAIL_ROWS,
		"ownerInputsUnchangedByObservation":before_first_observation == after_first_observation \
			and after_absent_observation == before_revision_replacement \
			and before_replaced_observation == after_replaced_observation,
		"forbiddenOperationCountsZero":provider.forbidden_calls == 0 \
			and coordinator.forbidden_calls == 0 and support.forbidden_calls == 0,
		"absentAndEmptyCoverageDistinct":absent_row.get("supportIndexRegistration", {}).get(
			"censusCertificatePresence", "") == "absent" \
			and replaced_row.get("supportIndexRegistration", {}).get(
			"censusCertificatePresence", "") == "present" \
			and absent_row.get("bandArtifact", {}).get("rows", [])[0].get(
			"artifactState", "") == "absent" \
			and replaced_row.get("bandArtifact", {}).get("rows", [])[0].get(
			"artifactState", "") == "authoritative_empty",
		"currentAndReplacedRevisionDistinguished":absent_row.get("coordinatorAdmission", {}).get(
			"sourceRevisionRelation", "") == "current" \
			and replaced_row.get("coordinatorAdmission", {}).get(
			"sourceRevisionRelation", "") == "replaced"}
	var passed := true
	for value: Variant in checks.values():
		if value is bool: passed = passed and bool(value)
	return {"schema":"static-section-admission-diagnostics-contract/v1",
		"passed":passed, "checks":checks,
		"forbiddenOperationCounts":forbidden_calls}


static func _stub_inputs(main: _StubMain) -> Dictionary:
	var coordinator: _StubCoordinator = main.world_static_section_coordinator
	var provider: _StubProvider = main.ecology_static_section_provider
	var support: _StubSupportIndex = provider._support_index
	var tree_queue: _StubTreeQueue = main.tree_publication_queue
	return {"demands":coordinator._visible_section_demands.duplicate(true),
		"census":support._source_census_certificate_by_section.duplicate(true),
		"captureJobs":provider._source_capture_jobs.duplicate(true),
		"treeJobs":tree_queue.ecology_source_compile_jobs.duplicate(true),
		"bandJobs":tree_queue.ecology_tree_band_compile_jobs.duplicate(true),
		"compiledRecords":tree_queue.compiled_tree_section_records.duplicate(true)}


static func _bounded_rows(rows: Array, requested_limit: int) -> Array:
	return rows.slice(0, mini(rows.size(), clampi(requested_limit, 1, MAX_DETAIL_ROWS)))


static func _artifact_state(artifact: Variant) -> String:
	if not artifact is Dictionary or (artifact as Dictionary).is_empty(): return "absent"
	var row: Dictionary = artifact
	if String(row.get("status", "")) != "ready":
		return String(row.get("status", "unknown"))
	if String(row.get("disposition", "")) == "complete_empty":
		return "authoritative_empty"
	if String(row.get("disposition", "")) == "complete_nonempty":
		return "ready_nonempty"
	return "ready_unknown"


static func _revision_relation(captured: String, current: String) -> String:
	if captured.is_empty() or current.is_empty(): return "unknown"
	return "current" if captured == current else "replaced"


static func _select_scalars(value: Dictionary, keys: Array[String]) -> Dictionary:
	var result := {}
	for key: String in keys:
		var item: Variant = value.get(key, null)
		if item is int or item is float or item is String or item is bool:
			result[key] = item
	return result


static func _tree_progress_summary(value: Dictionary) -> Dictionary:
	var result := _select_scalars(value,
		["startedCount", "completedCount", "staleCount", "activeCandidateId", "activeSourceId"])
	var compiler_value: Variant = value.get("compiler", {})
	if compiler_value is Dictionary:
		result["compiler"] = _select_scalars(compiler_value as Dictionary,
			["status", "reason", "activeCandidateId", "activeSourceId", "workUnits",
			"recordIndex", "instanceIndex"])
	return result


static func _support_rows_for_section(nested: Dictionary, section_key: Vector3i,
		kind: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for chunk_value: Variant in nested.keys():
		var by_section: Variant = nested[chunk_value]
		if not by_section is Dictionary or not (by_section as Dictionary).has(section_key): continue
		var value: Variant = (by_section as Dictionary)[section_key]
		if value is Dictionary:
			var authority: Dictionary = value
			rows.append({"kind":kind, "sourceChunkKey":chunk_value,
				"sectionKey":section_key,
				"status":String(authority.get("status", "registered")),
				"sourceRevision":String(authority.get("sourceRevision", "")),
				"familyRevision":String(authority.get("sourceFamilyRevision", "")),
				"authorityDigest":String(authority.get("authorityDigest", "")),
				"sourceIds":_string_array(authority.get("producerSourceIds", []), 4),
				"sourcePartIds":_support_part_ids(authority.get("supportRows", []), 4)})
		if rows.size() >= 4: break
	return rows


static func _family_receipt_rows_for_section(nested: Dictionary,
		section_key: Vector3i) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for chunk_value: Variant in nested.keys():
		var by_family: Variant = nested[chunk_value]
		if not by_family is Dictionary: continue
		for family_value: Variant in (by_family as Dictionary).keys():
			var by_section: Variant = (by_family as Dictionary)[family_value]
			if not by_section is Dictionary or not (by_section as Dictionary).has(section_key): continue
			var receipt: Variant = (by_section as Dictionary)[section_key]
			if receipt is Dictionary:
				rows.append({"family":String(family_value), "sourceChunkKey":chunk_value,
					"sectionKey":section_key,
					"sourceRevision":String(receipt.get("sourceRevision", "")),
				"sourceFamilyRevision":String(receipt.get("sourceFamilyRevision", "")),
				"producerBandRevision":String(receipt.get("producerBandRevision", "")),
				"sourceIds":_string_array(receipt.get("producerSourceIds", []), 4)})
			if rows.size() >= 4: return rows
	return rows


static func _tree_source_ids(snapshot: Dictionary, publication_view: Dictionary,
		limit: int) -> Array[String]:
	var rows := _tree_source_rows(snapshot, publication_view)
	var result: Array[String] = []
	if rows is Array:
		for value: Variant in rows:
			if value is Dictionary:
				var id := String(value.get("sourceId", ""))
				if not id.is_empty() and id not in result: result.append(id)
				if result.size() >= limit: break
	return result


static func _tree_source_part_ids(snapshot: Dictionary, publication_view: Dictionary,
		limit: int) -> Array[String]:
	var rows := _tree_source_rows(snapshot, publication_view)
	var result: Array[String] = []
	if rows is Array:
		for value: Variant in rows:
			if value is Dictionary:
				var id := String(value.get("sourcePartId", ""))
				if not id.is_empty() and id not in result: result.append(id)
				if result.size() >= limit: break
	return result


static func _tree_source_rows(snapshot: Dictionary, publication_view: Dictionary) -> Array:
	var view_rows: Variant = publication_view.get("familyResultsById", {}).get(
		"trees", {}).get("sourceRows", [])
	if view_rows is Array: return view_rows
	for coverage_value: Variant in snapshot.get("familyCoverage", []):
		if coverage_value is Dictionary \
				and String(coverage_value.get("family", "")) == "trees":
			var rows: Variant = coverage_value.get("sourceRows", [])
			return rows if rows is Array else []
	return []


static func _support_part_ids(rows_value: Variant, limit: int) -> Array[String]:
	var result: Array[String] = []
	if rows_value is Array:
		for value: Variant in rows_value:
			if value is Dictionary:
				var id := String(value.get("sourcePartId", ""))
				if not id.is_empty() and id not in result: result.append(id)
				if result.size() >= limit: break
	return result


static func _candidate_section_matches(value: Variant, section_key: Vector3i) -> bool:
	return value is Dictionary and value.get("sectionKey") == section_key


static func _section_capture_job_count(jobs: Dictionary, section_key: Vector3i) -> int:
	var count := 0
	for value: Variant in jobs.values():
		if not value is Dictionary: continue
		var sections_value: Variant = value.get("sections", {})
		var demands_value: Variant = value.get("treeCompileDemands", {})
		if not sections_value is Dictionary: sections_value = {}
		if not demands_value is Dictionary: demands_value = {}
		if sections_value.has(section_key) or demands_value.has(section_key): count += 1
	return count


static func _section_band_job_count(jobs: Dictionary, section_key: Vector3i) -> int:
	var count := 0
	for value: Variant in jobs.values():
		if value is Dictionary and value.get("sectionKey") == section_key: count += 1
	return count


static func _section_compiled_record_count(records: Array, section_key: Vector3i) -> int:
	var count := 0
	for record_value: Variant in records:
		if not record_value is Dictionary: continue
		for source_value: Variant in record_value.get("compiled", {}).get("sources", []):
			if source_value is Dictionary and section_key in source_value.get("sectionKeys", []):
				count += 1
	return count


static func _ready_artifact_count(jobs: Dictionary) -> int:
	var count := 0
	for value: Variant in jobs.values():
		if value is Dictionary and String(value.get("status", "")) == "complete" \
				and String(value.get("artifact", {}).get("status", "")) == "ready": count += 1
	return count


static func _status_counts(rows: Dictionary, field: String) -> Dictionary:
	var counts := {}
	for value: Variant in rows.values():
		if not value is Dictionary: continue
		var status := String(value.get(field, "unknown"))
		counts[status] = int(counts.get(status, 0)) + 1
	return counts


static func _nested_count(nested: Dictionary) -> int:
	var count := 0
	for value: Variant in nested.values():
		count += _nested_record_count(value)
	return count


static func _nested_record_count(value: Variant) -> int:
	if not value is Dictionary: return 0
	var row: Dictionary = value
	if row.has("schema"): return 1
	var count := 0
	for child: Variant in row.values():
		count += _nested_record_count(child)
	return count


static func _add_nested_section_keys(found: Dictionary, nested: Dictionary) -> void:
	for value: Variant in nested.values():
		if not value is Dictionary: continue
		for key_value: Variant in (value as Dictionary).keys():
			if key_value is Vector3i: found[key_value] = true


static func _sorted_string_keys(value: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for key: Variant in value.keys(): result.append(String(key))
	result.sort()
	return result


static func _string_keys(value: Variant) -> Array[String]:
	return _sorted_string_keys(value) if value is Dictionary else []


static func _string_array(value: Variant, limit: int) -> Array[String]:
	var result: Array[String] = []
	if value is Array:
		for item: Variant in value:
			if item is String and not String(item).is_empty() and String(item) not in result:
				result.append(String(item))
			if result.size() >= limit: break
	return result


static func _dictionary_property(owner: Object, property: String) -> Dictionary:
	if not is_instance_valid(owner): return {}
	var value: Variant = owner.get(property)
	return value if value is Dictionary else {}


static func _array_property(owner: Object, property: String) -> Array:
	if not is_instance_valid(owner): return []
	var value: Variant = owner.get(property)
	return value if value is Array else []


static func _object_property(owner: Object, property: String) -> Object:
	if not is_instance_valid(owner): return null
	var value: Variant = owner.get(property)
	return value as Object if value is Object else null
