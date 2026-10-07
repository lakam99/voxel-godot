extends SceneTree
## Synthetic value-contract coverage. No live renderer, gameplay or retirement proof.

const Completion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var compatibility := {"meshContentDigest":"mesh-a".sha256_text(),
		"meshResourceKey":"mesh:a", "materialKey":"material:a",
		"pipelineRevision":"pipeline:1", "renderLayer":"opaque",
		"translucentSortPolicy":"none", "renderTier":"near", "castShadows":true,
		"visibilityRangeEnd":128.0, "fadeMargin":8.0}
	var bounds := AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	var buffer: Array[float] = []
	buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3(2, 4, 6)),
		Color(0.2, 0.3, 0.4, 0.5), Color(0.6, 0.7, 0.8, 0.9)))
	buffer.make_read_only()
	var first := Completion.packed_member("building", "part", "revision-1",
		"segment-a", 0, Vector3i.ZERO, bounds, buffer, 0, compatibility)
	var second := Completion.packed_member("building", "part", "revision-1",
		"segment-b", 0, Vector3i(1, 0, 0), bounds, buffer, 0, compatibility)
	var sealed := Completion.seal("world", "building", "part", "revision-1",
		"publisher-1", [first, second])
	var roster: Dictionary = sealed.get("roster", {})
	checks["complete_two_owner_roster_is_valid"] = sealed.get("status") == "ready" \
		and Completion.validate(roster) and roster.get("members", []).size() == 2
	checks["exact_installed_union_accepts_any_member_order"] = _ready(roster, [second, first])
	checks["missing_owner_member_is_pending"] = not _ready(roster, [first])
	checks["duplicate_owner_member_is_pending"] = not _ready(roster, [first, first, second])
	checks["extra_owner_member_is_pending"] = not _ready(roster, [first, second,
		_changed(first, "sourceSegmentId", "unexpected-segment")])
	checks["owner_sections_are_unique_and_sorted"] = Completion.owner_sections(roster) \
		== [Vector3i.ZERO, Vector3i(1, 0, 0)]
	for field: String in ["sourceId", "sourcePartId", "sourceRevision", "sourceSegmentId"]:
		checks["installed_" + field + "_change_rejected"] = not _ready(roster,
			[_changed(first, field, "different"), second])
	for field: String in ["meshContentDigest", "attributesDigest", "renderPolicyDigest"]:
		checks["installed_" + field + "_change_rejected"] = not _ready(roster,
			[_changed(first, field, "different".sha256_text()), second])
	checks["changed_instance_identity_rejected"] = not _ready(roster,
		[_changed(first, "sourceInstance", 1), second])
	checks["changed_owner_rejected"] = not _ready(roster,
		[_changed(first, "geometryOwnerSection", Vector3i(5, 0, 0)), second])
	checks["changed_bounds_rejected"] = not _ready(roster,
		[_changed(first, "worldBounds", AABB(Vector3.ONE, Vector3.ONE)), second])
	checks["mutable_installed_row_rejected"] = not _ready(roster, [first.duplicate(), second])
	checks["malformed_installed_row_rejected"] = not _ready(roster, [42, second])
	checks["duplicate_expected_member_rejected"] = Completion.seal("world", "building",
		"part", "revision-1", "publisher-1", [first, first]).get("status") != "ready"
	checks["mixed_expected_revision_rejected"] = Completion.seal("world", "building",
		"part", "revision-1", "publisher-1", [first,
		_changed(second, "sourceRevision", "revision-2")]).get("status") != "ready"
	checks["unproven_empty_roster_rejected"] = Completion.seal("world", "building",
		"part", "revision-1", "publisher-1", []).get("status") != "ready"
	var removed := Completion.seal("world", "building", "part", "revision-2",
		"publisher-1", [], true)
	checks["explicit_removal_accepts_exact_empty_union"] = removed.get("status") == "ready" \
		and _ready(removed.get("roster", {}), [])
	checks["explicit_removal_rejects_retained_geometry"] = not _ready(removed.get("roster", {}), [first])
	checks["nonempty_explicit_removal_rejected"] = Completion.seal("world", "building",
		"part", "revision-1", "publisher-1", [first], true).get("status") != "ready"
	checks["mutable_roster_rejected"] = not Completion.validate(roster.duplicate())
	for field: String in ["worldId", "sourceId", "sourcePartId", "sourceRevision", "sourceIncarnation", "digest"]:
		checks["roster_" + field + "_tamper_rejected"] = not Completion.validate(
			_changed(roster, field, "tampered"))
	var reversed := Completion.seal("world", "building", "part", "revision-1",
		"publisher-1", [second, first])
	checks["roster_digest_independent_of_member_enumeration"] = reversed.get("roster", {}) == roster
	for lane: int in [3, Attributes.COLOR_OFFSET, Attributes.CUSTOM_DATA_OFFSET]:
		var changed_buffer: Array[float] = buffer.duplicate()
		changed_buffer[lane] += 0.125
		changed_buffer.make_read_only()
		var changed_member := Completion.packed_member("building", "part", "revision-1",
			"segment-a", 0, Vector3i.ZERO, bounds, changed_buffer, 0, compatibility)
		checks["packed_lane_%d_changes_member_proof" % lane] = not changed_member.is_empty() \
			and changed_member.get("attributesDigest") != first.get("attributesDigest") \
			and not _ready(roster, [changed_member, second])
	for policy: String in ["materialKey", "pipelineRevision", "renderLayer", "translucentSortPolicy", "renderTier", "castShadows"]:
		var changed_policy := compatibility.duplicate()
		changed_policy[policy] = false if policy == "castShadows" else "different"
		var changed_member := Completion.packed_member("building", "part", "revision-1",
			"segment-a", 0, Vector3i.ZERO, bounds, buffer, 0, changed_policy)
		checks["render_policy_" + policy + "_is_bound"] = not changed_member.is_empty() \
			and not _ready(roster, [changed_member, second])
	for policy: String in ["visibilityRangeEnd", "fadeMargin"]:
		var changed_policy := compatibility.duplicate()
		changed_policy[policy] = float(changed_policy[policy]) + 4.0
		var changed_member := Completion.packed_member("building", "part", "revision-1",
			"segment-a", 0, Vector3i.ZERO, bounds, buffer, 0, changed_policy)
		checks["render_policy_" + policy + "_is_bound"] = not changed_member.is_empty() \
			and not _ready(roster, [changed_member, second])
	var installed_compatibility := compatibility.duplicate()
	installed_compatibility["meshKey"] = "native-batch-local-key"
	var installed_member := Completion.packed_member("building", "part", "revision-1",
		"segment-a", 0, Vector3i.ZERO, bounds, buffer, 0, installed_compatibility)
	checks["canonical_mesh_resource_key_survives_batch_key_normalization"] = installed_member == first
	installed_compatibility["meshResourceKey"] = "different-resource"
	installed_member = Completion.packed_member("building", "part", "revision-1",
		"segment-a", 0, Vector3i.ZERO, bounds, buffer, 0, installed_compatibility)
	checks["changed_canonical_mesh_resource_key_rejected"] = not installed_member.is_empty() \
		and not _ready(roster, [installed_member, second])
	for sort_policy: String in ["none", "camera_depth"]:
		var producer_policy := compatibility.duplicate()
		producer_policy["translucentSortPolicy"] = sort_policy
		var canonical_batch := producer_policy.duplicate()
		canonical_batch["transparencySortPolicy"] = sort_policy
		canonical_batch.erase("translucentSortPolicy")
		canonical_batch["meshKey"] = canonical_batch.meshResourceKey
		canonical_batch.erase("meshResourceKey")
		var producer_member := Completion.packed_member("building", "part", "revision-1",
			"segment-a", 0, Vector3i.ZERO, bounds, buffer, 0, producer_policy)
		var canonical_member := Completion.packed_member("building", "part", "revision-1",
			"segment-a", 0, Vector3i.ZERO, bounds, buffer, 0, canonical_batch)
		checks["canonical_batch_sort_policy_" + sort_policy + "_matches_producer"] = \
			not producer_member.is_empty() and producer_member == canonical_member
	var nonfinite: Array[float] = buffer.duplicate()
	nonfinite[0] = NAN
	checks["nonfinite_attributes_rejected"] = Completion.packed_member("building", "part",
		"revision-1", "segment-a", 0, Vector3i.ZERO, bounds, nonfinite, 0, compatibility).is_empty()
	checks["short_attribute_buffer_rejected"] = Completion.packed_member("building", "part",
		"revision-1", "segment-a", 0, Vector3i.ZERO, bounds, [1.0], 0, compatibility).is_empty()
	# Independent projection using the published instance ABI, including a large
	# world origin: exact stored floats must agree without a widened tolerance.
	var source_transform := Transform3D(Basis.IDENTITY, Vector3(4302.58, 37.8, -7380.37))
	var captured := Completion.capture_member("building", "part", "revision-1",
		"segment-a", 0, source_transform, bounds, buffer, 0, compatibility)
	var world_transform := source_transform * Attributes.decode_transform(buffer, 0)
	var section := Grid.key_for_world_position((world_transform * bounds).get_center())
	var local := Transform3D(Basis.IDENTITY, -Grid.origin_for_key(section)) * world_transform
	var encoded: Array[float] = Attributes.encode_transform(local, buffer, 0,
		Color(buffer[12], buffer[13], buffer[14], buffer[15]))
	var expected := Completion.packed_member("building", "part", "revision-1",
		"segment-a", 0, section, bounds, encoded, 0, compatibility)
	checks["large_world_capture_matches_canonical_packed_attributes"] = not captured.is_empty() and captured == expected
	var passed := true
	for value: Variant in checks.values(): passed = passed and value == true
	var report := {"schema":"static-geometry-owner-completion-contract/v1",
		"evidence":"synthetic_value_contract", "passed":passed, "checks":checks,
		"doesNotProve":"Native installation, provider retirement, collision, traversal, saves or live performance."}
	var report_path := OS.get_environment("STATIC_GEOMETRY_OWNER_COMPLETION_REPORT")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write owner completion contract report")
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print(JSON.stringify(report))
	quit(0 if passed else 1)


func _ready(roster: Dictionary, installed: Array) -> bool:
	return Completion.compare_installed_members(roster, installed).get("status") == "ready"


func _changed(value: Dictionary, key: String, replacement: Variant) -> Dictionary:
	var changed := value.duplicate(false)
	changed[key] = replacement
	changed.make_read_only()
	return changed
