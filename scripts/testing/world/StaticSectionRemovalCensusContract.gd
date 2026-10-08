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


class SectionProvider extends RefCounted:
	var live_section := Vector3i(1, 0, 0)
	var removed_section := Vector3i.ZERO
	var live_revision := "move-r2"
	var removal_revision := "move-r2"
	var include_live := true
	var include_removal := true

	func capture_static_section_sources(world: String, sections: Array) -> Dictionary:
		var rows: Dictionary = {}
		var revisions: Dictionary = {}
		var removals: Dictionary = {}
		for section: Vector3i in sections:
			var ids: Array[String] = []
			if include_live and section == live_section:
				ids.append("moving-member")
				revisions["moving-member"] = live_revision
			rows[section] = {"status":"empty" if ids.is_empty() else "complete",
				"sourcePartIds":ids, "coverageRevision":"coverage:%s:%s" % [section, live_revision]}
			if include_removal and section == removed_section:
				removals[section] = [{"sourceId":"moving-member", "sourcePartId":"moving-member",
					"sourceRevision":removal_revision, "sectionKey":section}]
		return {"status":"complete", "worldId":world,
			"authorityRevision":"authority:%s" % live_revision,
			"sourceRevisions":revisions, "sections":rows, "removalsBySection":removals}


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
		and initial.expectedContributorsBySection.get(SECTION, []) == [_identity(provider.live_part_id)] \
		and initial.removalRevisions.is_empty()
	_check("live_source_census_is_exact_before_removal", initial_ok, initial)

	provider.live_part_id = ""
	provider.live_revision = "member-v2"
	var tombstone := {"sourceId":"ordinary:town-a:cell-0", "sourcePartId":"ordinary:town-a:cell-0",
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
		and removed.removalRevisions.get(_identity("ordinary:town-a:cell-0"), "") == "removed-v3" \
		and accepted_removal.get("sourceId") == "ordinary:town-a:cell-0" \
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
	var moving := SectionProvider.new()
	var moving_roster = Roster.new()
	moving_roster.bind_world(WORLD_ID, ["building"])
	moving_roster.register_provider("building", moving, "capture_static_section_sources")
	var moved: Dictionary = moving_roster.capture_sections([SECTION, moving.live_section])
	_check("member_can_move_with_one_authority_revision_and_section_scoped_removal",
		moved.get("status") == "complete"
		and moved.get("expectedContributorsBySection", {}).get(SECTION, []).is_empty()
		and moved.get("expectedContributorsBySection", {}).get(moving.live_section, []) == [_identity("moving-member")]
		and moved.get("removalsBySection", {}).get(SECTION, []).size() == 1
		and moved.get("removalsBySection", {}).get(moving.live_section, []).is_empty(), moved)
	moving.removal_revision = "stale-move-r1"
	var stale_move: Dictionary = moving_roster.capture_sections([SECTION, moving.live_section])
	_check("stale_departure_cannot_share_current_member_identity",
		stale_move.get("status") == "failed", stale_move)
	moving.removal_revision = moving.live_revision
	moving.removed_section = moving.live_section
	var same_section: Dictionary = moving_roster.capture_sections([SECTION, moving.live_section])
	_check("same_section_current_and_removed_remains_contradictory",
		same_section.get("status") == "failed", same_section)
	moving.include_removal = false
	var foreign := SectionProvider.new()
	foreign.include_live = false
	var foreign_roster = Roster.new()
	foreign_roster.bind_world(WORLD_ID, ["a-remover", "z-builder"])
	foreign_roster.register_provider("a-remover", foreign, "capture_static_section_sources")
	foreign_roster.register_provider("z-builder", moving, "capture_static_section_sources")
	var foreign_move: Dictionary = foreign_roster.capture_sections([SECTION, moving.live_section])
	_check("another_provider_cannot_remove_a_live_member_even_at_equal_revision",
		foreign_move.get("status") == "failed", foreign_move)

	_finish()


func _identity(source_id: String) -> String:
	return "section-part:" + var_to_bytes([source_id, source_id]).hex_encode()


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
