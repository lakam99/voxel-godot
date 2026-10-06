extends RefCounted
class_name EcologyWorldSupportIndex

## Revisioned, value-only index from deterministic ecology producer domains to
## the render sections supported by their contributors. It owns no Nodes,
## Resources, gameplay state, or save data.

const QUERY_SCHEMA := "ecology-world-support-query/v1"
const CERTIFICATE_SCHEMA := "ecology-source-domain-coverage/v1"
const SOURCE_SCHEMA := "ecology-world-support-source/v1"
const INFLUENCE_POLICY_REVISION := "ecology-support-influence-policy/v1"
const OWNER_LEASE_SCHEMA := "ecology-support-owner-lease/v1"
const TREE_MEMBER_SUPPORT_POLICY := "tree-factory-support-envelope/v2"
const STATIC_MEMBER_ENVELOPE_SCHEMA := "ecology-certified-static-member-envelope/v1"
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const ProducerDomain := preload("res://scripts/world/EcologyProducerDomain.gd")

var _world_id := ""
var _next_source_index_revision := 0
var _section_index_revision: Dictionary = {} # Vector3i -> monotonic section-local revision
var _domains: Dictionary = {} # Vector2i -> immutable completeness certificate
var _sources: Dictionary = {} # source ID -> current immutable row
var _postings_by_section: Dictionary = {} # Vector3i -> source ID -> immutable row
var _retired_postings_by_section: Dictionary = {} # retained tombstones pending receipt
var _required_domains_by_section: Dictionary = {} # Vector3i -> sorted Vector2i[]
var _latest_query_by_section: Dictionary = {}
var _receipt_by_section: Dictionary = {}
var _source_census_certificate_by_section: Dictionary = {}


func configure(world_id: String) -> Dictionary:
	if world_id.strip_edges().is_empty():
		return {"status":"failed", "reason":"ecology_support_index_world_invalid"}
	if not _world_id.is_empty() and _world_id != world_id:
		return {"status":"failed", "reason":"ecology_support_index_world_replaced"}
	if _world_id.is_empty():
		_world_id = world_id
	return {"status":"ready", "worldId":_world_id,
		"sourceIndexRevision":_next_source_index_revision}


## Declare the producer source domains that can influence a section. The caller
## must derive this complete set from the certified producer influence policy;
## an empty/missing set never implies empty world content.
func set_required_source_domains(section_key: Vector3i,
		source_chunk_keys: Array, census_certificate: Dictionary) -> Dictionary:
	if not ProducerDomain.validate_source_domain_census_certificate(
			census_certificate, section_key):
		return {"status":"pending", "reason":"ecology_support_influence_census_unproven"}
	var keys: Array[Vector2i] = []
	for value: Variant in source_chunk_keys:
		if not value is Vector2i or value in keys:
			return {"status":"failed", "reason":"ecology_support_domain_key_invalid"}
		keys.append(value)
	keys.sort_custom(_chunk_less)
	var certified_keys: Variant = census_certificate.get("sourceChunkKeys", null)
	if not certified_keys is Array or certified_keys != keys:
		return {"status":"pending", "reason":"ecology_support_influence_census_mismatch"}
	if _required_domains_by_section.get(section_key, []) != keys:
		_required_domains_by_section[section_key] = keys.duplicate()
		_source_census_certificate_by_section[section_key] = census_certificate.duplicate(true)
		_bump_section_revision(section_key)
		_latest_query_by_section.erase(section_key)
	elif _source_census_certificate_by_section.get(section_key, {}) != census_certificate:
		_source_census_certificate_by_section[section_key] = census_certificate.duplicate(true)
		_bump_section_revision(section_key)
	return {"status":"ready", "sectionKey":section_key,
		"sourceDomains":keys.duplicate(), "sourceIndexRevision":_section_revision(section_key)}


## Publish rows derived from an independently sealed deterministic source
## snapshot. Runtime gameplay Node identity is deliberately not source authority.
func publish_source_domain(world_id: String, source_chunk_key: Vector2i,
		snapshot: Dictionary, rows: Array) -> Dictionary:
	if world_id != _world_id or world_id.is_empty() \
			or not ProducerDomain.validate_source_domain_snapshot(snapshot,
				world_id, source_chunk_key):
		return {"status":"pending", "reason":"ecology_source_domain_incomplete"}
	if String(snapshot.get("status", "")) != "ready" \
			or not bool(snapshot.get("producerComplete", false)):
		return {"status":"pending", "reason":"ecology_source_domain_not_complete",
			"producerReason":String(snapshot.get("reason", ""))}
	var source_revision := String(snapshot.get("sourceRevision", ""))
	var producer_snapshot_revision := String(snapshot.get("producerSnapshotRevision", ""))
	var removed_projection_digest := String(snapshot.get("removedSourceProjectionDigest", ""))
	var removed_props_revision := String(snapshot.get("removedPropsRevision",
		removed_projection_digest))
	var source_inputs: Dictionary = snapshot.get("sourceInputs", {})
	var runtime_policy := ProducerDomain.support_policy(source_inputs)
	var influence_revision := String(snapshot.get("influencePolicyRevision", ""))
	var influence_digest := String(snapshot.get("influencePolicyDigest", ""))
	var terrain_revision := String(snapshot.get("terrainVolumeChunkRevision",
		source_inputs.get("terrainVolumeChunkRevision", "")))
	var structure_revision := String(snapshot.get("structureAdmissionRevision",
		source_inputs.get("structureAdmissionRevision", "")))
	var structure_status := String(snapshot.get("structureAdmissionStatus",
		source_inputs.get("structureAdmissionStatus", "")))
	if source_revision.is_empty() or producer_snapshot_revision.is_empty() \
			or removed_props_revision.is_empty() or removed_projection_digest.length() != 64 \
			or terrain_revision.is_empty() or structure_revision.is_empty() \
			or structure_status not in ["ready", "complete"] \
			or String(runtime_policy.get("status", "")) != "ready" \
			or influence_revision != String(runtime_policy.get("revision", "")) \
			or influence_digest.length() != 64 \
			or influence_digest != String(runtime_policy.get("digest", "")):
		return {"status":"pending", "reason":"ecology_source_domain_identity_incomplete"}
	var snapshot_sources: Dictionary = {}
	for source_value: Variant in snapshot.get("sourceRows", []):
		if not source_value is Dictionary:
			return {"status":"pending", "reason":"ecology_source_snapshot_row_invalid"}
		var stable_source_id := String(source_value.get("sourceId", ""))
		if stable_source_id.is_empty() or snapshot_sources.has(stable_source_id):
			return {"status":"pending", "reason":"ecology_source_snapshot_id_invalid"}
		snapshot_sources[stable_source_id] = true
	var tuples: Array = []
	var prepared_rows: Array[Dictionary] = []
	var row_source_ids: Dictionary = {}
	for row_value: Variant in rows:
		if not row_value is Dictionary:
			return {"status":"pending", "reason":"ecology_source_domain_row_invalid"}
		var row: Dictionary = row_value
		var row_source_id := String(row.get("sourceId", ""))
		if not snapshot_sources.has(row_source_id):
			return {"status":"pending", "reason":"ecology_source_row_not_in_producer_snapshot",
				"sourceId":row_source_id}
		row_source_ids[row_source_id] = true
		var validated := _validate_source_row(row, world_id, source_chunk_key,
			source_revision, runtime_policy)
		if validated.get("status") != "ready":
			return validated
		var accepted_row: Dictionary = validated.row.duplicate(true)
		accepted_row["sourceDomainRevision"] = source_revision
		accepted_row["producerSnapshotRevision"] = producer_snapshot_revision
		accepted_row["terrainVolumeChunkRevision"] = terrain_revision
		accepted_row["structureAdmissionRevision"] = structure_revision
		accepted_row["removedSourceProjectionDigest"] = removed_projection_digest
		accepted_row["influencePolicyRevision"] = influence_revision
		accepted_row["influencePolicyDigest"] = influence_digest
		accepted_row.make_read_only()
		prepared_rows.append(accepted_row)
		tuples.append(_stable_source_tuple(accepted_row))
	if row_source_ids.size() != snapshot_sources.size():
		var missing_source_ids: Array[String] = []
		for source_id_value: Variant in snapshot_sources.keys():
			var source_id := String(source_id_value)
			if not row_source_ids.has(source_id): missing_source_ids.append(source_id)
		missing_source_ids.sort()
		return {"status":"pending", "reason":"ecology_producer_source_without_support_row",
			"producerSourceCount":snapshot_sources.size(),
			"supportSourceCount":row_source_ids.size(),
			"pendingSourceIds":missing_source_ids}
	tuples.sort_custom(_source_tuple_less)
	var old_domain: Dictionary = _domains.get(source_chunk_key, {})
	var domain_same := String(old_domain.get("sourceRevision", "")) == source_revision \
		and String(old_domain.get("removedPropsRevision", "")) == removed_props_revision \
		and String(old_domain.get("producerSnapshotRevision", "")) == producer_snapshot_revision \
		and String(old_domain.get("influencePolicyDigest", "")) == influence_digest
	if domain_same:
		var current_tuples: Array = []
		for row_value: Variant in _sources.values():
			if row_value is Dictionary and row_value.get("sourceChunkKey", null) == source_chunk_key:
				current_tuples.append(_stable_source_tuple(row_value))
		current_tuples.sort_custom(_source_tuple_less)
		if current_tuples == tuples:
			return {"status":"ready", "sourceChunkKey":source_chunk_key,
				"sourceManifestDigest":String(old_domain.get("sourceManifestDigest", "")),
				"sourceIndexRevision":_next_source_index_revision, "changed":false}
	# Retain prior support as tombstones until an accepted receipt covers each
	# affected section. A source replacement never makes old installed content
	# disappear merely because its producer row changed.
	var affected_sections: Dictionary = {}
	for section_key: Vector3i in _required_domains_by_section:
		if source_chunk_key in _required_domains_by_section[section_key]:
			affected_sections[section_key] = true
	for prior_value: Variant in _sources.values():
		if prior_value is Dictionary and Vector2i(prior_value.get("sourceChunkKey", Vector2i.ZERO)) == source_chunk_key:
			for key_value: Variant in prior_value.get("supportSectionKeys", []):
				affected_sections[key_value] = true
	for row: Dictionary in prepared_rows:
		for key_value: Variant in row.get("conservativeSupportSectionKeys", []):
			affected_sections[key_value] = true
	var new_by_key: Dictionary = {}
	for row: Dictionary in prepared_rows:
		new_by_key[_row_key(row)] = row
	var preserved: Dictionary = {}
	for source_key_value: Variant in _sources.keys().duplicate():
		var source_key := String(source_key_value)
		var old_row: Dictionary = _sources[source_key]
		if old_row.get("sourceChunkKey", null) != source_chunk_key:
			continue
		var replacement: Variant = new_by_key.get(source_key, null)
		if replacement is Dictionary and _stable_source_tuple(old_row) == _stable_source_tuple(replacement):
			preserved[source_key] = replacement
			new_by_key.erase(source_key)
			continue
		_retire_source_to_tombstone(source_key, old_row, source_revision)
		_sources.erase(source_key)
	for source_key: String in preserved:
		_sources[source_key] = preserved[source_key]
	for source_key: String in new_by_key:
		var row: Dictionary = new_by_key[source_key]
		_sources[source_key] = row
		_post_row(row)
	var manifest_tuples: Array = tuples.duplicate()
	for section_map_value: Variant in _retired_postings_by_section.values():
		if not section_map_value is Dictionary:
			continue
		for retired_value: Variant in section_map_value.values():
			if retired_value is Dictionary \
					and retired_value.get("sourceChunkKey", null) == source_chunk_key:
				manifest_tuples.append(_stable_source_tuple(retired_value))
	manifest_tuples.sort_custom(_source_tuple_less)
	var support_manifest_digest := _sha256_bytes(var_to_bytes([
		source_chunk_key, source_revision, removed_props_revision, manifest_tuples]))
	if support_manifest_digest.is_empty():
		return {"status":"failed", "reason":"ecology_source_manifest_digest_failed"}
	var domain := {"sourceChunkKey":source_chunk_key,
		"worldId":world_id, "sourceRevision":source_revision,
		"removedPropsRevision":removed_props_revision,
		"producerSnapshotRevision":producer_snapshot_revision,
		"producerComplete":bool(snapshot.get("producerComplete", false)),
		"enumeratedSourceCount":int(snapshot.get("enumeratedSourceCount", -1)),
		"categoriesComplete":snapshot.get("categoriesComplete", []),
		"terrainVolumeChunkRevision":terrain_revision,
		"structureAdmissionRevision":structure_revision,
		"structureAdmissionStatus":structure_status,
		"removedSourceProjectionDigest":removed_projection_digest,
		"sourceManifestDigest":String(snapshot.get("sourceManifestDigest", "")),
		"supportManifestDigest":support_manifest_digest,
		"influencePolicyRevision":String(snapshot.get("influencePolicyRevision", "")),
		"influencePolicyDigest":influence_digest, "sourceInputs":source_inputs,
		"sourceIndexRevision":_next_source_index_revision + 1}
	domain.make_read_only()
	_domains[source_chunk_key] = domain
	_bump_sections(affected_sections)
	return {"status":"ready", "sourceChunkKey":source_chunk_key,
		"sourceManifestDigest":String(snapshot.get("sourceManifestDigest", "")),
		"supportManifestDigest":support_manifest_digest,
		"sourceIndexRevision":_next_source_index_revision, "changed":true,
		"affectedSections":_sorted_sections(affected_sections)}


func mark_source_domain_unknown(source_chunk_key: Vector2i) -> void:
	if _domains.has(source_chunk_key):
		_domains.erase(source_chunk_key)
		var affected: Dictionary = {}
		for section_key: Vector3i in _required_domains_by_section:
			if source_chunk_key in _required_domains_by_section[section_key]:
				affected[section_key] = true
		_bump_sections(affected)


func query_section(world_id: String, section_key: Vector3i) -> Dictionary:
	if world_id != _world_id or _world_id.is_empty():
		return _pending("ecology_support_query_world_stale", section_key)
	var census_value: Variant = _source_census_certificate_by_section.get(section_key, null)
	if not census_value is Dictionary or not ProducerDomain.validate_source_domain_census_certificate(
			census_value, section_key):
		return _pending("ecology_support_influence_census_unproven", section_key)
	var census_policy_digest := String(census_value.get("influencePolicyDigest", ""))
	if census_policy_digest.is_empty():
		return _pending("ecology_support_influence_policy_digest_missing", section_key)
	var required_value: Variant = _required_domains_by_section.get(section_key, null)
	if not required_value is Array or required_value.is_empty():
		return _pending("ecology_support_influence_domain_missing", section_key)
	var domain_rows: Array[Dictionary] = []
	for key: Vector2i in required_value:
		var domain_value: Variant = _domains.get(key, null)
		if not domain_value is Dictionary or not _valid_domain(domain_value, key):
			return _pending("ecology_support_source_domain_incomplete", section_key,
				{"sourceChunkKey":key})
		if String(domain_value.get("influencePolicyDigest", "")) != census_policy_digest:
			return _pending("ecology_support_source_policy_stale", section_key,
				{"sourceChunkKey":key})
		domain_rows.append(domain_value)
	var contributors: Array[Dictionary] = []
	var support_owner_demands: Array[Dictionary] = []
	var seen: Dictionary = {}
	for row_map in [_postings_by_section.get(section_key, {}),
			_retired_postings_by_section.get(section_key, {})]:
		if not row_map is Dictionary:
			continue
		for source_id_value: Variant in row_map:
			var source_id := String(source_id_value)
			var row: Dictionary = row_map[source_id]
			var contributor_key := "%s|%s|%s" % [_row_key(row),
				String(row.get("sourceRevision", "")), String(row.get("state", ""))]
			if String(row.get("state", "")) == "tombstoned":
				contributor_key += "|" + String(row.get("tombstoneRevision", ""))
			if seen.has(contributor_key):
				continue
			seen[contributor_key] = true
			contributors.append(row)
	contributors.sort_custom(_row_less)
	domain_rows.sort_custom(_domain_less)
	var digest_rows: Array = []
	for row: Dictionary in contributors:
		digest_rows.append(_stable_source_tuple(row))
	var canonical_domains: Array = []
	for domain: Dictionary in domain_rows:
		canonical_domains.append(_stable_domain_tuple(domain))
	var section_revision := _section_revision(section_key)
	var coverage_digest := _sha256_bytes(var_to_bytes([
		CERTIFICATE_SCHEMA, world_id,
		[section_key.x, section_key.y, section_key.z], section_revision,
		canonical_domains, digest_rows]))
	if coverage_digest.is_empty():
		return _pending("ecology_support_coverage_digest_failed", section_key)
	for row: Dictionary in contributors:
		var lease := _support_owner_lease(row, section_key, world_id,
			section_revision, coverage_digest)
		if lease.is_empty():
			return _pending("ecology_support_owner_lease_unprovable", section_key,
				{"sourceId":String(row.get("sourceId", "")),
				"memberId":String(row.get("sourcePartId", ""))})
		support_owner_demands.append(lease)
	support_owner_demands.sort_custom(_demand_less)
	var certificate := {"schema":CERTIFICATE_SCHEMA, "worldId":world_id,
		"sectionKey":section_key, "sourceIndexRevision":section_revision,
		"coverageDigest":coverage_digest, "sourceDomains":domain_rows.duplicate(),
		"influencePolicyRevision":INFLUENCE_POLICY_REVISION}
	_deep_freeze(certificate)
	var result := {"status":"ready", "schema":QUERY_SCHEMA,
		"sectionKey":section_key, "worldId":world_id,
		"sourceIndexRevision":section_revision,
		"coverageCertificate":certificate,
		"contributors":contributors, "supportOwnerDemands":support_owner_demands}
	_deep_freeze(result)
	_latest_query_by_section[section_key] = result
	return result


func validate_coverage_certificate(certificate: Dictionary, world_id: String,
		section_key: Vector3i) -> Dictionary:
	if String(certificate.get("schema", "")) != CERTIFICATE_SCHEMA \
			or String(certificate.get("worldId", "")) != world_id \
			or certificate.get("sectionKey", null) != section_key:
		return {"status":"failed", "reason":"ecology_support_certificate_identity_invalid"}
	var current := query_section(world_id, section_key)
	if current.get("status") != "ready":
		return current
	var expected: Dictionary = current.coverageCertificate
	if int(certificate.get("sourceIndexRevision", -1)) != int(expected.sourceIndexRevision) \
			or String(certificate.get("coverageDigest", "")) != String(expected.coverageDigest) \
			or certificate.get("sourceDomains", []) != expected.get("sourceDomains", []):
		return {"status":"pending", "reason":"ecology_support_certificate_stale",
			"sourceIndexRevision":_section_revision(section_key)}
	return {"status":"ready", "sourceIndexRevision":_section_revision(section_key),
		"coverageDigest":String(expected.coverageDigest)}


## Accept a receipt only for the exact latest section index revision. Tombstones
## become reclaimable only after the native owner confirms the replacement.
func acknowledge_section_receipt(section_key: Vector3i, source_index_revision: int,
		installed_receipt: Dictionary) -> Dictionary:
	var query_value: Variant = _latest_query_by_section.get(section_key, null)
	if not query_value is Dictionary or query_value.get("status", "") != "ready" \
			or int(query_value.get("sourceIndexRevision", -1)) != source_index_revision:
		return {"status":"pending", "reason":"ecology_support_receipt_revision_stale"}
	if String(installed_receipt.get("schema", "")) != \
			"ecology-support-section-install-receipt/v1":
		return {"status":"pending", "reason":"ecology_support_receipt_schema_invalid"}
	var receipt_section: Variant = installed_receipt.get("sectionKey", null)
	var receipt_revision := int(installed_receipt.get("sourceIndexRevision", -1))
	var expected_coverage := String(query_value.coverageCertificate.coverageDigest)
	if receipt_section != section_key or receipt_revision != source_index_revision \
			or String(installed_receipt.get("coverageDigest", "")) != expected_coverage \
			or not installed_receipt.get("nativeReceipt", null) is Dictionary \
			or (installed_receipt.get("nativeReceipt", {}) as Dictionary).is_empty():
		return {"status":"pending", "reason":"ecology_support_receipt_invalid"}
	var member_receipts: Variant = installed_receipt.get("installedMemberReceipts", null)
	if not member_receipts is Array:
		return {"status":"pending", "reason":"ecology_support_member_receipt_missing"}
	var expected_members: Array = []
	var expected_absent_members: Array = []
	for lease_value: Variant in query_value.get("supportOwnerDemands", []):
		if not lease_value is Dictionary:
			continue
		var member_identity := [String(lease_value.get("sourceId", "")),
			String(lease_value.get("sourceRevision", "")),
			String(lease_value.get("memberId", "")),
			lease_value.get("ownerSectionKey", Vector3i.ZERO),
			String(lease_value.get("supportLeaseToken", ""))]
		match String(lease_value.get("state", "")):
			"compiled": expected_members.append(member_identity)
			"tombstoned": expected_absent_members.append(member_identity)
			"pending_recipe":
				return {"status":"pending", "reason":"ecology_support_pending_recipe_unresolved",
					"sourceId":String(lease_value.get("sourceId", "")),
					"memberId":String(lease_value.get("memberId", ""))}
	var received_members: Array = []
	for member_value: Variant in member_receipts:
		if not member_value is Dictionary:
			return {"status":"pending", "reason":"ecology_support_member_receipt_invalid"}
		var member: Dictionary = member_value
		received_members.append([String(member.get("sourceId", "")),
			String(member.get("sourceRevision", "")),
			String(member.get("memberId", "")),
			member.get("ownerSectionKey", Vector3i.ZERO),
			String(member.get("supportLeaseToken", ""))])
	expected_members.sort_custom(_array_identity_less)
	received_members.sort_custom(_array_identity_less)
	if expected_members != received_members:
		return {"status":"pending", "reason":"ecology_support_member_receipt_mismatch",
			"expectedMemberCount":expected_members.size(),
			"receivedMemberCount":received_members.size()}
	var absent_member_receipts: Variant = installed_receipt.get(
		"verifiedAbsentMemberReceipts", null)
	if not absent_member_receipts is Array:
		return {"status":"pending", "reason":"ecology_support_tombstone_absence_missing"}
	var received_absent_members: Array = []
	for member_value: Variant in absent_member_receipts:
		if not member_value is Dictionary:
			return {"status":"pending", "reason":"ecology_support_tombstone_absence_invalid"}
		var member: Dictionary = member_value
		received_absent_members.append([String(member.get("sourceId", "")),
			String(member.get("sourceRevision", "")),
			String(member.get("memberId", "")),
			member.get("ownerSectionKey", Vector3i.ZERO),
			String(member.get("supportLeaseToken", ""))])
	expected_absent_members.sort_custom(_array_identity_less)
	received_absent_members.sort_custom(_array_identity_less)
	if expected_absent_members != received_absent_members:
		return {"status":"pending", "reason":"ecology_support_tombstone_absence_mismatch",
			"expectedAbsentMemberCount":expected_absent_members.size(),
			"receivedAbsentMemberCount":received_absent_members.size()}
	var retired: Dictionary = _retired_postings_by_section.get(section_key, {})
	var retired_count := retired.size()
	retired.clear()
	_retired_postings_by_section.erase(section_key)
	_receipt_by_section[section_key] = {"sourceIndexRevision":source_index_revision,
		"receiptId":String(installed_receipt.nativeReceipt.get("receiptId",
			_sha256_bytes(var_to_bytes(installed_receipt.nativeReceipt))))}
	return {"status":"ready", "sectionKey":section_key,
		"sourceIndexRevision":source_index_revision,
		"retiredTombstoneCount":retired_count}


func _validate_source_row(row: Dictionary, world_id: String,
		source_chunk_key: Vector2i, source_revision: String,
		runtime_policy: Dictionary) -> Dictionary:
	var source_id := String(row.get("sourceId", ""))
	var kind := String(row.get("kind", ""))
	var state := String(row.get("state", ""))
	var bounds_value: Variant = row.get("conservativeWorldBounds", null)
	var geometry_owner: Variant = row.get("geometryOwnerSection", null)
	var support_value: Variant = row.get("conservativeSupportSectionKeys", null)
	if source_id.is_empty() or kind not in ["tree", "static_prop", "surface_detail"] \
		or state not in ["pending_recipe", "compiled", "tombstoned"] \
			or not bounds_value is AABB or not _valid_bounds(bounds_value) \
		or not geometry_owner is Vector3i or String(row.get("sourcePartId", "")).is_empty() \
			or not support_value is Array \
			or support_value.is_empty() \
			or not _certified_envelope_matches(row, world_id, runtime_policy):
		return {"status":"pending", "reason":"ecology_support_source_row_uncertified",
			"sourceId":source_id}
	var expected_support := Grid.keys_intersecting_bounds(bounds_value)
	var supplied: Array[Vector3i] = []
	for key_value: Variant in support_value:
		if not key_value is Vector3i or key_value in supplied:
			return {"status":"pending", "reason":"ecology_support_source_sections_invalid",
				"sourceId":source_id}
		supplied.append(key_value)
	supplied.sort_custom(_section_less)
	expected_support.sort_custom(_section_less)
	if supplied != expected_support or geometry_owner != Grid.key_for_world_position(bounds_value.get_center()):
		return {"status":"pending", "reason":"ecology_support_source_envelope_mismatch",
			"sourceId":source_id}
	var family := String(row.get("family", "trees" if kind == "tree" else ""))
	var source_origin: Variant = row.get("sourceOrigin", null)
	if not source_origin is Vector3:
		return {"status":"pending", "reason":"ecology_support_source_origin_missing",
			"sourceId":source_id}
	var bounds_policy := ProducerDomain.validate_source_bounds(family,
		source_origin, bounds_value, runtime_policy)
	if bounds_policy.get("status") != "ready":
		return {"status":"pending", "reason":"ecology_support_source_policy_unproven",
			"sourceId":source_id, "family":family,
			"policyEvidence":bounds_policy}
	var copy := row.duplicate(true)
	copy["schema"] = SOURCE_SCHEMA
	copy["worldId"] = world_id
	copy["sourceChunkKey"] = source_chunk_key
	copy["sourceDomainRevision"] = source_revision
	copy["sourceRevision"] = String(row.get("sourceRevision", source_revision))
	copy["family"] = family
	copy["supportSectionKeys"] = supplied.duplicate()
	copy.make_read_only()
	return {"status":"ready", "row":copy}


func _support_owner_lease(row: Dictionary, support_section: Vector3i,
		world_id: String, section_revision: int, coverage_digest: String) -> Dictionary:
	var member_id := String(row.get("sourcePartId", ""))
	var source_id := String(row.get("sourceId", ""))
	var source_revision := String(row.get("sourceRevision", ""))
	var owner_section: Variant = row.get("geometryOwnerSection", null)
	var chunk: Variant = row.get("sourceChunkKey", null)
	if member_id.is_empty() or source_id.is_empty() or source_revision.is_empty() \
			or not owner_section is Vector3i or not chunk is Vector2i:
		return {}
	var identity := [OWNER_LEASE_SCHEMA, world_id,
		[support_section.x, support_section.y, support_section.z],
		[chunk.x, chunk.y], source_id, source_revision,
		member_id, int(row.get("artifactGeneration", 0)),
		[owner_section.x, owner_section.y, owner_section.z],
		coverage_digest, String(row.get("sourceDomainRevision", "")),
		String(row.get("producerSnapshotRevision", "")),
		String(row.get("influencePolicyRevision", "")),
		String(row.get("influencePolicyDigest", ""))]
	if String(row.get("state", "")) == "tombstoned":
		identity.append(String(row.get("tombstoneRevision", "")))
	var token := _sha256_bytes(var_to_bytes(identity))
	if token.is_empty(): return {}
	return {"schema":OWNER_LEASE_SCHEMA, "worldId":world_id,
		"sourceIndexRevision":section_revision,
		"coverageDigest":coverage_digest,
		"supportSectionKey":support_section, "sourceChunkKey":chunk,
		"sourceDomainRevision":String(row.get("sourceDomainRevision", "")),
		"producerSnapshotRevision":String(row.get("producerSnapshotRevision", "")),
		"terrainVolumeChunkRevision":String(row.get("terrainVolumeChunkRevision", "")),
		"structureAdmissionRevision":String(row.get("structureAdmissionRevision", "")),
		"removedSourceProjectionDigest":String(row.get("removedSourceProjectionDigest", "")),
		"influencePolicyRevision":String(row.get("influencePolicyRevision", "")),
		"influencePolicyDigest":String(row.get("influencePolicyDigest", "")),
		"sourceId":source_id, "sourceRevision":source_revision,
		"memberId":member_id,
		"tombstoneRevision":String(row.get("tombstoneRevision", "")),
		"recipeArtifactGeneration":int(row.get("artifactGeneration", 0)),
		"ownerSectionKey":owner_section,
		"supportLeaseToken":token, "state":String(row.get("state", "pending_recipe"))}


func _certified_envelope_matches(row: Dictionary, world_id: String,
		runtime_policy: Dictionary) -> bool:
	var proof_value: Variant = row.get("certifiedEnvelopeProof", null)
	if not proof_value is Dictionary:
		return false
	var proof: Dictionary = proof_value
	var bounds: Variant = row.get("conservativeWorldBounds", null)
	if not bounds is AABB or not _valid_bounds(bounds):
		return false
	var kind := String(row.get("kind", ""))
	if kind in ["static_prop", "surface_detail"]:
		var family := String(row.get("family", ""))
		if family not in ["surface_rocks", "ore", "forage", "details", "underground_props"]:
			return false
		var family_policy: Variant = runtime_policy.get("families", {}).get(family, null)
		var source_domain_revision := String(row.get("sourceDomainRevision", ""))
		var producer_snapshot_revision := String(row.get("producerSnapshotRevision", ""))
		var resource_descriptor_revision := String(row.get("resourceDescriptorRevision", ""))
		var static_mesh_digest := String(row.get("meshContentDigest", ""))
		var static_policy_revision := String(runtime_policy.get("revision", ""))
		var static_policy_digest := String(runtime_policy.get("digest", ""))
		if not family_policy is Dictionary or String(family_policy.get("status", "")) != "bounded" \
				or source_domain_revision.is_empty() or producer_snapshot_revision.is_empty() \
				or resource_descriptor_revision.is_empty() or static_mesh_digest.length() != 64 \
				or static_policy_revision.is_empty() or static_policy_digest.length() != 64 \
				or String(proof.get("schema", "")) != STATIC_MEMBER_ENVELOPE_SCHEMA \
				or String(proof.get("status", "")) != "ready" \
				or String(proof.get("worldId", "")) != world_id \
				or String(proof.get("sourceId", "")) != String(row.get("sourceId", "")) \
				or String(proof.get("sourcePartId", "")) != String(row.get("sourcePartId", "")) \
				or String(proof.get("family", "")) != family \
				or proof.get("worldBounds", null) != bounds \
				or String(proof.get("meshContentDigest", "")) != static_mesh_digest \
				or String(proof.get("policyRevision", "")) != static_policy_revision \
				or String(proof.get("policyDigest", "")) != static_policy_digest \
				or String(proof.get("sourceDomainRevision", "")) != source_domain_revision \
				or String(proof.get("producerSnapshotRevision", "")) != producer_snapshot_revision \
				or String(proof.get("resourceDescriptorRevision", "")) != resource_descriptor_revision:
			return false
		var expected_static_digest := _sha256_bytes(var_to_bytes([
			STATIC_MEMBER_ENVELOPE_SCHEMA, world_id,
			String(row.get("sourceId", "")), String(row.get("sourcePartId", "")),
			family, bounds, static_mesh_digest, static_policy_revision, static_policy_digest,
			source_domain_revision, producer_snapshot_revision,
			resource_descriptor_revision]))
		return expected_static_digest.length() == 64 \
			and String(proof.get("digest", "")) == expected_static_digest \
			and String(row.get("certifiedEnvelopeDigest", "")) == expected_static_digest
	if kind != "tree":
		return false
	var mesh_digest := String(proof.get("meshContentDigest", ""))
	var policy_revision := String(proof.get("policyRevision", ""))
	var tree_envelope: Variant = runtime_policy.get("treeEnvelope", null)
	var wind_envelope: Variant = tree_envelope.get("visualWindEnvelope", null) \
		if tree_envelope is Dictionary else null
	if not wind_envelope is Dictionary or String(wind_envelope.get("status", "")) != "ready":
		return false
	var active_wind_digest := String(wind_envelope.get("digest", ""))
	var proof_wind_digest := String(proof.get("activeWindEnvelopeDigest", ""))
	var expected := _sha256_bytes(var_to_bytes([
		"ecology-certified-member-envelope/v2", world_id,
		String(row.get("sourceId", "")), String(row.get("sourcePartId", "")),
		bounds, mesh_digest, policy_revision,
		String(row.get("recipeSignature", "")), int(row.get("artifactGeneration", 0)),
		active_wind_digest]))
	return mesh_digest.length() == 64 and policy_revision == TREE_MEMBER_SUPPORT_POLICY \
		and active_wind_digest.length() == 64 and proof_wind_digest == active_wind_digest \
		and expected.length() == 64 \
		and String(proof.get("digest", "")) == expected \
		and String(row.get("certifiedEnvelopeDigest", "")) == expected


func _valid_domain(domain: Dictionary, key: Vector2i) -> bool:
	var source_inputs: Variant = domain.get("sourceInputs", null)
	if not source_inputs is Dictionary:
		return false
	var runtime_policy := ProducerDomain.support_policy(source_inputs)
	return domain.get("sourceChunkKey", null) == key \
		and String(domain.get("worldId", "")) == _world_id \
		and String(domain.get("sourceRevision", "")) != "" \
		and String(domain.get("removedPropsRevision", "")).length() == 64 \
		and String(domain.get("producerSnapshotRevision", "")) != "" \
		and bool(domain.get("producerComplete", false)) \
		and int(domain.get("enumeratedSourceCount", -1)) >= 0 \
		and domain.get("categoriesComplete", []) is Array \
		and String(domain.get("terrainVolumeChunkRevision", "")) != "" \
		and String(domain.get("structureAdmissionRevision", "")) != "" \
		and String(domain.get("structureAdmissionStatus", "")) in ["ready", "complete"] \
		and String(domain.get("removedSourceProjectionDigest", "")).length() == 64 \
		and String(domain.get("sourceManifestDigest", "")).length() == 64 \
		and String(domain.get("supportManifestDigest", "")).length() == 64 \
		and String(runtime_policy.get("status", "")) == "ready" \
		and String(domain.get("influencePolicyRevision", "")) == \
			String(runtime_policy.get("revision", "")) \
		and String(domain.get("influencePolicyDigest", "")) == \
			String(runtime_policy.get("digest", ""))


func _retire_source_to_tombstone(source_key: String, row: Dictionary,
		replacement_revision: String) -> void:
	var tombstone := row.duplicate(true)
	tombstone["state"] = "tombstoned"
	tombstone["tombstoneRevision"] = _sha256_bytes(var_to_bytes([
		"ecology-support-source-tombstone/v1", _world_id,
		String(row.get("sourceId", "")), String(row.get("sourcePartId", "")),
		String(row.get("sourceRevision", "")), replacement_revision]))
	tombstone.make_read_only()
	for section_key: Vector3i in row.get("supportSectionKeys", []):
		if not _retired_postings_by_section.has(section_key):
			_retired_postings_by_section[section_key] = {}
		var retired: Dictionary = _retired_postings_by_section[section_key]
		retired[_retired_row_key(tombstone)] = tombstone
		var postings: Dictionary = _postings_by_section.get(section_key, {})
		postings.erase(source_key)


func _post_row(row: Dictionary) -> void:
	var source_id := _row_key(row)
	for section_key: Vector3i in row.get("supportSectionKeys", []):
		if not _postings_by_section.has(section_key):
			_postings_by_section[section_key] = {}
		var section_postings: Dictionary = _postings_by_section[section_key]
		section_postings[source_id] = row


func _stable_source_tuple(row: Dictionary) -> Array:
	return [String(row.get("sourceId", "")), String(row.get("sourcePartId", "")),
		String(row.get("sourceRevision", "")), Vector2i(row.get("sourceChunkKey", Vector2i.ZERO)),
		String(row.get("sourceDomainRevision", "")),
		String(row.get("producerSnapshotRevision", "")),
		String(row.get("influencePolicyRevision", "")),
		String(row.get("influencePolicyDigest", "")),
		String(row.get("removedSourceProjectionDigest", "")),
		String(row.get("recipeSignature", "")),
		int(row.get("artifactGeneration", 0)), Vector3i(row.get("geometryOwnerSection", Vector3i.ZERO)),
		row.get("conservativeWorldBounds", AABB()),
		row.get("supportSectionKeys", []), String(row.get("state", "")),
		String(row.get("certifiedEnvelopeDigest", "")), String(row.get("tombstoneRevision", ""))]


func _stable_domain_tuple(domain: Dictionary) -> Array:
	return [Vector2i(domain.get("sourceChunkKey", Vector2i.ZERO)),
		String(domain.get("worldId", "")), String(domain.get("sourceRevision", "")),
		String(domain.get("removedPropsRevision", "")),
		String(domain.get("producerSnapshotRevision", "")),
		bool(domain.get("producerComplete", false)), int(domain.get("enumeratedSourceCount", -1)),
		domain.get("categoriesComplete", []),
		String(domain.get("terrainVolumeChunkRevision", "")),
		String(domain.get("structureAdmissionRevision", "")),
		String(domain.get("structureAdmissionStatus", "")),
		String(domain.get("removedSourceProjectionDigest", "")),
		String(domain.get("sourceManifestDigest", "")),
		String(domain.get("supportManifestDigest", "")),
		String(domain.get("influencePolicyRevision", "")),
		String(domain.get("influencePolicyDigest", "")),
		String(ProducerDomain.support_policy(domain.get("sourceInputs", {})).get("digest", ""))]


func _sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _pending(reason: String, section_key: Vector3i, extra := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "sectionKey":section_key,
		"worldId":_world_id, "sourceIndexRevision":_section_revision(section_key)}
	for key: Variant in extra:
		result[key] = extra[key]
	return result


func _invalidate_sections(sections: Dictionary) -> void:
	for section_value: Variant in sections:
		_latest_query_by_section.erase(section_value)


func _section_revision(section_key: Vector3i) -> int:
	return int(_section_index_revision.get(section_key, 0))


func _bump_section_revision(section_key: Vector3i) -> void:
	_next_source_index_revision += 1
	_section_index_revision[section_key] = _next_source_index_revision
	_latest_query_by_section.erase(section_key)


func _bump_sections(sections: Dictionary) -> void:
	for section_key: Vector3i in _sorted_sections(sections):
		_bump_section_revision(section_key)


func _sorted_sections(values: Dictionary) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for value: Variant in values:
		if value is Vector3i: result.append(value)
	result.sort_custom(_section_less)
	return result


func _deep_freeze(value: Variant) -> void:
	if value is Dictionary:
		for child: Variant in value.values(): _deep_freeze(child)
		(value as Dictionary).make_read_only()
	elif value is Array:
		for child: Variant in value: _deep_freeze(child)
		(value as Array).make_read_only()


func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0


func _chunk_less(a: Vector2i, b: Vector2i) -> bool:
	if a.x != b.x: return a.x < b.x
	return a.y < b.y


func _section_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x: return a.x < b.x
	if a.y != b.y: return a.y < b.y
	return a.z < b.z


func _domain_less(a: Dictionary, b: Dictionary) -> bool:
	return _chunk_less(a.sourceChunkKey, b.sourceChunkKey)


func _source_tuple_less(a: Array, b: Array) -> bool:
	if String(a[0]) != String(b[0]): return String(a[0]) < String(b[0])
	return String(a[1]) < String(b[1])


func _row_less(a: Dictionary, b: Dictionary) -> bool:
	var chunk_a := Vector2i(a.get("sourceChunkKey", Vector2i.ZERO))
	var chunk_b := Vector2i(b.get("sourceChunkKey", Vector2i.ZERO))
	if chunk_a != chunk_b:
		return _chunk_less(chunk_a, chunk_b)
	var source_a := String(a.get("sourceId", ""))
	var source_b := String(b.get("sourceId", ""))
	if source_a != source_b:
		return source_a < source_b
	var part_a := String(a.get("sourcePartId", ""))
	var part_b := String(b.get("sourcePartId", ""))
	if part_a != part_b:
		return part_a < part_b
	var revision_a := String(a.get("sourceRevision", ""))
	var revision_b := String(b.get("sourceRevision", ""))
	if revision_a != revision_b:
		return revision_a < revision_b
	var state_a := String(a.get("state", ""))
	var state_b := String(b.get("state", ""))
	if state_a != state_b:
		return state_a < state_b
	return String(a.get("tombstoneRevision", "")) \
		< String(b.get("tombstoneRevision", ""))


func _demand_less(a: Dictionary, b: Dictionary) -> bool:
	if a.sourceChunkKey != b.sourceChunkKey:
		return _chunk_less(a.sourceChunkKey, b.sourceChunkKey)
	if String(a.sourceId) != String(b.sourceId):
		return String(a.sourceId) < String(b.sourceId)
	if String(a.memberId) != String(b.memberId):
		return String(a.memberId) < String(b.memberId)
	if String(a.get("sourceRevision", "")) != String(b.get("sourceRevision", "")):
		return String(a.get("sourceRevision", "")) < String(b.get("sourceRevision", ""))
	if String(a.get("state", "")) != String(b.get("state", "")):
		return String(a.get("state", "")) < String(b.get("state", ""))
	if String(a.get("tombstoneRevision", "")) != String(b.get("tombstoneRevision", "")):
		return String(a.get("tombstoneRevision", "")) < String(b.get("tombstoneRevision", ""))
	return String(a.get("supportLeaseToken", "")) < String(b.get("supportLeaseToken", ""))


func _array_identity_less(a: Array, b: Array) -> bool:
	return var_to_bytes(a).hex_encode() < var_to_bytes(b).hex_encode()


func _row_key(row: Dictionary) -> String:
	return _source_part_identity_key(String(row.get("sourceId", "")),
		String(row.get("sourcePartId", "")))


func _retired_row_key(row: Dictionary) -> String:
	return "%s|%s" % [_row_key(row), String(row.get("tombstoneRevision", ""))]


func _source_part_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()
