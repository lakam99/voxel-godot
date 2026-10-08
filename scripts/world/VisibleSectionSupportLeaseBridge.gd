extends RefCounted
class_name VisibleSectionSupportLeaseBridge

## Holds independent, certificate-backed ecology support snapshots per render
## section. A failed query never turns into an empty section and never releases
## the last accepted lease set.

const SectionGrid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const MAX_SUPPORT_VIEW_SECTION_QUERIES_PER_REFRESH := 32
const MAX_SUPPORT_OWNER_SECTION_QUERIES_PER_REFRESH := 8

var _views: Dictionary = {}


func clear() -> void:
	_views.clear()


func release_view(view_owner: String) -> void:
	_views.erase(view_owner)


func reconcile_view(view_owner: String, manifest: Dictionary, provider: Object) -> Dictionary:
	if view_owner.is_empty() or not _valid_manifest(manifest) \
			or not is_instance_valid(provider) \
			or not provider.has_method("query_section") \
			or not provider.has_method("validate_coverage_certificate"):
		return {"status":"pending", "reason":"support_manifest_or_index_unavailable",
			"retryable":true}
	var identity := _view_identity(manifest)
	var state: Dictionary = _views.get(view_owner, {"identity":identity,
		"accepted":{}, "pending":{}, "ownerSections":{},
		"sectionQueryCursor":0, "ownerQueryCursor":0})
	if state.get("identity", {}) != identity:
		# Keep accepted per-section leases during view rebases. Only query rows
		# that remain required; rows absent from this complete manifest can retire.
		state["identity"] = identity
	state["required"] = true
	var wanted: Dictionary = {}
	var section_keys: Array[Vector3i] = []
	for key_value: Variant in manifest.sectionKeys:
		if not key_value is Vector3i:
			return {"status":"failed", "reason":"invalid_required_support_section_key"}
		var section_key := Vector3i(key_value)
		wanted[section_key] = true
		section_keys.append(section_key)
	section_keys.sort_custom(_section_less)
	var section_query_count := mini(MAX_SUPPORT_VIEW_SECTION_QUERIES_PER_REFRESH,
		section_keys.size())
	var section_cursor := posmod(int(state.get("sectionQueryCursor", 0)),
		maxi(1, section_keys.size()))
	var pending_queries := section_keys.size() - section_query_count
	for offset in section_query_count:
		var section_key: Vector3i = section_keys[(section_cursor + offset) % section_keys.size()]
		var snapshot := snapshot_section(provider, manifest, section_key)
		if snapshot.is_empty():
			# Preserve both the pending replacement and accepted lease for this slot.
			pending_queries += 1
			continue
		var accepted: Dictionary = state.get("accepted", {})
		var prior: Dictionary = accepted.get(section_key, {})
		if not prior.is_empty() and String(prior.get("snapshotDigest", "")) \
				== String(snapshot.snapshotDigest):
			# Identical installed content can carry forward, but the accepted lease
			# snapshot must still bind to the current view/request identity.
			accepted[section_key] = snapshot
			state.get("pending", {}).erase(section_key)
		elif not prior.is_empty() \
				and prior.get("contributors", []) == snapshot.get("contributors", []) \
				and prior.get("supportOwnerDemands", []) == snapshot.get("supportOwnerDemands", []):
			# A global index revision can advance because of a distant source. The
			# complete local certificate was revalidated, and this slot's exact
			# contributor/lease manifest is unchanged, so retain its installed output.
			accepted[section_key] = snapshot
			state.get("pending", {}).erase(section_key)
		else:
			var pending_for_view: Dictionary = state.get("pending", {})
			pending_for_view[section_key] = snapshot
			state["pending"] = pending_for_view
	state["sectionQueryCursor"] = (section_cursor + section_query_count) % maxi(1, section_keys.size())
	# A complete manifest makes removed sections authoritative; section-level
	# query incompleteness above affects only that section's lease.
	var accepted_sections: Dictionary = state.get("accepted", {})
	var pending_sections: Dictionary = state.get("pending", {})
	for section_value: Variant in accepted_sections.keys():
		if section_value is Vector3i and not wanted.has(section_value):
			accepted_sections.erase(section_value)
	for section_value: Variant in pending_sections.keys():
		if section_value is Vector3i and not wanted.has(section_value):
			pending_sections.erase(section_value)
	state["accepted"] = accepted_sections
	state["pending"] = pending_sections
	state["requiredSections"] = wanted.duplicate()
	var required_owners: Dictionary = {}
	for snapshot_value: Variant in accepted_sections.values() + pending_sections.values():
		if not snapshot_value is Dictionary:
			continue
		for lease_value: Variant in snapshot_value.get("supportOwnerDemands", []):
			if lease_value is Dictionary and lease_value.get("ownerSectionKey") is Vector3i:
				required_owners[Vector3i(lease_value.ownerSectionKey)] = true
	var owner_sections: Dictionary = state.get("ownerSections", {})
	var owner_keys: Array[Vector3i] = []
	for owner_key: Variant in required_owners:
		if owner_key is Vector3i: owner_keys.append(Vector3i(owner_key))
	owner_keys.sort_custom(_section_less)
	var owner_query_count := mini(MAX_SUPPORT_OWNER_SECTION_QUERIES_PER_REFRESH,
		owner_keys.size())
	var owner_cursor := posmod(int(state.get("ownerQueryCursor", 0)), maxi(1, owner_keys.size()))
	var pending_owner_queries := owner_keys.size() - owner_query_count
	for offset in owner_query_count:
		var owner_key: Vector3i = owner_keys[(owner_cursor + offset) % owner_keys.size()]
		var owner_snapshot := snapshot_section(provider, manifest, owner_key)
		if not owner_snapshot.is_empty(): owner_sections[owner_key] = owner_snapshot
		else: pending_owner_queries += 1
	state["ownerQueryCursor"] = (owner_cursor + owner_query_count) % maxi(1, owner_keys.size())
	for owner_key: Variant in owner_sections.keys():
		if not required_owners.has(owner_key): owner_sections.erase(owner_key)
	state["ownerSections"] = owner_sections
	_views[view_owner] = state
	var pending_total := pending_queries + pending_owner_queries
	return {"status":"pending" if pending_total > 0 else "ready",
		"reason":"support_section_query_pending" if pending_total > 0 else "",
		"retryable":pending_total > 0, "viewOwner":view_owner,
		"requestId":int(manifest.requestId), "viewRevision":int(manifest.viewRevision),
		"requiredSectionCount":wanted.size(),
		"acceptedSectionCount":accepted_sections.size(),
		"pendingSectionCount":pending_sections.size(),
		"pendingQueryCount":pending_total,
		"ownerCells":owner_demand_cells(view_owner)}


static func _section_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x: return a.x < b.x
	if a.y != b.y: return a.y < b.y
	return a.z < b.z


func snapshot_section(provider: Object, manifest: Dictionary,
		section_key: Vector3i) -> Dictionary:
	if not _valid_manifest(manifest) or not is_instance_valid(provider) \
			or not provider.has_method("query_section") \
			or not provider.has_method("validate_coverage_certificate"):
		return {}
	var query: Dictionary = provider.call("query_section", String(manifest.worldId), section_key)
	if query.get("status") != "ready" or not _validate_query(provider, query,
			section_key, String(manifest.worldId)):
		return {}
	return _freeze_query(query, manifest)


func required_section_snapshots(view_owner: String) -> Dictionary:
	var state: Dictionary = _views.get(view_owner, {})
	return {"accepted":state.get("accepted", {}).duplicate(),
		"pending":state.get("pending", {}).duplicate(),
		"ownerSections":state.get("ownerSections", {}).duplicate(),
		"identity":state.get("identity", {}).duplicate(true)}


func owner_demand_cells(view_owner: String) -> Dictionary:
	var result: Dictionary = {}
	var state: Dictionary = _views.get(view_owner, {})
	for section_value: Variant in state.get("requiredSections", {}):
		if section_value is Vector3i:
			result[SectionGrid.chunk_key_for_section(Vector3i(section_value))] = true
	for set_name: String in ["accepted", "pending"]:
		var snapshots: Dictionary = state.get(set_name, {})
		for snapshot_value: Variant in snapshots.values():
			if not snapshot_value is Dictionary:
				continue
			for lease_value: Variant in snapshot_value.get("supportOwnerDemands", []):
				var owner_value: Variant = lease_value.get("ownerSectionKey", null) \
					if lease_value is Dictionary else null
				if lease_value is Dictionary and owner_value is Vector3i:
					result[SectionGrid.chunk_key_for_section(
						Vector3i(owner_value))] = true
	return result


func active_section_keys(view_owner: String) -> Dictionary:
	var result: Dictionary = {}
	var state: Dictionary = _views.get(view_owner, {})
	for key_value: Variant in state.get("requiredSections", {}):
		if key_value is Vector3i: result[key_value] = true
	for set_name: String in ["accepted", "pending", "ownerSections"]:
		for key_value: Variant in state.get(set_name, {}).keys():
			if key_value is Vector3i: result[key_value] = true
	return result


func promote_section(view_owner: String, section_key: Vector3i,
		installed_snapshot_digest: String) -> bool:
	var state: Dictionary = _views.get(view_owner, {})
	var pending: Dictionary = state.get("pending", {})
	var replacement: Dictionary = pending.get(section_key, {})
	if replacement.is_empty() or String(replacement.get("snapshotDigest", "")) \
			!= installed_snapshot_digest:
		return false
	var accepted: Dictionary = state.get("accepted", {})
	accepted[section_key] = replacement
	state["accepted"] = accepted
	pending.erase(section_key)
	_views[view_owner] = state
	return true


func _validate_query(provider: Object, query: Dictionary, section_key: Vector3i,
		world_id: String) -> bool:
	if String(query.get("schema", "")) != "ecology-world-support-query/v1" \
			or String(query.get("worldId", "")) != world_id \
			or query.get("sectionKey") != section_key \
			or String(query.get("sourceIndexRevision", "")).is_empty() \
			or not query.get("coverageCertificate") is Dictionary \
			or not query.coverageCertificate.is_read_only() \
			or not query.get("contributors") is Array \
			or not query.contributors.is_read_only() \
			or not query.get("supportOwnerDemands") is Array \
			or not query.supportOwnerDemands.is_read_only():
		return false
	for contributor_value: Variant in query.contributors:
		if not contributor_value is Dictionary or not contributor_value.is_read_only():
			return false
	var validation: Dictionary = provider.call("validate_coverage_certificate",
		query.coverageCertificate, world_id, section_key)
	return validation.get("status") == "ready"


func _freeze_query(query: Dictionary, manifest: Dictionary) -> Dictionary:
	var leases: Array = []
	for lease_value: Variant in query.supportOwnerDemands:
		if not lease_value is Dictionary or not lease_value.is_read_only():
			return {}
		if String(lease_value.get("schema", "")) != "ecology-support-owner-lease/v1" \
				or lease_value.get("supportSectionKey") != query.sectionKey \
				or String(lease_value.get("worldId", "")) != String(query.worldId) \
				or String(lease_value.get("sourceIndexRevision", "")) \
					!= String(query.sourceIndexRevision) \
				or String(lease_value.get("coverageDigest", "")) \
					!= String(query.coverageCertificate.get("coverageDigest", "")) \
				or String(lease_value.get("sourceId", "")).is_empty() \
				or String(lease_value.get("sourceRevision", "")).is_empty() \
				or String(lease_value.get("supportLeaseToken", "")).is_empty() \
				or String(lease_value.get("memberId", "")).is_empty() \
				or String(lease_value.get("sourceDomainRevision", "")).is_empty() \
				or String(lease_value.get("producerSnapshotRevision", "")).is_empty() \
				or (int(lease_value.get("recipeArtifactGeneration", 0)) <= 0 \
					and (String(lease_value.get("kind", "")) not in ["static_prop", "surface_detail"] \
						or String(lease_value.get("certifiedEnvelopeDigest", "")).length() != 64)) \
				or not lease_value.get("ownerSectionKey") is Vector3i:
			return {}
		leases.append(lease_value)
	leases.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("supportLeaseToken", "")) < String(b.get("supportLeaseToken", "")))
	leases.make_read_only()
	var digest := String(query.coverageCertificate.get("coverageDigest", ""))
	if digest.length() != 64:
		return {}
	var snapshot := {"schema":"visible-support-section-snapshot/v1",
		"viewOwner":String(manifest.viewOwner), "requestId":int(manifest.requestId),
		"viewRevision":int(manifest.viewRevision), "demandRevision":int(manifest.demandRevision),
		"worldId":String(query.worldId), "supportSectionKey":query.sectionKey,
		"sourceIndexRevision":String(query.sourceIndexRevision),
		"coverageDigest":digest, "coverageCertificate":query.coverageCertificate,
		"contributors":query.contributors, "supportOwnerDemands":leases,
		"snapshotDigest":digest}
	snapshot.make_read_only()
	return snapshot


func _valid_manifest(manifest: Dictionary) -> bool:
	return manifest.get("status") == "ready" \
		and String(manifest.get("schema", "")) == "voxel-terrain-required-section-set/v1" \
		and int(manifest.get("requestId", 0)) > 0 \
		and int(manifest.get("viewRevision", 0)) > 0 \
		and manifest.get("sectionKeys") is Array \
		and String(manifest.get("worldRevision", "")).is_empty() == false


func _view_identity(manifest: Dictionary) -> Dictionary:
	return {"requestId":int(manifest.requestId), "seed":String(manifest.seed),
		"worldRevision":String(manifest.worldRevision),
		"viewRevision":int(manifest.viewRevision),
		"demandRevision":int(manifest.demandRevision),
		"centerCells":manifest.centerCells, "radiusCells":int(manifest.radiusCells),
		"worldId":String(manifest.worldId)}
