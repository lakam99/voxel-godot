extends SceneTree

const Roster := preload("res://scripts/world/StaticSectionSourceRoster.gd")
const REPORT_ENV := "VOXEL_STATIC_SECTION_REMOVAL_CENSUS_REPORT"
const WORLD_ID := "seed:static-removal-census-contract"
const SECTION := Vector3i.ZERO

var checks: Dictionary = {}


class Provider extends RefCounted:
	var world_id := ""
	var live_part_id := ""
	var live_revision := ""
	var removals: Array[Dictionary] = []

	func capture_static_section_sources(request_world_id: String,
		sections: Array) -> Dictionary:
		if request_world_id != world_id or sections != [SECTION]:
			return {"status":"failed", "worldId":request_world_id,
				"reason":"unexpected_query"}
		var ids: Array[String] = []
		var revisions: Dictionary = {}
		if not live_part_id.is_empty():
			ids.append(live_part_id)
			revisions[live_part_id] = live_revision
		var row := {"status":"empty" if ids.is_empty() else "complete",
			"coverageRevision":"coverage:" + live_revision,
			"sourcePartIds":ids}
		var result := {"status":"complete", "worldId":world_id,
			"authorityRevision":"authority:" + live_revision,
			"sourceRevisions":revisions,
			"sections":{SECTION:row},
			"removalsBySection":{SECTION:removals}}
		return result


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var provider := Provider.new()
	provider.world_id = WORLD_ID
	provider.live_part_id = "ordinary:town-a:cell-0"
	provider.live_revision = "member-v1"
	var roster = Roster.new()
	var bound: Dictionary = roster.bind_world(WORLD_ID, ["ordinary"])
	var registered: Dictionary = roster.register_provider("ordinary", provider,
		"capture_static_section_sources")
	var initial: Dictionary = roster.capture_sections([SECTION])
	var initial_ok: bool = bound.get("status") == "ready" \
		and registered.get("status") == "ready" \
		and initial.get("status") == "complete" \
		and initial.expectedContributorsBySection.get(SECTION, []) == [provider.live_part_id] \
		and initial.removalRevisions.is_empty()
	_check("live_source_census_is_exact_before_removal", initial_ok, initial)

	provider.live_part_id = ""
	provider.live_revision = "member-v2"
	var tombstone := {"sourceId":"town:town-a", "sourcePartId":"ordinary:town-a:cell-0",
		"sourceRevision":"removed-v3", "sectionKey":SECTION,
		"reason":"durable_edit_removed_member"}
	tombstone.make_read_only()
	provider.removals = [tombstone]
	var removed: Dictionary = roster.capture_sections([SECTION])
	var removal_values: Array = removed.get("removalsBySection", {}).get(SECTION, [])
	var accepted_removal: Dictionary = removal_values[0] if not removal_values.is_empty() else {}
	var removed_ok: bool = removed.get("status") == "complete" \
		and removed.expectedContributorsBySection.get(SECTION, []).is_empty() \
		and removed.sourceRevisions.is_empty() \
		and removed.removalRevisions.get("ordinary:town-a:cell-0", "") == "removed-v3" \
		and accepted_removal.get("sourceId") == "town:town-a" \
		and accepted_removal.get("providerId") == "ordinary"
	_check("removed_source_is_revisioned_tombstone_not_live_contributor", removed_ok, removed)
	_check("tombstone_changes_census_digest", 
		String(initial.get("censusDigest", "")) != String(removed.get("censusDigest", "")),
		{"initial":initial.get("censusDigest", ""), "removed":removed.get("censusDigest", "")})
	_check("captured_tombstone_snapshot_revalidates", roster.is_snapshot_current(removed),
		{"snapshotCurrent":roster.is_snapshot_current(removed)})

	provider.live_part_id = "ordinary:town-a:cell-0"
	provider.live_revision = "member-v4"
	var contradictory: Dictionary = roster.capture_sections([SECTION])
	_check("current_contributor_cannot_also_be_a_tombstone",
		contradictory.get("status") == "failed"
		and contradictory.get("reason") == "invalid_or_current_static_source_removal",
		contradictory)

	_finish()


func _check(name: String, passed: bool, evidence: Variant) -> void:
	checks[name] = {"passed":passed, "evidence":evidence}


func _finish() -> void:
	var failed: Array[String] = []
	for name: String in checks:
		if not bool(checks[name].get("passed", false)):
			failed.append(name)
	var report := {"schema":"static-section-removal-census-contract/v1",
		"complete":true, "passed":failed.is_empty(), "checks":checks,
		"checkCount":checks.size(), "failedChecks":failed,
		"evidenceLevel":"synthetic_source_roster_tombstone_contract",
		"doesNotProve":"provider acknowledgement, coordinator/native installation, gameplay, persistence or performance."}
	var path := OS.get_environment(REPORT_ENV)
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	quit(0 if failed.is_empty() else 1)
