extends RefCounted
## Value-only full-part geometry expectations. The producer supplies the complete
## admitted member set; installed rows are never used to invent that expectation.

const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SCHEMA := "static-geometry-owner-completion/v1"
const MAX_MEMBERS := 65536


static func capture_member(source_id: String, part_id: String, revision: String,
		segment_id: String, instance_index: int, source_to_world: Transform3D,
		mesh_bounds: AABB, buffer: Array, offset: int,
		compatibility: Dictionary) -> Dictionary:
	if offset < 0 or offset + Attributes.FLOATS_PER_INSTANCE > buffer.size(): return {}
	# This is the existing partitioner's owner-local conversion and attribute
	# encoder, including its Color conversion. No independent transform tolerance.
	var world_transform := source_to_world * Attributes.decode_transform(buffer, offset)
	var world_bounds := world_transform * mesh_bounds
	var anchor: Dictionary = compatibility.get("compoundAnchor", {})
	var section := Grid.key_for_world_position(anchor.get("worldPosition", world_bounds.get_center()))
	var local_transform := Transform3D(Basis.IDENTITY, -Grid.origin_for_key(section)) * world_transform
	var color := Color(float(buffer[offset + Attributes.COLOR_OFFSET]),
		float(buffer[offset + Attributes.COLOR_OFFSET + 1]),
		float(buffer[offset + Attributes.COLOR_OFFSET + 2]),
		float(buffer[offset + Attributes.COLOR_OFFSET + 3]))
	var encoded: Array = Attributes.encode_transform(local_transform, buffer, offset, color)
	return packed_member(source_id, part_id, revision, segment_id, instance_index,
		section, mesh_bounds, encoded, 0, compatibility)


static func packed_member(source_id: String, part_id: String, revision: String,
		segment_id: String, instance_index: int, section: Vector3i,
		mesh_bounds: AABB, buffer: Array, offset: int,
		compatibility: Dictionary) -> Dictionary:
	if source_id.is_empty() or part_id.is_empty() or revision.is_empty() \
			or segment_id.is_empty() or instance_index < 0 or offset < 0 \
			or offset + Attributes.FLOATS_PER_INSTANCE > buffer.size(): return {}
	var record: Array[float] = []
	for index: int in range(Attributes.FLOATS_PER_INSTANCE):
		var value := float(buffer[offset + index])
		if not is_finite(value): return {}
		record.append(value)
	record.make_read_only()
	var transform := Attributes.decode_transform(record, 0)
	var bounds := (Transform3D(Basis.IDENTITY, Grid.origin_for_key(section)) * transform) * mesh_bounds
	var policy: Array = []
	for key: String in ["materialKey", "meshKey", "pipelineRevision", "renderLayer",
			"translucentSortPolicy", "renderTier", "castShadows", "visibilityRangeEnd", "fadeMargin"]:
		var value: Variant = compatibility.get(key, null)
		if key == "meshKey": value = compatibility.get("meshResourceKey", value)
		if key == "translucentSortPolicy": value = compatibility.get("transparencySortPolicy", value)
		if not (value == null or value is String or value is bool or value is float or value is int): return {}
		policy.append(value)
	if not String(compatibility.get("attachmentKey", "")).is_empty():
		var neutral: Variant = compatibility.get("neutralParentToWorld")
		var swept: Variant = compatibility.get("sweptWorldBounds")
		if not neutral is Transform3D or not neutral.is_finite() or not swept is AABB \
				or not swept.position.is_finite() or not swept.end.is_finite(): return {}
		var motion: Variant = compatibility.get("motion")
		if not motion is Dictionary or not motion.is_read_only(): return {}
		policy.append([String(compatibility.attachmentKey),var_to_bytes(neutral).hex_encode(),var_to_bytes(swept).hex_encode(),var_to_bytes(motion).hex_encode()])
	if compatibility.has("compoundAnchor"): policy.append(var_to_bytes(compatibility.compoundAnchor).hex_encode())
	policy.make_read_only()
	var row := {"sourceId":source_id, "sourcePartId":part_id, "sourceRevision":revision,
		"sourceSegmentId":segment_id, "sourceInstance":instance_index,
		"geometryOwnerSection":section, "meshContentDigest":String(compatibility.get("meshContentDigest", "")),
		"attributesDigest":_digest(record), "renderPolicyDigest":_digest(policy),
		"worldBounds":bounds}
	if compatibility.has("compoundAnchor"): row["compoundAnchor"] = compatibility.compoundAnchor
	row.make_read_only()
	return row if valid_member(row) else {}


static func member_key(row: Dictionary) -> String:
	return _digest([String(row.get("sourceSegmentId", "")), int(row.get("sourceInstance", -1))])


static func valid_member(row: Dictionary) -> bool:
	if not row.is_read_only() or row.size() != (11 if row.has("compoundAnchor") else 10) or not row.get("geometryOwnerSection") is Vector3i \
			or not row.get("sourceInstance") is int or int(row.sourceInstance) < 0 \
			or not row.get("worldBounds") is AABB: return false
	for key: String in ["sourceId", "sourcePartId", "sourceRevision", "sourceSegmentId"]:
		if not row.get(key) is String or String(row[key]).is_empty(): return false
	for key: String in ["meshContentDigest", "attributesDigest", "renderPolicyDigest"]:
		var value := String(row.get(key, ""))
		if value.length() != 64 or not value.is_valid_hex_number(false): return false
	var bounds: AABB = row.worldBounds
	var owner_position := bounds.get_center()
	if row.has("compoundAnchor"):
		var anchor: Variant = row.compoundAnchor
		if not anchor is Dictionary or not anchor.is_read_only() or anchor.size() != 2 \
				or String(anchor.get("key", "")).is_empty() or not anchor.get("worldPosition") is Vector3 \
				or not anchor.worldPosition.is_finite(): return false
		owner_position = anchor.worldPosition
	return bounds.position.is_finite() and bounds.end.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0 \
		and Grid.key_for_world_position(owner_position) == row.geometryOwnerSection


static func seal(world_id: String, source_id: String, part_id: String,
		revision: String, incarnation: String, members: Array,
		explicit_removal: bool = false) -> Dictionary:
	if world_id.is_empty() or source_id.is_empty() or part_id.is_empty() \
			or revision.is_empty() or incarnation.is_empty() or members.size() > MAX_MEMBERS \
			or (members.is_empty() and not explicit_removal) \
			or (explicit_removal and not members.is_empty()):
		return {"status":"pending", "reason":"full_geometry_owner_roster_unavailable"}
	var owned: Array[Dictionary] = []
	var seen: Dictionary = {}
	for value: Variant in members:
		if not value is Dictionary or not valid_member(value) \
				or value.sourceId != source_id or value.sourcePartId != part_id \
				or value.sourceRevision != revision:
			return {"status":"failed", "reason":"invalid_full_geometry_owner_member"}
		var key := member_key(value)
		if seen.has(key): return {"status":"failed", "reason":"duplicate_full_geometry_owner_member"}
		seen[key] = true
		owned.append(value)
	owned.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return member_key(a) < member_key(b))
	owned.make_read_only()
	var roster := {"schema":SCHEMA, "worldId":world_id, "sourceId":source_id,
		"sourcePartId":part_id, "sourceRevision":revision, "sourceIncarnation":incarnation,
		"explicitRemoval":explicit_removal, "members":owned}
	roster.make_read_only()
	var envelope := roster.duplicate(false)
	# Preserve the original public digest exactly. This seal operation is producer
	# admission work; the coordinator consumes the sealed read-only value in slices.
	envelope["digest"] = _digest(roster)
	envelope.make_read_only()
	return {"status":"ready", "roster":envelope}


static func incremental_header_is_valid(roster: Dictionary,
		expected_world_id: String) -> bool:
	return _sealed_roster_header_is_well_formed(roster, expected_world_id)


static func validate(roster: Dictionary) -> bool:
	if not roster.is_read_only() or roster.get("schema") != SCHEMA \
			or not roster.get("members") is Array or not roster.members.is_read_only(): return false
	var rebuilt := seal(String(roster.get("worldId", "")), String(roster.get("sourceId", "")),
		String(roster.get("sourcePartId", "")), String(roster.get("sourceRevision", "")),
		String(roster.get("sourceIncarnation", "")), roster.members,
		bool(roster.get("explicitRemoval", false)))
	return rebuilt.get("status") == "ready" and rebuilt.roster == roster


static func _digest(value: Variant) -> String:
	return Marshalls.raw_to_base64(var_to_bytes(value)).sha256_text()


static func _sealed_roster_header_is_well_formed(roster: Dictionary,
		expected_world_id: String) -> bool:
	if roster.is_empty() or not roster.is_read_only() \
			or roster.get("schema") != SCHEMA \
			or String(roster.get("worldId", "")) != expected_world_id \
			or String(roster.get("sourceId", "")).is_empty() \
			or String(roster.get("sourcePartId", "")).is_empty() \
			or String(roster.get("sourceRevision", "")).is_empty() \
			or String(roster.get("sourceIncarnation", "")).is_empty() \
			or not roster.get("explicitRemoval") is bool \
			or not roster.get("members") is Array \
			or not roster.members.is_read_only() \
			or roster.members.size() > MAX_MEMBERS \
			or (roster.members.is_empty() and not bool(roster.explicitRemoval)) \
			or (not roster.members.is_empty() and bool(roster.explicitRemoval)):
		return false
	var digest := String(roster.get("digest", ""))
	return digest.length() == 64 and digest.is_valid_hex_number(false)



static func owner_sections(roster: Dictionary) -> Array[Vector3i]:
	var sections: Array[Vector3i] = []
	for member: Dictionary in roster.get("members", []):
		var section: Vector3i = member.geometryOwnerSection
		if section not in sections: sections.append(section)
	sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	return sections


static func compare_installed_members(roster: Dictionary, installed: Array) -> Dictionary:
	if not validate(roster): return {"status":"pending", "reason":"geometry_owner_roster_invalid"}
	var expected: Dictionary = {}
	for row: Dictionary in roster.members: expected[member_key(row)] = row
	var seen: Dictionary = {}
	for value: Variant in installed:
		if not value is Dictionary or not valid_member(value):
			return {"status":"pending", "reason":"geometry_owner_installed_member_invalid"}
		var key := member_key(value)
		if seen.has(key): return {"status":"pending", "reason":"geometry_owner_duplicate_installed_member"}
		seen[key] = true
		if not expected.has(key): return {"status":"pending", "reason":"geometry_owner_extra_installed_member"}
		if expected[key] != value:
			return {"status":"pending", "reason":"geometry_owner_installed_member_mismatch", "memberKey":key}
	if seen.size() != expected.size():
		return {"status":"pending", "reason":"geometry_owner_missing_installed_member",
			"expectedCount":expected.size(), "installedCount":seen.size()}
	return {"status":"ready", "memberCount":seen.size(), "rosterDigest":roster.digest}
