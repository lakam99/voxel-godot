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


class MutablePolicy extends RefCounted:
	var backing
	var exposed_limits := {}
	var exposed_formula := ""
	var exposed_identity := ""

	func _init(value) -> void:
		backing = value
		exposed_limits = value.limits()
		exposed_formula = value.formula_version()
		exposed_identity = value.policy_identity()

	func is_configured() -> bool:
		return true

	func estimate_window(rows: Array) -> Dictionary:
		return backing.estimate_window(rows)

	func limits() -> Dictionary:
		return exposed_limits.duplicate(true)

	func formula_version() -> String:
		return exposed_formula

	func policy_identity() -> String:
		return exposed_identity

	func mutate_after_setup() -> void:
		exposed_limits.maxWindowChargedBytes = 1
		exposed_limits.maxAggregateChargedBytes = 1
		exposed_identity = "mutated-policy-identity"


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


func _ack(ledger_epoch: String, ledger_identity: String, token: String,
		owner: String, window: String,
		queued_physics: int, queued_process: int, ids: Array,
		physics_frame := 11, process_frame := 21) -> Dictionary:
	return {"schema":ADMISSION.RELEASE_ACK_SCHEMA, "ledgerEpoch":ledger_epoch,
		"ledgerIdentity":ledger_identity,
		"reservationToken":token, "ownerEpoch":owner, "windowToken":window,
		"queuedPhysicsFrame":queued_physics, "queuedProcessFrame":queued_process,
		"physicsFrame":physics_frame, "processFrame":process_frame,
		"allBodiesAbsent":true, "deferredEntriesReleased":true,
		"absentBodyInstanceIds":ids.duplicate(),
		"observedColliderInstanceIds":[]}


func _reserved_fixture(policy, suffix: String, rows: Array) -> Dictionary:
	var ledger = ADMISSION.new()
	var setup: Dictionary = ledger.setup(policy, "ledger-%s" % suffix,
		"instance-%s" % suffix)
	if setup.get("status") != "ready":
		return {"status":"failed", "ledger":ledger, "setup":setup}
	var reservation: Dictionary = ledger.reserve_candidate("owner", "window",
		"candidate", rows)
	return {"status":reservation.get("status"), "ledger":ledger,
		"reservation":reservation}


func _inject_candidate_clone(ledger, source_token: String,
		reservation_id: String, window_token: String) -> String:
	var sequence: int = ledger._next_sequence
	var token: String = ledger._token_for_sequence(sequence)
	var record: Dictionary = ledger._reservations[source_token].duplicate(true)
	var semantic_key: String = ledger._semantic_key(String(record.ownerEpoch),
		window_token, reservation_id)
	record.token = token
	record.sequence = sequence
	record.windowToken = window_token
	record.reservationId = reservation_id
	record.semanticKey = semantic_key
	ledger._reservations[token] = record
	ledger._reservation_keys[semantic_key] = token
	ledger._window_charged[window_token] = int(
		ledger._window_charged.get(window_token, 0)) + int(record.chargedBytes)
	ledger._total_charged += int(record.chargedBytes)
	ledger._last_issued_sequence = sequence
	ledger._next_sequence = sequence + 1
	return token


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
	_check(incomplete_ledger.setup(IncompletePolicy.new(), "incomplete",
		"instance-incomplete").reason \
		== "collision_memory_admission_setup_invalid",
		"duck-typed policy setup requires formula and identity methods up front")
	var missing_nonce_ledger = ADMISSION.new()
	_check(missing_nonce_ledger.setup(exact_policy, "ledger-missing-nonce", "").reason \
		== "collision_memory_admission_setup_invalid",
		"ledger setup requires an explicit unique instance nonce")
	var ledger = ADMISSION.new()
	_check(ledger.setup(exact_policy, "ledger-A", "instance-A").status == "ready",
		"ledger binds one immutable configured policy")
	_check(ledger.setup(exact_policy, "ledger-B", "instance-B").status == "failed",
		"ledger setup cannot be replaced")
	var row_spec := [{"vertexCount":100, "expectedHit":true}]
	var abort_policy = POLICY.new()
	_check(abort_policy.configure(_config(50000, 100000, 8)).status == "ready",
		"abort-body recovery policy is explicitly configured")
	var abort_ledger = ADMISSION.new()
	_check(abort_ledger.setup(abort_policy, "ledger-abort-body",
		"instance-abort-body").status == "ready",
		"abort-body recovery ledger binds its own identity")
	var occupied: Dictionary = abort_ledger.reserve_candidate("owner-abort",
		"window-abort", "occupied", row_spec)
	_check(occupied.status == "ready" and abort_ledger.mark_candidate_constructed(
		occupied.token, "owner-abort", [501]).status == "ready",
		"occupied body fixture reaches constructed state")
	var abort_body: Dictionary = abort_ledger.reserve_candidate("owner-abort",
		"window-abort", "abort-body", row_spec)
	var abort_charge_before: int = int(abort_ledger.snapshot().totalChargedBytes)
	_check(abort_body.status == "ready" \
		and abort_ledger.register_candidate_abort_body(abort_body.token,
			"foreign-owner", [502]).reason == "collision_memory_owner_epoch_mismatch" \
		and abort_ledger.register_candidate_abort_body(abort_body.token,
			"owner-abort", []).reason == "collision_memory_body_count_mismatch" \
		and abort_ledger.register_candidate_abort_body(abort_body.token,
			"owner-abort", [0]).reason == "collision_memory_body_ids_invalid" \
		and abort_ledger.register_candidate_abort_body(abort_body.token,
			"owner-abort", [501]).reason == "collision_memory_body_owner_collision" \
		and int(abort_ledger.snapshot().totalChargedBytes) == abort_charge_before,
		"abort registration rejects foreign epoch, wrong count, collision without charge mutation")
	var recovered_abort: Dictionary = abort_ledger.register_candidate_abort_body(
		abort_body.token, "owner-abort", [502])
	_check(recovered_abort.status == "ready" \
		and recovered_abort.transition == "candidate_abort_body_registered" \
		and recovered_abort.state == "candidate_constructed" \
		and abort_ledger.cancel_unconstructed(abort_body.token,
			"owner-abort").reason \
			== "collision_memory_cancel_requires_unconstructed" \
		and abort_ledger.snapshot().totalChargedBytes == abort_charge_before,
		"exact abort-body identity enters deferred lifecycle without releasing charge early")
	var abort_deferred: Dictionary = abort_ledger.defer_release(abort_body.token,
		"owner-abort", 10, 20)
	var abort_ack := _ack(String(abort_ledger.snapshot().ledgerEpoch),
		String(abort_ledger.snapshot().ledgerIdentity), abort_body.token,
		"owner-abort", "window-abort", 10, 20, [502])
	_check(abort_deferred.status == "ready" \
		and abort_ledger.acknowledge_deferred_release(abort_body.token,
			"owner-abort", abort_ack).status == "ready" \
		and int(abort_ledger.snapshot().totalChargedBytes) \
			== int(occupied.chargedBytes),
		"recovered shape-less body releases only through exact later deferred acknowledgement")
	var duplicate_ids: Dictionary = abort_ledger.reserve_candidate("owner-abort",
		"window-abort", "duplicate-abort-ids", [
			{"vertexCount":100, "expectedHit":true},
			{"vertexCount":100, "expectedHit":true}])
	var duplicate_abort: Dictionary = abort_ledger.register_candidate_abort_body(
		duplicate_ids.token, "owner-abort", [503, 503])
	_check(duplicate_abort.reason == "collision_memory_body_ids_invalid" \
		and abort_ledger.snapshot().stateCounts.candidate_reserved == 1 \
		and abort_ledger.snapshot().totalChargedBytes \
			== int(occupied.chargedBytes) + int(duplicate_ids.chargedBytes) \
		and abort_ledger.cancel_unconstructed(duplicate_ids.token,
			"owner-abort").status == "ready",
		"duplicate abort body identities fail closed and preserve the reserved charge")
	var mutable_source = MutablePolicy.new(exact_policy)
	var frozen_ledger = ADMISSION.new()
	_check(frozen_ledger.setup(mutable_source, "ledger-frozen",
		"instance-frozen").status == "ready",
		"ledger captures a canonical policy value at setup")
	mutable_source.mutate_after_setup()
	_check(frozen_ledger.reserve_candidate("owner", "window", "candidate",
		row_spec).status == "ready" \
		and frozen_ledger.snapshot().policyIdentity == exact_policy.policy_identity(),
		"mutable source changes cannot alter frozen limits or identity")
	var foreign_formula = ADMISSION.new()
	_check(foreign_formula.setup(ForeignFormulaPolicy.new(exact_policy),
		"foreign-formula", "foreign-instance").status == "ready" \
		and foreign_formula.reserve_candidate("owner", "window", "candidate",
			row_spec).status == "ready",
		"admission uses its frozen canonical policy instead of a mutable wrapper")
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
	var before_duplicate_body: Dictionary = ledger.snapshot()
	_check(ledger.mark_candidate_constructed(replacement.token, "owner-A", [909]).reason \
		== "collision_memory_body_owner_collision" \
		and ledger.snapshot() == before_duplicate_body,
		"one body instance cannot belong to two active reservations")
	ledger.mark_candidate_constructed(replacement.token, "owner-A", [303])
	_check(ledger.cancel_unconstructed(replacement.token, "owner-A").status == "failed",
		"constructed resources cannot bypass deferred-free acknowledgement")
	var deferred: Dictionary = ledger.defer_release(replacement.token, "owner-A",
		10, 20)
	_check(deferred.status == "ready" \
		and ledger.snapshot().stateCounts.retired_deferred == 1 \
		and ledger.snapshot().bodyOwnerCount == 2 \
		and ledger.snapshot().totalChargedBytes == 16928,
		"deferred resources retain their full charge and body ownership")
	var valid_ack := _ack("ledger-A", String(ledger.snapshot().ledgerIdentity),
		replacement.token, "owner-A", "window-A", 10, 20, [303])
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
	var duplicate_observed_ack: Dictionary = valid_ack.duplicate(true)
	duplicate_observed_ack.observedColliderInstanceIds = [404, 404]
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		duplicate_observed_ack).reason \
			== "collision_memory_observed_body_ids_invalid",
		"duplicate observed collider IDs cannot serve as release proof")
	var nonpositive_observed_ack: Dictionary = valid_ack.duplicate(true)
	nonpositive_observed_ack.observedColliderInstanceIds = [0]
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		nonpositive_observed_ack).reason \
			== "collision_memory_observed_body_ids_invalid",
		"nonpositive observed collider IDs cannot serve as release proof")
	var string_observed_ack: Dictionary = valid_ack.duplicate(true)
	string_observed_ack.observedColliderInstanceIds = ["404"]
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		string_observed_ack).reason \
			== "collision_memory_observed_body_ids_invalid",
		"non-integer observed collider IDs cannot serve as release proof")
	var wrong_ids: Dictionary = valid_ack.duplicate(true)
	wrong_ids.absentBodyInstanceIds = [101]
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		wrong_ids).reason == "collision_memory_release_body_set_mismatch",
		"partial body absence cannot release bytes")
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		valid_ack).status == "ready" and ledger.snapshot().totalChargedBytes == 8464 \
		and ledger.snapshot().bodyOwnerCount == 1,
		"exact later physics/process/body acknowledgement releases deferred bytes")
	_check(ledger.acknowledge_deferred_release(replacement.token, "owner-A",
		valid_ack).reason == "collision_memory_reservation_stale",
		"release acknowledgement cannot replay")
	_check(ledger.drain_receipt().status == "pending",
		"live reservations keep drain pending")
	_check(ledger.defer_release(old.token, "owner-A", 30, 40).status == "ready",
		"live entry enters deferred state during stop")
	var old_ack := _ack("ledger-A", String(ledger.snapshot().ledgerIdentity),
		old.token, "owner-A", "window-A", 30, 40, [909], 31, 41)
	_check(ledger.acknowledge_deferred_release(old.token, "owner-A", old_ack).status \
		== "ready" and ledger.drain_receipt().status == "ready",
		"zero-reservation drain is ready only after the final exact acknowledgement")

	var same_epoch_a = ADMISSION.new()
	var same_epoch_b = ADMISSION.new()
	same_epoch_a.setup(exact_policy, "shared-caller-epoch", "instance-shared-A")
	same_epoch_b.setup(exact_policy, "shared-caller-epoch", "instance-shared-B")
	var same_a: Dictionary = same_epoch_a.reserve_candidate("owner", "window",
		"candidate", row_spec)
	var same_b: Dictionary = same_epoch_b.reserve_candidate("owner", "window",
		"candidate", row_spec)
	same_epoch_a.mark_candidate_constructed(same_a.token, "owner", [601])
	same_epoch_b.mark_candidate_constructed(same_b.token, "owner", [602])
	same_epoch_a.defer_release(same_a.token, "owner", 1, 2)
	same_epoch_b.defer_release(same_b.token, "owner", 1, 2)
	var foreign_ledger_ack := _ack("shared-caller-epoch",
		String(same_epoch_a.snapshot().ledgerIdentity), same_b.token, "owner",
		"window", 1, 2, [602], 3, 4)
	_check(same_a.token != same_b.token \
		and same_epoch_a.snapshot().ledgerIdentity \
			!= same_epoch_b.snapshot().ledgerIdentity \
		and same_epoch_b.acknowledge_deferred_release(same_b.token, "owner",
			foreign_ledger_ack).reason == "collision_memory_release_ack_invalid" \
		and same_epoch_b.snapshot().bodyOwnerCount == 1,
		"same-epoch ledgers have non-interchangeable tokens and acknowledgements")
	var delimiter_a = ADMISSION.new()
	var delimiter_b = ADMISSION.new()
	delimiter_a.setup(exact_policy, "a:b", "c")
	delimiter_b.setup(exact_policy, "a", "b:c")
	var delimiter_reservation_a: Dictionary = delimiter_a.reserve_candidate(
		"owner", "window", "candidate", row_spec)
	var delimiter_reservation_b: Dictionary = delimiter_b.reserve_candidate(
		"owner", "window", "candidate", row_spec)
	_check(delimiter_a.snapshot().ledgerIdentity \
		!= delimiter_b.snapshot().ledgerIdentity \
		and delimiter_reservation_a.token != delimiter_reservation_b.token,
		"length framing distinguishes colon-ambiguous ledger tuples")
	var unicode_a = ADMISSION.new()
	var unicode_b = ADMISSION.new()
	unicode_a.setup(exact_policy, "雪:界", "δ")
	unicode_b.setup(exact_policy, "雪", "界:δ")
	var unicode_reservation_a: Dictionary = unicode_a.reserve_candidate(
		"owner", "window", "candidate", row_spec)
	var unicode_reservation_b: Dictionary = unicode_b.reserve_candidate(
		"owner", "window", "candidate", row_spec)
	_check(unicode_a.snapshot().ledgerIdentity != unicode_b.snapshot().ledgerIdentity \
		and unicode_reservation_a.token != unicode_reservation_b.token,
		"length framing distinguishes Unicode delimiter-ambiguous ledger tuples")

	var one_byte_policy = POLICY.new()
	one_byte_policy.configure(_config(8464, 8464))
	var one_byte_ledger = ADMISSION.new()
	one_byte_ledger.setup(one_byte_policy, "ledger-boundary", "instance-boundary")
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
	capacity_ledger.setup(capacity_policy, "ledger-capacity", "instance-capacity")
	capacity_ledger.reserve_candidate("owner", "window", "first", row_spec)
	var before_capacity_replay: Dictionary = capacity_ledger.snapshot()
	var capacity_replay: Dictionary = capacity_ledger.reserve_candidate("owner",
		"window", "first", row_spec)
	var capacity_invalid: Dictionary = capacity_ledger.reserve_candidate("owner",
		"other", "invalid", [{"vertexCount":0, "expectedHit":true}])
	var capacity_oversize: Dictionary = capacity_ledger.reserve_candidate("owner",
		"other", "oversize", [{"vertexCount":769, "expectedHit":true}])
	var capacity_new: Dictionary = capacity_ledger.reserve_candidate("owner",
		"window", "second", row_spec)
	_check(capacity_replay.reason == "collision_memory_reservation_duplicate" \
		and capacity_invalid.reason == "collision_memory_row_invalid" \
		and capacity_oversize.reason == "collision_memory_request_exceeds_window_cap" \
		and capacity_new.reason == "collision_memory_reservation_capacity" \
		and capacity_new.retryable == true \
		and capacity_ledger.snapshot() == before_capacity_replay,
		"intrinsic invalidity and semantic replay precede retryable capacity")

	var arithmetic_policy = POLICY.new()
	var arithmetic_config := _config(POLICY.MAX_I64, POLICY.MAX_I64, 4)
	arithmetic_config.rowEntryBytes = POLICY.MAX_I64 - 100
	arithmetic_config.bodyEntryBytes = 1
	arithmetic_config.shapeEntryBytes = 1
	arithmetic_config.physicsPayloadMultiplier = 1
	arithmetic_policy.configure(arithmetic_config)
	var arithmetic_ledger = ADMISSION.new()
	arithmetic_ledger.setup(arithmetic_policy, "ledger-arithmetic", "instance-arithmetic")
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
	sequence_ledger.setup(sequence_policy, "ledger-sequence", "instance-sequence")
	sequence_ledger._last_issued_sequence = ADMISSION.MAX_I64 - 1
	sequence_ledger._next_sequence = ADMISSION.MAX_I64
	var before_sequence: Dictionary = sequence_ledger.snapshot()
	var exhausted: Dictionary = sequence_ledger.reserve_candidate("owner", "window",
		"exhausted", row_spec)
	_check(exhausted.reason == "collision_memory_sequence_exhausted" \
		and sequence_ledger.snapshot() == before_sequence,
		"reservation sequence exhaustion fails closed without state mutation")
	var discontinuous_ledger = ADMISSION.new()
	discontinuous_ledger.setup(sequence_policy, "ledger-discontinuous",
		"instance-discontinuous")
	discontinuous_ledger._last_issued_sequence = 1
	var before_discontinuous: Dictionary = discontinuous_ledger.snapshot()
	var discontinuous: Dictionary = discontinuous_ledger.reserve_candidate("owner",
		"window", "rewound", row_spec)
	_check(discontinuous.reason == "collision_memory_ledger_invariant" \
		and discontinuous.detail == "sequence_continuity" \
		and discontinuous_ledger.snapshot() == before_discontinuous,
		"sequence rewind fails the pre-mutation audit without mutation")

	var collision_ledger = ADMISSION.new()
	collision_ledger.setup(sequence_policy, "ledger-token-collision",
		"instance-token-collision")
	var first_collision_reservation: Dictionary = collision_ledger.reserve_candidate(
		"owner", "window", "first", row_spec)
	var first_record: Dictionary = collision_ledger._reservations[
		first_collision_reservation.token]
	var prospective_token := collision_ledger._token_for_sequence(
		collision_ledger._next_sequence)
	collision_ledger._reservations[prospective_token] = first_record.duplicate(true)
	var before_token_collision: Dictionary = collision_ledger.snapshot()
	var token_collision: Dictionary = collision_ledger.reserve_candidate("owner",
		"other", "second", row_spec)
	_check(token_collision.reason == "collision_memory_ledger_invariant" \
		and token_collision.detail == "token_sequence" \
		and collision_ledger.snapshot() == before_token_collision,
		"structural token corruption fails the pre-mutation audit")

	var churn_ledger = ADMISSION.new()
	churn_ledger.setup(sequence_policy, "ledger-churn", "instance-churn")
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
	var epoch_identity_fixture := _reserved_fixture(corrupt_policy,
		"identity-epoch", row_spec)
	var epoch_identity_ledger = epoch_identity_fixture.ledger
	epoch_identity_ledger._ledger_epoch = "corrupt-epoch"
	var before_epoch_identity: Dictionary = epoch_identity_ledger.snapshot()
	var epoch_identity_result: Dictionary = epoch_identity_ledger.reserve_candidate(
		"owner", "other", "next", row_spec)
	_check(epoch_identity_result.reason == "collision_memory_ledger_invariant" \
		and epoch_identity_result.detail == "ledger_identity" \
		and epoch_identity_ledger.snapshot() == before_epoch_identity,
		"mutated ledger epoch fails derived-identity audit without mutation")
	var nonce_identity_fixture := _reserved_fixture(corrupt_policy,
		"identity-nonce", row_spec)
	var nonce_identity_ledger = nonce_identity_fixture.ledger
	nonce_identity_ledger._instance_nonce = "corrupt-nonce"
	var before_nonce_identity: Dictionary = nonce_identity_ledger.snapshot()
	var nonce_identity_result: Dictionary = nonce_identity_ledger.reserve_candidate(
		"owner", "other", "next", row_spec)
	_check(nonce_identity_result.reason == "collision_memory_ledger_invariant" \
		and nonce_identity_result.detail == "ledger_identity" \
		and nonce_identity_ledger.snapshot() == before_nonce_identity,
		"mutated ledger nonce fails derived-identity audit without mutation")
	var direct_identity_fixture := _reserved_fixture(corrupt_policy,
		"identity-direct", row_spec)
	var direct_identity_ledger = direct_identity_fixture.ledger
	direct_identity_ledger._ledger_identity = "corrupt-ledger-identity"
	var before_direct_identity: Dictionary = direct_identity_ledger.snapshot()
	var direct_identity_result: Dictionary = direct_identity_ledger.reserve_candidate(
		"owner", "other", "next", row_spec)
	_check(direct_identity_result.reason == "collision_memory_ledger_invariant" \
		and direct_identity_result.detail == "ledger_identity" \
		and direct_identity_ledger.snapshot() == before_direct_identity,
		"mutated ledger identity fails derived-identity audit without mutation")
	var undercount_fixture := _reserved_fixture(corrupt_policy, "undercount", row_spec)
	var undercount_ledger = undercount_fixture.ledger
	undercount_ledger._total_charged = 1
	var before_undercount: Dictionary = undercount_ledger.snapshot()
	_check(undercount_ledger.reserve_candidate("owner", "other", "next",
		row_spec).reason == "collision_memory_ledger_invariant" \
		and undercount_ledger.snapshot() == before_undercount,
		"nonzero aggregate undercount blocks reserve without mutation")
	var coherent_charge_fixture := _reserved_fixture(corrupt_policy,
		"coherent-charge", row_spec)
	var coherent_charge_ledger = coherent_charge_fixture.ledger
	var coherent_charge_token := String(coherent_charge_fixture.reservation.token)
	var coherent_charge_record: Dictionary = \
		coherent_charge_ledger._reservations[coherent_charge_token]
	var coherent_charge_estimate: Dictionary = coherent_charge_record.estimate
	coherent_charge_estimate.physicalChargedBytes = 1
	coherent_charge_record.estimate = coherent_charge_estimate
	coherent_charge_record.chargedBytes = 1
	coherent_charge_ledger._reservations[coherent_charge_token] = \
		coherent_charge_record
	coherent_charge_ledger._total_charged = 1
	coherent_charge_ledger._window_charged["window"] = 1
	var before_coherent_charge: Dictionary = coherent_charge_ledger.snapshot()
	_check(coherent_charge_ledger.reserve_candidate("owner", "other", "next",
		row_spec).reason == "collision_memory_ledger_invariant" \
		and coherent_charge_ledger.snapshot() == before_coherent_charge,
		"canonical rows reject coherently forged nonzero charge undercount")
	var extra_window_fixture := _reserved_fixture(corrupt_policy, "extra-window",
		row_spec)
	var extra_window_ledger = extra_window_fixture.ledger
	extra_window_ledger._window_charged["foreign-window"] = 1
	var before_extra_window: Dictionary = extra_window_ledger.snapshot()
	_check(extra_window_ledger.cancel_unconstructed(
		extra_window_fixture.reservation.token, "owner").reason \
			== "collision_memory_ledger_invariant" \
		and extra_window_ledger.snapshot() == before_extra_window,
		"extra window charge key blocks release without mutation")
	var missing_window_fixture := _reserved_fixture(corrupt_policy,
		"missing-window", row_spec)
	var missing_window_ledger = missing_window_fixture.ledger
	missing_window_ledger._window_charged.erase("window")
	var before_missing_window: Dictionary = missing_window_ledger.snapshot()
	_check(missing_window_ledger.reserve_candidate("owner", "other", "next",
		row_spec).reason == "collision_memory_ledger_invariant" \
		and missing_window_ledger.snapshot() == before_missing_window,
		"missing window charge key blocks reserve without mutation")
	var missing_semantic_fixture := _reserved_fixture(corrupt_policy,
		"missing-semantic", row_spec)
	var missing_semantic_ledger = missing_semantic_fixture.ledger
	var semantic_key = missing_semantic_ledger._reservation_keys.keys()[0]
	missing_semantic_ledger._reservation_keys.erase(semantic_key)
	var before_missing_semantic: Dictionary = missing_semantic_ledger.snapshot()
	_check(missing_semantic_ledger.cancel_unconstructed(
		missing_semantic_fixture.reservation.token, "owner").reason \
			== "collision_memory_ledger_invariant" \
		and missing_semantic_ledger.snapshot() == before_missing_semantic,
		"missing semantic index blocks release without mutation")
	var foreign_semantic_fixture := _reserved_fixture(corrupt_policy,
		"foreign-semantic", row_spec)
	var foreign_semantic_ledger = foreign_semantic_fixture.ledger
	var foreign_semantic_key = foreign_semantic_ledger._reservation_keys.keys()[0]
	foreign_semantic_ledger._reservation_keys[foreign_semantic_key] = "foreign-token"
	var before_foreign_semantic: Dictionary = foreign_semantic_ledger.snapshot()
	_check(foreign_semantic_ledger.reserve_candidate("owner", "other", "next",
		row_spec).reason == "collision_memory_ledger_invariant" \
		and foreign_semantic_ledger.snapshot() == before_foreign_semantic,
		"foreign semantic index blocks reserve without mutation")
	var over_window_fixture := _reserved_fixture(corrupt_policy, "over-window",
		row_spec)
	var over_window_ledger = over_window_fixture.ledger
	var over_window_source := String(over_window_fixture.reservation.token)
	_inject_candidate_clone(over_window_ledger, over_window_source, "second",
		"window")
	_inject_candidate_clone(over_window_ledger, over_window_source, "third",
		"window")
	var before_over_window: Dictionary = over_window_ledger.snapshot()
	var over_window_result: Dictionary = over_window_ledger.reserve_candidate(
		"owner", "other", "next", row_spec)
	_check(over_window_result.reason == "collision_memory_ledger_invariant" \
		and over_window_result.detail == "window_cap" \
		and over_window_ledger.snapshot() == before_over_window,
		"coherently indexed reservations cannot exceed the frozen window cap")
	var over_aggregate_fixture := _reserved_fixture(exact_policy,
		"over-aggregate", row_spec)
	var over_aggregate_ledger = over_aggregate_fixture.ledger
	var over_aggregate_source := String(over_aggregate_fixture.reservation.token)
	_inject_candidate_clone(over_aggregate_ledger, over_aggregate_source,
		"second", "window-B")
	_inject_candidate_clone(over_aggregate_ledger, over_aggregate_source,
		"third", "window-C")
	var before_over_aggregate: Dictionary = over_aggregate_ledger.snapshot()
	var over_aggregate_result: Dictionary = over_aggregate_ledger.reserve_candidate(
		"owner", "other", "next", row_spec)
	_check(over_aggregate_result.reason == "collision_memory_ledger_invariant" \
		and over_aggregate_result.detail == "aggregate_cap" \
		and over_aggregate_ledger.snapshot() == before_over_aggregate,
		"coherently indexed reservations cannot exceed the frozen aggregate cap")
	var body_index_fixture := _reserved_fixture(corrupt_policy, "body-index", row_spec)
	var body_index_ledger = body_index_fixture.ledger
	body_index_ledger.mark_candidate_constructed(
		body_index_fixture.reservation.token, "owner", [701])
	body_index_ledger._body_owners.erase(701)
	var before_body_index: Dictionary = body_index_ledger.snapshot()
	_check(body_index_ledger.commit_live(body_index_fixture.reservation.token,
		"owner").reason == "collision_memory_ledger_invariant" \
		and body_index_ledger.snapshot() == before_body_index,
		"missing body owner blocks transition without mutation")
	var coherent_body_fixture := _reserved_fixture(corrupt_policy,
		"coherent-body", row_spec)
	var coherent_body_ledger = coherent_body_fixture.ledger
	var coherent_body_token := String(coherent_body_fixture.reservation.token)
	coherent_body_ledger.mark_candidate_constructed(coherent_body_token,
		"owner", [702])
	var coherent_body_record: Dictionary = \
		coherent_body_ledger._reservations[coherent_body_token]
	var coherent_body_estimate: Dictionary = coherent_body_record.estimate
	coherent_body_estimate.expectedBodyCount = 0
	coherent_body_record.estimate = coherent_body_estimate
	coherent_body_record.bodyInstanceIds = []
	coherent_body_ledger._reservations[coherent_body_token] = coherent_body_record
	coherent_body_ledger._body_owners.erase(702)
	var before_coherent_body: Dictionary = coherent_body_ledger.snapshot()
	_check(coherent_body_ledger.commit_live(coherent_body_token, "owner").reason \
		== "collision_memory_ledger_invariant" \
		and coherent_body_ledger.snapshot() == before_coherent_body,
		"canonical rows reject coherently forged body-count and owner indexes")

	var source_hashes = JSON.parse_string(OS.get_environment(
		"N5_COLLISION_MEMORY_POLICY_SOURCE_HASHES"))
	if not source_hashes is Dictionary: source_hashes = {}
	var report := {"schema":"n5-collision-memory-policy-contract/v2",
		"passed":failures.is_empty(), "evidenceLevel":"pure policy/ledger contract",
		"productionWired":false, "productionCapsConfigured":false,
		"sourceCommit":OS.get_environment(
			"N5_COLLISION_MEMORY_POLICY_SOURCE_COMMIT"),
		"sourceHashes":source_hashes,
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
