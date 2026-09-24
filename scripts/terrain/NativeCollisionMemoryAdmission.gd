extends RefCounted
class_name NativeCollisionMemoryAdmission

## Pure reservation ledger for physical collision allocations. It does not
## inspect the scene tree or release engine memory. Owners must retain charges
## until they can provide the exact deferred-free acknowledgement below.
const SCHEMA := "n5-collision-memory-admission/v2"
const RELEASE_ACK_SCHEMA := "n5-collision-memory-release-ack/v2"
const MAX_I64 := 0x7fffffffffffffff
const POLICY_SCRIPT = preload("res://scripts/terrain/NativeCollisionMemoryPolicy.gd")
const VALID_STATES := ["candidate_reserved", "candidate_constructed",
	"live_current", "retired_deferred"]

var _policy
var _limits := {}
var _formula_version := ""
var _policy_identity := ""
var _ledger_epoch := ""
var _instance_nonce := ""
var _ledger_identity := ""
var _reservations := {}
var _reservation_keys := {}
var _body_owners := {}
var _window_charged := {}
var _total_charged := 0
var _last_issued_sequence := 0
var _next_sequence := 1
var _sealed_after_drain := false


func setup(policy, ledger_epoch: String, instance_nonce: String) -> Dictionary:
	if _policy != null or policy == null or ledger_epoch.is_empty() \
			or instance_nonce.is_empty() \
			or not policy.has_method("is_configured") \
			or not policy.has_method("estimate_window") \
			or not policy.has_method("limits") \
			or not policy.has_method("formula_version") \
			or not policy.has_method("policy_identity") \
			or not bool(policy.call("is_configured")):
		return {"status":"failed", "reason":"collision_memory_admission_setup_invalid"}
	var source_limits = policy.call("limits")
	var source_formula = policy.call("formula_version")
	var source_identity = policy.call("policy_identity")
	if not source_limits is Dictionary or not source_formula is String \
			or not source_identity is String or String(source_formula).is_empty() \
			or String(source_identity).is_empty():
		return {"status":"failed", "reason":"collision_memory_admission_setup_invalid"}
	var frozen_policy = POLICY_SCRIPT.new()
	var frozen: Dictionary = frozen_policy.configure(
		(source_limits as Dictionary).duplicate(true))
	if frozen.get("status") != "ready" \
			or frozen.get("formulaVersion") != source_formula \
			or frozen.get("policyIdentity") != source_identity:
		return {"status":"failed", "reason":"collision_memory_policy_binding_invalid"}
	_policy = frozen_policy
	_limits = (source_limits as Dictionary).duplicate(true)
	_formula_version = String(source_formula)
	_policy_identity = String(source_identity)
	_ledger_epoch = ledger_epoch
	_instance_nonce = instance_nonce
	_ledger_identity = _derived_ledger_identity()
	return {"status":"ready", "schema":SCHEMA, "ledgerEpoch":_ledger_epoch,
		"ledgerIdentity":_ledger_identity,
		"policyIdentity":_policy_identity}


func reserve_candidate(owner_epoch: String, window_token: String,
		reservation_id: String, rows: Array) -> Dictionary:
	if not _active() or owner_epoch.is_empty() or window_token.is_empty() \
			or reservation_id.is_empty():
		return {"status":"failed", "reason":"collision_memory_reservation_invalid"}
	if _sealed_after_drain:
		return {"status":"failed", "reason":"collision_memory_ledger_drained",
			"accepted":false, "snapshot":snapshot()}
	var integrity := _audit_integrity()
	if integrity.get("status") != "ready": return integrity
	var estimate: Dictionary = _policy.estimate_window(rows)
	if estimate.get("status") != "ready": return estimate
	if estimate.get("formulaVersion") != _formula_version \
			or estimate.get("policyIdentity") != _policy_identity:
		return {"status":"failed", "reason":"collision_memory_formula_identity_mismatch"}
	var charged := int(estimate.get("physicalChargedBytes", -1))
	if charged <= 0 or charged > int(_limits.maxWindowChargedBytes):
		return {"status":"failed", "reason":"collision_memory_request_exceeds_window_cap",
			"requestedBytes":charged,
			"maxWindowChargedBytes":_limits.maxWindowChargedBytes}
	var canonical_rows: Array = []
	for row in rows:
		canonical_rows.append({"vertexCount":int(row.vertexCount),
			"expectedHit":bool(row.expectedHit)})
	var semantic_key := _semantic_key(owner_epoch, window_token, reservation_id)
	if _reservation_keys.has(semantic_key):
		return {"status":"failed", "reason":"collision_memory_reservation_duplicate",
			"accepted":false, "snapshot":snapshot()}
	if _reservations.size() >= int(_limits.maxReservations):
		return _backpressure("collision_memory_reservation_capacity", window_token, 0)
	var window_add := _checked_add(int(_window_charged.get(window_token, 0)), charged)
	var total_add := _checked_add(_total_charged, charged)
	if window_add.get("status") != "ready" or total_add.get("status") != "ready":
		return {"status":"failed", "reason":"collision_memory_byte_overflow",
			"accepted":false, "snapshot":snapshot()}
	var window_after := int(window_add.value)
	var total_after := int(total_add.value)
	if window_after > int(_limits.maxWindowChargedBytes) \
			or total_after > int(_limits.maxAggregateChargedBytes):
		return _backpressure("collision_memory_backpressure", window_token, charged)
	var following_sequence := _checked_add(_next_sequence, 1)
	if following_sequence.get("status") != "ready":
		return {"status":"failed", "reason":"collision_memory_sequence_exhausted",
			"accepted":false, "snapshot":snapshot()}
	var token := _token_for_sequence(_next_sequence)
	_reservations[token] = {"token":token, "reservationId":reservation_id,
		"sequence":_next_sequence,
		"ownerEpoch":owner_epoch, "windowToken":window_token,
		"semanticKey":semantic_key,
		"state":"candidate_reserved", "estimate":estimate.duplicate(true),
		"canonicalRows":canonical_rows,
		"chargedBytes":charged, "queuedPhysicsFrame":-1,
		"queuedProcessFrame":-1, "bodyInstanceIds":[]}
	_reservation_keys[semantic_key] = token
	_window_charged[window_token] = window_after
	_total_charged = total_after
	_last_issued_sequence = _next_sequence
	_next_sequence = int(following_sequence.value)
	return {"status":"ready", "token":token, "state":"candidate_reserved",
		"chargedBytes":charged, "snapshot":snapshot()}


func mark_candidate_constructed(token: String, owner_epoch: String,
		body_instance_ids: Array) -> Dictionary:
	var checked := _reservation(token, owner_epoch)
	if checked.get("status") != "ready": return checked
	var reservation: Dictionary = checked.reservation
	if reservation.state != "candidate_reserved":
		return {"status":"failed", "reason":"collision_memory_state_transition_invalid",
			"expected":"candidate_reserved", "actual":reservation.state}
	var ids: Dictionary = _validated_body_ids(body_instance_ids,
		int(reservation.get("estimate", {}).get("expectedBodyCount", -1)))
	if ids.get("status") != "ready": return ids
	for id in ids.ids:
		if _body_owners.has(id):
			return {"status":"failed", "reason":"collision_memory_body_owner_collision",
				"bodyInstanceId":id, "snapshot":snapshot()}
	reservation.bodyInstanceIds = ids.ids
	reservation.state = "candidate_constructed"
	_reservations[token] = reservation
	for id in ids.ids: _body_owners[id] = token
	return {"status":"ready", "token":token, "state":"candidate_constructed",
		"chargedBytes":reservation.chargedBytes, "bodyInstanceIds":ids.ids,
		"snapshot":snapshot()}


func commit_live(token: String, owner_epoch: String) -> Dictionary:
	return _transition(token, owner_epoch, "candidate_constructed", "live_current")


func cancel_unconstructed(token: String, owner_epoch: String) -> Dictionary:
	var checked := _reservation(token, owner_epoch)
	if checked.get("status") != "ready": return checked
	if checked.reservation.state != "candidate_reserved":
		return {"status":"failed", "reason":"collision_memory_cancel_requires_unconstructed"}
	return _release(token, "unconstructed_candidate_cancelled")


func defer_release(token: String, owner_epoch: String, physics_frame: int,
		process_frame: int) -> Dictionary:
	var checked := _reservation(token, owner_epoch)
	if checked.get("status") != "ready": return checked
	var reservation: Dictionary = checked.reservation
	if not reservation.state in ["candidate_constructed", "live_current"] \
			or physics_frame < 0 or process_frame < 0:
		return {"status":"failed", "reason":"collision_memory_defer_invalid"}
	var ids: Array = reservation.get("bodyInstanceIds", [])
	if ids.size() != int(reservation.get("estimate", {}).get("expectedBodyCount", -1)):
		return {"status":"failed", "reason":"collision_memory_body_count_mismatch"}
	reservation.state = "retired_deferred"
	reservation.queuedPhysicsFrame = physics_frame
	reservation.queuedProcessFrame = process_frame
	_reservations[token] = reservation
	return {"status":"ready", "token":token, "state":"retired_deferred",
		"chargedBytesRetained":reservation.chargedBytes, "snapshot":snapshot()}


func acknowledge_deferred_release(token: String, owner_epoch: String,
		ack: Dictionary) -> Dictionary:
	var checked := _reservation(token, owner_epoch)
	if checked.get("status") != "ready": return checked
	var reservation: Dictionary = checked.reservation
	if reservation.state != "retired_deferred":
		return {"status":"failed", "reason":"collision_memory_release_not_deferred"}
	if ack.get("schema") != RELEASE_ACK_SCHEMA \
			or ack.get("ledgerEpoch") != _ledger_epoch \
			or ack.get("ledgerIdentity") != _ledger_identity \
			or ack.get("reservationToken") != token \
			or ack.get("ownerEpoch") != owner_epoch \
			or ack.get("windowToken") != reservation.windowToken \
			or not ack.get("queuedPhysicsFrame") is int \
			or not ack.get("queuedProcessFrame") is int \
			or not ack.get("physicsFrame") is int \
			or not ack.get("processFrame") is int \
			or int(ack.get("queuedPhysicsFrame", -1)) != int(reservation.queuedPhysicsFrame) \
			or int(ack.get("queuedProcessFrame", -1)) != int(reservation.queuedProcessFrame) \
			or int(ack.get("physicsFrame", -1)) <= int(reservation.queuedPhysicsFrame) \
			or int(ack.get("processFrame", -1)) <= int(reservation.queuedProcessFrame) \
			or ack.get("allBodiesAbsent") != true \
			or ack.get("deferredEntriesReleased") != true \
			or not ack.get("absentBodyInstanceIds") is Array \
			or not ack.get("observedColliderInstanceIds") is Array:
		return {"status":"failed", "reason":"collision_memory_release_ack_invalid"}
	var absent: Dictionary = _validated_body_ids(ack.absentBodyInstanceIds,
		(reservation.bodyInstanceIds as Array).size())
	if absent.get("status") != "ready" or absent.ids != reservation.bodyInstanceIds:
		return {"status":"failed", "reason":"collision_memory_release_body_set_mismatch"}
	var retired_ids := {}
	for id in reservation.bodyInstanceIds: retired_ids[id] = true
	var observed: Dictionary = _validated_body_ids(
		ack.observedColliderInstanceIds,
		(ack.observedColliderInstanceIds as Array).size())
	if observed.get("status") != "ready":
		return {"status":"failed",
			"reason":"collision_memory_observed_body_ids_invalid"}
	for observed_id in observed.ids:
		if retired_ids.has(observed_id):
			return {"status":"failed", "reason":"collision_memory_retired_collider_observed"}
	return _release(token, "deferred_free_acknowledged")


func snapshot() -> Dictionary:
	var counts := {"candidate_reserved":0, "candidate_constructed":0,
		"live_current":0, "retired_deferred":0}
	var bytes := {"candidate_reserved":0, "candidate_constructed":0,
		"live_current":0, "retired_deferred":0}
	for reservation in _reservations.values():
		var state := String(reservation.state)
		counts[state] = int(counts.get(state, 0)) + 1
		bytes[state] = int(bytes.get(state, 0)) + int(reservation.chargedBytes)
	return {"schema":SCHEMA, "ledgerEpoch":_ledger_epoch,
		"ledgerIdentity":_ledger_identity,
		"policyIdentity":_policy_identity,
		"reservationCount":_reservations.size(), "totalChargedBytes":_total_charged,
		"semanticReservationCount":_reservation_keys.size(),
		"bodyOwnerCount":_body_owners.size(),
		"lastIssuedSequence":_last_issued_sequence,
		"nextSequence":_next_sequence,
		"sealedAfterDrain":_sealed_after_drain,
		"windowChargedBytes":_window_charged.duplicate(true),
		"stateCounts":counts, "stateChargedBytes":bytes}


func drain_receipt() -> Dictionary:
	if not _active():
		return {"status":"failed", "reason":"collision_memory_admission_inactive"}
	var integrity := _audit_integrity()
	if integrity.get("status") != "ready": return integrity
	if not _reservations.is_empty() or not _reservation_keys.is_empty() \
			or not _body_owners.is_empty() \
			or _total_charged != 0 \
			or not _window_charged.is_empty():
		return {"status":"pending", "reason":"collision_memory_reservations_retained",
			"snapshot":snapshot()}
	_sealed_after_drain = true
	return {"status":"ready", "drained":true, "ledgerEpoch":_ledger_epoch,
		"ledgerIdentity":_ledger_identity, "sealedAfterDrain":true,
		"reservationCount":0, "totalChargedBytes":0}


func _transition(token: String, owner_epoch: String, expected: String,
		next: String) -> Dictionary:
	var checked := _reservation(token, owner_epoch)
	if checked.get("status") != "ready": return checked
	var reservation: Dictionary = checked.reservation
	if reservation.state != expected:
		return {"status":"failed", "reason":"collision_memory_state_transition_invalid",
			"expected":expected, "actual":reservation.state}
	reservation.state = next
	_reservations[token] = reservation
	return {"status":"ready", "token":token, "state":next,
		"chargedBytes":reservation.chargedBytes, "snapshot":snapshot()}


func _reservation(token: String, owner_epoch: String) -> Dictionary:
	if not _active() or token.is_empty() or owner_epoch.is_empty():
		return {"status":"failed", "reason":"collision_memory_reservation_stale"}
	var integrity := _audit_integrity()
	if integrity.get("status") != "ready": return integrity
	if not _reservations.has(token):
		return {"status":"failed", "reason":"collision_memory_reservation_stale"}
	var reservation: Dictionary = _reservations[token]
	if reservation.ownerEpoch != owner_epoch:
		return {"status":"failed", "reason":"collision_memory_owner_epoch_mismatch"}
	return {"status":"ready", "reservation":reservation}


func _release(token: String, reason: String) -> Dictionary:
	var integrity := _audit_integrity()
	if integrity.get("status") != "ready": return integrity
	if not _reservations.has(token):
		return {"status":"failed", "reason":"collision_memory_ledger_invariant"}
	var reservation: Dictionary = _reservations[token]
	var charged := int(reservation.chargedBytes)
	var window := String(reservation.windowToken)
	var semantic_key := String(reservation.get("semanticKey", ""))
	var window_before := int(_window_charged.get(window, -1))
	if charged <= 0 or window_before < charged or _total_charged < charged \
			or semantic_key.is_empty() \
			or _reservation_keys.get(semantic_key, "") != token:
		return {"status":"failed", "reason":"collision_memory_ledger_invariant",
			"snapshot":snapshot()}
	var window_after := window_before - charged
	var total_after := _total_charged - charged
	_reservations.erase(token)
	_reservation_keys.erase(semantic_key)
	for id in reservation.get("bodyInstanceIds", []): _body_owners.erase(id)
	if window_after == 0: _window_charged.erase(window)
	else: _window_charged[window] = window_after
	_total_charged = total_after
	return {"status":"ready", "released":true, "reason":reason,
		"releasedBytes":charged, "snapshot":snapshot()}


func _backpressure(reason: String, window_token: String,
		requested_bytes: int) -> Dictionary:
	return {"status":"pending", "reason":reason, "retryable":true,
		"accepted":false, "windowToken":window_token,
		"requestedBytes":requested_bytes, "snapshot":snapshot()}


func _audit_integrity() -> Dictionary:
	if not _active():
		return _integrity_failure("inactive")
	if _ledger_identity != _derived_ledger_identity():
		return _integrity_failure("ledger_identity")
	if _policy.limits() != _limits \
			or _policy.formula_version() != _formula_version \
			or _policy.policy_identity() != _policy_identity:
		return _integrity_failure("frozen_policy_binding")
	var expected_semantic := {}
	var expected_bodies := {}
	var expected_windows := {}
	var expected_total := 0
	if _reservations.size() > int(_limits.maxReservations):
		return _integrity_failure("reservation_cap")
	for token_value in _reservations.keys():
		if not token_value is String:
			return _integrity_failure("token_type")
		var token := String(token_value)
		var record_value = _reservations[token]
		if not record_value is Dictionary:
			return _integrity_failure("record_type")
		var reservation: Dictionary = record_value
		if reservation.get("token") != token \
				or not reservation.get("sequence") is int \
				or int(reservation.get("sequence", 0)) <= 0 \
				or int(reservation.get("sequence", 0)) > _last_issued_sequence \
				or _token_for_sequence(int(reservation.sequence)) != token:
			return _integrity_failure("token_sequence")
		if not reservation.get("ownerEpoch") is String \
				or String(reservation.get("ownerEpoch", "")).is_empty() \
				or not reservation.get("windowToken") is String \
				or String(reservation.get("windowToken", "")).is_empty() \
				or not reservation.get("reservationId") is String \
				or String(reservation.get("reservationId", "")).is_empty():
			return _integrity_failure("reservation_identity")
		var state = reservation.get("state")
		if not state is String or not VALID_STATES.has(String(state)):
			return _integrity_failure("reservation_state")
		var semantic_key := _semantic_key(String(reservation.ownerEpoch),
			String(reservation.windowToken), String(reservation.reservationId))
		if reservation.get("semanticKey") != semantic_key \
				or expected_semantic.has(semantic_key):
			return _integrity_failure("semantic_key")
		expected_semantic[semantic_key] = token
		var canonical_rows_value = reservation.get("canonicalRows")
		if not canonical_rows_value is Array:
			return _integrity_failure("canonical_rows_type")
		var recomputed: Dictionary = _policy.estimate_window(
			canonical_rows_value as Array)
		if recomputed.get("status") != "ready" \
				or recomputed.get("formulaVersion") != _formula_version \
				or recomputed.get("policyIdentity") != _policy_identity \
				or int(recomputed.get("physicalChargedBytes", -1)) \
					> int(_limits.maxWindowChargedBytes):
			return _integrity_failure("canonical_rows_receipt")
		var estimate_value = reservation.get("estimate")
		if not estimate_value is Dictionary:
			return _integrity_failure("estimate_type")
		var estimate: Dictionary = estimate_value
		if estimate != recomputed \
				or estimate.get("status") != "ready" \
				or estimate.get("formulaVersion") != _formula_version \
				or estimate.get("policyIdentity") != _policy_identity \
				or not estimate.get("physicalChargedBytes") is int \
				or not estimate.get("expectedBodyCount") is int \
				or int(estimate.get("expectedBodyCount", -1)) < 0 \
				or not reservation.get("chargedBytes") is int \
				or int(reservation.get("chargedBytes", -1)) <= 0 \
				or int(reservation.chargedBytes) != int(estimate.physicalChargedBytes):
			return _integrity_failure("estimate_charge")
		var body_values = reservation.get("bodyInstanceIds")
		if not body_values is Array:
			return _integrity_failure("body_values_type")
		var expected_body_count := int(estimate.expectedBodyCount)
		var body_check: Dictionary
		if String(state) == "candidate_reserved":
			body_check = _validated_body_ids(body_values as Array, 0)
		else:
			body_check = _validated_body_ids(body_values as Array,
				expected_body_count)
		if body_check.get("status") != "ready":
			return _integrity_failure("body_values")
		for id in body_check.ids:
			if expected_bodies.has(id):
				return _integrity_failure("body_owner_duplicate")
			expected_bodies[id] = token
		if not reservation.get("queuedPhysicsFrame") is int \
				or not reservation.get("queuedProcessFrame") is int:
			return _integrity_failure("queued_frame_type")
		if String(state) == "retired_deferred":
			if int(reservation.queuedPhysicsFrame) < 0 \
					or int(reservation.queuedProcessFrame) < 0:
				return _integrity_failure("deferred_frame")
		elif int(reservation.queuedPhysicsFrame) != -1 \
				or int(reservation.queuedProcessFrame) != -1:
			return _integrity_failure("unexpected_queued_frame")
		var total_result := _checked_add(expected_total,
			int(reservation.chargedBytes))
		if total_result.get("status") != "ready":
			return _integrity_failure("total_overflow")
		expected_total = int(total_result.value)
		if expected_total > int(_limits.maxAggregateChargedBytes):
			return _integrity_failure("aggregate_cap")
		var window := String(reservation.windowToken)
		var window_result := _checked_add(int(expected_windows.get(window, 0)),
			int(reservation.chargedBytes))
		if window_result.get("status") != "ready":
			return _integrity_failure("window_overflow")
		expected_windows[window] = int(window_result.value)
		if int(expected_windows[window]) > int(_limits.maxWindowChargedBytes):
			return _integrity_failure("window_cap")
	var sequence_result := _checked_add(_last_issued_sequence, 1)
	if sequence_result.get("status") != "ready" \
			or _next_sequence != int(sequence_result.get("value", -1)):
		return _integrity_failure("sequence_continuity")
	if expected_total != _total_charged:
		return _integrity_failure("aggregate_charge")
	if expected_windows != _window_charged:
		return _integrity_failure("window_charge")
	if expected_semantic != _reservation_keys:
		return _integrity_failure("semantic_index")
	if expected_bodies != _body_owners:
		return _integrity_failure("body_owner_index")
	return {"status":"ready"}


func _integrity_failure(detail: String) -> Dictionary:
	return {"status":"failed", "reason":"collision_memory_ledger_invariant",
		"detail":detail, "accepted":false}


func _active() -> bool:
	return _policy != null and not _ledger_epoch.is_empty() \
		and not _instance_nonce.is_empty() and not _ledger_identity.is_empty() \
		and not _limits.is_empty() and not _formula_version.is_empty() \
		and not _policy_identity.is_empty()


func _checked_add(left: int, right: int) -> Dictionary:
	if left < 0 or right < 0 or left > MAX_I64 - right:
		return {"status":"failed", "reason":"collision_memory_byte_overflow"}
	return {"status":"ready", "value":left + right}


func _semantic_key(owner_epoch: String, window_token: String,
		reservation_id: String) -> String:
	return ("%d:%s:%d:%s:%d:%s" % [owner_epoch.length(), owner_epoch,
		window_token.length(), window_token, reservation_id.length(),
		reservation_id]).sha256_text()


func _token_for_sequence(sequence: int) -> String:
	return "%s:%d" % [_ledger_identity, sequence]


func _derived_ledger_identity() -> String:
	return ("%d:%s:%d:%s:%d:%s:%d:%s" % [SCHEMA.length(), SCHEMA,
		_ledger_epoch.length(), _ledger_epoch, _instance_nonce.length(),
		_instance_nonce, _policy_identity.length(), _policy_identity]).sha256_text()


func _validated_body_ids(values: Array, expected_count: int) -> Dictionary:
	if expected_count < 0 or values.size() != expected_count:
		return {"status":"failed", "reason":"collision_memory_body_count_mismatch"}
	var seen := {}
	var ids: Array[int] = []
	for value in values:
		if not value is int or int(value) <= 0 or seen.has(int(value)):
			return {"status":"failed", "reason":"collision_memory_body_ids_invalid"}
		seen[int(value)] = true
		ids.append(int(value))
	ids.sort()
	return {"status":"ready", "ids":ids}
