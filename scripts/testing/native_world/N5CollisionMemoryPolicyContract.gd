extends SceneTree

const POLICY = preload("res://scripts/terrain/NativeCollisionMemoryPolicy.gd")
const ADMISSION = preload("res://scripts/terrain/NativeCollisionMemoryAdmission.gd")

class ForeignFormulaPolicy extends RefCounted:
	var backing

	func _init(value) -> void:
		backing = value

	func is_configured() -> bool:
		return true

	func estimate_window(rows: Array) -> Dictionary:
		var estimate: Dictionary = backing.estimate_window(rows)
		estimate.formulaVersion = "foreign-formula/v1"
		return estimate

	func limits() -> Dictionary:
		return backing.limits()

	func formula_version() -> String:
		return backing.formula_version()

	func policy_identity() -> String:
		return backing.policy_identity()


class IncompletePolicy extends RefCounted:
	func is_configured() -> bool:
		return true

	func estimate_window(_rows: Array) -> Dictionary:
		return {"status":"failed"}

	func limits() -> Dictionary:
		return {}


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _check(value: bool, label: String) -> void:
	if not value: failures.append(label)


func _config(window_cap: int, aggregate_cap: int,
		max_reservations := 16) -> Dictionary:
	return {"maxVerticesPerRow":65536, "verticesPerShape":768,
		"rowEntryBytes":256, "bodyEntryBytes":4096, "shapeEntryBytes":512,
		"physicsPayloadMultiplier":3, "maxRowsPerWindow":4096,
		"maxWindowChargedBytes":window_cap,
		"maxAggregateChargedBytes":aggregate_cap,
		"maxReservations":max_reservations}


func _ack(ledger_epoch: String, token: String, owner: String, window: String,
		queued_physics: int, queued_process: int, ids: Array,
		physics_frame := 11, process_frame := 21) -> Dictionary:
	return {"schema":ADMISSION.RELEASE_ACK_SCHEMA, "ledgerEpoch":ledger_epoch,
		"reservationToken":token, "ownerEpoch":owner, "windowToken":window,
		"queuedPhysicsFrame":queued_physics, "queuedProcessFrame":queued_process,
		"physicsFrame":physics_frame, "processFrame":process_frame,
		"allBodiesAbsent":true, "deferredEntriesReleased":true,
		"absentBodyInstanceIds":ids.duplicate(),
		"observedColliderInstanceIds":[]}


func _run() -> void:
	var unconfigured = POLICY.new()
	_check(unconfigured.estimate_row(1, true).reason == "collision_memory_policy_unconfigured",
		"unconfigured formulas fail closed")
	var invalid = POLICY.new()
	_check(invalid.configure(_config(0, 1)).status == "failed",
		"zero caps reject configuration")
	var invalid_aggregate = POLICY.new()
	_check(invalid_aggregate.configure(_config(100, 99)).status == "failed",
		"aggregate cap cannot be smaller than a window cap")

	var policy = POLICY.new()
	var configured: Dictionary = policy.configure(_config(20000, 40000))
	_check(configured.status == "ready" and not policy.policy_identity().is_empty(),
		"explicit configuration publishes a stable policy identity")
	_check(policy.configure(_config(20000, 40000)).status == "failed",
		"policy configuration is immutable")
	var empty: Dictionary = policy.estimate_row(0, false)
	var one_shape: Dictionary = policy.estimate_row(100, true)
	var two_shapes: Dictionary = policy.estimate_row(769, true)
	_check(empty.sourceVertexBytes == 0 and empty.shapeCount == 0 \
		and empty.physicalChargedBytes == 256,
		"empty rows retain only the configured row-entry charge")
	_check(one_shape.sourceVertexBytes == 1200 and one_shape.shapeCount == 1 \
		and one_shape.physicalChargedBytes == 8464,
		"one-shape charge follows the versioned exact formula")
	_check(two_shapes.sourceVertexBytes == 9228 and two_shapes.shapeCount == 2 \
		and two_shapes.expectedBodyCount == 1 \
		and two_shapes.physicalChargedBytes == 33060,
		"shape rounding and payload multiplication are exact")
	_check(policy.estimate_row(0, true).status == "failed" \
		and policy.estimate_row(1, false).status == "failed" \
		and policy.estimate_row(65537, true).status == "failed",
		"hit/vertex mismatch and row capacity fail closed")
	var window: Dictionary = policy.estimate_window([
		{"vertexCount":0, "expectedHit":false},
		{"vertexCount":100, "expectedHit":true}])
	_check(window.rowCount == 2 and window.sourceVertexBytes == 1200 \
		and window.physicalChargedBytes == 8720 and window.shapeCount == 1 \
		and window.expectedBodyCount == 1,
		"window formula sums source and physical charges independently")

	var overflow = POLICY.new()
	var overflow_config := _config(POLICY.MAX_I64, POLICY.MAX_I64)
	overflow_config.physicsPayloadMultiplier = POLICY.MAX_I64
	_check(overflow.configure(overflow_config).status == "ready" \
		and overflow.estimate_row(2, true).reason == "collision_memory_byte_overflow",
		"checked multiplication rejects signed 64-bit overflow")
	var addition_overflow = POLICY.new()
	var addition_config := _config(POLICY.MAX_I64, POLICY.MAX_I64)
	addition_config.rowEntryBytes = POLICY.MAX_I64 - 10
	addition_config.bodyEntryBytes = 20
	addition_config.physicsPayloadMultiplier = 1
	_check(addition_overflow.configure(addition_config).status == "ready" \
		and addition_overflow.estimate_row(1, true).reason \
			== "collision_memory_byte_overflow",
		"checked addition rejects signed 64-bit overflow")
	var large_integer_policy = POLICY.new()
	var large_integer_config := _config(POLICY.MAX_I64, POLICY.MAX_I64)
	large_integer_config.maxVerticesPerRow = POLICY.MAX_I64
	large_integer_config.verticesPerShape = POLICY.MAX_I64 - 1
	large_integer_config.rowEntryBytes = 1
	large_integer_config.bodyEntryBytes = 1
	large_integer_config.shapeEntryBytes = 1
	large_integer_config.physicsPayloadMultiplier = 1
	_check(large_integer_policy.configure(large_integer_config).status == "ready" \
		and large_integer_policy._shape_count(POLICY.MAX_I64 - 1,
			POLICY.MAX_I64 - 1).value == 1 \
		and large_integer_policy._shape_count(POLICY.MAX_I64,
			POLICY.MAX_I64 - 1).value == 2 \
		and large_integer_policy._checked_mul(POLICY.MAX_I64, 1).value \
			== POLICY.MAX_I64 \
		and large_integer_policy._checked_mul(POLICY.MAX_I64, 2).reason \
			== "collision_memory_byte_overflow" \
		and large_integer_policy.estimate_row(POLICY.MAX_I64, true).reason \
			== "collision_memory_byte_overflow",
		"near-int64 shape quotient/remainder stays exact before byte overflow")

	var exact_policy = POLICY.new()
	_check(exact_policy.configure(_config(16928, 16928, 4)).status == "ready",
		"test policy admits the formula-exact two-generation overlap")
	var incomplete_ledger = ADMISSION.new()
	_check(incomplete_ledger.setup(IncompletePolicy.new(), "incomplete").reason \
		== "collision_memory_admission_setup_invalid",
		"duck-typed policy setup requires formula and identity methods up front")
	var ledger = ADMISSION.new()
	_check(ledger.setup(exact_policy, "ledger-A").status == "ready",
		"ledger binds one immutable configured policy")
	_check(ledger.setup(exact_policy, "ledger-B").status == "failed",
		"ledger setup cannot be replaced")
	var row_spec := [{"vertexCount":100, "expectedHit":true}]
	var foreign_formula = ADMISSION.new()
	foreign_formula.setup(ForeignFormulaPolicy.new(exact_policy), "foreign-formula")
	_check(foreign_formula.reserve_candidate("owner", "window", "candidate",
		row_spec).reason == "collision_memory_formula_identity_mismatch",
		"admission rejects a forged or mismatched formula receipt")
	var old: Dictionary = ledger.reserve_candidate("owner-A", "window-A", "old", row_spec)
	_check(old.status == "ready" and old.chargedBytes == 8464,
		"candidate reserves exact bytes")
	var duplicate: Dictionary = ledger.reserve_candidate("owner-A", "window-A",
		"old", row_spec)
	_check(duplicate.reason == "collision_memory_reservation_duplicate" \
		and ledger.snapshot().reservationCount == 1 \
		and ledger.snapshot().totalChargedBytes == 8464,
		"duplicate semantic reservation is rejected without mutation")
	_check(ledger.mark_candidate_constructed(old.token, "foreign-owner", [909]).reason \
		== "collision_memory_owner_epoch_mismatch",
		"foreign owner cannot advance a reservation")
	_check(ledger.mark_candidate_constructed(old.token, "owner-A", [909]).status == "ready" \
		and ledger.commit_live(old.token, "owner-A").status == "ready",
		"candidate transitions reserved to constructed to live")
	var candidate: Dictionary = ledger.reserve_candidate("owner-A", "window-A",
		"replacement", row_spec)
	_check(candidate.status == "ready" \
		and ledger.snapshot().totalChargedBytes == 16928,
		"old and replacement candidate remain charged simultaneously")
	var denied: Dictionary = ledger.reserve_candidate("owner-A", "window-A",
		"over-cap", row_spec)
	_check(denied.status == "pending" and denied.retryable == true \
		and denied.accepted == false and ledger.snapshot().reservationCount == 2,
		"capacity denial is retryable and does not mutate the ledger")
	var aggregate_denied: Dictionary = ledger.reserve_candidate("owner-B", "window-B",
		"aggregate-over-cap", row_spec)
	_check(aggregate_denied.status == "pending" and aggregate_denied.retryable == true \
		and ledger.snapshot().reservationCount == 2,
		"aggregate capacity denial is retryable and does not mutate the ledger")
	_check(ledger.cancel_unconstructed(candidate.token, "owner-A").status == "ready" \
		and ledger.snapshot().totalChargedBytes == 8464,
		"unconstructed cancellation releases its reservation exactly")
	var replacement: Dictionary = ledger.reserve_candidate("owner-A", "window-A",
		"replacement-2", row_spec)
	var before_bad_body_count: Dictionary = ledger.snapshot()
	_check(ledger.mark_candidate_constructed(replacement.token, "owner-A", []).reason \
		== "collision_memory_body_count_mismatch" \
		and ledger.snapshot() == before_bad_body_count,
		"wrong body cardinality cannot construct or mutate a reservation")
	ledger.mark_candidate_constructed(replacement.token, "owner-A", [303])
	_check(ledger.cancel_unconstructed(replacement.token, "owner-A").status == "failed",
		"constructed resources cannot bypass deferred-free acknowledgement")
	var deferred: Dictionary = ledger.defer_release(replacement.token, "owner-A",
		10, 20)
	_check(deferred.status == "ready" \
		and ledger.snapshot().stateCounts.retired_deferred == 1 \
		and ledger.snapshot().totalChargedBytes == 16928,
		"deferred resources retain their full charge")
	var valid_ack := _ack("ledger-A", replacement.token, "owner-A", "window-A",
		10, 20, [303])
	var early_ack: Dictionary = valid_ack.duplicate(true)
	early_ack.physicsFrame = 10
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		early_ack).status == "failed" and ledger.snapshot().totalChargedBytes == 16928,
		"same-physics-frame acknowledgement retains the charge")
	var foreign_ack: Dictionary = valid_ack.duplicate(true)
	foreign_ack.ledgerEpoch = "ledger-B"
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		foreign_ack).status == "failed",
		"foreign ledger epoch cannot release bytes")
	var wrong_window_ack: Dictionary = valid_ack.duplicate(true)
	wrong_window_ack.windowToken = "window-B"
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		wrong_window_ack).status == "failed",
		"foreign window token cannot release bytes")
	var string_frame_ack: Dictionary = valid_ack.duplicate(true)
	string_frame_ack.queuedPhysicsFrame = "10"
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		string_frame_ack).reason == "collision_memory_release_ack_invalid",
		"numeric-looking string frames cannot masquerade as teardown proof")
	var float_frame_ack: Dictionary = valid_ack.duplicate(true)
	float_frame_ack.physicsFrame = 11.0
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		float_frame_ack).reason == "collision_memory_release_ack_invalid",
		"floating-point frames cannot masquerade as teardown proof")
	var string_body_ack: Dictionary = valid_ack.duplicate(true)
	string_body_ack.absentBodyInstanceIds = ["303"]
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		string_body_ack).reason == "collision_memory_release_body_set_mismatch",
		"numeric-looking body IDs cannot masquerade as absence proof")
	var observed_ack: Dictionary = valid_ack.duplicate(true)
	observed_ack.observedColliderInstanceIds = [303]
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		observed_ack).reason == "collision_memory_retired_collider_observed",
		"an observed retired collider retains the reservation")
	var wrong_ids: Dictionary = valid_ack.duplicate(true)
	wrong_ids.absentBodyInstanceIds = [101]
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		wrong_ids).reason == "collision_memory_release_body_set_mismatch",
		"partial body absence cannot release bytes")
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		valid_ack).status == "ready" and ledger.snapshot().totalChargedBytes == 8464,
		"exact later physics/process/body acknowledgement releases deferred bytes")
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		valid_ack).reason == "collision_memory_reservation_stale",
		"release acknowledgement cannot replay")
	_check(ledger.drain_receipt().status == "pending",
		"live reservations keep drain pending")
	_check(ledger.defer_release(old.token, "owner-A", 30, 40).status == "ready",
		"live entry enters deferred state during stop")
	var old_ack := _ack("ledger-A", old.token, "owner-A", "window-A", 30, 40,
		[909], 31, 41)
	_check(ledger.acknowledge_deferred_release(old.token, "owner-A", old_ack).status \
		== "ready" and ledger.drain_receipt().status == "ready",
		"zero-reservation drain is ready only after the final exact acknowledgement")

	var one_byte_policy = POLICY.new()
	one_byte_policy.configure(_config(8464, 8464))
	var one_byte_ledger = ADMISSION.new()
	one_byte_ledger.setup(one_byte_policy, "ledger-boundary")
	_check(one_byte_ledger.reserve_candidate("owner", "window", "exact", row_spec).status \
		== "ready", "exact per-window and aggregate boundary is admitted")
	var over_row := [{"vertexCount":101, "expectedHit":true}]
	_check(one_byte_ledger.reserve_candidate("owner", "other", "over", over_row).reason \
		== "collision_memory_request_exceeds_window_cap",
		"one formula increment above a window cap fails terminally")
	var boundary_reservations: Dictionary = one_byte_ledger._reservations
	var exact_token := String(boundary_reservations.keys()[0])
	one_byte_ledger.cancel_unconstructed(exact_token, "owner")
	var before_old_token_replay: Dictionary = one_byte_ledger.snapshot()
	_check(one_byte_ledger.cancel_unconstructed(exact_token, "owner").reason \
		== "collision_memory_reservation_stale" \
		and one_byte_ledger.snapshot() == before_old_token_replay,
		"released token replay is stale without retaining token history")

	var capacity_policy = POLICY.new()
	capacity_policy.configure(_config(16928, 16928, 1))
	var capacity_ledger = ADMISSION.new()
	capacity_ledger.setup(capacity_policy, "ledger-capacity")
	capacity_ledger.reserve_candidate("owner", "window", "first", row_spec)
	var before_capacity_replay: Dictionary = capacity_ledger.snapshot()
	var capacity_replay: Dictionary = capacity_ledger.reserve_candidate("owner",
		"window", "first", row_spec)
	var capacity_new: Dictionary = capacity_ledger.reserve_candidate("owner",
		"window", "second", row_spec)
	_check(capacity_replay.reason == "collision_memory_reservation_duplicate" \
		and capacity_new.reason == "collision_memory_reservation_capacity" \
		and capacity_new.retryable == true \
		and capacity_ledger.snapshot() == before_capacity_replay,
		"semantic replay is classified before retryable reservation capacity")

	var arithmetic_policy = POLICY.new()
	var arithmetic_config := _config(POLICY.MAX_I64, POLICY.MAX_I64, 4)
	arithmetic_config.rowEntryBytes = POLICY.MAX_I64 - 100
	arithmetic_config.bodyEntryBytes = 1
	arithmetic_config.shapeEntryBytes = 1
	arithmetic_config.physicsPayloadMultiplier = 1
	arithmetic_policy.configure(arithmetic_config)
	var arithmetic_ledger = ADMISSION.new()
	arithmetic_ledger.setup(arithmetic_policy, "ledger-arithmetic")
	var huge_empty := [{"vertexCount":0, "expectedHit":false}]
	var huge_first: Dictionary = arithmetic_ledger.reserve_candidate("owner",
		"window", "first", huge_empty)
	var before_overflow: Dictionary = arithmetic_ledger.snapshot()
	var huge_second: Dictionary = arithmetic_ledger.reserve_candidate("owner",
		"window", "second", huge_empty)
	_check(huge_first.status == "ready" \
		and huge_second.reason == "collision_memory_byte_overflow" \
		and arithmetic_ledger.snapshot() == before_overflow,
		"ledger addition overflow fails closed without state mutation")
	var sequence_policy = POLICY.new()
	sequence_policy.configure(_config(20000, 40000))
	var sequence_ledger = ADMISSION.new()
	sequence_ledger.setup(sequence_policy, "ledger-sequence")
	sequence_ledger._last_issued_sequence = ADMISSION.MAX_I64 - 1
	sequence_ledger._next_sequence = ADMISSION.MAX_I64
	var before_sequence: Dictionary = sequence_ledger.snapshot()
	var exhausted: Dictionary = sequence_ledger.reserve_candidate("owner", "window",
		"exhausted", row_spec)
	_check(exhausted.reason == "collision_memory_sequence_exhausted" \
		and sequence_ledger.snapshot() == before_sequence,
		"reservation sequence exhaustion fails closed without state mutation")
	var discontinuous_ledger = ADMISSION.new()
	discontinuous_ledger.setup(sequence_policy, "ledger-discontinuous")
	discontinuous_ledger._last_issued_sequence = 1
	var before_discontinuous: Dictionary = discontinuous_ledger.snapshot()
	_check(discontinuous_ledger.reserve_candidate("owner", "window", "rewound",
		row_spec).reason == "collision_memory_sequence_discontinuous" \
		and discontinuous_ledger.snapshot() == before_discontinuous,
		"sequence rewind fails closed without mutation")

	var collision_ledger = ADMISSION.new()
	collision_ledger.setup(sequence_policy, "ledger-token-collision")
	var first_collision_reservation: Dictionary = collision_ledger.reserve_candidate(
		"owner", "window", "first", row_spec)
	var first_record: Dictionary = collision_ledger._reservations[
		first_collision_reservation.token]
	var prospective_token := collision_ledger._token_for_sequence(
		collision_ledger._next_sequence)
	collision_ledger._reservations[prospective_token] = first_record.duplicate(true)
	var before_token_collision: Dictionary = collision_ledger.snapshot()
	_check(collision_ledger.reserve_candidate("owner", "other", "second",
		row_spec).reason == "collision_memory_reservation_token_collision" \
		and collision_ledger.snapshot() == before_token_collision,
		"active structural token collision fails closed before mutation")

	var churn_ledger = ADMISSION.new()
	churn_ledger.setup(sequence_policy, "ledger-churn")
	var churn_tokens := {}
	for cycle in range(256):
		var churn: Dictionary = churn_ledger.reserve_candidate("owner", "window",
			"cycle-%d" % cycle, row_spec)
		if churn.get("status") != "ready":
			failures.append("churn reservation %d is ready" % cycle)
			break
		churn_tokens[churn.token] = true
		if churn_ledger.cancel_unconstructed(churn.token, "owner").get("status") \
				!= "ready":
			failures.append("churn release %d is ready" % cycle)
			break
	var churn_snapshot: Dictionary = churn_ledger.snapshot()
	_check(churn_tokens.size() == 256 and churn_snapshot.reservationCount == 0 \
		and churn_snapshot.semanticReservationCount == 0 \
		and churn_snapshot.lastIssuedSequence == 256 \
		and churn_snapshot.nextSequence == 257 \
		and churn_snapshot.has("issuedTokenCount") == false,
		"256-cycle churn keeps constant-size ledger bookkeeping and exact sequence")
	_check(churn_ledger.drain_receipt().status == "ready" \
		and churn_ledger.snapshot().sealedAfterDrain == true \
		and churn_ledger.reserve_candidate("owner", "window", "after-drain",
			row_spec).reason == "collision_memory_ledger_drained",
		"drain seals the ledger epoch and requires a new ledger object")

	var corrupt_policy = POLICY.new()
	corrupt_policy.configure(_config(20000, 40000))
	var corrupt_ledger = ADMISSION.new()
	corrupt_ledger.setup(corrupt_policy, "ledger-corrupt")
	var corrupt: Dictionary = corrupt_ledger.reserve_candidate("owner", "window",
		"candidate", row_spec)
	corrupt_ledger._window_charged["window"] = 0
	var before_corrupt_release: Dictionary = corrupt_ledger.snapshot()
	_check(corrupt_ledger.cancel_unconstructed(corrupt.token, "owner").reason \
		== "collision_memory_ledger_invariant" \
		and corrupt_ledger.snapshot() == before_corrupt_release,
		"inconsistent release accounting fails closed without further mutation")

	var report := {"schema":"n5-collision-memory-policy-contract/v1",
		"passed":failures.is_empty(), "evidenceLevel":"pure policy/ledger contract",
		"productionWired":false, "productionCapsConfigured":false,
		"formulaVersion":POLICY.FORMULA_VERSION,
		"policyIdentity":policy.policy_identity(), "failures":failures,
		"finalDrain":ledger.drain_receipt()}
	var path := OS.get_environment("N5_COLLISION_MEMORY_POLICY_REPORT")
	if not path.is_empty():
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
			file.close()
	quit(0 if report.passed else 1)
