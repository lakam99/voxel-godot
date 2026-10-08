extends RefCounted
## Immutable section-local slices of a complete StaticGeometryOwnerCompletion roster.
## This is a value contract; it does not install or retire rendered content.

const Completion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const SCHEMA := "static-geometry-owner-section-slice/v1"
const MAX_SECTIONS := 65536


static func for_section(roster: Dictionary, section: Vector3i) -> Dictionary:
	if not Completion.validate(roster):
		return {"status":"pending", "reason":"parent_geometry_owner_roster_invalid"}
	return _for_validated_roster_section(roster, section)


## Provider-only fast path. The caller must have validated this immutable parent
## roster against its current owner before requesting a local slice.
static func for_validated_roster_section(roster: Dictionary, section: Vector3i) -> Dictionary:
	if not roster.is_read_only() or not roster.get("members") is Array \
			or not roster.members.is_read_only() or String(roster.get("digest", "")).length() != 64:
		return {"status":"pending", "reason":"validated_parent_roster_envelope_invalid"}
	return _for_validated_roster_section(roster, section)


## Seal rows accumulated by a budgeted provider cursor that scanned this entire
## validated parent roster and selected this exact owner section.
static func seal_validated_section_members(roster: Dictionary, section: Vector3i,
		members: Array[Dictionary]) -> Dictionary:
	if not roster.is_read_only() or String(roster.get("digest", "")).length() != 64:
		return {"status":"pending", "reason":"validated_parent_roster_envelope_invalid"}
	for member: Dictionary in members:
		if not member.is_read_only() or member.get("geometryOwnerSection") != section \
				or member.get("sourceId") != roster.get("sourceId") \
				or member.get("sourcePartId") != roster.get("sourcePartId") \
				or member.get("sourceRevision") != roster.get("sourceRevision"):
			return {"status":"failed", "reason":"section_slice_member_identity_invalid"}
	var slice := _seal_slice(roster, section, members)
	return {"status":"ready", "slice":slice} if not slice.is_empty() \
		else {"status":"failed", "reason":"section_slice_seal_failed"}


static func _for_validated_roster_section(roster: Dictionary, section: Vector3i) -> Dictionary:
	var members: Array[Dictionary] = []
	for value: Variant in roster.members:
		if not value is Dictionary:
			return {"status":"failed", "reason":"validated_parent_member_invalid"}
		var member: Dictionary = value
		if member.geometryOwnerSection == section:
			members.append(member)
	var slice := _seal_slice(roster, section, members)
	if slice.is_empty() or not _validate_slice_against_validated_roster(roster, slice):
		return {"status":"failed", "reason":"section_slice_validation_failed"}
	return {"status":"ready", "slice":slice}


static func partition(roster: Dictionary, expected_sections: Array) -> Dictionary:
	if not Completion.validate(roster):
		return {"status":"pending", "reason":"parent_geometry_owner_roster_invalid"}
	if expected_sections.size() > MAX_SECTIONS:
		return {"status":"failed", "reason":"section_count_limit_exceeded"}
	var sections: Array[Vector3i] = []
	var seen_sections: Dictionary = {}
	for value: Variant in expected_sections:
		if not value is Vector3i:
			return {"status":"failed", "reason":"invalid_expected_section"}
		if seen_sections.has(value):
			return {"status":"failed", "reason":"duplicate_expected_section"}
		seen_sections[value] = true
		sections.append(value)
	for owner: Vector3i in Completion.owner_sections(roster):
		if not seen_sections.has(owner):
			return {"status":"pending", "reason":"parent_member_section_omitted"}
	if bool(roster.get("explicitRemoval", false)) and sections.is_empty():
		return {"status":"pending", "reason":"removal_sections_unavailable"}
	sections.sort_custom(_section_less)
	var slices: Array[Dictionary] = []
	for section: Vector3i in sections:
		var members: Array[Dictionary] = []
		for member: Dictionary in roster.members:
			if member.geometryOwnerSection == section:
				members.append(member)
		var sealed := _seal_slice(roster, section, members)
		if sealed.is_empty():
			return {"status":"failed", "reason":"section_slice_seal_failed"}
		slices.append(sealed)
	slices.make_read_only()
	var partition := {"schema":SCHEMA, "parentRosterDigest":String(roster.digest),
		"sections":sections, "slices":slices}
	sections.make_read_only()
	partition.make_read_only()
	var envelope := partition.duplicate(false)
	envelope["digest"] = _digest(partition)
	envelope.make_read_only()
	if not validate_partition(roster, envelope, sections):
		return {"status":"failed", "reason":"section_slice_partition_validation_failed"}
	return {"status":"ready", "partition":envelope}


static func validate_slice(roster: Dictionary, slice: Dictionary) -> bool:
	return Completion.validate(roster) and validate_slice_for_validated_roster(roster, slice)


## Use only when the provider has already validated this immutable parent roster.
static func validate_slice_for_validated_roster(roster: Dictionary, slice: Dictionary) -> bool:
	if not roster.is_read_only() or not roster.get("members") is Array \
			or not roster.members.is_read_only() or String(roster.get("digest", "")).length() != 64:
		return false
	return _validate_slice_against_validated_roster(roster, slice)


## Recheck an immutable provider-cached slice against a freshly validated parent.
## Exact membership was proven when the provider first sealed this slice.
static func validate_cached_slice_for_parent(roster: Dictionary, slice: Dictionary) -> bool:
	if not roster.is_read_only() or String(roster.get("digest", "")).length() != 64 \
			or not slice.is_read_only() or not slice.get("members") is Array \
			or not slice.members.is_read_only() or slice.get("schema") != SCHEMA \
			or slice.get("parentRosterDigest") != roster.get("digest") \
			or slice.get("worldId") != roster.get("worldId") \
			or slice.get("sourceId") != roster.get("sourceId") \
			or slice.get("sourcePartId") != roster.get("sourcePartId") \
			or slice.get("sourceRevision") != roster.get("sourceRevision") \
			or slice.get("sourceIncarnation") != roster.get("sourceIncarnation") \
			or not slice.get("ownerSection") is Vector3i \
			or bool(slice.get("sourceRemoved", false)) != bool(roster.get("explicitRemoval", false)):
		return false
	for member: Variant in slice.members:
		if not member is Dictionary or member.get("sourceId") != roster.get("sourceId") \
				or member.get("sourcePartId") != roster.get("sourcePartId") \
				or member.get("sourceRevision") != roster.get("sourceRevision") \
				or member.get("geometryOwnerSection") != slice.get("ownerSection"):
			return false
	if bool(slice.get("sectionEmpty", false)) != slice.members.is_empty() \
			or (bool(slice.get("sourceRemoved", false)) and not slice.members.is_empty()):
		return false
	var payload := slice.duplicate(false)
	payload.erase("digest")
	payload.make_read_only()
	return String(slice.get("digest", "")) == _slice_digest(payload)


static func _validate_slice_against_validated_roster(roster: Dictionary, slice: Dictionary) -> bool:
	if not slice.is_read_only() \
			or slice.get("schema") != SCHEMA or not slice.get("ownerSection") is Vector3i \
			or not slice.get("members") is Array or not slice.members.is_read_only():
		return false
	if slice.get("worldId") != roster.worldId or slice.get("sourceId") != roster.sourceId \
			or slice.get("sourcePartId") != roster.sourcePartId \
			or slice.get("sourceRevision") != roster.sourceRevision \
			or slice.get("sourceIncarnation") != roster.sourceIncarnation \
			or slice.get("parentRosterDigest") != roster.digest \
			or bool(slice.get("sourceRemoved", false)) != bool(roster.explicitRemoval):
		return false
	if bool(slice.get("sectionEmpty", false)) != slice.members.is_empty() \
			or (bool(slice.sourceRemoved) and not slice.members.is_empty()):
		return false
	var expected_members: Array[Dictionary] = []
	for member: Dictionary in roster.members:
		if member.geometryOwnerSection == slice.ownerSection:
			expected_members.append(member)
	if expected_members != slice.members:
		return false
	var payload := slice.duplicate(false)
	payload.erase("digest")
	payload.make_read_only()
	return String(slice.get("digest", "")) == _slice_digest(payload)


static func validate_partition(roster: Dictionary, partition: Dictionary,
		expected_sections: Array = []) -> bool:
	if not Completion.validate(roster) or not partition.is_read_only() \
			or partition.get("schema") != SCHEMA \
			or partition.get("parentRosterDigest") != roster.digest \
			or not partition.get("sections") is Array or not partition.sections.is_read_only() \
			or not partition.get("slices") is Array or not partition.slices.is_read_only():
		return false
	if not expected_sections.is_empty() and expected_sections != partition.sections:
		return false
	if partition.sections.size() != partition.slices.size() or partition.sections.size() > MAX_SECTIONS:
		return false
	var listed_sections: Dictionary = {}
	var included_members: Dictionary = {}
	for index: int in range(partition.sections.size()):
		var section: Variant = partition.sections[index]
		var slice: Variant = partition.slices[index]
		if not section is Vector3i or listed_sections.has(section) \
				or (index > 0 and not _section_less(partition.sections[index - 1], section)) \
				or not slice is Dictionary or slice.get("ownerSection") != section \
				or not validate_slice(roster, slice):
			return false
		listed_sections[section] = true
		for member: Dictionary in slice.members:
			var member_key := Completion.member_key(member)
			if included_members.has(member_key): return false
			included_members[member_key] = member
	for section: Vector3i in Completion.owner_sections(roster):
		if not listed_sections.has(section): return false
	var expected_members: Dictionary = {}
	for member: Dictionary in roster.members:
		expected_members[Completion.member_key(member)] = member
	if included_members.size() != expected_members.size(): return false
	for key: String in expected_members:
		if not included_members.has(key) or included_members[key] != expected_members[key]:
			return false
	var payload := partition.duplicate(false)
	payload.erase("digest")
	payload.make_read_only()
	return String(partition.get("digest", "")) == _digest(payload)


static func _seal_slice(roster: Dictionary, section: Vector3i,
		members: Array[Dictionary]) -> Dictionary:
	# Parent rosters are already sorted by member identity. Preserve that order so
	# making one local slice does not hash or sort every packed member again.
	var owned_members: Array[Dictionary] = members.duplicate()
	owned_members.make_read_only()
	var payload := {"schema":SCHEMA, "worldId":String(roster.worldId),
		"sourceId":String(roster.sourceId), "sourcePartId":String(roster.sourcePartId),
		"sourceRevision":String(roster.sourceRevision),
		"sourceIncarnation":String(roster.sourceIncarnation),
		"parentRosterDigest":String(roster.digest), "ownerSection":section,
		"sourceRemoved":bool(roster.explicitRemoval), "sectionEmpty":owned_members.is_empty(),
		"members":owned_members}
	payload.make_read_only()
	var sealed := payload.duplicate(false)
	sealed["digest"] = _slice_digest(payload)
	sealed.make_read_only()
	return sealed


static func _slice_digest(payload: Dictionary) -> String:
	var member_identities: Array = []
	for member: Dictionary in payload.get("members", []):
		member_identities.append([String(member.get("sourceSegmentId", "")),
			int(member.get("sourceInstance", -1))])
	return _digest([SCHEMA, String(payload.get("parentRosterDigest", "")),
		payload.get("ownerSection"), bool(payload.get("sourceRemoved", false)),
		member_identities])


static func _section_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x: return a.x < b.x
	if a.y != b.y: return a.y < b.y
	return a.z < b.z


static func _digest(value: Variant) -> String:
	return Marshalls.raw_to_base64(var_to_bytes(value)).sha256_text()
