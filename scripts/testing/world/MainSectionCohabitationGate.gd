extends SceneTree

const MainScene := preload("res://scenes/Main.tscn")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const ProducerDomain := preload("res://scripts/world/EcologyProducerDomain.gd")
const AdmissionDiagnostics := preload("res://scripts/testing/world/StaticSectionAdmissionDiagnostics.gd")
const REPORT_SCHEMA := "main-section-cohabitation-gate/v1"
const REQUIRED_PROVIDER_IDS := ["terrain", "ordinary-structures",
	"blueprint_buildings", "ecology_and_static_props"]
const REQUIRED_DOMAINS := ["terrain", "building", "ecology"]
const WAIT_SECONDS := 600.0
const DEFAULT_STARTUP_WAIT_SECONDS := 300.0
const FINAL_VIEWPORT_CAPTURE_ACK_TIMEOUT_SECONDS := 30.0
const SCAN_INTERVAL_FRAMES := 30
const TREE_COMPILE_PROGRESS_SAMPLE_INTERVAL_SECONDS := 2.0
const TREE_COMPILE_PROGRESS_POLL_SECONDS := 0.5
const TREE_COMPILE_PROGRESS_MIN_ACTIVE_JOBS := 16

var main: Node3D
var coordinator: Object
var seed_text := ""
var report_path := ""
var progress_path := ""
var started_msec := 0
var startup_wait_seconds := DEFAULT_STARTUP_WAIT_SECONDS
var startup_failure: Variant = {}
var startup_failure_message := ""
var finished := false
var candidate_scan_cursor := 0
var tree_compile_progress_samples: Array[Dictionary] = []
var tree_compile_progress_sampler_active := false
var tree_compile_progress_sampler_stop_requested := false


func _initialize() -> void:
	started_msec = Time.get_ticks_msec()
	seed_text = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	var configured_startup_wait := OS.get_environment(
		"VOXEL_MAIN_SECTION_COHABITATION_STARTUP_WAIT_SECONDS").strip_edges()
	if not configured_startup_wait.is_empty():
		startup_wait_seconds = maxf(1.0, configured_startup_wait.to_float())
	report_path = OS.get_environment("VOXEL_MAIN_SECTION_COHABITATION_REPORT")
	progress_path = OS.get_environment("VOXEL_MAIN_SECTION_COHABITATION_PROGRESS")
	call_deferred("_run")


func _run() -> void:
	OS.set_environment("VOXEL_PLAYTEST", "1")
	OS.set_environment("VOXEL_TEST_SEED", seed_text)
	var checks: Array[Dictionary] = []
	var diagnostics_contract: Dictionary = AdmissionDiagnostics.synthetic_contract()
	_record(checks, "static_section_admission_diagnostics_contract",
		bool(diagnostics_contract.get("passed", false)), diagnostics_contract)
	if not checks.back().passed:
		print(JSON.stringify(diagnostics_contract))
		await _finish(checks, {}, "static_section_admission_diagnostics_contract_failed")
		return
	if "--DiagnosticsContractOnly" in OS.get_cmdline_user_args():
		print(JSON.stringify(diagnostics_contract))
		await _finish(checks, {"diagnosticsContract":diagnostics_contract},
			"diagnostics_contract_only")
		return
	_record(checks, "seed_and_skip_tutorial_arguments",
		not seed_text.is_empty() and "-SkipTutorial" in OS.get_cmdline_user_args(), {
		"seed":seed_text, "arguments":OS.get_cmdline_user_args()})
	main = MainScene.instantiate() as Node3D
	_record(checks, "production_main_instantiated", is_instance_valid(main), {})
	if not is_instance_valid(main):
		await _finish(checks, {}, "main_scene_instantiation_failed")
		return
	if main.has_signal("startup_loading_failed"):
		main.connect("startup_loading_failed", _on_startup_failed)
	if main.has_signal("startup_loading_step"):
		main.connect("startup_loading_step", _on_startup_step)
	root.add_child(main)
	var launch_options: Dictionary = main.get("launch_options")
	_record(checks, "production_main_tutorial_skipped",
		bool(launch_options.get("skipTutorial", false)), launch_options)
	_write_progress("waiting_for_main_startup", {"seed":seed_text})
	tree_compile_progress_sampler_stop_requested = false
	call_deferred("_sample_startup_tree_compile_progress")
	var startup_ready := bool(await main.call("wait_for_startup_loading_complete",
		startup_wait_seconds, true))
	tree_compile_progress_sampler_stop_requested = true
	if not startup_ready:
		await _ensure_two_tree_compile_progress_samples()
		var failure: Variant = main.get("startup_loading_failure_result")
		if failure is Dictionary:
			startup_failure = failure.duplicate(true)
		else:
			startup_failure = {"result":str(failure)}
		startup_failure["diagnosticSnapshot"] = _startup_diagnostic_snapshot()
		var pending_tree_visuals := _final_pending_tree_visual_snapshot()
		startup_failure["pendingTreeVisualCandidates"] = pending_tree_visuals
		var diagnostic_binding: Dictionary = pending_tree_visuals.get(
			"diagnosticBinding", {})
		var candidate_rows: Variant = pending_tree_visuals.get("rows", [])
		_record(checks, "final_tree_visual_diagnostic_matches_player_request",
			bool(diagnostic_binding.get("matchesCurrentPlayerRequest", false)) \
			and bool(diagnostic_binding.get("matchesCurrentPlayerBounds", false)), {
			"requestId":diagnostic_binding.get("requestId", -1),
			"expectedBounds":diagnostic_binding.get("expectedBounds", []),
			"countsComplete":pending_tree_visuals.get("countsComplete", false),
			"candidateRows":candidate_rows.size() if candidate_rows is Array else 0})
		if not startup_failure_message.is_empty():
			startup_failure["signalMessage"] = startup_failure_message
		_record(checks, "main_startup_ready", false, startup_failure)
		await _finish(checks, {}, "main_startup_not_ready")
		return
	_record(checks, "main_startup_ready", true, {
		"readinessDomains":main.get("startup_readiness_domains")})
	coordinator = main.get("world_static_section_coordinator") as Object
	_record(checks, "production_coordinator_and_all_providers_registered",
		is_instance_valid(coordinator) and _required_providers_registered(), {
		"coordinator":is_instance_valid(coordinator),
		"requiredProviderIds":REQUIRED_PROVIDER_IDS})
	if not is_instance_valid(coordinator) or not _required_providers_registered():
		await _finish(checks, {}, "production_provider_roster_unavailable")
		return
	var deadline := Time.get_ticks_msec() + int(WAIT_SECONDS * 1000.0)
	var scans := 0
	var last_scan: Dictionary = {"status":"pending", "reason":"no_installed_candidates"}
	while is_instance_valid(main) and main.is_inside_tree() and Time.get_ticks_msec() < deadline:
		if Engine.get_process_frames() % SCAN_INTERVAL_FRAMES == 0:
			scans += 1
			last_scan = _scan_installed_candidates()
			if last_scan.get("status") == "ready":
				_record(checks, "same_current_production_candidate_contains_terrain_building_and_ecology",
					true, last_scan)
				_record(checks, "candidate_generation_digest_and_current_revisions_match_native_receipt",
					true, last_scan.get("receiptProof", {}))
				_record(checks, "all_required_provider_install_acknowledgements_settled",
					true, last_scan.get("acknowledgementProof", {}))
				_record(checks, "installed_candidate_completed_native_worker_compilation",
					true, last_scan.get("nativeCompileProof", {}))
				await _finish(checks, last_scan, "cohabitation_gate_passed")
				return
			if scans % 10 == 0:
				_write_progress("searching_installed_production_candidates", {
					"scanCount":scans, "lastScan":last_scan,
					"installedCandidateCount":(coordinator.get(
						"_production_candidates_by_section") as Dictionary).size()})
		await process_frame
	_record(checks, "same_current_production_candidate_contains_terrain_building_and_ecology",
		false, last_scan.merged({"scanCount":scans,
		"waitLimitSeconds":WAIT_SECONDS}, true))
	await _finish(checks, last_scan, "cohabitation_candidate_not_found_before_deadline")


func _scan_installed_candidates() -> Dictionary:
	var candidates: Dictionary = coordinator.get("_production_candidates_by_section")
	var receipts: Dictionary = coordinator.get("_production_candidate_receipts")
	var section_keys: Array[Vector3i] = []
	for key_value: Variant in candidates:
		if key_value is Vector3i and candidates[key_value] is Dictionary:
			section_keys.append(Vector3i(key_value))
	section_keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	if section_keys.is_empty():
		return {"status":"pending", "reason":"no_installed_candidates"}
	var rejections: Dictionary = {}
	# A candidate's census digest covers exactly its own section. Capturing all
	# installed sections would produce a different digest and reject valid slots.
	for _index in range(mini(4, section_keys.size())):
		candidate_scan_cursor = posmod(candidate_scan_cursor, section_keys.size())
		var section_key := section_keys[candidate_scan_cursor]
		candidate_scan_cursor += 1
		var census: Dictionary = coordinator.call("capture_authoritative_source_census", [section_key])
		if census.get("status") != "complete":
			rejections["current_source_census_pending"] = int(rejections.get(
				"current_source_census_pending", 0)) + 1
			continue
		var candidate: Dictionary = candidates.get(section_key, {})
		var receipt: Dictionary = receipts.get(section_key, {})
		var proof := _candidate_proof(section_key, candidate, receipt, census)
		if proof.get("status") == "ready":
			return proof
		var reason := String(proof.get("reason", "candidate_not_eligible"))
		rejections[reason] = int(rejections.get(reason, 0)) + 1
	return {"status":"pending", "reason":"no_current_cohabiting_candidate",
		"candidateCount":section_keys.size(), "rejections":rejections}


func _candidate_proof(section_key: Vector3i, candidate: Dictionary,
		receipt: Dictionary, census: Dictionary) -> Dictionary:
	if candidate.is_empty() or receipt.is_empty():
		return {"status":"pending", "reason":"installed_candidate_or_receipt_missing"}
	var generation := int(candidate.get("generation", 0))
	var digest := String(candidate.get("contentManifestDigest", ""))
	var envelope: Dictionary = candidate.get("candidate", {})
	var snapshot: Dictionary = envelope.get("snapshot", {})
	if generation <= 0 or digest.is_empty() or envelope.is_empty() or snapshot.is_empty():
		return {"status":"pending", "reason":"installed_candidate_payload_missing"}
	var compile_receipt: Dictionary = candidate.get("nativeCompileReceipt", {})
	var compile_identity: Dictionary = compile_receipt.get("identity", {})
	if compile_receipt.get("status") != "compiled" \
			or int(compile_receipt.get("ticket", 0)) <= 0 \
			or compile_identity.get("sectionKey") != section_key \
			or compile_identity.get("generation") != generation \
			or compile_identity.get("worldId") != candidate.get("worldId") \
			or compile_identity.get("providerRevisionDigest") != candidate.get("censusDigest") \
			or String(compile_identity.get("preparedPayloadDigest", "")).length() != 64:
		return {"status":"pending", "reason":"native_compile_receipt_missing_or_stale"}
	if String(candidate.get("worldId", "")) != String(census.get("worldId", "")) \
			or String(candidate.get("censusDigest", "")) != String(census.get("censusDigest", "")):
		return {"status":"pending", "reason":"candidate_census_revision_stale"}
	if int(receipt.get("generation", 0)) != generation \
			or String(receipt.get("contentManifestDigest", "")) != digest \
			or String(receipt.get("censusDigest", "")) != String(census.get("censusDigest", "")) \
			or not coordinator.call("installed_section_receipt_is_current", section_key, receipt):
		return {"status":"pending", "reason":"native_receipt_not_current_for_candidate"}
	if not coordinator.call("_receipt_backend_matches_candidate", candidate, receipt):
		return {"status":"pending", "reason":"native_backend_slot_does_not_match_candidate"}
	var provider_coverage: Variant = candidate.get("providerCoverage", [])
	var snapshot_revisions: Dictionary = census.get("providerSnapshotRevisions", {})
	var coverage_revisions: Dictionary = census.get("providerCoverageRevisions", {})
	var coverage_by_provider: Dictionary = {}
	if not provider_coverage is Array or provider_coverage.size() != REQUIRED_PROVIDER_IDS.size():
		return {"status":"pending", "reason":"candidate_provider_coverage_incomplete"}
	for coverage_value: Variant in provider_coverage:
		if not coverage_value is Array or coverage_value.size() < 3:
			return {"status":"pending", "reason":"candidate_provider_coverage_invalid"}
		var provider_id := String(coverage_value[0])
		if coverage_by_provider.has(provider_id) \
				or provider_id not in REQUIRED_PROVIDER_IDS \
				or String(coverage_value[1]) != String(coverage_revisions.get(
					provider_id, {}).get(section_key, "")) \
				or String(coverage_value[2]) != String(snapshot_revisions.get(provider_id, "")):
			return {"status":"pending", "reason":"candidate_provider_coverage_stale"}
		coverage_by_provider[provider_id] = true
	for provider_id: String in REQUIRED_PROVIDER_IDS:
		if not coverage_by_provider.has(provider_id):
			return {"status":"pending", "reason":"required_provider_missing:" + provider_id}
	var source_revisions: Dictionary = candidate.get("sourceRevisions", {})
	var current_revisions: Dictionary = census.get("sourceRevisions", {})
	var current_providers: Dictionary = census.get("sourceProviderIds", {})
	var geometry_by_domain := {"terrain":[], "building":[], "ecology":[]}
	var manifest: Variant = snapshot.get("manifest", [])
	if not manifest is Array or manifest.is_empty():
		return {"status":"pending", "reason":"candidate_manifest_missing"}
	var expected_sections: Dictionary = census.get("expectedContributorsBySection", {})
	var expected_manifest: Variant = expected_sections.get(section_key, null)
	if not expected_manifest is Array or expected_manifest.size() != manifest.size():
		return {"status":"pending", "reason":"candidate_manifest_not_exactly_current"}
	var observed_manifest: Dictionary = {}
	for row_value: Variant in manifest:
		if not row_value is Dictionary:
			return {"status":"pending", "reason":"candidate_manifest_row_invalid"}
		var row: Dictionary = row_value
		var source_id := String(row.get("sourceId", ""))
		var source_part_id := String(row.get("sourcePartId", ""))
		var identity_key := "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()
		var revision := String(row.get("sourceRevision", ""))
		if identity_key.is_empty() or revision.is_empty() \
				or observed_manifest.has(identity_key) \
				or String(source_revisions.get(identity_key, "")) != revision \
				or String(current_revisions.get(identity_key, "")) != revision:
			return {"status":"pending", "reason":"candidate_manifest_source_revision_stale"}
		observed_manifest[identity_key] = true
		var provider_id := String(current_providers.get(identity_key, ""))
		var domain := _domain_for_provider(provider_id)
		if domain.is_empty() or String(row.get("contributorKind", "")) != "geometry":
			continue
		var ranges: Variant = row.get("ranges", [])
		if not ranges is Array or ranges.is_empty():
			return {"status":"pending", "reason":"geometry_contributor_has_no_render_ranges"}
		var range_instances := 0
		for range_value: Variant in ranges:
			if not range_value is Dictionary:
				return {"status":"pending", "reason":"manifest_render_range_invalid"}
			var render_range: Dictionary = range_value
			if String(render_range.get("sourceId", "")) != source_id \
					or String(render_range.get("sourcePartId", "")) != source_part_id \
					or String(render_range.get("sourceRevision", "")) != revision \
					or int(render_range.get("instanceCount", 0)) <= 0:
				return {"status":"pending", "reason":"manifest_render_range_not_current_or_empty"}
			range_instances += int(render_range.get("instanceCount", 0))
		geometry_by_domain[domain].append({"providerId":provider_id,
			"sourceId":source_id, "sourcePartId":source_part_id,
			"sourceRevision":revision, "instanceCount":range_instances,
			"rangeCount":ranges.size()})
	for expected_identity_value: Variant in expected_manifest:
		if not observed_manifest.has(String(expected_identity_value)):
			return {"status":"pending", "reason":"candidate_manifest_omits_current_source_identity"}
	for domain: String in REQUIRED_DOMAINS:
		if geometry_by_domain[domain].is_empty():
			return {"status":"pending", "reason":"required_nonempty_geometry_missing:" + domain,
				"geometryByDomain":geometry_by_domain}
	var layers := _layer_summary(snapshot.get("renderLayers", []))
	if layers.get("status") != "ready" or int(snapshot.get("instanceCount", 0)) <= 0:
		return {"status":"pending", "reason":"candidate_render_layers_or_geometry_empty"}
	var demand: Dictionary = coordinator.get("_visible_section_demands").get(section_key, {})
	var demand_receipt: Dictionary = demand.get("installedReceipt", {})
	var acknowledgement_proof: Dictionary = coordinator.call(
		"source_install_acknowledgement_proof", section_key, receipt)
	if String(demand.get("lastInstallStatus", "")) != "installed" \
			or int(demand.get("installedGeneration", 0)) != generation \
			or String(demand_receipt.get("contentManifestDigest", "")) != digest \
			or acknowledgement_proof.get("status") != "ready":
		return {"status":"pending", "reason":"provider_install_acknowledgement_not_settled",
			"demand":demand, "acknowledgementProof":acknowledgement_proof}
	var native: Dictionary = _native_snapshot(candidate, receipt)
	if String(native.get("status", "")) != "ready" \
			or int(native.get("generation", 0)) != generation \
			or String(native.get("packetDigest", "")) != digest:
		return {"status":"pending", "reason":"native_installed_slot_identity_mismatch",
			"native":_compact(native)}
	return {"status":"ready", "sectionKey":_vec3(section_key),
		"nativeCompileProof":compile_receipt,
		"providerAcknowledgementProof":acknowledgement_proof,
		"worldId":String(candidate.get("worldId", "")),
		"censusDigest":String(candidate.get("censusDigest", "")),
		"generation":generation, "contentManifestDigest":digest,
		"sourceRevisions":source_revisions.duplicate(true),
		"geometryByDomain":geometry_by_domain, "renderLayers":layers.layers,
		"snapshotCounts":{"contributors":int(snapshot.get("contributorCount", 0)),
			"batches":int(snapshot.get("batchCount", 0)),
			"segments":int(snapshot.get("segmentCount", 0)),
			"instances":int(snapshot.get("instanceCount", 0))},
		"receiptProof":{"generationMatches":int(receipt.get("generation", 0)) == generation,
			"digestMatches":String(receipt.get("contentManifestDigest", "")) == digest,
			"censusMatches":String(receipt.get("censusDigest", "")) == String(census.get("censusDigest", "")),
			"receiptCurrent":true, "backendMatchesCandidate":true,
			"nativeInstalledSnapshot":_compact(native)},
		"acknowledgementProof":{"lastInstallStatus":String(demand.get("lastInstallStatus", "")),
			"installedGeneration":int(demand.get("installedGeneration", 0)),
			"pendingAcknowledgement":false,
			"installedReceiptDigest":String(demand_receipt.get("contentManifestDigest", "")),
			"providerCoverage":provider_coverage}}


func _native_snapshot(candidate: Dictionary, receipt: Dictionary) -> Dictionary:
	var owner_cell: Variant = receipt.get("ownerCell", Vector2i.ZERO)
	var owner_result: Dictionary = main.call("get_static_section_render_owner", owner_cell, false)
	if owner_result.get("status") != "ready":
		return {"status":"pending", "reason":String(owner_result.get("reason", "owner_unavailable"))}
	var backend: Object = owner_result.get("backend") as Object
	if not is_instance_valid(backend) or not backend.has_method("installed_snapshot"):
		return {"status":"pending", "reason":"native_backend_snapshot_unavailable"}
	var slot_id := String(InstallSession.slot_id(String(candidate.get("worldId", "")),
		candidate.get("sectionKey", Vector3i.ZERO)))
	return backend.call("installed_snapshot", slot_id)


func _required_providers_registered() -> bool:
	var roster: Object = coordinator.get("_source_roster") as Object
	if not is_instance_valid(roster):
		return false
	var registrations: Dictionary = roster.get("_providers")
	for provider_id: String in REQUIRED_PROVIDER_IDS:
		var registration: Dictionary = registrations.get(provider_id, {})
		var owner_ref: Variant = registration.get("owner", null)
		var owner: Object = owner_ref.get_ref() if owner_ref is WeakRef else null
		if registration.is_empty() or not is_instance_valid(owner) \
				or owner.get_instance_id() != int(registration.get("ownerInstanceId", 0)):
			return false
	return true


func _domain_for_provider(provider_id: String) -> String:
	if provider_id == "terrain": return "terrain"
	if provider_id in ["ordinary-structures", "blueprint_buildings"]: return "building"
	if provider_id == "ecology_and_static_props": return "ecology"
	return ""


func _layer_summary(value: Variant) -> Dictionary:
	if not value is Array or value.size() != 3:
		return {"status":"pending", "layers":[]}
	var rows: Array[Dictionary] = []
	var seen: Dictionary = {}
	for row_value: Variant in value:
		if not row_value is Dictionary:
			return {"status":"pending", "layers":[]}
		var row: Dictionary = row_value
		var layer := String(row.get("layer", ""))
		if layer not in ["opaque", "cutout", "translucent"] or seen.has(layer):
			return {"status":"pending", "layers":[]}
		seen[layer] = true
		rows.append({"layer":layer,
			"expectedBatchCount":int(row.get("expectedBatchCount", 0)),
			"expectedInstanceCount":int(row.get("expectedInstanceCount", 0))})
	return {"status":"ready" if seen.size() == 3 else "pending", "layers":rows}


func _compact(value: Variant) -> Variant:
	if value is Dictionary:
		var result := {}
		for key: Variant in value:
			if String(key) in ["sourceRevisions", "sourceProviderIds", "sourceIdentities",
					"expectedContributorsBySection", "providerCoverageRevisions",
					"providerSnapshotRevisions"]:
				continue
			result[key] = value[key]
		return result
	return value


func _vec3(value: Vector3i) -> Array[int]:
	return [value.x, value.y, value.z]


func _record(checks: Array[Dictionary], name: String, passed: bool,
		evidence: Variant) -> void:
	checks.append({"name":name, "passed":passed, "evidence":evidence})


func _write_progress(stage: String, details: Dictionary) -> void:
	if progress_path.is_empty():
		return
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"schema":REPORT_SCHEMA + "/progress",
			"stage":stage, "elapsedMsec":Time.get_ticks_msec() - started_msec,
			"details":details}, "\t"))
		file.close()


func _on_startup_step(message: String) -> void:
	if finished:
		return
	_write_progress("main_startup_step", {
		"message":message, "startup":_startup_diagnostic_snapshot()})


func _startup_diagnostic_snapshot() -> Dictionary:
	if not is_instance_valid(main):
		return {"mainValid":false}
	var timeline_value: Variant = main.get("startup_loading_timeline")
	var timeline: Array = timeline_value if timeline_value is Array else []
	var work_progress: Variant = main.get("startup_work_progress")
	var receipts: Variant = work_progress.get("receipts") if is_instance_valid(work_progress) else []
	var receipt_rows: Array = receipts if receipts is Array else []
	var receipt_start := maxi(0, receipt_rows.size() - 8)
	var timeline_start := maxi(0, timeline.size() - 8)
	var summarized_timeline: Array[Dictionary] = []
	for timeline_row_value: Variant in timeline.slice(timeline_start):
		if timeline_row_value is Dictionary:
			summarized_timeline.append(_summarize_startup_row(timeline_row_value))
	var readiness_summary := {}
	var capture_profile := {}
	var demand_breakdown := _visible_demand_breakdown(main)
	var monitor: Object = main.get("runtime_perf_monitor") as Object
	if is_instance_valid(monitor):
		var maxima: Dictionary = monitor.get("max_section_ms")
		var recent: Dictionary = monitor.get("last_section_ms")
		for name: String in maxima:
			if name.begins_with("ecology_catalog_") \
					or name.begins_with("ecology_source_capture_") or name in [
					"ecology_source_queue_service", "ecology_section_admission",
					"ecology_section_install_service"]:
				capture_profile[name] = {"maxMs":maxima[name], "lastMs":recent.get(name, 0.0)}
		var counters: Dictionary = monitor.get("counters")
		for name: String in counters:
			if name.begins_with("ecology_catalog_") \
					or name.begins_with("ecology_source_capture_"):
				capture_profile[name] = counters[name]
	var section_pipeline := {}
	var source_failures: Array[Dictionary] = []
	var cohort_failures: Array[Dictionary] = []
	var tree_preparation := {}
	var tree_compile_progress := {"schema":"startup-tree-compile-progress/v1",
		"minimumActiveJobsForFirstSample":TREE_COMPILE_PROGRESS_MIN_ACTIVE_JOBS,
		"followUpIntervalSeconds":TREE_COMPILE_PROGRESS_SAMPLE_INTERVAL_SECONDS,
		"hasBoundedStartupFailureFallback":true,
		"samples":tree_compile_progress_samples.duplicate(true)}
	var capture_scheduler := {}
	var capture_sessions := {}
	if main.has_method("ecology_source_capture_diagnostics_snapshot"):
		capture_sessions = main.call("ecology_source_capture_diagnostics_snapshot")
	var ecology_owner: Object = main.get("ecology_static_section_provider") as Object
	if is_instance_valid(ecology_owner):
		if ecology_owner.has_method("source_capture_scheduler_snapshot"):
			capture_scheduler = ecology_owner.call("source_capture_scheduler_snapshot")
		var source_jobs: Dictionary = ecology_owner.get("_source_capture_jobs")
		for source_key: Variant in source_jobs:
			var source_job: Dictionary = source_jobs[source_key]
			if source_job.get("status") == "failed":
				source_failures.append({"sourceChunkKey":source_job.get("sourceChunkKey"),
					"attempts":source_job.get("attempts", 0), "failure":source_job.get("failure", {})})
				if source_failures.size() >= 4: break
		var cohorts: Dictionary = ecology_owner.get("_source_capture_cohorts")
		for section_key: Variant in cohorts:
			var cohort: Dictionary = cohorts[section_key]
			if cohort.get("status") == "failed":
				cohort_failures.append({"sectionKey":section_key,
					"reason":cohort.get("cachedFailureReason", ""),
					"blockedReason":cohort.get("blockedReason", "")})
				if cohort_failures.size() >= 4: break
	var tree_queue: Object = main.get("tree_publication_queue") as Object
	if is_instance_valid(tree_queue):
		var tree_jobs: Dictionary = tree_queue.get("ecology_source_compile_jobs")
		var statuses := {}
		var examples: Array[Dictionary] = []
		for job_key: Variant in tree_jobs:
			var job: Dictionary = tree_jobs[job_key]
			var status := String(job.get("status", "unknown"))
			statuses[status] = int(statuses.get(status, 0)) + 1
			if examples.size() < 4:
				examples.append({"sourceChunkKey":job.get("sourceChunkKey"),
					"status":status, "reason":job.get("reason", ""),
					"consumerCount":job.get("consumers", {}).size(),
					"hasPublicationLease":not String(job.get("publicationLeaseToken", "")).is_empty()})
		tree_preparation = {"jobCount":tree_jobs.size(), "statuses":statuses,
			"sourceRecordCompileStarts":tree_queue.get("ecology_tree_source_record_compile_start_count"),
			"sourceRecordCacheReuses":tree_queue.get("ecology_tree_source_record_cache_reuse_count"),
			"sourceRecordWorkUnits":tree_queue.get("ecology_tree_source_record_work_unit_count"),
			"recipeJobCount":tree_queue.get("source_recipe_jobs").size(),
			"recipeWorkerCount":tree_queue.get("source_recipe_workers").size(),
			"examples":examples}
	var section_owner: Object = main.get("world_static_section_coordinator") as Object
	if is_instance_valid(section_owner):
		section_pipeline = {
			"compileJobs":section_owner.get("_section_compile_jobs").size(),
			"completedNativeCompiles":section_owner.get("_section_compile_completed_count"),
			"installJobs":section_owner.get("_production_candidate_jobs").size(),
			"installedCandidates":section_owner.get("_production_candidates_by_section").size()}
	var readiness_value: Variant = main.get("startup_readiness_domains")
	if readiness_value is Dictionary:
		for domain_value: Variant in readiness_value:
			var row: Variant = readiness_value[domain_value]
			if row is Dictionary:
				readiness_summary[String(domain_value)] = _summarize_startup_row(row)
	return {"mainValid":true,
		"sourceCaptureScheduler":capture_scheduler,
		"sourceCaptureSessions":capture_sessions,
		"sourceCaptureFailures":source_failures,
		"sourceCohortFailures":cohort_failures,
		"treePreparation":tree_preparation,
		"treeCompileProgress":tree_compile_progress,
		"capturePreparationProfile":capture_profile,
		"visibleDemandBreakdown":demand_breakdown,
		"staticSectionAdmission":AdmissionDiagnostics.snapshot(main),
		"sectionPipeline":section_pipeline,
		"startupLoadingActive":bool(main.get("startup_loading_active")),
		"runtimeLoadingActive":bool(main.get("runtime_loading_active")),
		"startupOperationActive":bool(main.get("startup_operation_active")),
		"readinessDomains":readiness_summary,
		"failureResult":main.get("startup_loading_failure_result"),
		"maxStep":_summarize_startup_row(main.get("startup_loading_max_step")),
		"timelineTail":summarized_timeline,
		"workProgress":{"completedRevision":work_progress.get("completed_revision") \
			if is_instance_valid(work_progress) else 0,
			"overflow":work_progress.get("overflow") if is_instance_valid(work_progress) else false,
			"receiptsTail":receipt_rows.slice(receipt_start)}}


func _final_pending_tree_visual_snapshot() -> Dictionary:
	if not is_instance_valid(main):
		return {"status":"unavailable", "reason":"main_instance_missing"}
	if not main.has_method("startup_pending_tree_visual_diagnostics"):
		return {"status":"unavailable", "reason":"main_tree_diagnostic_authority_missing"}
	var requests_value: Variant = main.get("streaming_requests")
	var bounds_by_owner_value: Variant = main.get("streaming_request_foreground_bounds")
	if not requests_value is Dictionary or not bounds_by_owner_value is Dictionary:
		return {"status":"unavailable", "reason":"player_region_request_missing"}
	var request_id := int((requests_value as Dictionary).get("player", 0))
	var bounds_value: Variant = (bounds_by_owner_value as Dictionary).get("player", null)
	if request_id <= 0 or not bounds_value is Rect2i:
		return {"status":"unavailable", "reason":"player_region_request_invalid",
			"requestId":request_id}
	var bounds: Rect2i = bounds_value
	if not bounds.has_area():
		return {"status":"unavailable", "reason":"player_region_request_invalid",
			"requestId":request_id}
	var snapshot_value: Variant = main.call(
		"startup_pending_tree_visual_diagnostics", request_id, bounds)
	if not snapshot_value is Dictionary:
		return {"status":"unavailable", "reason":"main_tree_diagnostic_snapshot_invalid",
			"requestId":request_id,
			"bounds":[bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y]}
	var snapshot: Dictionary = snapshot_value.duplicate(true)
	var expected_bounds := [bounds.position.x, bounds.position.y,
		bounds.size.x, bounds.size.y]
	var snapshot_bounds: Variant = snapshot.get("bounds", null)
	snapshot["diagnosticBinding"] = {
		"requestId":request_id,
		"matchesCurrentPlayerRequest":int((requests_value as Dictionary).get(
			"player", 0)) == request_id,
		"matchesCurrentPlayerBounds":snapshot_bounds is Array \
			and snapshot_bounds == expected_bounds,
		"expectedBounds":expected_bounds}
	return snapshot


func _sample_startup_tree_compile_progress() -> void:
	if tree_compile_progress_sampler_active:
		return
	tree_compile_progress_sampler_active = true
	var deadline := Time.get_ticks_msec() + int(startup_wait_seconds * 1000.0)
	while not tree_compile_progress_sampler_stop_requested \
			and Time.get_ticks_msec() < deadline:
		var snapshot := _tree_compile_progress_snapshot()
		if int(snapshot.get("activeJobCount", 0)) >= TREE_COMPILE_PROGRESS_MIN_ACTIVE_JOBS \
				or int(snapshot.get("activeBandJobCount", 0)) > 0:
			snapshot["captureReason"] = "active_compile_cohort_threshold_met"
			tree_compile_progress_samples = [snapshot]
			await create_timer(TREE_COMPILE_PROGRESS_SAMPLE_INTERVAL_SECONDS).timeout
			var second_snapshot := _tree_compile_progress_snapshot()
			second_snapshot["captureReason"] = "two_second_follow_up"
			tree_compile_progress_samples.append(second_snapshot)
			_tree_compile_progress_samples_add_delta()
			tree_compile_progress_sampler_active = false
			return
		await create_timer(TREE_COMPILE_PROGRESS_POLL_SECONDS).timeout
	tree_compile_progress_sampler_active = false


func _ensure_two_tree_compile_progress_samples() -> void:
	while tree_compile_progress_sampler_active:
		await process_frame
	if tree_compile_progress_samples.is_empty():
		var fallback_first := _tree_compile_progress_snapshot()
		fallback_first["captureReason"] = "bounded_startup_failure_fallback"
		tree_compile_progress_samples.append(fallback_first)
	if tree_compile_progress_samples.size() < 2:
		await create_timer(TREE_COMPILE_PROGRESS_SAMPLE_INTERVAL_SECONDS).timeout
		var fallback_second := _tree_compile_progress_snapshot()
		fallback_second["captureReason"] = "bounded_startup_failure_fallback_follow_up"
		tree_compile_progress_samples.append(fallback_second)
		_tree_compile_progress_samples_add_delta()


func _tree_compile_progress_snapshot() -> Dictionary:
	var queue: Object = main.get("tree_publication_queue") as Object \
		if is_instance_valid(main) else null
	if not is_instance_valid(queue):
		return {"elapsedMsec":Time.get_ticks_msec() - started_msec,
			"spawnPosition":Vector3.ZERO, "spawnPositionAvailable":false,
			"activeJobCount":0, "observedJobCount":0,
			"jobs":[], "nativeFoliageTickets":{"status":"unavailable"}}
	var jobs_value: Variant = queue.get("ecology_source_compile_jobs")
	var jobs: Dictionary = jobs_value if jobs_value is Dictionary else {}
	var provider: Object = main.get("ecology_static_section_provider") as Object
	var source_jobs_value: Variant = provider.get("_source_capture_jobs") \
		if is_instance_valid(provider) else {}
	var source_jobs: Dictionary = source_jobs_value if source_jobs_value is Dictionary else {}
	var band_jobs_value: Variant = queue.get("ecology_tree_band_compile_jobs")
	var band_jobs: Dictionary = band_jobs_value if band_jobs_value is Dictionary else {}
	var player_value: Variant = main.get("player")
	var spawn_position_available := player_value is Node3D and is_instance_valid(player_value)
	var spawn_position := (player_value as Node3D).global_position \
		if spawn_position_available else Vector3.ZERO
	var observed: Array[Dictionary] = []
	var observed_band: Array[Dictionary] = []
	var active_job_count := 0
	var active_band_job_count := 0
	for job_key_value: Variant in jobs.keys():
		var job_value: Variant = jobs.get(job_key_value)
		if not job_value is Dictionary:
			continue
		var job: Dictionary = job_value
		var status := String(job.get("status", "unknown"))
		if status not in ["queued", "active", "complete"]:
			continue
		if status in ["queued", "active"]:
			active_job_count += 1
		var job_key := String(job_key_value)
		var consumer_sections: Array[Dictionary] = []
		for source_job_value: Variant in source_jobs.values():
			if not source_job_value is Dictionary:
				continue
			var demands_value: Variant = source_job_value.get("treeCompileDemands", {})
			if not demands_value is Dictionary:
				continue
			var demands: Dictionary = demands_value
			for section_value: Variant in demands:
				var demand_value: Variant = demands.get(section_value)
				if not section_value is Vector3i or not demand_value is Dictionary \
						or String(demand_value.get("jobKey", "")) != job_key:
					continue
				var section_key: Vector3i = section_value
				var section_center := ProducerDomain.section_bounds(section_key).get_center()
				consumer_sections.append({"sectionKey":section_key,
					"distanceFromSpawnMeters":section_center.distance_to(spawn_position)})
		consumer_sections.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var distance_a := float(a.get("distanceFromSpawnMeters", INF))
			var distance_b := float(b.get("distanceFromSpawnMeters", INF))
			if not is_equal_approx(distance_a, distance_b):
				return distance_a < distance_b
			var key_a: Vector3i = a.get("sectionKey", Vector3i.ZERO)
			var key_b: Vector3i = b.get("sectionKey", Vector3i.ZERO)
			if key_a.x != key_b.x: return key_a.x < key_b.x
			if key_a.y != key_b.y: return key_a.y < key_b.y
			return key_a.z < key_b.z)
		var compiler: Variant = job.get("compiler", null)
		var progress: Dictionary = compiler.progress_snapshot() \
			if is_instance_valid(compiler) and compiler.has_method("progress_snapshot") else {
				"status":"unavailable"}
		observed.append({"jobKey":job_key, "status":status,
			"sourceChunkKey":job.get("sourceChunkKey", Vector2i.ZERO),
			"consumerSectionCount":consumer_sections.size(),
			"consumerSections":consumer_sections, "progress":progress})
	for job_key_value: Variant in band_jobs.keys():
		var band_job_value: Variant = band_jobs.get(job_key_value)
		if not band_job_value is Dictionary:
			continue
		var band_job: Dictionary = band_job_value
		var band_status := String(band_job.get("status", "unknown"))
		if band_status not in ["queued", "active", "complete", "failed"]:
			continue
		if band_status in ["queued", "active"]:
			active_band_job_count += 1
		var band_job_key := String(job_key_value)
		var band_sections: Array[Dictionary] = []
		for source_job_value: Variant in source_jobs.values():
			if not source_job_value is Dictionary:
				continue
			var demands_value: Variant = source_job_value.get("treeCompileDemands", {})
			if not demands_value is Dictionary:
				continue
			for section_value: Variant in demands_value:
				var demand_value: Variant = demands_value.get(section_value)
				if section_value is not Vector3i or not demand_value is Dictionary \
						or String(demand_value.get("jobKey", "")) != band_job_key:
					continue
				var section_key: Vector3i = section_value
				var section_center := ProducerDomain.section_bounds(section_key).get_center()
				band_sections.append({"sectionKey":section_key,
					"distanceFromSpawnMeters":section_center.distance_to(spawn_position)})
		var compiler_value: Variant = band_job.get("compiler", null)
		var band_progress: Dictionary = compiler_value.progress_snapshot() \
			if is_instance_valid(compiler_value) and compiler_value.has_method("progress_snapshot") \
			else {"status":"unavailable"}
		observed_band.append({"jobKey":band_job_key, "status":band_status,
			"reason":String(band_job.get("reason", "")),
			"sourceChunkKey":band_job.get("sourceChunkKey", Vector2i.ZERO),
			"sectionKey":band_job.get("sectionKey", Vector3i.ZERO),
			"consumerCount":(band_job.get("consumers", {}) as Dictionary).size(),
			"consumerSections":band_sections, "progress":band_progress,
			"lastProgress":band_job.get("lastProgress", {})})
	observed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sections_a: Array = a.get("consumerSections", [])
		var sections_b: Array = b.get("consumerSections", [])
		var distance_a := float(sections_a[0].get("distanceFromSpawnMeters", INF)) \
			if not sections_a.is_empty() else INF
		var distance_b := float(sections_b[0].get("distanceFromSpawnMeters", INF)) \
			if not sections_b.is_empty() else INF
		if not is_equal_approx(distance_a, distance_b):
			return distance_a < distance_b
		return String(a.get("jobKey", "")) < String(b.get("jobKey", "")))
	var dispatcher_value: Variant = queue.get("native_tree_geometry_dispatcher")
	var native_metrics: Dictionary = {"status":"unavailable"}
	if dispatcher_value is Object and is_instance_valid(dispatcher_value) \
			and dispatcher_value.has_method("tree_geometry_compile_metrics"):
		native_metrics = dispatcher_value.call("tree_geometry_compile_metrics")
	return {"elapsedMsec":Time.get_ticks_msec() - started_msec,
		"spawnPosition":spawn_position,
		"spawnPositionAvailable":spawn_position_available,
		"activeJobCount":active_job_count,
		"observedJobCount":observed.size(), "jobs":observed,
		"activeBandJobCount":active_band_job_count,
		"observedBandJobCount":observed_band.size(), "bandJobs":observed_band,
		"nativeFoliageTickets":native_metrics}


func _tree_compile_progress_samples_add_delta() -> void:
	if tree_compile_progress_samples.size() != 2:
		return
	var before: Dictionary = tree_compile_progress_samples[0]
	var after: Dictionary = tree_compile_progress_samples[1]
	var before_jobs_by_key: Dictionary = {}
	for job_value: Variant in before.get("jobs", []):
		if job_value is Dictionary:
			before_jobs_by_key[String(job_value.get("jobKey", ""))] = job_value
	var after_jobs_by_key: Dictionary = {}
	for job_value: Variant in after.get("jobs", []):
		if job_value is Dictionary:
			after_jobs_by_key[String(job_value.get("jobKey", ""))] = job_value
	var job_deltas: Array[Dictionary] = []
	for job_key_value: Variant in before_jobs_by_key.keys():
		var job_key := String(job_key_value)
		var old_job: Dictionary = before_jobs_by_key[job_key]
		var new_job: Dictionary = after_jobs_by_key.get(job_key, {})
		var old_progress: Dictionary = old_job.get("progress", {})
		var new_progress: Dictionary = new_job.get("progress", {})
		job_deltas.append({"jobKey":job_key,
			"statusBefore":String(old_job.get("status", "unknown")),
			"statusAfter":String(new_job.get("status", "completed_or_retired")),
			"recordIndexDelta":int(new_progress.get("recordIndex", 0)) \
				- int(old_progress.get("recordIndex", 0)),
			"workUnitsDelta":int(new_progress.get("workUnits", 0)) \
				- int(old_progress.get("workUnits", 0)),
			"instanceIndexDelta":int(new_progress.get("instanceIndex", 0)) \
				- int(old_progress.get("instanceIndex", 0)),
			"progressAdvanced":String(new_job.get("status", "")) == "complete" \
				or int(new_progress.get("recordIndex", 0)) \
				> int(old_progress.get("recordIndex", 0)) \
				or int(new_progress.get("workUnits", 0)) \
				> int(old_progress.get("workUnits", 0)) \
				or int(new_progress.get("instanceIndex", 0)) \
				> int(old_progress.get("instanceIndex", 0))})
	job_deltas.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("jobKey", "")) < String(b.get("jobKey", "")))
	var before_band_by_key: Dictionary = {}
	for job_value: Variant in before.get("bandJobs", []):
		if job_value is Dictionary:
			before_band_by_key[String(job_value.get("jobKey", ""))] = job_value
	var after_band_by_key: Dictionary = {}
	for job_value: Variant in after.get("bandJobs", []):
		if job_value is Dictionary:
			after_band_by_key[String(job_value.get("jobKey", ""))] = job_value
	var band_job_deltas: Array[Dictionary] = []
	for job_key_value: Variant in before_band_by_key.keys():
		var job_key := String(job_key_value)
		var old_job: Dictionary = before_band_by_key[job_key]
		var new_job: Dictionary = after_band_by_key.get(job_key, {})
		var old_progress: Dictionary = old_job.get("progress", {})
		var new_progress: Dictionary = new_job.get("progress", {})
		var old_last: Dictionary = old_job.get("lastProgress", {})
		var new_last: Dictionary = new_job.get("lastProgress", {})
		band_job_deltas.append({"jobKey":job_key,
			"statusBefore":String(old_job.get("status", "unknown")),
			"statusAfter":String(new_job.get("status", "completed_or_retired")),
			"reasonBefore":String(old_job.get("reason", "")),
			"reasonAfter":String(new_job.get("reason", "")),
			"workUnitsDelta":int(new_progress.get("workUnits", 0)) \
				- int(old_progress.get("workUnits", 0)),
			"instanceIndexDelta":int(new_progress.get("instanceIndex", 0)) \
				- int(old_progress.get("instanceIndex", 0)),
			"lastProgressWorkUnitsDelta":int(new_last.get("workUnits", 0)) \
				- int(old_last.get("workUnits", 0)),
			"progressAdvanced":String(new_job.get("status", "")) == "complete" \
				or int(new_progress.get("workUnits", 0)) > int(old_progress.get("workUnits", 0)) \
				or int(new_progress.get("instanceIndex", 0)) \
				> int(old_progress.get("instanceIndex", 0)) \
				or int(new_last.get("workUnits", 0)) > int(old_last.get("workUnits", 0))})
	band_job_deltas.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("jobKey", "")) < String(b.get("jobKey", "")))
	after["deltaFromPrevious"] = {"intervalMsec":int(after.get("elapsedMsec", 0)) \
		- int(before.get("elapsedMsec", 0)), "jobDeltas":job_deltas,
		"bandJobDeltas":band_job_deltas,
		"nativeFoliageTicketsDelta":_numeric_dictionary_delta(
			before.get("nativeFoliageTickets", {}), after.get("nativeFoliageTickets", {}))}
	tree_compile_progress_samples[1] = after


func _numeric_dictionary_delta(before_value: Variant, after_value: Variant) -> Dictionary:
	if not before_value is Dictionary or not after_value is Dictionary:
		return {"status":"unavailable"}
	var before: Dictionary = before_value
	var after: Dictionary = after_value
	var result := {}
	for key_value: Variant in after.keys():
		var key := String(key_value)
		if before.get(key) is int or before.get(key) is float:
			if after[key] is int or after[key] is float:
				result[key] = float(after[key]) - float(before[key])
	return result


func _visible_demand_breakdown(main_authority: Object) -> Dictionary:
	var coordinator: Object = main_authority.get("world_static_section_coordinator") as Object
	var provider: Object = main_authority.get("ecology_static_section_provider") as Object
	var section_demands: Dictionary = coordinator.get("_visible_section_demands") \
		if is_instance_valid(coordinator) else {}
	var terrain_sections := 0
	var combined_sections := 0
	var support_only_sections := 0
	var support_demand_rows := 0
	var support_owner_keys: Dictionary = {}
	for state_value: Variant in section_demands.values():
		if not state_value is Dictionary:
			continue
		var state: Dictionary = state_value
		var has_terrain := not String(state.get("terrainRevision", "")).is_empty() \
			and not bool(state.get("terrainDemandWithdrawn", false))
		var support_demands: Dictionary = state.get("supportDemands", {})
		if has_terrain:
			terrain_sections += 1
		if has_terrain and not support_demands.is_empty():
			combined_sections += 1
		elif not has_terrain and not support_demands.is_empty():
			support_only_sections += 1
		for demand_value: Variant in support_demands.values():
			support_demand_rows += 1
			var snapshot_value: Variant = demand_value.get("snapshot", null) \
				if demand_value is Dictionary else null
			if snapshot_value is Dictionary:
				for lease_value: Variant in snapshot_value.get("supportOwnerDemands", []):
					if lease_value is Dictionary and lease_value.get("ownerSectionKey", null) is Vector3i:
						support_owner_keys[lease_value.ownerSectionKey] = true
	var support_state := {}
	var controller: Object = main_authority.get("visible_world_demand_controller") as Object
	if is_instance_valid(controller):
		var bridge: Object = controller.get("_support_lease_bridge") as Object
		if is_instance_valid(bridge) and bridge.has_method("required_section_snapshots"):
			support_state = bridge.call("required_section_snapshots", "player")
	var required_manifest_sections := 0
	var accepted_manifest_sections := 0
	var pending_manifest_sections := 0
	var owner_sections := 0
	for set_name: String in ["accepted", "pending", "ownerSections"]:
		var rows: Variant = support_state.get(set_name, {})
		if not rows is Dictionary:
			continue
		if set_name == "accepted": accepted_manifest_sections = rows.size()
		elif set_name == "pending": pending_manifest_sections = rows.size()
		else: owner_sections = rows.size()
	var required_manifest: Variant = support_state.get("requiredSections", {})
	if required_manifest is Dictionary:
		required_manifest_sections = required_manifest.size()
	var source_jobs: Dictionary = provider.get("_source_capture_jobs") \
		if is_instance_valid(provider) else {}
	var source_states := {"queued":0, "pending":0, "ready":0, "failed":0}
	var source_chunk_keys: Dictionary = {}
	var source_subscribers := 0
	for job_value: Variant in source_jobs.values():
		if not job_value is Dictionary:
			continue
		var job: Dictionary = job_value
		var status := String(job.get("status", "unknown"))
		if not source_states.has(status): source_states[status] = 0
		source_states[status] = int(source_states.get(status, 0)) + 1
		var source_key: Variant = job.get("sourceChunkKey", null)
		if source_key is Vector2i: source_chunk_keys[source_key] = true
		source_subscribers += (job.get("sections", {}) as Dictionary).size()
	return {"sectionDemandCount":section_demands.size(),
		"terrainBackedSectionCount":terrain_sections,
		"terrainAndSupportSectionCount":combined_sections,
		"supportOnlySectionCount":support_only_sections,
		"supportDemandLeaseCount":support_demand_rows,
		"supportGeometryOwnerSectionCount":support_owner_keys.size(),
		"manifestRequiredSectionCount":required_manifest_sections,
		"manifestAcceptedSectionCount":accepted_manifest_sections,
		"manifestPendingSectionCount":pending_manifest_sections,
		"manifestGeometryOwnerSectionCount":owner_sections,
		"sourceCaptureJobCount":source_jobs.size(),
		"sourceCaptureChunkCount":source_chunk_keys.size(),
		"sourceCaptureSubscribers":source_subscribers,
		"sourceCaptureJobsByStatus":source_states}


func _summarize_startup_row(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var row: Dictionary = value
	var metrics: Variant = row.get("metrics", {})
	var visible: Variant = metrics.get("visibleSectionPublication", {}) \
		if metrics is Dictionary else {}
	var admission: Variant = visible.get("lastAdmission", {}) \
		if visible is Dictionary else {}
	return {"domain":String(row.get("domain", "")),
		"terrainExpansion":{
			"currentViewDistance":metrics.get("currentViewDistance", 0),
			"pendingNativeTasks":metrics.get("pendingNativeTasks", 0),
			"publishedRetainedGameplayChunks":metrics.get("publishedRetainedGameplayChunks", 0)} if metrics is Dictionary else {},
		"sourceCaptureService":visible.get("ecologySourceCapture", {}) if visible is Dictionary else {},
		"admissionPhaseUsec":admission.get("phaseUsec", {}) if admission is Dictionary else {},
		"status":String(row.get("status", "")),
		"reason":String(row.get("reason", "")),
		"message":String(row.get("message", "")),
		"elapsedMs":float(row.get("elapsedMs", 0.0)),
		"stepMs":float(row.get("stepMs", 0.0)),
		"completedWorkRevision":int(row.get("completedWorkRevision", 0)),
		"visualStatus":String(metrics.get("status", "")) if metrics is Dictionary else "",
		"visualMissing":metrics.get("missing", []) if metrics is Dictionary else [],
		"treeVisualPending":metrics.get("domains", {}).get("visual", {}).get(
			"byKind", {}).get("trees_foliage", {}).get("pending", 0) \
			if metrics is Dictionary else 0,
		"pendingDemandCount":int(visible.get("pendingDemandCount", 0)) \
			if visible is Dictionary else 0,
		"providerId":String(admission.get("providerId", "")) \
			if admission is Dictionary else "",
		"providerReason":String(admission.get("providerReason", "")) \
			if admission is Dictionary else "",
		"providerDetails":admission.get("providerDetails", {}) \
			if admission is Dictionary else {}}


func _finish(checks: Array[Dictionary], evidence: Dictionary, reason: String) -> void:
	if finished:
		return
	finished = true
	var passed := not checks.is_empty()
	for check: Dictionary in checks:
		passed = passed and bool(check.get("passed", false))
	var report_reason := reason
	var capture_ack: Dictionary = await _wait_for_final_viewport_capture_ack(passed)
	var capture_passed := bool(capture_ack.get("captured", false))
	_record(checks, "final_rendered_viewport_checkpoint_captured", capture_passed, capture_ack)
	if not capture_passed:
		passed = false
		report_reason = "final_rendered_viewport_checkpoint_capture_failed"
	_write_progress("finished", {"passed":passed, "reason":report_reason})
	var options: Dictionary = main.get("launch_options") if is_instance_valid(main) else {}
	var report := {"schema":REPORT_SCHEMA, "passed":passed,
		"gameplayAcceptance":false, "reason":report_reason, "seed":seed_text,
		"tutorialSkipped":bool(options.get("skipTutorial", false)),
		"worldId":coordinator.call("world_identity") if is_instance_valid(coordinator) else "",
		"elapsedMsec":Time.get_ticks_msec() - started_msec,
		"checks":checks, "checkCount":checks.size(), "evidence":evidence,
		"startupFailure":startup_failure,
		"doesNotProve":"Traversal/visual parity, collision or interaction parity, unload/replay, save/reload, or performance."}
	report["finalViewportCapture"] = capture_ack
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	if main != null and is_instance_valid(main):
		if main.has_method("request_graceful_quit"):
			main.call("request_graceful_quit", 0 if passed else 1)
		else:
			main.queue_free()
			quit(0 if passed else 1)
	else:
		quit(0 if passed else 1)


func _wait_for_final_viewport_capture_ack(passed: bool) -> Dictionary:
	if OS.get_environment("VOXEL_AUTOMATED_TEST") != "1":
		return {"required":true, "captured":false,
			"reason":"automated in-game viewport capture handshake is required for this gate"}
	_write_progress("awaiting_final_viewport_capture", {"passed":passed})
	if OS.get_environment("VOXEL_AUTOMATED_TEST_CAPTURE_MODE") != "godot_viewport":
		return {"required":true, "captured":false,
			"reason":"automated cohabitation gate requires in-game viewport capture mode"}
	var ack_path := OS.get_environment("VOXEL_AUTOMATED_TEST_FINAL_CAPTURE_ACK").strip_edges()
	if ack_path.is_empty():
		return {"required":true, "captured":false,
			"reason":"final viewport capture acknowledgement path is missing"}
	var expected_run_id := OS.get_environment("VOXEL_AUTOMATED_TEST_RUN_ID").strip_edges()
	var expected_runner_id := OS.get_environment("VOXEL_AUTOMATED_TEST_NAME").strip_edges()
	var expected_source_identity_sha256 := OS.get_environment(
		"VOXEL_AUTOMATED_TEST_SOURCE_IDENTITY_SHA256").strip_edges()
	var expected_checkpoint := "test-success" if passed else "test-failure"
	var expected_phase := "test_success" if passed else "test_failure"
	var expected_phase_kind := "harness" if passed else "failure"
	var sha256_pattern := RegEx.new()
	sha256_pattern.compile("^[0-9a-f]{64}$")
	var deadline_usec := Time.get_ticks_usec() \
		+ int(FINAL_VIEWPORT_CAPTURE_ACK_TIMEOUT_SECONDS * 1000000.0)
	while Time.get_ticks_usec() < deadline_usec:
		if FileAccess.file_exists(ack_path):
			var file := FileAccess.open(ack_path, FileAccess.READ)
			if file != null:
				var ack: Variant = JSON.parse_string(file.get_as_text())
				file.close()
				if ack is Dictionary and ack.get("schema") == "godot-viewport-final-capture-ack/v1" \
						and ack.get("runId") == expected_run_id \
						and ack.get("runnerId") == expected_runner_id \
						and ack.get("checkpoint") == expected_checkpoint \
						and ack.get("phase") == expected_phase \
						and ack.get("phaseKind") == expected_phase_kind \
						and ack.get("accepted") == passed \
						and ack.get("sourceIdentitySha256") == expected_source_identity_sha256:
					var viewport_receipt: Variant = ack.get("viewportCaptureReceipt", {})
					var capture_id := String(ack.get("captureId", ""))
					var screenshot_hash := String(ack.get("screenshotSha256", ""))
					var receipt_matches: bool = viewport_receipt is Dictionary \
						and viewport_receipt.get("schema") == "voxel-automated-test-viewport-capture-receipt/v1" \
						and viewport_receipt.get("captured") == true \
						and viewport_receipt.get("captureId") == capture_id \
						and viewport_receipt.get("runnerId") == expected_runner_id \
						and viewport_receipt.get("runId") == expected_run_id \
						and viewport_receipt.get("phase") == expected_phase \
						and viewport_receipt.get("phaseKind") == expected_phase_kind \
						and viewport_receipt.get("sourceIdentitySha256") == expected_source_identity_sha256
					if ack.get("captured") == true and capture_id.begins_with(expected_run_id + ":") \
							and sha256_pattern.search(screenshot_hash) != null and receipt_matches:
						return ack
					if ack.get("captured") == false:
						return ack
		await process_frame
	return {"required":true, "captured":false, "timedOut":true,
		"reason":"timed_out_waiting_for_runner_final_viewport_capture_ack",
		"runId":expected_run_id, "runnerId":expected_runner_id,
		"checkpoint":expected_checkpoint, "sourceIdentitySha256":expected_source_identity_sha256}


func _on_startup_failed(message: String) -> void:
	startup_failure_message = message
