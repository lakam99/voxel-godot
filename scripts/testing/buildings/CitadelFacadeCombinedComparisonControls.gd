extends "res://scripts/testing/buildings/CitadelFacadeCombinedComparisonContract.gd"

## Independent protocol-negative supplement. No new publication, classifier,
## source changes or contact acceptance. Valid captured envelopes are the
## positive controls; each negative changes one reviewed identity fact only.
const TESTED_PARENT_PATH := "res://scripts/testing/buildings/CitadelFacadeCombinedComparisonContract.gd"
const TESTED_PARENT_SHA := "3729ff24e4cfa24f9f6c0be36c22c7ca1ddcfa3614a321897515ee82779f8d0a"

func _run() -> void:
	if FileAccess.get_sha256(TESTED_PARENT_PATH) != TESTED_PARENT_SHA:
		quit(2)
		return
	_inputs_read[TESTED_PARENT_PATH] = TESTED_PARENT_SHA
	super._run()

func _comparison_controls() -> Dictionary:
	_binding["testedParentSha256"] = TESTED_PARENT_SHA
	var result: Dictionary = super._comparison_controls()
	result["testedParent"] = {"path": TESTED_PARENT_PATH, "sha256": TESTED_PARENT_SHA}
	var fresh: Dictionary = _load_capture("after_standard")
	var historical: Dictionary = _load_capture("legacy_after_standard")
	if fresh.is_empty() or historical.is_empty():
		result.checks["valid_full_capture_envelopes_admitted"] = false
		result.complete = false
		return result
	result.checks["valid_full_capture_envelopes_admitted"] = _capture_header_valid(fresh, "after_standard") and _capture_header_valid(historical, "legacy_after_standard")
	var original_fresh: String = _raw_digest(fresh)
	var original_historical: String = _raw_digest(historical)
	var bad: Dictionary = fresh.duplicate()
	bad.implementationIdentity = fresh.implementationIdentity.duplicate()
	bad.implementationIdentity["res://scripts/buildings/BuildingPartPublisher.gd"] = "0".repeat(64)
	result.checks["valid_capture_extra_runtime_drift_rejected"] = not _capture_header_valid(bad, "after_standard")
	bad = fresh.duplicate()
	bad.implementationIdentity = fresh.implementationIdentity.duplicate()
	bad.implementationIdentity.erase("res://scripts/buildings/BuildingPartPublisher.gd")
	result.checks["valid_capture_missing_dependency_rejected"] = not _capture_header_valid(bad, "after_standard")
	bad = fresh.duplicate()
	bad.implementationIdentity = historical.implementationIdentity
	result.checks["valid_capture_swapped_old_identity_rejected"] = not _capture_header_valid(bad, "after_standard")
	bad = historical.duplicate()
	bad.implementationIdentity = fresh.implementationIdentity
	result.checks["valid_capture_swapped_new_identity_rejected"] = not _capture_header_valid(bad, "legacy_after_standard")
	_allow_legacy = true
	result.checks["valid_historical_generator_provenance_admitted"] = _check_contract_identity(_reuse.contractIdentity).exact
	var changed_generator: Dictionary = _reuse.contractIdentity.duplicate()
	changed_generator[GENERATOR_TEST_PATH] = "0".repeat(64)
	_identity_failure = ""
	result.checks["altered_generator_provenance_rejected_at_generator"] = not _check_contract_identity(changed_generator).exact and _identity_failure == GENERATOR_TEST_PATH
	_identity_failure = ""
	result.checks["original_envelopes_unchanged_after_negatives"] = _raw_digest(fresh) == original_fresh and _raw_digest(historical) == original_historical
	result.checks["positive_envelopes_still_admitted"] = _capture_header_valid(fresh, "after_standard") and _capture_header_valid(historical, "legacy_after_standard")
	result["scope"] = "valid_full_envelope_identity_fault_injection_only"
	result.complete = result.checks.values().all(func(value): return value == true) and _within_budget()
	return result
