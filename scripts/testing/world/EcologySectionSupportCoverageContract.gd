extends SceneTree

const EcologyAdapter := preload("res://scripts/world/EcologySectionValueAdapter.gd")
const SectionSnapshot := preload("res://scripts/world/ChunkStaticRenderSectionSnapshot.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const REPORT_ENV := "VOXEL_ECOLOGY_SECTION_SUPPORT_REPORT"
const WORLD := "seed:ecology-section-support-contract"
const OWNER_SECTION := Vector3i.ZERO
const SUPPORT_SECTION := Vector3i(1, 0, 0)

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var adapter := EcologyAdapter.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(10.0, 1.0, 1.0)
	var candidate := _candidate("prop-source", "prop-1", Transform3D(Basis.IDENTITY,
		Vector3(18.0, 2.0, 2.0)), mesh)
	var capture := _capture_support(adapter, candidate, mesh)
	var support_by_section: Dictionary = capture.get("supportRangesBySection", {})
	var owner_rows: Array = support_by_section.get(OWNER_SECTION, [])
	var adjacent_rows: Array = support_by_section.get(SUPPORT_SECTION, [])
	_check("transformed_bounds_cover_center_owner_and_adjacent_support",
		capture.get("status") == "ready" and support_by_section.size() == 2
		and owner_rows.size() == 1 and adjacent_rows.size() == 1
		and owner_rows[0].get("geometryOwnerSection") == OWNER_SECTION
		and adjacent_rows[0].get("geometryOwnerSection") == OWNER_SECTION
		and adjacent_rows[0].get("supportSectionKey") == SUPPORT_SECTION,
		{"capture":capture, "ownerRows":owner_rows.size(), "adjacentRows":adjacent_rows.size()})
	if capture.get("status") != "ready" or owner_rows.size() != 1 \
			or adjacent_rows.size() != 1:
		# Preserve the direct admission reason in the report rather than crashing
		# while a later assertion indexes a missing support row.
		_finish()
		return
	var support_contributor := _support_contributor(adjacent_rows[0], SUPPORT_SECTION)
	var support_contributors: Array = [support_contributor]
	support_contributors.make_read_only()
	var support_snapshot: Dictionary = SectionSnapshot.assemble(SUPPORT_SECTION,
		support_contributors)
	var support_manifest: Array = support_snapshot.get("snapshot", {}).get("manifest", [])
	_check("support_only_manifest_has_bounds_owner_and_no_geometry",
		support_snapshot.get("status") == "ready" and support_manifest.size() == 1
		and support_manifest[0].get("contributorKind") == "support_only"
		and support_manifest[0].get("ranges", []).is_empty()
		and support_manifest[0].get("supportRanges", []).size() == 1
		and support_snapshot.get("snapshot", {}).get("batchCount") == 0,
		{"result":support_snapshot, "manifest":support_manifest})

	var small_candidate := _candidate("small-prop", "prop-small",
		Transform3D(Basis.IDENTITY, Vector3(10.0, 2.0, 2.0)), mesh)
	var small_capture := _capture_support(adapter, small_candidate, mesh)
	var small_sections: Dictionary = small_capture.get("supportRangesBySection", {})
	_check("non_overlapping_prop_has_single_section_membership",
		small_capture.get("status") == "ready" and small_sections.size() == 1
		and small_sections.has(OWNER_SECTION),
		{"capture":small_capture})

	var current_row: Dictionary = adjacent_rows[0]
	var current_revision := String(current_row.get("sourceRevision", ""))
	var current_source_id := String(current_row.get("sourceId", ""))
	var current_source_part_id := String(current_row.get("sourcePartId", ""))
	var current_valid: bool = SectionSnapshot._validate_support_range(current_row,
		SUPPORT_SECTION, current_source_id, current_source_part_id, current_revision)
	var stale_row: Dictionary = current_row.duplicate(false)
	stale_row["sourceRevision"] = "stale-r0"
	stale_row.make_read_only()
	var stale_valid: bool = SectionSnapshot._validate_support_range(stale_row,
		SUPPORT_SECTION, current_source_id, current_source_part_id, current_revision)
	_check("support_receipt_proof_uses_distinct_v2_source_and_part_identity",
		current_source_id == "prop-source" and current_source_part_id == "member-0"
		and current_valid and not stale_valid,
		{"currentValid":current_valid, "staleValid":stale_valid,
			"sourceId":current_source_id, "sourcePartId":current_source_part_id,
			"currentRevision":current_revision})
	var same_revision_removal := adapter._support_footprint_removal_revision(WORLD,
		SUPPORT_SECTION, "prop-source", adjacent_rows, "prop-source", adjacent_rows,
		current_revision)
	var changed_candidate := _candidate("prop-source", "prop-1",
		Transform3D(Basis.IDENTITY, Vector3(18.0, 2.0, 2.0)), mesh)
	changed_candidate["contentRevision"] = "candidate-r2"
	var changed_capture := _capture_support(adapter, changed_candidate, mesh)
	var changed_rows: Array = changed_capture.get("supportRangesBySection", {}).get(
		SUPPORT_SECTION, [])
	var replacement_revision := String(changed_rows[0].get("sourceRevision", "")) \
		if not changed_rows.is_empty() else ""
	var removal_revision := adapter._support_footprint_removal_revision(WORLD,
		SUPPORT_SECTION, "prop-source", adjacent_rows, "prop-source", changed_rows,
		replacement_revision)
	var rehomed_candidate := _candidate("prop-source-rehomed", "prop-1",
		Transform3D(Basis.IDENTITY, Vector3(18.0, 2.0, 2.0)), mesh)
	var rehomed_capture := _capture_support(adapter, rehomed_candidate, mesh)
	var rehomed_rows: Array = rehomed_capture.get("supportRangesBySection", {}).get(
		SUPPORT_SECTION, [])
	var rehomed_revision := String(rehomed_rows[0].get("sourceRevision", "")) \
		if not rehomed_rows.is_empty() else ""
	var moved_source_removal := adapter._support_footprint_removal_revision(WORLD,
		SUPPORT_SECTION, "prop-source", adjacent_rows, "prop-source-rehomed",
		rehomed_rows, rehomed_revision)
	_check("support_footprint_removal_is_bound_to_old_and_replacement_revisions",
		removal_revision.length() == 64 and same_revision_removal.is_empty()
		and moved_source_removal.length() == 64 and moved_source_removal != removal_revision,
		{"removalRevision":removal_revision, "sameRevisionResult":same_revision_removal,
			"movedSourceRemovalRevision":moved_source_removal})

	var multi_mesh := BoxMesh.new()
	multi_mesh.size = Vector3(10.0, 1.0, 1.0)
	var multi_candidate := _multi_candidate(multi_mesh)
	var multi_capture := _capture_multi_support(adapter, multi_candidate, multi_mesh)
	var multi_prepared := _prepare_multi_support(adapter, multi_candidate, multi_mesh)
	var census_multi_rows: Dictionary = multi_capture.get("supportRangesBySection", {})
	var prepared_multi_rows: Dictionary = multi_prepared.get("supportRangesBySection", {})
	var digest_matches: bool = multi_capture.get("status") == "ready" \
		and multi_prepared.get("status") == "ready" \
		and census_multi_rows.size() == prepared_multi_rows.size()
	for section_value: Variant in census_multi_rows:
		var census_rows: Array = census_multi_rows[section_value]
		var prepared_source_map: Dictionary = prepared_multi_rows.get(section_value, {})
		var prepared_rows: Array = prepared_source_map.get("multi-prop", [])
		if EcologyAdapter._value_digest(census_rows) != EcologyAdapter._value_digest(prepared_rows):
			digest_matches = false
	var instances_by_member: Dictionary = {}
	var v2_identity_matches := true
	for rows_value: Variant in census_multi_rows.values():
		for row_value: Variant in rows_value:
			var row: Dictionary = row_value
			var member_id := String(row.get("memberId", ""))
			instances_by_member[member_id] = int(row.get("sourceInstance", -1))
			v2_identity_matches = v2_identity_matches \
				and String(row.get("sourceId", "")) == "multi-prop" \
				and String(row.get("sourcePartId", "")) == member_id \
				and SectionSnapshot._validate_support_range(row,
					Vector3i(row.get("supportSectionKey", Vector3i.ZERO)),
					"multi-prop", member_id, String(row.get("sourceRevision", "")))
	_check("two_member_census_and_contribution_support_digests_match",
		digest_matches and instances_by_member.get("member-0", -1) == 0
		and instances_by_member.get("member-1", -1) == 1 and v2_identity_matches,
		{"captureStatus":multi_capture.get("status"),
			"preparedStatus":multi_prepared.get("status"),
			"instancesByMember":instances_by_member,
			"v2IdentityMatches":v2_identity_matches,
			"censusSupport":census_multi_rows, "preparedSupport":prepared_multi_rows})

	var empty_contributor := _explicit_empty_contributor("prop-source", "member-0",
		String(current_row.get("sourceRevision", "")), SUPPORT_SECTION)
	var empty_contributors: Array = [empty_contributor]
	empty_contributors.make_read_only()
	var empty_replacement: Dictionary = SectionSnapshot.assemble(SUPPORT_SECTION,
		empty_contributors)
	var empty_manifest: Array = empty_replacement.get("snapshot", {}).get("manifest", [])
	_check("v2_member_removal_replacement_is_explicit_empty_not_missing_support",
		empty_replacement.get("status") == "ready" and empty_manifest.size() == 1
		and empty_manifest[0].get("contributorKind") == "explicit_empty"
		and empty_manifest[0].get("sourceId") == current_row.get("sourceId")
		and empty_manifest[0].get("sourcePartId") == current_row.get("sourcePartId")
		and empty_manifest[0].get("ranges", []).is_empty(),
		{"replacement":empty_replacement, "manifest":empty_manifest})
	_finish()


func _candidate(source_id: String, prop_id: String, body_transform: Transform3D,
		mesh: Mesh) -> Dictionary:
	var member_bounds := mesh.get_aabb()
	var member := {"memberId":"member-0", "transform":Transform3D.IDENTITY,
		"meshBounds":mesh.get_aabb(), "localBounds":member_bounds}
	var members: Array = [member]
	members.make_read_only()
	return {"sourceId":source_id, "propId":prop_id,
		"contentRevision":"candidate-r1", "category":"surface_rocks",
		"transform":body_transform,
		"renderMembers":members}


func _multi_candidate(mesh: Mesh) -> Dictionary:
	var members: Array = []
	var union_bounds := AABB()
	for member_index in range(2):
		var member_transform := Transform3D(Basis.IDENTITY,
			Vector3(-3.0 if member_index == 0 else 3.0, 0.0, 0.0))
		var member_bounds: AABB = member_transform * mesh.get_aabb()
		union_bounds = member_bounds if member_index == 0 else union_bounds.merge(member_bounds)
		members.append({"memberId":"member-%d" % member_index,
			"transform":member_transform, "localBounds":member_bounds,
			"meshBounds":mesh.get_aabb(),
			"meshContentDigest":"pending", "materialContentDigest":"pending",
			"materialKey":"contract:prop", "renderLayer":"opaque"})
	members.make_read_only()
	return {"sourceId":"multi-prop", "propId":"multi-prop-id",
		"kind":"realized_static_prop", "contentRevision":"multi-candidate-r1", "category":"surface_rocks",
		"renderStatus":"ready", "transform":Transform3D(Basis.IDENTITY,
			Vector3(18.0, 2.0, 2.0)), "localBounds":union_bounds,
		"renderMembers":members}


func _capture_support(adapter: Object, candidate: Dictionary, mesh: Mesh) -> Dictionary:
	var bindings := {String(candidate.sourceId) + "|member-0":{"mesh":mesh}}
	var source_snapshot := {"chunk":Vector2i.ZERO, "sourceRevision":"chunk-source-r1"}
	return adapter._static_prop_support_ranges(source_snapshot, candidate,
		Transform3D.IDENTITY, bindings, WORLD)


func _capture_multi_support(adapter: Object, candidate: Dictionary, mesh: Mesh) -> Dictionary:
	var bindings: Dictionary = {}
	for member_value: Variant in candidate.renderMembers:
		var member: Dictionary = member_value
		var binding := {"mesh":mesh}
		binding.make_read_only()
		bindings[String(candidate.sourceId) + "|" + String(member.memberId)] = binding
	bindings.make_read_only()
	var source_snapshot := {"chunk":Vector2i.ZERO, "sourceRevision":"chunk-source-r1"}
	return adapter._static_prop_support_ranges(source_snapshot, candidate,
		Transform3D.IDENTITY, bindings, WORLD)


func _prepare_multi_support(adapter: Object, candidate: Dictionary, mesh: Mesh) -> Dictionary:
	var fingerprint := MeshFingerprint.inspect(mesh)
	var mesh_digest := String(fingerprint.get("contentDigest", ""))
	var material := StandardMaterial3D.new()
	var material_digest := EcologyAdapter._material_digest(material)
	var bindings: Dictionary = {}
	var members: Array = []
	for member_value: Variant in candidate.renderMembers:
		var member: Dictionary = member_value.duplicate(false)
		member["meshContentDigest"] = mesh_digest
		member["materialContentDigest"] = material_digest
		member.make_read_only()
		members.append(member)
		var binding := {"mesh":mesh, "material":material,
			"materialKey":"contract:prop", "meshContentDigest":mesh_digest,
			"materialContentDigest":material_digest}
		binding.make_read_only()
		bindings[String(candidate.sourceId) + "|" + String(member.memberId)] = binding
	bindings.make_read_only()
	var prepared_candidate: Dictionary = candidate.duplicate(false)
	members.make_read_only()
	prepared_candidate["renderMembers"] = members
	prepared_candidate.make_read_only()
	var source_snapshot := {"chunk":Vector2i.ZERO, "sourceRevision":"chunk-source-r1",
		"candidates":[prepared_candidate]}
	var adapter_bindings := bindings.duplicate(false)
	adapter_bindings.make_read_only()
	return adapter._prepare_realized_static_props(source_snapshot, adapter_bindings,
		Transform3D.IDENTITY, WORLD, true, {})


func _support_contributor(row: Dictionary, section_key: Vector3i) -> Dictionary:
	var batches: Array = []
	batches.make_read_only()
	var ranges: Array = [row]
	ranges.make_read_only()
	var contributor := {"instanceAttributeLayout":SectionSnapshot.INSTANCE_ATTRIBUTE_LAYOUT,
		"sourceId":String(row.get("sourceId", "")),
		"sourcePartId":String(row.get("sourcePartId", "")),
		"sourceRevision":String(row.get("sourceRevision", "")),
		"ownerCell":Vector2i.ZERO, "sectionKey":section_key,
		"bufferSpace":"section_local", "contributorKind":"support_only",
		"supportRanges":ranges, "batches":batches}
	contributor.make_read_only()
	return contributor


func _explicit_empty_contributor(source_id: String, source_part_id: String,
		revision: String,
		section_key: Vector3i) -> Dictionary:
	var batches: Array = []
	batches.make_read_only()
	var ranges: Array = []
	ranges.make_read_only()
	var contributor := {"instanceAttributeLayout":SectionSnapshot.INSTANCE_ATTRIBUTE_LAYOUT,
		"sourceId":source_id, "sourcePartId":source_part_id,
		"sourceRevision":revision, "ownerCell":Vector2i.ZERO,
		"sectionKey":section_key, "bufferSpace":"section_local",
		"contributorKind":"explicit_empty", "supportRanges":ranges,
		"batches":batches}
	contributor.make_read_only()
	return contributor


func _check(name: String, passed: bool, evidence: Variant) -> void:
	checks[name] = {"passed":passed, "evidence":evidence}


func _finish() -> void:
	var failures: Array[String] = []
	for name: String in checks:
		if not bool(checks[name].get("passed", false)):
			failures.append(name)
	var report := {"schema":"ecology_section_support_coverage_contract/v1",
		"complete":true, "passed":failures.is_empty(), "checks":checks,
		"checkCount":checks.size(), "failedChecks":failures,
		"evidenceLevel":"synthetic_ecology_support_manifest_v2_identity_contract",
		"doesNotProve":"live Main census, coordinator invalidation, native install or receipt, legacy visual retirement, collision/interactions, save reload, or gameplay."}
	var path := OS.get_environment(REPORT_ENV)
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	quit(0 if failures.is_empty() else 1)
