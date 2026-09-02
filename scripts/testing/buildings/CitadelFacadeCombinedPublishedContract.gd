extends "res://scripts/testing/buildings/CitadelFacadePavingPublishedContract.gd"

## Whole09 adapter for the unchanged complete publication-cycle collector.
## Raw source is never rewritten. Derived header hashes use the collector's
## raw-byte convention; source-contract hexadecimal-encoding hashes are first
## verified separately. These captures alone do not approve contacts or reuse.
const COMBINED_SHA := "36ed79a46e014afd35c78fdf54cbbbb88730241165bd72c3c9491c8c7eb4d004"

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	_cycle_report_path = OS.get_environment("VOXEL_FACADE_PAVING_PUBLISHED_REPORT")
	var stage := OS.get_environment("VOXEL_FACADE_PAVING_STAGE")
	var input := OS.get_environment("VOXEL_FACADE_PAVING_CANDIDATE")
	if not _cycle_report_path.is_absolute_path() or _cycle_report_path.get_extension() != "json" or FileAccess.file_exists(_cycle_report_path) or not DirAccess.dir_exists_absolute(_cycle_report_path.get_base_dir()):
		quit(2)
		return
	var report := {"passed": false, "diagnosticCompleted": false, "publicationAcceptance": false, "modes": [],
		"requestedStage": stage, "requestedStageCompleted": false, "inputPath": input, "inputSha256": COMBINED_SHA,
		"evidenceLevel": "combined_actual_full_source_CPU_publication_cycle",
		"limits": {"softMsec": SOFT_LIMIT_MSEC, "sourceParts": MAX_SOURCE_PARTS, "publishedPrimitives": MAX_PUBLISHED_PRIMITIVES,
			"primitiveTests": MAX_PRIMITIVE_TESTS, "recordedContacts": MAX_RECORDED_CONTACTS, "nodes": MAX_COLLECTED_NODES}}
	if stage not in ["after_standard", "after_static"] or not input.is_absolute_path() or FileAccess.get_sha256(input) != COMBINED_SHA:
		_finish_cycle_report(report, "combined_input_or_stage")
		return
	var file := FileAccess.open(input, FileAccess.READ)
	if file == null:
		_finish_cycle_report(report, "combined_open")
		return
	var count := file.get_length()
	if count <= 0 or count > MAX_ARTIFACT_BYTES:
		file.close()
		_finish_cycle_report(report, "combined_size")
		return
	var bytes := file.get_buffer(count)
	var complete := bytes.size() == count and file.get_error() == OK
	file.close()
	var decoded: Variant = bytes_to_var(bytes)
	if not complete or not _valid_facade_archive(decoded) or var_to_bytes(decoded) != bytes:
		_finish_cycle_report(report, "combined_schema")
		return
	var source: Dictionary = decoded
	if source.get("mainShardPassed") != true or source.get("pairedAcceptancePending") != true or not source.get("pavingFinishPartIds") is Array or source.pavingFinishPartIds.size() != 1 or source.partIds.size() != 16 or source.furnitureSnapshot.parts.size() != 152:
		_finish_cycle_report(report, "combined_checkpoint_shape")
		return
	var original_hashes := {"sourceDigest": source.sourceDigest, "outputDigest": source.outputDigest, "fixtureDigest": source.fixtureDigest, "policyDigest": source.policyDigest}
	var policy := {"furnitureParts": source.furnitureSnapshot.parts, "reservedVolumes": source.protectedReservations}
	for pair in [[source.beforeSnapshot, source.sourceDigest], [source.afterSnapshot, source.outputDigest], [source.fixture, source.fixtureDigest], [policy, source.policyDigest]]:
		if var_to_bytes(pair[0]).hex_encode().sha256_text() != pair[1]:
			_finish_cycle_report(report, "combined_source_digest")
			return
	var identity := _check_contract_identity(source.contractIdentity)
	report["contractIdentity"] = identity
	if not identity.exact:
		_finish_cycle_report(report, "combined_implementation_identity")
		return
	# Metadata adapter only; all source/furniture/reservation values are shared
	# immutable inputs and passed unchanged into the inherited lifecycle.
	var archive: Dictionary = source.duplicate()
	archive.sourceDigest = _raw_digest(source.beforeSnapshot)
	archive.afterDigest = _raw_digest(source.afterSnapshot)
	archive.fixtureDigest = _raw_digest(source.fixture)
	archive.policyDigest = _raw_digest(policy)
	archive.furnitureDigest = _raw_digest(source.furnitureSnapshot)
	archive.reservationDigest = _raw_digest(source.protectedReservations)
	report["originalSourceContractHashes"] = original_hashes
	report["derivedRawHashes"] = {"before": archive.sourceDigest, "after": archive.afterDigest, "policy": archive.policyDigest}
	_finish_ids = source.pavingFinishPartIds.duplicate()
	report["collectorControls"] = _collector_controls()
	if not report.collectorControls.passed:
		_finish_cycle_report(report, "collector_controls")
		return
	_run_checkpoint(archive, report, stage, input, COMBINED_SHA)

func _finish_cycle_report(report: Dictionary, reason: String) -> void:
	report["doesNotProve"] = "One combined after-cycle only. Does not establish baseline reuse, material-winner equality, inter-component contacts, GPU appearance, gameplay or gate zero."
	report["outstandingCoverage"] = ["both_combined_after_modes", "explicit_baseline_source_and_publication_dependency_mapping", "all_new_cross_component_contacts", "independent_contact_review", "critic_approved_headed_visuals"]
	super._finish_cycle_report(report, reason)
