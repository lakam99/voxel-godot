extends RefCounted
class_name NativeCollisionMemoryAdmission

## Pure reservation ledger for physical collision allocations. It does not
## inspect the scene tree or release engine memory. Owners must retain charges
## until they can provide the exact deferred-free acknowledgement below.
const SCHEMA := "n5-collision-memory-admission/v1"
const RELEASE_ACK_SCHEMA := "n5-collision-memory-release-ack/v1"
const MAX_I64 := 0x7fffffffffffffff

var _policy
var _ledger_epoch := ""
var _ledger_identity := ""
var _reservations := {}
var _reservation_keys := {}
var _window_charged := {}
var _total_charged := 0
var _last_issued_sequence := 0
var _next_sequence := 1
var _sealed_after_drain := false


func setup(policy, ledger_epoch: String) -> Dictionary:
	if _policy != null or policy == null or ledger_epoch.is_empty() \
			or not policy.has_method("is_configured") \
			or not policy.has_method("estimate_window") \
			or not policy.has_method("limits") \
			or not policy.has_method("formula_version") \
			or not policy.has_method("policy_identity") \
			or not bool(policy.call("is_configured")):
		return {"status":"failed", "reason":"collision_memory_admission_setup_invalid"}
	_policy = policy
	_ledger_epoch = ledger_epoch
	_ledger_identity = ("%s:%s:%s" % [SCHEMA, _ledger_epoch,
		String(_policy.call("policy_identity"))]).sha256_text()
	return {"status":"ready", "schema":SCHEMA, "ledgerEpoch":_ledger_epoch,
		"ledgerIdentity":_ledger_identity,
		"policyIdentity":String(_policy.call("policy_identity"))}


func reserve_candidate(owner_epoch: String, window_token: String,
		reservation_id: String, rows: Array) -> Dictionary:
	if not _active() or owner_epoch.is_empty() or window_token.is_empty() \
			or reservation_id.is_empty():
		return {"status":"failed", "reason":"collision_memory_reservation_invalid"}
	if _sealed_after_drain:
		return {"status":"failed", "reason":"collision_memory_ledger_drained",
			"accepted":false, "snapshot":snapshot()}
	var limits: Dictionary = _policy.call("limits")
	var semantic_key := _semantic_key(owner_epoch, window_token, reservation_id)
	if _reservation_keys.has(semantic_key):
		return {"status":"failed", "reason":"collision_memory_reservation_duplicate",
			"accepted":false, "snapshot":snapshot()}
	if _reservations.size() >= int(limits.maxReservations):
		return _backpressure("collision_memory_reservation_capacity", window_token, 0)
	var estimate: Dictionary = _policy.call("estimate_window", rows)
	if estimate.get("status") != "ready": return estimate
	if estimate.get("formulaVersion") != _policy.call("formula_version") \
			or estimate.get("policyIdentity") != _policy.call("policy_identity"):
		return {"status":"failed", "reason":"collision_memory_formula_identity_mismatch"}
	var charged := int(estimate.get("physicalChargedBytes", -1))
	if charged <= 0 or charged > int(limits.maxWindowChargedBytes):
		return {"status":"failed", "reason":"collision_memory_request_exceeds_window_cap",
			"requestedBytes":charged, "maxWindowChargedBytes":limits.maxWindowChargedBytes}
	var window_add := _checked_add(int(_window_charged.get(window_token, 0)), charged)
	var total_add := _checked_add(_total_charged, charged)
	if window_add.get("status") != "ready" or total_add.get("status") != "ready":
		return {"status":"failed", "reason":"collision_memory_byte_overflow",
			"accepted":false, "snapshot":snapshot()}
	var window_after := int(window_add.value)
	var total_after := int(total_add.value)
	if window_after > int(limits.maxWindowChargedBytes) \
			or total_after > int(limits.maxAggregateChargedBytes):
		return _backpressure("collision_memory_backpressure", window_token, charged)
	var expected_sequence := _checked_add(_last_issued_sequence, 1)
	if expected_sequence.get("status") != "ready":
		return {"status":"failed", "reason":"collision_memory_sequence_exhausted",
			"accepted":false, "snapshot":snapshot()}
	if _next_sequence != int(expected_sequence.value):
		return {"status":"failed", "reason":"collision_memory_sequence_discontinuous",
			"accepted":false, "snapshot":snapshot()}
	var following_sequence := _checked_add(_next_sequence, 1)
	if following_sequence.get("status") != "ready":
		return {"status":"failed", "reason":"collision_memory_sequence_exhausted",
			"accepted":false, "snapshot":snapshot()}
	var token := _token_for_sequence(_next_sequence)
	if _reservations.has(token):
		return {"status":"failed", "reason":"collision_memory_reservation_token_collision",
			"accepted":false, "snapshot":snapshot()}
	_reservations[token] = {"token":token, "reservationId":reservation_id,
		"ownerEpoch":owner_epoch, "windowToken":window_token,
		"semanticKey":semantic_key,
		"state":"candidate_reserved", "estimate":estimate.duplicate(true),
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
	reservation.bodyInstanceIds = ids.ids
	reservation.state = "candidate_constructed"
	_reservations[token] = reservation
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
	for observed in ack.observedColliderInstanceIds:
		if not observed is int or retired_ids.has(int(observed)):
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
		"policyIdentity":String(_policy.call("policy_identity")) if _policy != null else "",
		"reservationCount":_reservations.size(), "totalChargedBytes":_total_charged,
		"semanticReservationCount":_reservation_keys.size(),
		"lastIssuedSequence":_last_issued_sequence,
		"nextSequence":_next_sequence,
		"sealedAfterDrain":_sealed_after_drain,
		"windowChargedBytes":_window_charged.duplicate(true),
		"stateCounts":counts, "stateChargedBytes":bytes}


func drain_receipt() -> Dictionary:
	if not _active():
		return {"status":"failed", "reason":"collision_memory_admission_inactive"}
	if not _reservations.is_empty() or not _reservation_keys.is_empty() \
			or _total_charged != 0 \
			or not _window_charged.is_empty():
		return {"status":"pending", "reason":"collision_memory_reservations_retained",
			"snapshot":snapshot()}
	_sealed_after_drain = true
	return {"status":"ready", "drained":true, "ledgerEpoch":_ledger_epoch,
		"sealedAfterDrain":true,
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
	if not _active() or token.is_empty() or owner_epoch.is_empty() \
			or not _reservations.has(token):
		return {"status":"failed", "reason":"collision_memory_reservation_stale"}
	var reservation: Dictionary = _reservations[token]
	if reservation.ownerEpoch != owner_epoch:
		return {"status":"failed", "reason":"collision_memory_owner_epoch_mismatch"}
	return {"status":"ready", "reservation":reservation}


func _release(token: String, reason: String) -> Dictionary:
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


func _active() -> bool:
	return _policy != null and not _ledger_epoch.is_empty() \
		and not _ledger_identity.is_empty()


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
