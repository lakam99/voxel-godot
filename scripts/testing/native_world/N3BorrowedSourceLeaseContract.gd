extends SceneTree

const SEED := "atlas-1492"
const MAX_ADVANCE_FRAMES := 10000
const MAX_ADVANCE_MSEC := 120000

var checks := {}
var observations := {}
var backend_a
var backend_b
var active_a := 0
var active_b := 0

func _init() -> void:
	call_deferred("run")

func check(label: String, condition: bool) -> void:
	checks[label] = bool(checks.get(label, true)) and condition

func expect(value: Dictionary, status: String, reason: String, label: String) -> void:
	check(label, value.get("status") == status and value.get("reason") == reason)

func initialization() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":SEED,
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func find_ready_page(backend) -> Dictionary:
	var zero_pin: Dictionary = backend.pin_effective_page(Vector2i.ZERO)
	if zero_pin.get("status") == "ready":
		return {"page":Vector2i.ZERO, "status":zero_pin.get("pageStatus", {})}
	for z in range(-12, 0):
		for x in range(-12, 0):
			var page := Vector2i(x, z)
			if backend.shaping_requests(page).get("status") != "ready":
				continue
			var pinned: Dictionary = backend.pin_effective_page(page)
			if pinned.get("status") == "ready":
				return {"page":page, "status":pinned.get("pageStatus", {})}
	return {}

func durable_edit(page: Vector2i, expected_revision: int) -> Dictionary:
	var cell := Vector3i(page.x * 280 + 5, 10, page.y * 280 + 7)
	return {"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"borrowed-source-lease:between-advance",
		"expectedRevision":expected_revision,
		"operations":[{"kind":"set", "cell":cell, "state":{
			"materialId":3, "biomeId":13, "fluidId":0, "solid":true,
			"density":1.25, "light":Vector2i(4, 9),
			"metadata":{"source":"borrowed_lease_contract", "nested":[{"value":7.5}]},
			"blockId":"borrowed.lease.stone", "editReason":"borrowed_lease_contract"}}]}

func drain_a(cancel_first: bool) -> void:
	if backend_a == null or active_a <= 0:
		return
	if cancel_first:
		var cancelled: Dictionary = backend_a.cancel_borrowed_source_lease(active_a)
		check("active_a_cancelled", cancelled.get("status") == "ready"
			and cancelled.get("issue") == active_a)
	var drained: Dictionary = backend_a.drain_borrowed_source_lease(active_a)
	check("active_a_drained", drained.get("status") == "ready"
		and drained.get("reason") == "lease_drained" and drained.get("issue") == active_a)
	if drained.get("status") == "ready":
		active_a = 0

func drain_b() -> void:
	if backend_b == null or active_b <= 0:
		return
	var cancelled: Dictionary = backend_b.cancel_borrowed_source_lease(active_b)
	check("active_b_cancelled", cancelled.get("status") == "ready"
		and cancelled.get("issue") == active_b)
	var drained: Dictionary = backend_b.drain_borrowed_source_lease(active_b)
	check("active_b_drained", drained.get("status") == "ready"
		and drained.get("reason") == "lease_drained" and drained.get("issue") == active_b)
	if drained.get("status") == "ready":
		active_b = 0

func advance_until_ready(issue: int) -> Dictionary:
	var result: Dictionary = {}
	var started := Time.get_ticks_msec()
	var charged := 0
	var zero_seen := false
	var one_seen := false
	for frame in range(MAX_ADVANCE_FRAMES):
		if Time.get_ticks_msec() - started >= MAX_ADVANCE_MSEC:
			break
		var offered := 0 if frame % 5 == 0 else (1 if frame % 5 == 1 else 64)
		result = backend_a.advance_borrowed_source_lease(issue, offered)
		var consumed := int(result.get("consumedOps", -1))
		check("advance_bounded_by_offer", consumed >= 0 and consumed <= offered)
		if result.get("status") == "pending":
			var next_atomic := int(result.get("nextAtomicOps", -1))
			# A completed phase may report zero at the exact budget boundary.
			check("pending_reports_next_atomic_hint", result.has("nextAtomicOps")
				and next_atomic >= 0 and next_atomic <= 64)
		if result.has("sharedFrameWorkOps"):
			var frame_work := int(result.get("sharedFrameWorkOps", -1))
			check("shared_frame_work_cap_observed", frame_work >= 0 and frame_work <= 64)
		if offered == 0:
			zero_seen = zero_seen or consumed == 0
		if offered == 1:
			one_seen = one_seen or consumed <= 1
		charged += maxi(consumed, 0)
		if result.get("status") in ["ready", "failed"]:
			break
		await process_frame
	check("zero_quota_observational", zero_seen)
	check("one_quota_observed", one_seen)
	check("ready_lease_progress_charged", charged > 1)
	observations.readyAdvance = {"status":result.get("status"),
		"reason":result.get("reason"), "chargedOps":charged,
		"dependencyCount":result.get("dependencyCount", -1)}
	return result

func run() -> void:
	backend_a = ClassDB.instantiate("NativeWorldBackend")
	backend_b = ClassDB.instantiate("NativeWorldBackend")
	check("two_native_backends_registered", backend_a != null and backend_b != null)
	if backend_a == null or backend_b == null:
		finish()
		return
	var not_initialized: Dictionary = backend_a.begin_borrowed_source_lease(Vector2i.ZERO)
	expect(not_initialized, "failed", "source_owner_unavailable", "begin_before_initialize_rejected")
	check("backend_a_initialized", backend_a.initialize(initialization()).get("status") == "ready")
	check("backend_b_initialized", backend_b.initialize(initialization()).get("status") == "ready")
	var located := find_ready_page(backend_a)
	check("genuine_ready_page_found", not located.is_empty())
	if located.is_empty():
		finish()
		return
	var page: Vector2i = located.page
	var invalid_page: Dictionary = backend_a.begin_borrowed_source_lease(Vector2i(8000000, 0))
	expect(invalid_page, "failed", "invalid_primary_page", "invalid_page_rejected_before_issue")
	var first_a: Dictionary = backend_a.begin_borrowed_source_lease(page)
	var first_b: Dictionary = backend_b.begin_borrowed_source_lease(page)
	active_a = int(first_a.get("issue", 0))
	active_b = int(first_b.get("issue", 0))
	check("two_real_leases_issued", first_a.get("status") == "pending"
		and first_b.get("status") == "pending" and active_a > 0 and active_b > 0)
	check("global_issue_distinguishes_owners", active_a != active_b)
	check("begin_charges_one", first_a.get("consumedOps") == 1
		and first_b.get("consumedOps") == 1
		and first_a.get("nextAtomicOps") == 1
		and first_b.get("nextAtomicOps") == 1)
	if active_a <= 0 or active_b <= 0:
		finish()
		return
	expect(backend_a.begin_borrowed_source_lease(page), "pending", "prior_lease_not_drained",
		"second_begin_preserves_first_issue")
	expect(backend_b.advance_borrowed_source_lease(active_a, 1), "failed", "lease_issue_mismatch",
		"foreign_issue_cannot_advance_other_owner")
	expect(backend_b.cancel_borrowed_source_lease(active_a), "failed", "lease_issue_mismatch",
		"foreign_issue_cannot_cancel_other_owner")
	expect(backend_a.advance_borrowed_source_lease(active_b, 1), "failed", "lease_issue_mismatch",
		"other_owner_issue_cannot_advance_first_owner")
	expect(backend_a.advance_borrowed_source_lease(active_a, -1), "failed", "invalid_work_quota",
		"negative_quota_rejected")
	var zero: Dictionary = backend_a.advance_borrowed_source_lease(active_a, 0)
	check("zero_quota_no_work", zero.get("status") == "pending"
		and zero.get("consumedOps") == 0 and zero.get("issue") == active_a
		and int(zero.get("nextAtomicOps", 0)) >= 1)
	var one: Dictionary = backend_a.advance_borrowed_source_lease(active_a, 1)
	check("one_quota_bounded", one.get("status") == "pending"
		and int(one.get("consumedOps", -1)) in [0, 1])
	expect(backend_a.start_private_staged_save_retirement(1), "pending",
		"borrowed_source_lease_not_drained", "owner_retirement_waits_for_lease_drain")
	var replay_b := active_b
	drain_b()
	# The drained issue must remain unusable even when another lease exists.
	expect(backend_b.advance_borrowed_source_lease(replay_b, 1), "failed", "lease_issue_mismatch",
		"drained_issue_replay_rejected")
	var stale_issue := active_a
	drain_a(true)
	expect(backend_a.advance_borrowed_source_lease(stale_issue, 1), "failed", "lease_issue_mismatch",
		"cancelled_drained_issue_replay_rejected")
	var restarted: Dictionary = backend_a.begin_borrowed_source_lease(page)
	active_a = int(restarted.get("issue", 0))
	check("exact_rebegin_issues_fresh_identity", restarted.get("status") == "pending"
		and active_a > stale_issue and active_a != active_b)
	if active_a <= 0:
		finish()
		return
	expect(backend_a.advance_borrowed_source_lease(stale_issue, 1), "failed",
		"lease_issue_mismatch", "old_issue_replay_rejected_while_new_issue_active")
	var before_revision := int(backend_a.status().get("terrainDeltaRevision", -1))
	var first_step: Dictionary = backend_a.advance_borrowed_source_lease(active_a, 1)
	check("stale_case_started_bounded", first_step.get("status") == "pending"
		and int(first_step.get("consumedOps", -1)) in [0, 1])
	var committed: Dictionary = backend_a.commit_durable_cells(durable_edit(page, before_revision))
	check("between_advance_writer_committed", committed.get("status") == "ready"
		and committed.get("commitStatus") == "committed"
		and int(backend_a.status().get("terrainDeltaRevision", -1)) == before_revision + 1)
	await process_frame
	var stale: Dictionary = backend_a.advance_borrowed_source_lease(active_a, 64)
	expect(stale, "failed", "source_changed", "between_advance_write_revokes_old_issue")
	expect(backend_a.begin_borrowed_source_lease(page), "pending", "prior_lease_not_drained",
		"stale_issue_requires_explicit_drain")
	var stale_drained: Dictionary = backend_a.drain_borrowed_source_lease(active_a)
	check("stale_issue_drained", stale_drained.get("status") == "ready"
		and stale_drained.get("reason") == "lease_drained")
	if stale_drained.get("status") == "ready":
		active_a = 0
	var current_oracle := find_ready_page(backend_a)
	check("post_edit_ready_page_found", not current_oracle.is_empty())
	if current_oracle.is_empty():
		finish()
		return
	page = current_oracle.page
	var ready_begin: Dictionary = backend_a.begin_borrowed_source_lease(page)
	active_a = int(ready_begin.get("issue", 0))
	check("ready_case_started_with_fresh_issue", ready_begin.get("status") == "pending"
		and active_a > stale_issue)
	if active_a <= 0:
		finish()
		return
	var ready: Dictionary = await advance_until_ready(active_a)
	check("source_lease_reaches_ready", ready.get("status") == "ready")
	if ready.get("status") == "ready":
		var oracle_status: Dictionary = current_oracle.get("status", {})
		check("ready_pin_matches_public_sync_oracle", ready.get("pinIdentity") == oracle_status.get("pinIdentity")
			and ready.get("sourceIdentity") == oracle_status.get("sourceIdentity"))
		check("ready_revision_matches_oracle", ready.get("terrainDeltaRevision") == oracle_status.get("terrainDeltaRevision")
			and ready.get("shapingRegistryRevision") == oracle_status.get("shapingRegistryRevision"))
		check("ready_dependency_set_nonempty", int(ready.get("dependencyCount", 0)) > 0)
		var repeat: Dictionary = backend_a.advance_borrowed_source_lease(active_a, 64)
		check("ready_replay_idempotent", repeat.get("status") == "ready"
			and repeat.get("pinIdentity") == ready.get("pinIdentity")
			and repeat.get("consumedOps") == 0 and repeat.get("nextAtomicOps") == 0)
	var final_drain: Dictionary = backend_a.drain_borrowed_source_lease(active_a)
	check("ready_issue_drained", final_drain.get("status") == "ready"
		and final_drain.get("reason") == "lease_drained")
	if final_drain.get("status") == "ready":
		active_a = 0
	finish()

func finish() -> void:
	if active_a > 0:
		drain_a(true)
	if active_b > 0:
		drain_b()
	var failed_labels: Array[String] = []
	for label in checks:
		if not bool(checks[label]):
			failed_labels.append(String(label))
	var report := {"schema":"n3-borrowed-source-lease-contract/v1",
		"passed":failed_labels.is_empty(), "evidenceLevel":"public NativeWorldBackend GDExtension contract",
		"checks":checks, "failures":failed_labels, "observations":observations,
		"drainedIssues":{"a":active_a == 0, "b":active_b == 0},
		"limitations":{"readGuardReentrantWriterObserved":false,
			"issueCounterExhaustionObserved":false,
			"actualStagedSaveRetirementCompleted":false,
			"productionCutover":false}}
	var path := OS.get_environment("VWB_BORROWED_SOURCE_LEASE_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)
