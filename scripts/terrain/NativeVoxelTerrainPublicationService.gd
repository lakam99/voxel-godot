extends RefCounted
class_name NativeVoxelTerrainPublicationService

## Composes the native N3 demand planner/publisher beneath VoxelTerrainRuntime.
## This service is deliberately inert until a runtime explicitly installs it;
## the existing script-generator path remains the default production behavior.
## It advances publication only. It cannot claim mesh or physics readiness.
## The caller transfers an immutable demand snapshot for this call. In particular,
## while a proposal is pending it must not mutate nested arrays/dictionaries;
## the service retains the same snapshot reference to avoid a tick-sized deep copy.
## This initial bridge is contract-only until demand planning is incrementally bounded.

const SCHEMA := "n3-vtr-native-publication-demand/v1"
const RECEIPT_SCHEMA := "n3-native-voxel-publication-step-receipt/v1"

var _runtime
var _owner
var _state := "new"
var _failure := ""
var _pending_demand: Dictionary = {}
var _accepted_revision := -1
var _runtime_identity: Dictionary = {}
var _owner_source_identity: Dictionary = {}
var _owner_backend_instance_id := 0
var _owner_generation := 0
var _owner_source_revision := -1
var _accepted_planner_identity: Dictionary = {}
var _latest_receipt: Dictionary = {}
var _advance_count := 0
var _pending_retries := 0
var _superseded_pending_revisions := 0
var _stop_requested := false
var _cleanup_complete := false
var _cleanup_failure := ""
var _drain_step_count := 0


func setup(runtime, owner) -> Dictionary:
	if _state != "new":
		return _failed("publication_service_already_started")
	if runtime == null or not runtime.has_method("validate_native_publication_receipt") \
			or not runtime.has_method("validate_native_publication_owner_binding") \
			or not runtime.has_method("validate_native_publication_retirement_receipt"):
		return _failed("runtime_native_publication_validation_api_missing")
	if owner == null or not owner.has_method("replace_demand") \
			or not owner.has_method("advance") or not owner.has_method("snapshot") \
			or not owner.has_method("request_stop") or not owner.has_method("drain_step"):
		return _failed("native_runtime_owner_api_missing")
	var owner_state: Dictionary = owner.snapshot()
	var pristine := _validate_pristine_owner(owner_state)
	if pristine.get("status") != "ready":
		return _failed(String(pristine.get("reason", "native_owner_not_virgin")))
	var binding: Dictionary = _owner_binding(owner_state)
	var binding_check: Dictionary = runtime.call("validate_native_publication_owner_binding", binding)
	if binding_check.get("status") != "ready":
		return _failed(String(binding_check.get("reason", "native_owner_binding_rejected")))
	_runtime = runtime
	_owner = owner
	_owner_backend_instance_id = int(binding.backendInstanceId)
	_owner_source_identity = (binding.sourceIdentity as Dictionary).duplicate(true)
	_owner_source_revision = int(binding.sourceRevision)
	_owner_generation = int(binding.ownerGeneration)
	_accepted_planner_identity = _planner_identity(owner_state)
	_state = "active"
	return {"status":"ready", "schema":SCHEMA}


func advance(snapshot: Dictionary) -> Dictionary:
	if _state == "failed_draining":
		return {"status":"failed_draining", "reason":_failure,
			"requiresExplicitDrain":true, "cleanupComplete":false}
	if _state != "active":
		return {"status":"failed", "reason":_failure if not _failure.is_empty() else "publication_service_not_active"}
	var validation := _validate_demand(snapshot)
	if validation.get("status") != "ready":
		return validation
	var identity := {"configuredSeed":String(snapshot.configuredSeed),
		"terrainInstanceId":int(snapshot.terrainInstanceId),
		"collisionOwnerGeneration":int(snapshot.collisionOwnerGeneration)}
	if _runtime_identity.is_empty():
		_runtime_identity = identity
	elif identity != _runtime_identity:
		return _begin_terminal_failure("native_publication_runtime_owner_changed",
			{"expected":_runtime_identity.duplicate(true), "actual":identity})
	var owner_before: Dictionary = _owner.snapshot()
	var before_check := _validate_owner_binding_and_planner(owner_before)
	if before_check.get("status") != "ready":
		return _begin_terminal_failure(String(before_check.get("reason", "native_owner_state_drift")),
			{"ownerCheck":before_check})
	var candidate: Dictionary = snapshot
	var revision := int(candidate.get("demandRevision", -1))
	if revision < _accepted_revision:
		return {"status":"failed", "reason":"native_demand_revision_regressed",
			"acceptedRevision":_accepted_revision, "receivedRevision":revision}
	if not _pending_demand.is_empty() and revision < int(_pending_demand.demandRevision):
		return {"status":"failed", "reason":"native_demand_revision_regressed",
			"pendingRevision":int(_pending_demand.demandRevision), "receivedRevision":revision}
	if revision != _accepted_revision and (_pending_demand.is_empty() \
			or revision > int(_pending_demand.demandRevision)):
		if not _pending_demand.is_empty():
			_superseded_pending_revisions += 1
		_pending_demand = candidate
	elif not _pending_demand.is_empty():
		candidate = _pending_demand
	else:
		candidate = {}

	var demand_result := {"status":"ready", "unchanged":true,
		"demandRevision":_accepted_revision}
	if not _pending_demand.is_empty():
		demand_result = _owner.replace_demand(
			_pending_demand.get("primaryViewer", {}),
			_pending_demand.get("otherViewers", []),
			_pending_demand.get("retainedChunks", []),
			_pending_demand.get("foregroundChunks", []),
			_pending_demand.get("verticalBounds", Vector2i.ZERO))
		if demand_result.get("status") == "ready":
			var after_replace: Dictionary = _owner.snapshot()
			var planner_receipt := _verify_replace_planner_receipt(demand_result, after_replace)
			if planner_receipt.get("status") != "ready":
				return _begin_terminal_failure(String(planner_receipt.get("reason", "planner_receipt_mismatch")),
					{"demand":demand_result, "plannerReceipt":planner_receipt})
			_accepted_revision = int(_pending_demand.demandRevision)
			_accepted_planner_identity = _planner_identity(after_replace)
			_pending_demand = {}
			_pending_retries = 0
		elif demand_result.get("status") == "pending":
			_pending_retries += 1
		elif demand_result.get("status") == "failed":
			return _begin_terminal_failure(String(demand_result.get("reason", "native_demand_rejected")),
				{"demandRevision":revision, "demand":demand_result})
		else:
			return _begin_terminal_failure("native_demand_result_invalid",
				{"demandRevision":revision, "demand":demand_result})

	# Always pump the previously accepted native owner once, including while a
	# newer full-source proposal is pending/capacity constrained. The candidate
	# remains retained and is retried on a later advance.
	var native_step: Dictionary = _owner.advance()
	_advance_count += 1
	if native_step.get("status") == "failed":
		return _begin_terminal_failure(String(native_step.get("reason", "native_publication_advance_failed")),
			{"demand":demand_result, "nativeStep":native_step})
	var owner_after: Dictionary = _owner.snapshot()
	var continuity := _validate_owner_binding_and_planner(owner_after)
	if continuity.get("status") != "ready":
		return _begin_terminal_failure(String(continuity.get("reason", "native_owner_planner_continuity_lost")),
			{"ownerCheck":continuity, "nativeStep":native_step})
	var receipt_snapshot: Dictionary = snapshot
	var receipt := _build_step_receipt(receipt_snapshot, demand_result, native_step,
		_accepted_revision, owner_after)
	var checked: Dictionary = _runtime.call("validate_native_publication_receipt", receipt)
	if checked.get("status") != "ready":
		return _begin_terminal_failure(String(checked.get("reason", "native_publication_receipt_rejected")),
			{"demand":demand_result, "nativeStep":native_step, "receipt":receipt,
			"runtimeValidation":checked})
	receipt["runtimeValidation"] = checked.duplicate(true)
	_latest_receipt = receipt.duplicate(true)
	return {"status":"advanced", "demandStatus":String(demand_result.get("status", "pending")),
		"demandRevision":_accepted_revision,
		"pendingDemandRevision":int(_pending_demand.get("demandRevision", -1)),
		"demand":demand_result, "nativeStep":native_step,
		"receipt":receipt, "readinessClaim":{"data":bool(receipt.get("dataInserted", false)),
			"mesh":false, "physics":false}}


## Called only after failure entered failed_draining. The caller first detaches
## the producer viewer and proves external physical/lease retirement; this
## function advances exactly one owner drain step and never pumps publication.
func drain_step(retirement_evidence: Dictionary) -> Dictionary:
	if _state != "failed_draining":
		return {"status":"failed", "reason":"native_publication_drain_not_requested"}
	var before: Dictionary = _owner.snapshot()
	var external_gate: Dictionary = _runtime.call(
		"validate_native_publication_retirement_receipt", retirement_evidence,
		{}, before, _owner_binding_facts())
	if external_gate.get("status") == "failed":
		_cleanup_failure = String(external_gate.get("reason", "external_retirement_evidence_rejected"))
		return {"status":"failed_draining", "reason":_failure,
			"cleanupFailure":_cleanup_failure, "externalValidation":external_gate,
			"cleanupComplete":false}
	if external_gate.get("status") != "ready":
		return {"status":"failed_draining", "reason":_failure,
			"externalValidation":external_gate, "cleanupComplete":false,
			"drainStepCount":_drain_step_count}
	var owner_step: Dictionary = _owner.drain_step()
	_drain_step_count += 1
	if owner_step.get("status") == "failed":
		_cleanup_failure = String(owner_step.get("reason", "native_owner_drain_failed"))
		return {"status":"failed_draining", "reason":_failure,
			"cleanupFailure":_cleanup_failure, "ownerStep":owner_step,
			"cleanupComplete":false}
	var owner_after: Dictionary = _owner.snapshot()
	var checked: Dictionary = _runtime.call("validate_native_publication_retirement_receipt",
		retirement_evidence, owner_step, owner_after, _owner_binding_facts())
	if checked.get("status") == "failed":
		_cleanup_failure = String(checked.get("reason", "runtime_retirement_evidence_rejected"))
		return {"status":"failed_draining", "reason":_failure,
			"cleanupFailure":_cleanup_failure, "ownerStep":owner_step,
			"runtimeValidation":checked, "cleanupComplete":false}
	if checked.get("status") != "ready":
		return {"status":"failed_draining", "reason":_failure,
			"ownerStep":owner_step, "runtimeValidation":checked,
			"cleanupComplete":false, "drainStepCount":_drain_step_count}
	if owner_step.get("drained") != true or owner_after.get("state") != "drained" \
			or int(owner_after.get("backendInstanceId", -1)) != 0 \
			or owner_step.get("physicalBlocksUnloaded") != true \
			or owner_step.get("nativeWorkersDrained") != true \
			or owner_step.get("demandReleased") != true \
			or owner_step.get("leasesReleased") != true \
			or owner_after.get("asyncStopReceipt", {}).get("drained") != true:
		return {"status":"failed_draining", "reason":_failure,
			"ownerStep":owner_step, "runtimeValidation":checked,
			"cleanupComplete":false, "drainStepCount":_drain_step_count}
	_cleanup_complete = true
	_state = "failed"
	return {"status":"failed", "reason":_failure, "cleanupComplete":true,
		"retirementReceipt":checked, "ownerStep":owner_step,
		"drainStepCount":_drain_step_count}


func latest_receipt() -> Dictionary:
	return _latest_receipt.duplicate(true)


func snapshot() -> Dictionary:
	return {"state":_state, "failure":_failure,
		"acceptedDemandRevision":_accepted_revision,
		"pendingDemandRevision":int(_pending_demand.get("demandRevision", -1)),
		"advanceCount":_advance_count, "pendingRetries":_pending_retries,
		"supersededPendingRevisions":_superseded_pending_revisions,
		"hasLatestReceipt":not _latest_receipt.is_empty(),
		"stopRequested":_stop_requested, "cleanupComplete":_cleanup_complete,
		"cleanupFailure":_cleanup_failure, "drainStepCount":_drain_step_count,
		"acceptedPlannerIdentity":_accepted_planner_identity.duplicate(true)}


func _build_step_receipt(snapshot: Dictionary, demand: Dictionary, native_step: Dictionary,
		accepted_revision: int, owner_state: Dictionary) -> Dictionary:
	var backend_state: Dictionary = owner_state.get("backend", {}) \
		if owner_state.get("backend", {}) is Dictionary else {}
	var backend_id := int(owner_state.get("backendInstanceId", 0))
	var owner_source_identity: Dictionary = backend_state.get("sourceIdentity", {}) \
		if backend_state.get("sourceIdentity", {}) is Dictionary else {}
	if _owner_source_identity.is_empty() and not owner_source_identity.is_empty():
		_owner_source_identity = owner_source_identity.duplicate(true)
		_owner_backend_instance_id = backend_id
	var source_current := owner_source_identity == _owner_source_identity \
		and backend_id == _owner_backend_instance_id and backend_id > 0
	var publication: Dictionary = native_step.get("publication", {}) \
		if native_step.get("publication", {}) is Dictionary else {}
	var inserted: bool = publication.get("state") == "inserted_waiting_mesh" \
		and publication.get("insertionReceipt") == "ready"
	return {"schema":RECEIPT_SCHEMA,
		"demandRevision":accepted_revision,
		"pendingProposalRevision":int(_pending_demand.get("demandRevision", -1)),
		"nativeDemandRevision":int(_accepted_planner_identity.get("demandRevision", -1)),
		"closureToken":String(_accepted_planner_identity.get("closureToken", "")),
		"requiredBlockCount":int(_accepted_planner_identity.get("requiredMeshBlocks", -1)),
		"consumerId":int(_accepted_planner_identity.get("consumerId", 0)),
		"ownerGeneration":_owner_generation,
		"configuredSeed":String(snapshot.get("configuredSeed", "")),
		"terrainInstanceId":int(snapshot.get("terrainInstanceId", 0)),
		"collisionOwnerGeneration":int(snapshot.get("collisionOwnerGeneration", 0)),
		"backendInstanceId":backend_id,
		"sourceIdentity":owner_source_identity,
		"sourceRevision":int(backend_state.get("terrainDeltaRevision", -1)),
		"ownerSourceCurrent":source_current,
		"demandAccepted":demand.get("status") == "ready",
		"publicationEvent":publication.duplicate(true),
		"block":publication.get("block", Vector3i.ZERO),
		"generation":int(publication.get("generation", 0)),
		"dataInserted":inserted,
		"meshReady":false, "physicsReady":false}


func _begin_terminal_failure(reason: String, context: Dictionary = {}) -> Dictionary:
	if _state == "active":
		_failure = reason
		_state = "failed_draining"
		_stop_requested = true
		var stop_request: Dictionary = _owner.request_stop()
		if stop_request.get("status") == "failed":
			_cleanup_failure = String(stop_request.get("reason", "native_owner_stop_request_failed"))
		return {"status":"failed_draining", "reason":_failure,
			"requiresExplicitDrain":true, "cleanupComplete":false,
			"stopRequest":stop_request, "context":context}
	return {"status":"failed_draining", "reason":_failure,
		"requiresExplicitDrain":true, "cleanupComplete":false, "context":context}


func _validate_pristine_owner(owner_state: Dictionary) -> Dictionary:
	if owner_state.get("state") != "active" \
			or int(owner_state.get("backendInstanceId", 0)) <= 0 \
			or int(owner_state.get("ownerGeneration", 0)) <= 0:
		return {"status":"failed", "reason":"native_owner_not_active_or_identified"}
	var backend: Dictionary = owner_state.get("backend", {})
	var source: Dictionary = backend.get("sourceIdentity", {})
	if backend.get("status") != "ready" or source.is_empty() \
			or int(backend.get("terrainDeltaRevision", -1)) < 0:
		return {"status":"failed", "reason":"native_owner_source_not_ready"}
	var planner: Dictionary = owner_state.get("planner", {})
	if int(planner.get("consumerId", 0)) <= 0 \
			or int(planner.get("sources", -1)) != 0 \
			or int(planner.get("desiredDataBlocks", -1)) != 0 \
			or int(planner.get("appliedDataBlocks", -1)) != 0 \
			or planner.get("deltaAckPending") != false \
			or int(planner.get("demandRevision", -1)) != 0 \
			or String(planner.get("closureToken", "")) != "" \
			or int(planner.get("requiredMeshBlocks", -1)) != 0:
		return {"status":"failed", "reason":"native_owner_planner_not_virgin"}
	var publisher: Dictionary = owner_state.get("publisher", {})
	for key in ["demanded", "registered", "waitingSource", "inserted", "retiring", "orphaned"]:
		if int(publisher.get(key, -1)) != 0:
			return {"status":"failed", "reason":"native_owner_publisher_not_empty",
				"field":key, "value":publisher.get(key)}
	if publisher.get("active") != true:
		return {"status":"failed", "reason":"native_owner_publisher_not_active"}
	var artifacts: Dictionary = owner_state.get("artifactRequests", {})
	if artifacts.get("producerActive") != false \
			or int(artifacts.get("windowRecords", -1)) != 0 \
			or int(artifacts.get("activeWindows", -1)) != 0 \
			or int(artifacts.get("retirementLeases", -1)) != 0:
		return {"status":"failed", "reason":"native_owner_artifact_state_not_empty"}
	return {"status":"ready"}


func _owner_binding(owner_state: Dictionary) -> Dictionary:
	var backend: Dictionary = owner_state.get("backend", {})
	return {"backendInstanceId":int(owner_state.get("backendInstanceId", 0)),
		"ownerGeneration":int(owner_state.get("ownerGeneration", 0)),
		"consumerId":int(owner_state.get("planner", {}).get("consumerId", 0)),
		"sourceIdentity":(backend.get("sourceIdentity", {}) as Dictionary).duplicate(true),
		"sourceRevision":int(backend.get("terrainDeltaRevision", -1)),
		"sourceSeedText":String(backend.get("sourceSeedText", ""))}


func _owner_binding_facts() -> Dictionary:
	return {"backendInstanceId":_owner_backend_instance_id,
		"ownerGeneration":_owner_generation, "sourceIdentity":_owner_source_identity.duplicate(true),
		"sourceRevision":_owner_source_revision}


func _planner_identity(owner_state: Dictionary) -> Dictionary:
	var planner: Dictionary = owner_state.get("planner", {})
	return {"demandRevision":int(planner.get("demandRevision", -1)),
		"closureToken":String(planner.get("closureToken", "")),
		"requiredMeshBlocks":int(planner.get("requiredMeshBlocks", -1)),
		"consumerId":int(planner.get("consumerId", 0)),
		"ownerGeneration":int(owner_state.get("ownerGeneration", 0)),
		"backendInstanceId":int(owner_state.get("backendInstanceId", 0)),
		"sourceIdentity":owner_state.get("sourceIdentity", {}),
		"sourceRevision":int(owner_state.get("backend", {}).get("terrainDeltaRevision", -1))}


func _validate_owner_binding_and_planner(owner_state: Dictionary) -> Dictionary:
	var binding := _owner_binding(owner_state)
	if owner_state.get("state") != "active" \
			or binding.backendInstanceId != _owner_backend_instance_id \
			or binding.ownerGeneration != _owner_generation \
			or binding.sourceIdentity != _owner_source_identity \
			or binding.sourceRevision != _owner_source_revision:
		return {"status":"failed", "reason":"native_owner_source_binding_changed",
			"binding":binding}
	var live_planner := _planner_identity(owner_state)
	if live_planner != _accepted_planner_identity:
		return {"status":"failed", "reason":"native_planner_receipt_continuity_lost",
			"expected":_accepted_planner_identity.duplicate(true),
			"actual":live_planner}
	return {"status":"ready", "plannerIdentity":live_planner}


func _verify_replace_planner_receipt(demand_result: Dictionary,
		owner_state: Dictionary) -> Dictionary:
	var live_binding := _owner_binding(owner_state)
	if live_binding.backendInstanceId != _owner_backend_instance_id \
			or live_binding.ownerGeneration != _owner_generation \
			or live_binding.sourceIdentity != _owner_source_identity \
			or live_binding.sourceRevision != _owner_source_revision:
		return {"status":"failed", "reason":"native_owner_source_binding_changed"}
	var live := _planner_identity(owner_state)
	var reported := {"demandRevision":int(demand_result.get("demandRevision", -1)),
		"closureToken":String(demand_result.get("closureToken", "")),
		"requiredMeshBlocks":int(demand_result.get("requiredMeshBlocks", -1)),
		"consumerId":int(demand_result.get("consumerId", 0)),
		"ownerGeneration":_owner_generation,
		"backendInstanceId":_owner_backend_instance_id,
		"sourceIdentity":_owner_source_identity,
		"sourceRevision":_owner_source_revision}
	if reported != live:
		return {"status":"failed", "reason":"native_replace_receipt_not_current_planner",
			"reported":reported, "actual":live}
	return {"status":"ready", "plannerIdentity":live}


func _validate_demand(snapshot: Dictionary) -> Dictionary:
	if not snapshot is Dictionary or snapshot.get("schema") != SCHEMA:
		return {"status":"failed", "reason":"native_publication_demand_schema_invalid"}
	if not snapshot.get("demandRevision", null) is int or int(snapshot.demandRevision) < 0:
		return {"status":"failed", "reason":"native_publication_demand_revision_invalid"}
	if String(snapshot.get("configuredSeed", "")).strip_edges().is_empty() \
			or int(snapshot.get("terrainInstanceId", 0)) <= 0 \
			or int(snapshot.get("collisionOwnerGeneration", 0)) <= 0:
		return {"status":"failed", "reason":"native_publication_runtime_identity_invalid"}
	if not snapshot.get("primaryViewer", {}) is Dictionary \
			or not snapshot.get("otherViewers", null) is Array \
			or not snapshot.get("retainedChunks", null) is Array \
		or not snapshot.get("foregroundChunks", null) is Array \
			or not snapshot.get("verticalBounds", null) is Vector2i:
		return {"status":"failed", "reason":"native_publication_demand_fields_invalid"}
	if int(snapshot.verticalBounds.x) > int(snapshot.verticalBounds.y):
		return {"status":"failed", "reason":"native_publication_vertical_bounds_invalid"}
	return {"status":"ready"}


func _failed(reason: String) -> Dictionary:
	_failure = reason
	_state = "failed"
	return {"status":"failed", "reason":reason}
