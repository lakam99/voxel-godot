extends SceneTree
## Value contract for exhaustive, section-local slices. No producer cutover or renderer proof.

const Completion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const Slices := preload("res://scripts/world/StaticGeometryOwnerSectionSlice.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var member_a := _member("seg-a", Vector3i(4, 0, -2))
	var member_b := _member("seg-b", Vector3i(4, 0, -2))
	var member_c := _member("seg-c", Vector3i(5, 0, -2))
	var sealed := Completion.seal("world-a", "building:citadel", "tower-foundation",
		"revision-17", "publisher-incarnation-3", [member_c, member_a, member_b])
	var roster: Dictionary = sealed.get("roster", {})
	var sections: Array[Vector3i] = [Vector3i(4, 0, -2), Vector3i(5, 0, -2), Vector3i(6, 0, -2)]
	var partition_result := Slices.partition(roster, sections)
	var partition: Dictionary = partition_result.get("partition", {})
	var split_slices: Array = partition.get("slices", [])
	var local_slice_result := Slices.for_section(roster, Vector3i(4, 0, -2))
	var local_slice: Dictionary = local_slice_result.get("slice", {})
	var local_current_slice_result := Slices.for_validated_roster_section(roster,
		Vector3i(4, 0, -2))
	var local_current_slice: Dictionary = local_current_slice_result.get("slice", {})
	var empty_slice_result := Slices.for_section(roster, Vector3i(6, 0, -2))
	var empty_slice: Dictionary = empty_slice_result.get("slice", {})
	checks["requested_section_slice_excludes_distant_parent_members"] = \
		local_slice_result.get("status") == "ready" and local_slice.members.size() == 2 \
		and local_slice.members.all(func(member: Dictionary) -> bool:
			return member.get("geometryOwnerSection") == Vector3i(4, 0, -2)) \
		and Slices.validate_slice(roster, local_slice)
	checks["validated_parent_fast_path_matches_verified_slice"] = \
		local_current_slice_result.get("status") == "ready" \
		and local_current_slice == local_slice \
		and Slices.validate_slice_for_validated_roster(roster, local_current_slice)
	var changed_parent := Completion.seal("world-a", "building:citadel", "tower-foundation",
		"revision-18", "publisher-incarnation-3", [
		_member("seg-a", Vector3i(4, 0, -2), "revision-18"),
		_member("seg-b", Vector3i(4, 0, -2), "revision-18"),
		_member("seg-c", Vector3i(5, 0, -2), "revision-18")])
	checks["cached_slice_rebinds_only_to_its_exact_current_parent"] = \
		Slices.validate_cached_slice_for_parent(roster, local_current_slice) \
		and not Slices.validate_cached_slice_for_parent(changed_parent.roster, local_current_slice)
	checks["requested_nonowner_section_is_a_valid_explicit_empty"] = \
		empty_slice_result.get("status") == "ready" and empty_slice.sectionEmpty \
		and empty_slice.members.is_empty() and Slices.validate_slice(roster, empty_slice)
	checks["complete_roster_partitions_into_declared_sections"] = sealed.get("status") == "ready" \
		and partition_result.get("status") == "ready" \
		and Slices.validate_partition(roster, partition, sections)
	checks["same_section_members_are_grouped_without_splitting_identity"] = split_slices.size() == 3 \
		and split_slices[0].members.size() == 2 and split_slices[1].members.size() == 1
	checks["declared_section_without_members_is_explicit_empty"] = split_slices.size() == 3 \
		and split_slices[2].sectionEmpty and split_slices[2].members.is_empty() \
		and not split_slices[2].sourceRemoved
	checks["partition_is_input_order_independent"] = Slices.partition(roster,
		[Vector3i(6, 0, -2), Vector3i(5, 0, -2), Vector3i(4, 0, -2)]).get("partition", {}) == partition
	checks["missing_member_owner_section_rejected"] = Slices.partition(roster,
		[Vector3i(4, 0, -2)]).get("status") == "pending"
	checks["duplicate_expected_section_rejected"] = Slices.partition(roster,
		[Vector3i(4, 0, -2), Vector3i(4, 0, -2), Vector3i(5, 0, -2)]).get("status") == "failed"
	checks["duplicate_slice_member_rejected"] = not _partition_with_slices(roster, partition,
		[split_slices[0].duplicate(false), split_slices[1], split_slices[2]], sections)
	checks["omitted_slice_rejected"] = not _partition_with_slices(roster, partition,
		[split_slices[0], split_slices[1]], sections)
	checks["tampered_slice_digest_rejected"] = not Slices.validate_slice(roster,
		_changed(split_slices[0], "digest", "0".repeat(64)))
	checks["changed_parent_incarnation_rejected"] = not Slices.validate_slice(
		Completion.seal("world-a", "building:citadel", "tower-foundation", "revision-17",
		"publisher-incarnation-4", [member_c, member_a, member_b]).roster, split_slices[0])
	checks["changed_parent_revision_rejected"] = not Slices.validate_slice(
		Completion.seal("world-a", "building:citadel", "tower-foundation", "revision-18",
		"publisher-incarnation-3", [_member("seg-a", Vector3i(4, 0, -2), "revision-18"),
		_member("seg-b", Vector3i(4, 0, -2), "revision-18"),
		_member("seg-c", Vector3i(5, 0, -2), "revision-18")]).roster, split_slices[0])
	checks["changed_parent_source_identity_rejected"] = not Slices.validate_slice(
		Completion.seal("world-a", "building:citadel:replacement", "tower-foundation", "revision-17",
		"publisher-incarnation-3", [_member("seg-a", Vector3i(4, 0, -2), "revision-17", "building:citadel:replacement"),
		_member("seg-b", Vector3i(4, 0, -2), "revision-17", "building:citadel:replacement"),
		_member("seg-c", Vector3i(5, 0, -2), "revision-17", "building:citadel:replacement")]).roster, split_slices[0])
	checks["wrong_owner_member_rejected"] = not Slices.validate_slice(roster,
		_slice_with_members(split_slices[0], [member_a, member_c]))
	var removal := Completion.seal("world-a", "building:citadel", "tower-foundation",
		"revision-18", "publisher-incarnation-3", [], true)
	var removal_result := Slices.partition(removal.roster, [Vector3i(4, 0, -2), Vector3i(5, 0, -2)])
	var removal_partition: Dictionary = removal_result.get("partition", {})
	var local_removal := Slices.for_section(removal.roster, Vector3i(4, 0, -2))
	checks["explicit_source_removal_has_empty_tombstone_for_each_owner"] = removal_result.get("status") == "ready" \
		and removal_partition.slices.size() == 2 \
		and removal_partition.slices.all(func(row: Dictionary) -> bool:
			return row.sectionEmpty and row.sourceRemoved and row.members.is_empty()) \
		and Slices.validate_partition(removal.roster, removal_partition)
	checks["section_removal_query_returns_only_the_requested_tombstone"] = \
		local_removal.get("status") == "ready" \
		and Slices.validate_slice(removal.roster, local_removal.get("slice", {})) \
		and local_removal.slice.sectionEmpty and local_removal.slice.sourceRemoved
	checks["unscoped_source_removal_is_pending"] = Slices.partition(removal.roster, []).get("status") == "pending"
	var passed := true
	for value: Variant in checks.values(): passed = passed and value == true
	var report := {"schema":"static-geometry-owner-section-slice-contract/v1",
		"evidence":"synthetic_value_contract", "passed":passed, "checkCount":checks.size(),
		"checks":checks, "sourceIncarnation":roster.get("sourceIncarnation", ""),
		"parentRosterDigest":roster.get("digest", ""),
		"doesNotProve":"Producer integration, native installation, visual continuity, collision, traversal, saves or performance."}
	var report_path := OS.get_environment("STATIC_GEOMETRY_OWNER_SECTION_SLICE_REPORT")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write section slice contract report")
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print(JSON.stringify(report))
	quit(0 if passed else 1)


func _member(segment: String, section: Vector3i, revision := "revision-17",
		source_id := "building:citadel") -> Dictionary:
	var compatibility := {"meshContentDigest":"mesh-content".sha256_text(),
		"meshResourceKey":"mesh:stone", "materialKey":"material:stone",
		"pipelineRevision":"pipeline:1", "renderLayer":"opaque",
		"translucentSortPolicy":"none", "renderTier":"near", "castShadows":true,
		"visibilityRangeEnd":128.0, "fadeMargin":8.0}
	var bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	var buffer: Array[float] = []
	buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3(2, 2, 2)),
		Color.WHITE, Color.WHITE))
	buffer.make_read_only()
	return Completion.packed_member(source_id, "tower-foundation", revision,
		segment, 0, section, bounds, buffer, 0, compatibility)


func _partition_with_slices(roster: Dictionary, original: Dictionary, slices: Array,
		expected: Array) -> bool:
	var copy := original.duplicate(false)
	copy["slices"] = slices
	var payload := copy.duplicate(false)
	payload.erase("digest")
	payload.make_read_only()
	copy["digest"] = Marshalls.raw_to_base64(var_to_bytes(payload)).sha256_text()
	copy.make_read_only()
	return Slices.validate_partition(roster, copy, expected)


func _slice_with_members(slice: Dictionary, members: Array) -> Dictionary:
	var copy := slice.duplicate(false)
	copy["members"] = members
	copy.make_read_only()
	return copy


func _changed(value: Dictionary, key: String, replacement: Variant) -> Dictionary:
	var copy := value.duplicate(false)
	copy[key] = replacement
	copy.make_read_only()
	return copy
