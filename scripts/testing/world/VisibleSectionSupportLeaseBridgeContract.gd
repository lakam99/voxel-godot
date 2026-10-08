extends SceneTree

const Bridge := preload("res://scripts/world/VisibleSectionSupportLeaseBridge.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const REPORT_ENV := "VISIBLE_SECTION_SUPPORT_LEASE_BRIDGE_REPORT"

var checks: Dictionary = {}
var bridge: RefCounted = Bridge.new()
var provider: RefCounted
var world_id := "seed:visible-support-lease-contract"
var section_a := Vector3i(0, 0, 0)
var section_b := Vector3i(0, 0, 1)


class Provider extends RefCounted:
	var pending_sections: Dictionary = {}
	var lease_revisions: Dictionary = {}
	var owner_section := Vector3i(4, 0, 0)

	func query_section(world_id: String, section_key: Vector3i) -> Dictionary:
		if pending_sections.has(section_key):
			return {"status":"pending", "retryable":true}
		var revision := String(lease_revisions.get(section_key, "r1"))
		var token := "token:%s:%s" % [str(section_key), revision]
		var lease := {"schema":"ecology-support-owner-lease/v1",
			"worldId":world_id, "sourceIndexRevision":"7",
			"coverageDigest":"a".repeat(64), "supportSectionKey":section_key,
			"sourceChunkKey":Vector2i.ZERO, "sourceChunkOwnerGeneration":1,
			"sourceChunkOwnerInstanceId":11, "sourceId":"tree:oak:1",
			"sourceRevision":revision, "sourceDomainRevision":"domain-r1",
			"producerSnapshotRevision":"producer-r1", "memberId":"tree:oak:1",
			"recipeArtifactGeneration":2, "ownerSectionKey":owner_section,
			"supportLeaseToken":token, "state":"compiled"}
		lease.make_read_only()
		var contributors: Array = [{"sourceId":"tree:oak:1", "sourceRevision":revision,
			"state":"compiled"}]
		contributors[0].make_read_only()
		contributors.make_read_only()
		var domains: Array = []
		domains.make_read_only()
		var certificate := {"schema":"ecology-source-domain-coverage/v1",
			"worldId":world_id, "sectionKey":section_key,
			"sourceIndexRevision":7, "coverageDigest":"a".repeat(64),
			"sourceDomains":domains}
		certificate.make_read_only()
		var leases: Array = [lease]
		leases.make_read_only()
		var query := {"status":"ready", "schema":"ecology-world-support-query/v1",
			"worldId":world_id, "sectionKey":section_key,
			"sourceIndexRevision":7, "coverageCertificate":certificate,
			"contributors":contributors, "supportOwnerDemands":leases}
		query.make_read_only()
		return query

	func validate_coverage_certificate(_certificate: Dictionary,
			_query_world_id: String, _section_key: Vector3i) -> Dictionary:
		return {"status":"ready"}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	provider = Provider.new()
	var first := _manifest(1, [section_a, section_b])
	var initial: Dictionary = bridge.reconcile_view("player", first, provider)
	var initial_snapshots: Dictionary = bridge.required_section_snapshots("player")
	_check("complete_exact_section_set_admitted_independently",
		initial.get("status") == "ready"
		and initial_snapshots.get("accepted", {}).is_empty()
		and initial_snapshots.get("pending", {}).size() == 2,
		{"result":initial, "snapshots":initial_snapshots})
	var owners: Dictionary = bridge.owner_demand_cells("player")
	_check("visible_sections_and_member_leases_retain_canonical_static_owner_cells",
		owners.has(Grid.chunk_key_for_section(owner_section))
		and owners.has(Grid.chunk_key_for_section(section_a))
		and owners.has(Grid.chunk_key_for_section(section_b)), owners)
	var snapshot_a: Dictionary = initial_snapshots.pending[section_a]
	_check("query_snapshot_and_lease_are_immutable",
		snapshot_a.is_read_only()
		and snapshot_a.get("supportOwnerDemands", [])[0].is_read_only()
		and snapshot_a.get("coverageCertificate", {}).is_read_only(), snapshot_a)
	_check("first_slot_promotes_only_by_exact_receipt_identity",
		bridge.promote_section("player", section_a, String(snapshot_a.snapshotDigest))
		and bridge.required_section_snapshots("player").get("accepted", {}).has(section_a),
		snapshot_a)
	provider.pending_sections[section_a] = true
	provider.lease_revisions[section_b] = "r2"
	var next := _manifest(2, [section_a, section_b])
	var advanced: Dictionary = bridge.reconcile_view("player", next, provider)
	var next_snapshots: Dictionary = bridge.required_section_snapshots("player")
	_check("one_pending_slot_holds_its_previous_lease_while_other_advances",
		advanced.get("status") == "pending"
		and next_snapshots.get("accepted", {}).has(section_a)
		and next_snapshots.get("pending", {}).has(section_b)
		and String(next_snapshots.pending[section_b].supportOwnerDemands[0].sourceRevision) == "r2",
		{"result":advanced, "snapshots":next_snapshots})
	var snapshot_b: Dictionary = next_snapshots.pending[section_b]
	_check("changed_slot_promotes_without_waiting_for_unrelated_pending_slot",
		bridge.promote_section("player", section_b, String(snapshot_b.snapshotDigest))
		and bridge.required_section_snapshots("player").get("accepted", {}).has(section_b),
		snapshot_b)
	provider.pending_sections.erase(section_a)
	var shrunken := _manifest(3, [section_b])
	bridge.reconcile_view("player", shrunken, provider)
	var final_snapshots: Dictionary = bridge.required_section_snapshots("player")
	_check("complete_new_manifest_releases_only_sections_it_removed",
		not final_snapshots.get("accepted", {}).has(section_a)
		and final_snapshots.get("accepted", {}).has(section_b), final_snapshots)
	_finish()


func _manifest(view_revision: int, keys: Array[Vector3i]) -> Dictionary:
	var frozen_keys: Array[Vector3i] = keys.duplicate()
	frozen_keys.make_read_only()
	var value := {"status":"ready", "schema":"voxel-terrain-required-section-set/v1",
		"requestId":1, "seed":"contract", "worldRevision":"world-r1",
		"viewRevision":view_revision, "demandRevision":view_revision,
		"centerCells":Vector3.ZERO, "radiusCells":100,
		"worldId":world_id, "viewOwner":"player", "sectionKeys":frozen_keys}
	value.make_read_only()
	return value


func _check(name: String, passed: bool, detail: Variant) -> void:
	checks[name] = {"passed":passed, "detail":detail}


func _finish() -> void:
	var failures := 0
	for value: Variant in checks.values():
		if not bool(value.get("passed", false)): failures += 1
	var report := {"schema":"visible-section-support-lease-bridge-contract/v1",
		"passed":failures == 0, "failureCount":failures,
		"checks":checks,
		"evidence":"Synthetic bridge contract only; no native install or live renderer acceptance."}
	var report_path := OS.get_environment(REPORT_ENV)
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	if failures > 0: quit(1)
	else: quit(0)
