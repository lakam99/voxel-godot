extends SceneTree
## Coordinator-only scheduler contract. It proves queued owner proof advances
## independently of ACK retries and rejects replaced owner/receipt identities.

const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const OwnerCompletion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SourceRoster := preload("res://scripts/world/StaticSectionSourceRoster.gd")


class FixtureCoordinator extends "res://scripts/world/WorldStaticSectionCoordinator.gd":
	func _receipt_is_live(candidate: Dictionary, receipt: Dictionary) -> bool:
		return receipt.get("status") == "installed" \
			and receipt.get("worldId") == candidate.get("worldId") \
			and receipt.get("sectionKey") == candidate.get("sectionKey") \
			and int(receipt.get("generation", -1)) == int(candidate.get("generation", -2)) \
			and receipt.get("censusDigest") == candidate.get("censusDigest") \
			and receipt.get("contentManifestDigest") == candidate.get("contentManifestDigest")


var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_fair_background_progress()
	_check_owner_replacement_invalidates_request()
	_check_stale_receipt_never_returns_cached_ready()
	_finish()


func _check_fair_background_progress() -> void:
	var coordinator := FixtureCoordinator.new()
	coordinator.configure("scheduler-world")
	var roster_a := _make_roster("owner-a", "revision-a", "incarnation-a", 8)
	var roster_b := _make_roster("owner-b", "revision-b", "incarnation-b", 8)
	var request_a := coordinator.request_geometry_owner_completion(roster_a, [])
	var request_b := coordinator.request_geometry_owner_completion(roster_b, [])
	var duplicate_a := coordinator.request_geometry_owner_completion(roster_a, [])
	var queued_once: bool = request_a.get("status") == "pending" \
		and request_b.get("status") == "pending" \
		and duplicate_a.get("status") == "pending" \
		and coordinator._geometry_owner_completion_requests.size() == 2 \
		and coordinator._geometry_owner_completion_sessions.is_empty()
	var first_advance := coordinator.advance_pending_geometry_owner_completions(1, 1, 1000)
	var first_source := String(first_advance.get("outcomes", [])[0].get("sourceId", "")) \
		if not first_advance.get("outcomes", []).is_empty() else ""
	var second_advance := coordinator.advance_pending_geometry_owner_completions(1, 1, 1000)
	var second_source := String(second_advance.get("outcomes", [])[0].get("sourceId", "")) \
		if not second_advance.get("outcomes", []).is_empty() else ""
	var third_advance := coordinator.advance_pending_geometry_owner_completions(1, 1, 1000)
	var third_source := String(third_advance.get("outcomes", [])[0].get("sourceId", "")) \
		if not third_advance.get("outcomes", []).is_empty() else ""
	var fourth_advance := coordinator.advance_pending_geometry_owner_completions(1, 1, 1000)
	var fourth_source := String(fourth_advance.get("outcomes", [])[0].get("sourceId", "")) \
		if not fourth_advance.get("outcomes", []).is_empty() else ""
	var key_a := String(coordinator._geometry_owner_completion_session_key_by_source.get("owner-a", ""))
	var key_b := String(coordinator._geometry_owner_completion_session_key_by_source.get("owner-b", ""))
	var session_a: Dictionary = coordinator._geometry_owner_completion_sessions.get(key_a, {})
	var session_b: Dictionary = coordinator._geometry_owner_completion_sessions.get(key_b, {})
	var progressed_fairly := first_source == "owner-a" and second_source == "owner-b" \
		and third_source == "owner-a" and fourth_source == "owner-b" \
		and int(session_a.get("memberCursor", 0)) == 1 \
		and int(session_b.get("memberCursor", 0)) == 1
	var normal_turn_coordinator := FixtureCoordinator.new()
	normal_turn_coordinator.configure("scheduler-world")
	var normal_roster := _make_roster("normal-owner", "normal-revision", "normal-incarnation", 8)
	var normal_request := normal_turn_coordinator.request_geometry_owner_completion(
		normal_roster, [])
	var normal_turn := normal_turn_coordinator.advance_queued_complete_section_candidates()
	var normal_key := String(normal_turn_coordinator._geometry_owner_completion_session_key_by_source.get(
		"normal-owner", ""))
	var normal_session: Dictionary = normal_turn_coordinator._geometry_owner_completion_sessions.get(
		normal_key, {})
	_check("owner_requests_queue_without_cursor_work_and_advance_fairly",
		queued_once and progressed_fairly
		and int(first_advance.get("attemptCount", 0)) == 1
		and int(second_advance.get("attemptCount", 0)) == 1
		and int(third_advance.get("attemptCount", 0)) == 1
		and int(fourth_advance.get("attemptCount", 0)) == 1
		and first_advance.get("cursorWorkItems", 0) <= 1
		and second_advance.get("cursorWorkItems", 0) <= 1,
		{"requestA":request_a,"requestB":request_b,"duplicateA":duplicate_a,
			"firstAdvance":first_advance,"secondAdvance":second_advance,
			"thirdAdvance":third_advance,"fourthAdvance":fourth_advance,
			"queuedOnce":queued_once,"progressedFairly":progressed_fairly})
	_check("regular_coordinator_turn_advances_proof_without_ack_attempt",
		normal_request.get("status") == "pending"
		and normal_turn.get("geometryOwnerCompletionAdvance", {}).get("attemptCount", 0) > 0
		and int(normal_session.get("memberCursor", 0)) > 0
		and normal_turn.get("acknowledgementCount", 0) == 0,
		{"request":normal_request,"turn":normal_turn,"session":
			_coordinator_session_summary(normal_session)})


func _check_owner_replacement_invalidates_request() -> void:
	var coordinator := FixtureCoordinator.new()
	coordinator.configure("scheduler-world")
	var old_roster := _make_roster("replace-owner", "same-revision", "owner-incarnation-1", 8)
	var new_roster := _make_roster("replace-owner", "same-revision", "owner-incarnation-2", 8)
	var old_request := coordinator.request_geometry_owner_completion(old_roster, [])
	coordinator.advance_pending_geometry_owner_completions(1, 2, 1000)
	var old_session_key := String(coordinator._geometry_owner_completion_session_key_by_source.get(
		"replace-owner", ""))
	var old_session: Dictionary = coordinator._geometry_owner_completion_sessions.get(
		old_session_key, {})
	var old_cursor := int(old_session.get("memberCursor", 0))
	var new_request := coordinator.request_geometry_owner_completion(new_roster, [])
	var advance := coordinator.advance_pending_geometry_owner_completions(1, 2, 1000)
	var active_key := String(coordinator._geometry_owner_completion_session_key_by_source.get(
		"replace-owner", ""))
	var active: Dictionary = coordinator._geometry_owner_completion_sessions.get(active_key, {})
	_check("new_owner_incarnation_invalidates_old_cursor_and_is_rescheduled",
		old_request.get("status") == "pending" and old_cursor > 0
		and new_request.get("status") == "pending"
		and active_key != old_session_key
		and is_same(active.get("roster", {}), new_roster)
		and active.get("roster", {}).get("sourceIncarnation") == "owner-incarnation-2"
		and int(advance.get("attemptCount", 0)) == 1,
		{"oldRequest":old_request,"newRequest":new_request,
			"oldCursor":old_cursor,"advance":advance,
			"activeSession":_coordinator_session_summary(active)})


func _check_stale_receipt_never_returns_cached_ready() -> void:
	var coordinator := FixtureCoordinator.new()
	coordinator.configure("scheduler-world")
	var source_id := "stale-owner"
	var revision := "stale-revision"
	var section := Vector3i(4, 0, -2)
	var roster := _make_roster(source_id, revision, "stale-incarnation", 1, section)
	var members: Array = roster.get("members", [])
	var candidate := _make_candidate(roster, section, 1, members)
	var receipt := _make_receipt(roster, section, 1, candidate.get("censusDigest", ""),
		candidate.get("contentManifestDigest", ""))
	_install_fixture_candidate(coordinator, source_id, section, candidate, receipt)
	var keys: Array[Vector3i] = [section]
	keys.make_read_only()
	coordinator._visible_section_keys_by_source_id[source_id] = keys
	coordinator._visible_sections_by_source_id[source_id] = {section:revision}
	coordinator._advance_geometry_owner_visible_membership_revision(source_id)
	var request := coordinator.request_geometry_owner_completion(roster, [])
	var completion: Dictionary = {}
	for _advance in range(30):
		completion = coordinator.advance_pending_geometry_owner_completions(1, 8, 1000)
		var key := String(coordinator._geometry_owner_completion_session_key_by_source.get(source_id, ""))
		var session: Dictionary = coordinator._geometry_owner_completion_sessions.get(key, {})
		if session.get("stage") == "complete":
			break
	var ready := coordinator.request_geometry_owner_completion(roster, [])
	var replaced_receipt := _make_receipt(roster, section, 2,
		candidate.get("censusDigest", ""), candidate.get("contentManifestDigest", ""))
	coordinator._production_candidate_receipts[section] = replaced_receipt
	var after_replacement := coordinator.request_geometry_owner_completion(roster, [])
	var stale_advance := coordinator.advance_pending_geometry_owner_completions(1, 8, 1000)
	var active_key := String(coordinator._geometry_owner_completion_session_key_by_source.get(source_id, ""))
	var active: Dictionary = coordinator._geometry_owner_completion_sessions.get(active_key, {})
	var stale_receipt_pending: bool = not stale_advance.get("outcomes", []).is_empty() \
		and stale_advance.get("outcomes", [])[0].get("status") == "pending" \
		and String(active.get("stage", "")) != "complete"
	_check("stale_native_receipt_invalidates_cached_ready_and_stays_pending",
		request.get("status") == "pending"
		and ready.get("status") == "ready" and ready.get("schedulerCached", false)
		and after_replacement.get("status") == "pending"
		and not after_replacement.get("schedulerCached", false)
		and stale_receipt_pending,
		{"request":request,"completion":completion,"ready":ready,
			"afterReceiptReplacement":after_replacement,
			"staleAdvance":stale_advance,
			"session":_coordinator_session_summary(active)})


func _make_roster(source_id: String, revision: String, incarnation: String,
		member_count: int, section := Vector3i.ZERO) -> Dictionary:
	var buffer: Array[float] = []
	buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3.ZERO),
		Color.WHITE, Color.WHITE))
	buffer.make_read_only()
	var members: Array[Dictionary] = []
	for index in range(member_count):
		members.append(OwnerCompletion.packed_member(source_id, source_id, revision,
			"segment-%04d" % index, 0, section,
			AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE), buffer, 0,
			{"meshContentDigest":"scheduler-mesh".sha256_text()}))
	var sealed := OwnerCompletion.seal("scheduler-world", source_id, source_id,
		revision, incarnation, members)
	return sealed.get("roster", {})


func _make_candidate(roster: Dictionary, section: Vector3i, generation: int,
		members: Array) -> Dictionary:
	var manifest := [{"sourceId":roster.get("sourceId", ""),
		"sourcePartId":roster.get("sourcePartId", ""),
		"geometrySourceRanges":members}]
	return {"worldId":"scheduler-world", "sectionKey":section,
		"generation":generation, "censusDigest":"scheduler-census-%d" % generation,
		"contentManifestDigest":"scheduler-manifest-%d" % generation,
		"candidate":{"snapshot":{"manifest":manifest}}}


func _make_receipt(roster: Dictionary, section: Vector3i, generation: int,
		census_digest: String, manifest_digest: String) -> Dictionary:
	var identity := SourceRoster._source_part_identity_key(
		String(roster.get("sourceId", "")), String(roster.get("sourcePartId", "")))
	var receipt := {"status":"installed", "worldId":"scheduler-world",
		"sectionKey":section, "generation":generation,
		"censusDigest":census_digest,
		"contentManifestDigest":manifest_digest,
		"sourceRevision":String(roster.get("sourceRevision", "")),
		"translucentPovRevision":"scheduler-pov",
		"backendInstanceId":17, "chunkInstanceId":23,
		"ownerCell":Vector2i(section.x, section.z),
		"sourceRevisions":{identity:String(roster.get("sourceRevision", ""))}}
	receipt.make_read_only()
	return receipt


func _install_fixture_candidate(coordinator: FixtureCoordinator, source_id: String,
		section: Vector3i, candidate: Dictionary, receipt: Dictionary) -> void:
	coordinator._production_candidates_by_section[section] = candidate
	coordinator._production_candidate_receipts[section] = receipt
	coordinator._advance_geometry_owner_dependency_revision_for_candidate(candidate)


func _coordinator_session_summary(session: Dictionary) -> Dictionary:
	return {"stage":session.get("stage", ""),
		"cursor":session.get("memberCursor", session.get("sectionCursor", 0)),
		"total":session.get("roster", {}).get("members", []).size(),
		"ownerInputResetCount":session.get("ownerInputResetCount", 0),
		"closureResetCount":session.get("closureResetCount", 0)}


func _check(name: String, passed: bool, details: Dictionary = {}) -> void:
	checks[name] = {"passed":passed, "details":details}
	if not passed:
		push_error("Geometry owner completion scheduler contract failed: %s" % name)


func _finish() -> void:
	var passed := true
	var failed: Array[String] = []
	for name_value: Variant in checks:
		if not bool(checks[name_value].get("passed", false)):
			passed = false
			failed.append(String(name_value))
	var report := {"schema":"geometry-owner-completion-scheduler-contract/v1",
		"evidenceLevel":"synthetic_coordinator_scheduler_and_native_receipt_identity",
		"complete":not checks.is_empty(), "passed":passed,
		"checkCount":checks.size(), "failedChecks":failed, "checks":checks}
	var report_path := OS.get_environment("GEOMETRY_OWNER_COMPLETION_SCHEDULER_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	quit(0 if passed else 1)
