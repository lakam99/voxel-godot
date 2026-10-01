extends SceneTree

const VisualReadinessScript := preload("res://scripts/world/VisibleWorldReadiness.gd")
const REPORT_ENV := "VOXEL_VISIBLE_WORLD_READINESS_REPORT"
const BOUNDS := Rect2i(-6, -6, 12, 12)
const NEAR_BOUNDS := Rect2i(-2, -2, 4, 4)
const VIEW_CENTER := Vector2(0.0, 0.0)
const VIEW_RADIUS := 6.0

var _checks: Array[Dictionary] = []
var _passed := true


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	test_empty_manifest_requires_complete_source_coverage()
	test_incomplete_discovery_never_reports_empty_ready()
	await test_receipts_are_request_revision_tier_and_installation_bound()
	test_candidate_accounting_and_explicit_failure()
	write_report()
	quit(0 if _passed else 1)


func test_empty_manifest_requires_complete_source_coverage() -> void:
	var book = VisualReadinessScript.new()
	var started: Dictionary = book.begin_view(11, "seed-a", "world-1", BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS)
	var revision := int(started.get("viewRevision", 0))
	var open_result: Dictionary = book.region_readiness(11, "seed-a", "world-1", revision, BOUNDS)
	_check("unsealed_empty_source_set_is_pending", open_result.status == "pending")
	var missing_coverage: Dictionary = book.seal_source_set(revision)
	_check("empty_source_set_without_descriptors_cannot_seal",
		missing_coverage.status == "pending" and missing_coverage.missingKinds.size() == 5)
	_declare_sources(book, revision, BOUNDS)
	_check("empty_sources_only_ready_after_every_kind_is_described",
		book.seal_source_set(revision).status == "ready")
	var ready: Dictionary = book.region_readiness(11, "seed-a", "world-1", revision, BOUNDS)
	_check("complete_deterministic_empty_manifest_is_ready",
		ready.status == "ready" and int(ready.candidateCount) == 0 and int(ready.pendingCount) == 0)


func test_incomplete_discovery_never_reports_empty_ready() -> void:
	var book = VisualReadinessScript.new()
	var revision := int(book.begin_view(12, "seed-b", "world-2", BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	_declare_sources(book, revision, BOUNDS, "wildlife")
	var sealed: Dictionary = book.seal_source_set(revision)
	_check("missing_wildlife_enumeration_retries_instead_of_claiming_empty",
		sealed.status == "pending" and sealed.missingKinds == ["wildlife"])
	var query: Dictionary = book.region_readiness(12, "seed-b", "world-2", revision, BOUNDS)
	_check("incomplete_discovery_is_pending", query.status == "pending")


func test_receipts_are_request_revision_tier_and_installation_bound() -> void:
	var book = VisualReadinessScript.new()
	var revision := int(book.begin_view(13, "seed-c", "world-3", BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	for kind: String in VisualReadinessScript.CONTENT_KINDS:
		_expect_source(book, kind, revision, BOUNDS)
		if kind == "props":
			_check("candidate_declaration_succeeds",
			book.describe_candidate("source:props", "tree:stable-id", "horizon", {"positionXZ": Vector2(3.0, 1.0)}).status == "ready")
			_check("candidate_without_position_is_rejected",
				book.describe_candidate("source:props", "tree:no-position", "horizon").reason == "visual_candidate_position_missing")
			_check("candidate_outside_view_is_rejected",
				book.describe_candidate("source:props", "tree:outside", "horizon", {"positionXZ": Vector2(30.0, 30.0)}).reason == "visual_candidate_outside_view")
			_check("candidate_wrong_tier_is_rejected",
				book.describe_candidate("source:props", "tree:wrong-tier", "near", {"positionXZ": Vector2(3.0, 1.0)}).reason == "visual_candidate_tier_mismatch")
		_check("source_enumeration_receipt_succeeds",
			book.finish_source("source:" + kind, "identity:" + kind, "rev:1", revision).status == "ready")
	_check("source_set_seals_after_full_kind_coverage", book.seal_source_set(revision).status == "ready")
	var borrowed: Dictionary = book.region_readiness(99, "seed-c", "world-3", revision, BOUNDS)
	_check("another_request_cannot_borrow_readiness", borrowed.status == "pending")
	var pending: Dictionary = book.region_readiness(13, "seed-c", "world-3", revision, BOUNDS)
	_check("queued_candidate_remains_pending_and_accounted",
		pending.status == "pending" and int(pending.candidateCount) == 1 and int(pending.pendingCount) == 1 \
		and int(pending.byKind.props.candidate) == 1 and int(pending.byKind.props.represented) == 0)

	var owner := Node3D.new()
	owner.name = "ReceiptOwner"
	root.add_child(owner)
	var representation := MeshInstance3D.new()
	representation.name = "InstalledHorizon"
	representation.mesh = BoxMesh.new()
	owner.add_child(representation)
	await process_frame
	var stale: Dictionary = book.accept_receipt("source:props", "tree:stable-id", "tree:stable-id:horizon",
		"horizon", "identity:props", "stale-revision", revision, owner, representation)
	_check("stale_source_revision_is_rejected", stale.status == "pending")
	var low_tier: Dictionary = book.accept_receipt("source:props", "tree:stable-id", "tree:stable-id:near",
		"near", "identity:props", "rev:1", revision, owner, representation)
	_check("lower_tier_does_not_satisfy_horizon", low_tier.status == "pending")
	var detached: Node3D = Node3D.new()
	root.add_child(detached)
	var unowned: Dictionary = book.accept_receipt("source:props", "tree:stable-id", "tree:stable-id:unowned",
		"horizon", "identity:props", "rev:1", revision, owner, detached)
	_check("uninstalled_representation_cannot_be_accepted", unowned.status == "pending")
	_check("committed_horizon_receipt_is_accepted",
		book.accept_receipt("source:props", "tree:stable-id", "tree:stable-id:horizon",
			"horizon", "identity:props", "rev:1", revision, owner, representation).status == "ready")
	var represented: Dictionary = book.region_readiness(13, "seed-c", "world-3", revision, BOUNDS)
	_check("accepted_receipt_counts_in_the_candidate_kind_and_tier",
		represented.status == "ready" and int(represented.byKind.props.represented) == 1 \
		and int(represented.tiers.horizon.represented) == 1)
	owner.queue_free()
	await process_frame
	var replaced: Dictionary = book.region_readiness(13, "seed-c", "world-3", revision, BOUNDS)
	_check("removed_owner_invalidates_receipt", replaced.status == "pending" and int(replaced.pendingCount) == 1)
	var old_revision := revision
	revision = int(book.begin_view(13, "seed-c", "world-4", BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	_check("world_source_change_advances_view_revision", revision > old_revision)
	_check("old_receipt_cannot_cross_source_revision",
		book.region_readiness(13, "seed-c", "world-3", old_revision, BOUNDS).status == "pending")
	_check("new_revision_starts_pending_without_old_candidates",
		book.region_readiness(13, "seed-c", "world-4", revision, BOUNDS).status == "pending")
	detached.queue_free()
	await process_frame


func test_candidate_accounting_and_explicit_failure() -> void:
	var book = VisualReadinessScript.new()
	var revision := int(book.begin_view(14, "seed-d", "world-5", BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	for kind: String in VisualReadinessScript.CONTENT_KINDS:
		_expect_source(book, kind, revision, BOUNDS)
		if kind == "props":
			book.describe_candidate("source:props", "rock:stable-id", "near", {"positionXZ": Vector2(-1.0, 0.0)})
			book.fail_candidate("source:props", "rock:stable-id", "publisher_rejected", {"stage": "install"})
		if kind != "props":
			book.finish_source("source:" + kind, "identity:" + kind, "rev:1", revision)
	var unsealed: Dictionary = book.seal_source_set(revision)
	_check("covered_but_incomplete_source_cannot_seal", unsealed.status == "pending")
	book.finish_source("source:props", "identity:props", "rev:1", revision)
	book.seal_source_set(revision)
	var failed: Dictionary = book.region_readiness(14, "seed-d", "world-5", revision, BOUNDS)
	_check("explicit_candidate_failure_is_not_pending_or_empty",
		failed.status == "failed" and int(failed.candidateCount) == 1 and int(failed.failedCount) == 1 \
		and int(failed.byKind.props.failed) == 1)
	_check("failure_diagnostics_are_source_scoped",
		failed.failures.size() == 1 and failed.failures[0].sourceId == "source:props")


func _declare_sources(book, revision: int, bounds: Rect2i, skip_kind := "") -> void:
	for kind: String in VisualReadinessScript.CONTENT_KINDS:
		if kind == skip_kind: continue
		_expect_source(book, kind, revision, bounds)
		book.finish_source("source:" + kind, "identity:" + kind, "rev:1", revision)


func _expect_source(book, kind: String, revision: int, bounds: Rect2i) -> void:
	var result: Dictionary = book.expect_source("source:" + kind, kind, "identity:" + kind,
		"rev:1", bounds, revision)
	_check("source_descriptor_" + kind, result.status == "ready")


func _check(name: String, passed: bool, details: Dictionary = {}) -> void:
	if not passed: _passed = false
	_checks.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])


func write_report() -> void:
	var path := OS.get_environment(REPORT_ENV).strip_edges()
	if path.is_empty(): path = ProjectSettings.globalize_path("res://artifacts/visible-world-readiness-contract.json")
	var directory := path.get_base_dir()
	if directory != "": DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_passed = false
		push_error("could not write visual readiness contract report: " + path)
		return
	file.store_string(JSON.stringify({"schema": "visible-world-readiness-contract/v1",
		"complete": true, "passed": _passed and not _checks.is_empty(), "checkCount": _checks.size(),
		"failureCount": _checks.filter(func(row: Dictionary): return not bool(row.passed)).size(),
		"checks": _checks, "evidenceLevel": "synthetic_owner_receipt_contract",
		"scope": "Request, manifest coverage, tier, installation, revision, and candidate-accounting contracts; no live world visual acceptance."}, "\t"))
	file.close()
