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
var _latest_receipt: Dictionary = {}
var _advance_count := 0
var _pending_retries := 0
var _superseded_pending_revisions := 0


func setup(runtime, owner) -> Dictionary:
	if _state != "new":
		return _failed("publication_service_already_started")
	if runtime == null or not runtime.has_method("validate_native_publication_receipt"):
		return _failed("runtime_receipt_validator_missing")
	if owner == null or not owner.has_method("replace_demand") \
			or not owner.has_method("advance") or not owner.has_method("snapshot"):
		return _failed("native_runtime_owner_api_missing")
	_runtime = runtime
	_owner = owner
	_state = "active"
	return {"status":"ready", "schema":SCHEMA}


func advance(snapshot: Dictionary) -> Dictionary:
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
		return {"status":"failed", "reason":"native_publication_runtime_owner_changed",
			"expected":_runtime_identity.duplicate(true), "actual":identity}
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
			_accepted_revision = int(_pending_demand.demandRevision)
			_pending_demand = {}
			_pending_retries = 0
		elif demand_result.get("status") == "pending":
			_pending_retries += 1
		elif demand_result.get("status") == "failed":
			return {"status":"failed", "reason":String(demand_result.get("reason", "native_demand_rejected")),
				"demandRevision":revision, "demand":demand_result}
		else:
			return {"status":"failed", "reason":"native_demand_result_invalid",
				"demandRevision":revision, "demand":demand_result}

	# Always pump the previously accepted native owner once, including while a
	# newer full-source proposal is pending/capacity constrained. The candidate
	# remains retained and is retried on a later advance.
	var native_step: Dictionary = _owner.advance()
	_advance_count += 1
	if native_step.get("status") == "failed":
		_failure = String(native_step.get("reason", "native_publication_advance_failed"))
		_state = "failed"
		return {"status":"failed", "reason":_failure, "demand":demand_result,
			"nativeStep":native_step}
	var receipt_snapshot: Dictionary = snapshot
	var receipt := _build_step_receipt(receipt_snapshot, demand_result, native_step,
		_accepted_revision)
	var checked: Dictionary = _runtime.call("validate_native_publication_receipt", receipt)
	if checked.get("status") != "ready":
		_failure = String(checked.get("reason", "native_publication_receipt_rejected"))
		_state = "failed"
		return {"status":"failed", "reason":_failure,
			"demand":demand_result, "nativeStep":native_step, "receipt":receipt,
			"runtimeValidation":checked}
	receipt["runtimeValidation"] = checked.duplicate(true)
	_latest_receipt = receipt.duplicate(true)
	return {"status":"advanced", "demandStatus":String(demand_result.get("status", "pending")),
		"demandRevision":_accepted_revision,
		"pendingDemandRevision":int(_pending_demand.get("demandRevision", -1)),
		"demand":demand_result, "nativeStep":native_step,
		"receipt":receipt, "readinessClaim":{"data":bool(receipt.get("dataInserted", false)),
			"mesh":false, "physics":false}}


func latest_receipt() -> Dictionary:
	return _latest_receipt.duplicate(true)


func snapshot() -> Dictionary:
	return {"state":_state, "failure":_failure,
		"acceptedDemandRevision":_accepted_revision,
		"pendingDemandRevision":int(_pending_demand.get("demandRevision", -1)),
		"advanceCount":_advance_count, "pendingRetries":_pending_retries,
		"supersededPendingRevisions":_superseded_pending_revisions,
		"hasLatestReceipt":not _latest_receipt.is_empty()}


func _build_step_receipt(snapshot: Dictionary, demand: Dictionary, native_step: Dictionary,
		accepted_revision: int) -> Dictionary:
	var owner_state: Dictionary = _owner.snapshot()
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
