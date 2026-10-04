extends RefCounted
class_name StaticSectionSourceRoster

## World-lifetime source census for section candidates. Providers describe
## authoritative source membership; render/readiness owners are not providers.

var _world_id := ""
var _required_provider_ids: Array[String] = []
var _providers: Dictionary = {}
var _registration_generation := 0


func bind_world(world_id: String, required_provider_ids: Array[String]) -> Dictionary:
	if world_id.strip_edges().is_empty() or required_provider_ids.is_empty():
		return _failed("invalid_static_source_roster_binding")
	var normalized: Array[String] = []
	for provider_id in required_provider_ids:
		var value := provider_id.strip_edges()
		if value.is_empty() or value in normalized:
			return _failed("invalid_or_duplicate_static_source_provider_id")
		normalized.append(value)
	normalized.sort()
	if _world_id == world_id:
		if _required_provider_ids != normalized:
			return _failed("static_source_roster_provider_set_changed")
		return {"status":"ready", "worldId":_world_id}
	if not _world_id.is_empty() or not _providers.is_empty():
		return _failed("static_source_roster_already_bound")
	_world_id = world_id
	_required_provider_ids = normalized
	return {"status":"ready", "worldId":_world_id,
		"requiredProviderIds":_required_provider_ids.duplicate()}


func register_provider(provider_id: String, authority_owner: Object,
		capture_method: String) -> Dictionary:
	if _world_id.is_empty() or provider_id not in _required_provider_ids \
			or not is_instance_valid(authority_owner) or capture_method.strip_edges().is_empty() \
			or not authority_owner.has_method(capture_method):
		return _failed("invalid_static_source_provider_registration")
	if _providers.has(provider_id):
		return _failed("static_source_provider_already_registered")
	_registration_generation += 1
	_providers[provider_id] = {
		"owner": weakref(authority_owner),
		"ownerInstanceId": authority_owner.get_instance_id(),
		"captureMethod": capture_method,
		"registrationGeneration": _registration_generation
	}
	return {"status":"ready", "providerId":provider_id,
		"registrationGeneration":_registration_generation}


func unregister_provider(provider_id: String, authority_owner: Object) -> Dictionary:
	var registration: Dictionary = _providers.get(provider_id, {})
	if registration.is_empty() or not is_instance_valid(authority_owner) \
			or int(registration.get("ownerInstanceId", 0)) != authority_owner.get_instance_id():
		return _failed("static_source_provider_owner_mismatch")
	_providers.erase(provider_id)
	return {"status":"ready", "providerId":provider_id,
		"registrationRetired":true}


## Every provider must answer every requested section. A zero-member answer is
## accepted only as an explicit revisioned `empty` coverage record.
func capture_sections(requested_sections: Array) -> Dictionary:
	var provider_phase_usec := {}
	var result := _capture_sections_impl(requested_sections, provider_phase_usec)
	var profiled := result.duplicate(false)
	var frozen_provider_timings := provider_phase_usec.duplicate(false)
	frozen_provider_timings.make_read_only()
	profiled["providerPhaseUsec"] = frozen_provider_timings
	if result.is_read_only():
		profiled.make_read_only()
	return profiled


func _capture_sections_impl(requested_sections: Array,
		provider_phase_usec: Dictionary) -> Dictionary:
	if _world_id.is_empty() or _required_provider_ids.is_empty():
		return _pending("static_source_roster_unconfigured")
	var sections: Array[Vector3i] = []
	for value in requested_sections:
		if not value is Vector3i or value in sections:
			return _failed("invalid_or_duplicate_static_source_section")
		sections.append(value)
	if sections.is_empty():
		return _failed("empty_static_source_section_query")
	sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var callback_sections: Array[Vector3i] = sections.duplicate()
	callback_sections.make_read_only()
	var contributors_by_section: Dictionary = {}
	var source_revisions: Dictionary = {}
	var source_provider_ids: Dictionary = {}
	var provider_snapshot_revisions: Dictionary = {}
	var provider_coverage_revisions: Dictionary = {}
	var removal_revisions: Dictionary = {}
	var removals_by_section: Dictionary = {}
	var provider_generations: Array = []
	var provider_section_revisions: Array = []
	for section in sections:
		contributors_by_section[section] = []
		removals_by_section[section] = []
	for provider_id in _required_provider_ids:
		var registration: Dictionary = _providers.get(provider_id, {})
		if registration.is_empty():
			return _pending("static_source_provider_missing", {"providerId":provider_id})
		var owner_ref: WeakRef = registration.get("owner") as WeakRef
		var owner = owner_ref.get_ref() if owner_ref != null else null
		if not is_instance_valid(owner) or owner.get_instance_id() != int(registration.ownerInstanceId):
			return _pending("static_source_provider_owner_unavailable", {"providerId":provider_id})
		var method := String(registration.captureMethod)
		if not owner.has_method(method):
			return _failed("static_source_provider_method_removed", {"providerId":provider_id})
		var provider_started_usec := Time.get_ticks_usec()
		var raw: Variant = owner.call(method, _world_id, callback_sections)
		provider_phase_usec[provider_id] = Time.get_ticks_usec() - provider_started_usec
		if not raw is Dictionary:
			return _failed("static_source_provider_returned_non_dictionary", {"providerId":provider_id})
		var provider: Dictionary = raw
		var coverage_status := String(provider.get("status", ""))
		if coverage_status == "pending":
			var provider_details := {}
			for detail_key in ["chunk", "snapshotRemovedPropsRevision",
					"currentRemovedPropsRevision", "snapshotSourceRevision", "currentSourceRevision"]:
				if provider.has(detail_key):
					provider_details[detail_key] = provider[detail_key]
			var validation_value: Variant = provider.get("snapshotValidation", {})
			if validation_value is Dictionary:
				provider_details["snapshotValidationStatus"] = String(
					validation_value.get("status", ""))
				provider_details["snapshotValidationReason"] = String(
					validation_value.get("reason", ""))
			provider_details.make_read_only()
			return _pending("static_source_provider_pending", {
				"providerId":provider_id,
				"providerReason":String(provider.get("reason", "coverage_pending")),
				"providerDetails":provider_details,
				"retryable":bool(provider.get("retryable", true))
			})
		if coverage_status != "complete" or String(provider.get("worldId", "")) != _world_id:
			return _failed("invalid_static_source_provider_snapshot", {"providerId":provider_id})
		var authority_revision_value: Variant = provider.get("authorityRevision", null)
		if not authority_revision_value is String:
			return _failed("incomplete_static_source_provider_snapshot", {"providerId":provider_id})
		var authority_revision: String = authority_revision_value
		var source_revision_map: Variant = provider.get("sourceRevisions", null)
		var sections_map: Variant = provider.get("sections", null)
		if authority_revision.is_empty() or not source_revision_map is Dictionary \
				or not sections_map is Dictionary or sections_map.size() != sections.size():
			return _failed("incomplete_static_source_provider_snapshot", {"providerId":provider_id})
		var local_source_revisions: Dictionary = source_revision_map
		var local_coverage_revisions: Dictionary = {}
		var local_contributor_ids: Dictionary = {}
		for source_id_value in local_source_revisions:
			if not source_id_value is String \
					or not local_source_revisions[source_id_value] is String \
					or String(source_id_value).strip_edges().is_empty() \
					or String(local_source_revisions[source_id_value]).is_empty():
				return _failed("invalid_static_source_revision_entry", {"providerId":provider_id})
		for raw_section in sections:
			if not sections_map.has(raw_section):
				return _failed("static_source_provider_omitted_section", {
					"providerId":provider_id, "section":raw_section
				})
			var row: Variant = sections_map[raw_section]
			if not row is Dictionary:
				return _failed("invalid_static_source_section_coverage", {"providerId":provider_id})
			var row_status := String(row.get("status", ""))
			var coverage_revision_value: Variant = row.get("coverageRevision", null)
			if not coverage_revision_value is String:
				return _failed("invalid_static_source_section_coverage", {"providerId":provider_id})
			var coverage_revision: String = coverage_revision_value
			var raw_ids: Variant = row.get("sourcePartIds", null)
			if row_status not in ["complete", "empty"] or coverage_revision.is_empty() \
					or not raw_ids is Array:
				return _failed("invalid_static_source_section_coverage", {"providerId":provider_id})
			var ids: Array[String] = []
			for raw_id in raw_ids:
				if not raw_id is String:
					return _failed("invalid_static_source_contributor_id", {"providerId":provider_id})
				var source_id: String = raw_id
				if source_id.strip_edges().is_empty() or source_id in ids:
					return _failed("invalid_static_source_contributor_id", {"providerId":provider_id})
				if not local_source_revisions.has(source_id) \
						or String(local_source_revisions[source_id]).is_empty():
					return _failed("static_source_contributor_revision_missing", {
						"providerId":provider_id, "sourcePartId":source_id
					})
				ids.append(source_id)
				local_contributor_ids[source_id] = true
			ids.sort()
			if (row_status == "empty") != ids.is_empty():
				return _failed("static_source_empty_coverage_contradiction", {
					"providerId":provider_id, "section":raw_section
				})
			provider_section_revisions.append([provider_id,
				[raw_section.x, raw_section.y, raw_section.z], row_status,
				coverage_revision, ids.duplicate()])
			local_coverage_revisions[raw_section] = coverage_revision
			var merged: Array = contributors_by_section[raw_section]
			for source_id in ids:
				if source_id in merged:
					return _failed("duplicate_static_source_contributor", {"sourcePartId":source_id})
				merged.append(source_id)
		if local_source_revisions.size() != local_contributor_ids.size():
			return _failed("static_source_revision_membership_mismatch", {"providerId":provider_id})
		for source_id_value in local_source_revisions:
			var source_id: String = source_id_value
			var revision: String = local_source_revisions[source_id_value]
			if source_id.strip_edges().is_empty() or revision.is_empty():
				return _failed("invalid_static_source_revision_entry", {"providerId":provider_id})
			if source_provider_ids.has(source_id) and String(source_provider_ids[source_id]) != provider_id:
				return _failed("static_source_contributor_owned_by_multiple_providers", {
					"sourcePartId":source_id
				})
			source_provider_ids[source_id] = provider_id
			if source_revisions.has(source_id) and String(source_revisions[source_id]) != revision:
				return _failed("conflicting_static_source_revision", {"sourcePartId":source_id})
			source_revisions[source_id] = revision
		var provider_removals_value: Variant = provider.get("removalsBySection", {})
		if not provider_removals_value is Dictionary:
			return _failed("invalid_static_source_removal_coverage", {"providerId":provider_id})
		var provider_removals: Dictionary = provider_removals_value
		for section_value: Variant in provider_removals:
			if not section_value is Vector3i or not sections.has(section_value) \
					or not provider_removals[section_value] is Array:
				return _failed("invalid_static_source_removal_section", {"providerId":provider_id})
			for removal_value: Variant in provider_removals[section_value]:
				if not removal_value is Dictionary:
					return _failed("invalid_static_source_removal_record", {"providerId":provider_id})
				var removal: Dictionary = removal_value
				var part_id := String(removal.get("sourcePartId", ""))
				var source_id := String(removal.get("sourceId", ""))
				var revision := String(removal.get("sourceRevision", ""))
				if part_id.is_empty() or source_id.is_empty() or revision.is_empty() \
						or removal.get("sectionKey") != section_value \
						or local_source_revisions.has(part_id):
					return _failed("invalid_or_current_static_source_removal", {
						"providerId":provider_id, "sourcePartId":part_id})
				if removal_revisions.has(part_id) \
						and String(removal_revisions[part_id]) != revision:
					return _failed("conflicting_static_source_removal_revision", {
						"sourcePartId":part_id})
				var section_removals: Array = removals_by_section[section_value]
				for existing_value: Variant in section_removals:
					if String(existing_value.get("sourcePartId", "")) == part_id:
						return _failed("duplicate_static_source_removal", {
							"sourcePartId":part_id, "section":section_value})
				var sealed_removal := removal.duplicate(false)
				sealed_removal["providerId"] = provider_id
				sealed_removal.make_read_only()
				section_removals.append(sealed_removal)
				removal_revisions[part_id] = revision
				provider_section_revisions.append([provider_id,
					[section_value.x, section_value.y, section_value.z], "removed",
					part_id, source_id, revision])
		provider_snapshot_revisions[provider_id] = authority_revision
		local_coverage_revisions.make_read_only()
		provider_coverage_revisions[provider_id] = local_coverage_revisions
		provider_generations.append([provider_id, int(registration.registrationGeneration),
			int(registration.ownerInstanceId), authority_revision])
	for part_id_value: Variant in removal_revisions:
		var part_id := String(part_id_value)
		if source_revisions.has(part_id):
			return _failed("static_source_removal_is_current_contributor", {
				"sourcePartId":part_id})
	for section in sections:
		var contributors: Array = contributors_by_section[section]
		contributors.sort()
		contributors.make_read_only()
		contributors_by_section[section] = contributors
		var section_removals: Array = removals_by_section[section]
		section_removals.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("sourcePartId", "")) < String(b.get("sourcePartId", "")))
		section_removals.make_read_only()
		removals_by_section[section] = section_removals
	contributors_by_section.make_read_only()
	source_revisions.make_read_only()
	source_provider_ids.make_read_only()
	removal_revisions.make_read_only()
	removals_by_section.make_read_only()
	provider_snapshot_revisions.make_read_only()
	provider_coverage_revisions.make_read_only()
	provider_generations.sort_custom(func(a: Array, b: Array) -> bool: return String(a[0]) < String(b[0]))
	var revision_ids: Array = source_revisions.keys()
	revision_ids.sort()
	var revision_rows: Array = []
	for source_id_value in revision_ids:
		var source_id := String(source_id_value)
		revision_rows.append([source_id, String(source_revisions[source_id]),
			String(source_provider_ids[source_id])])
	var section_rows: Array = []
	for section in sections:
		section_rows.append([[section.x, section.y, section.z],
			contributors_by_section[section].duplicate()])
	var removal_rows: Array = []
	for section in sections:
		for removal: Dictionary in removals_by_section[section]:
			removal_rows.append([[section.x, section.y, section.z],
				String(removal.get("providerId", "")), String(removal.sourcePartId),
				String(removal.sourceId), String(removal.sourceRevision)])
	var digest_payload := [_world_id, sections, provider_generations,
		provider_section_revisions, revision_rows, section_rows, removal_rows]
	var census_digest := Marshalls.raw_to_base64(var_to_bytes(digest_payload)).sha256_text()
	sections.make_read_only()
	var result: Dictionary = {"status":"complete", "worldId":_world_id, "sections":sections,
		"sourceRevisions":source_revisions,
		"sourceProviderIds":source_provider_ids,
		"removalRevisions":removal_revisions,
		"removalsBySection":removals_by_section,
		"expectedContributorsBySection":contributors_by_section,
		"providerSnapshotRevisions":provider_snapshot_revisions,
		"providerCoverageRevisions":provider_coverage_revisions,
		"censusDigest":census_digest}
	result.make_read_only()
	return result


## Ask each registered authority owner for the immutable render inputs matching
## an already captured exact census. Every required provider must participate;
## absence of a contribution API or value data is retryable pending, never an
## empty section.
func capture_section_contributions(census: Dictionary,
		section_key: Vector3i) -> Dictionary:
	if census.get("status") != "complete" or census.get("worldId") != _world_id \
			or not census.get("sections", []).has(section_key):
		return _pending("static_section_contribution_census_invalid")
	var contributions: Array[Dictionary] = []
	for provider_id: String in _required_provider_ids:
		var registration: Dictionary = _providers.get(provider_id, {})
		var owner: Object = registration.get("owner").get_ref() \
			if registration.get("owner") is WeakRef else null
		if not is_instance_valid(owner) \
				or owner.get_instance_id() != int(registration.get("ownerInstanceId", 0)):
			return _pending("static_section_contribution_provider_owner_missing", {
				"providerId":provider_id})
		if not owner.has_method("capture_static_section_contribution"):
			return _pending("static_section_contribution_provider_not_implemented", {
				"providerId":provider_id})
		var captured: Dictionary = owner.call("capture_static_section_contribution",
			census, section_key)
		if captured.get("status") != "ready":
			captured["providerId"] = provider_id
			return captured
		var contribution: Variant = captured.get("contribution", {})
		if not contribution is Dictionary or not contribution.is_read_only() \
				or String(contribution.get("providerId", "")) != provider_id \
				or contribution.get("sectionKey") != section_key:
			return _failed("static_section_provider_contribution_invalid", {
				"providerId":provider_id})
		contributions.append(contribution)
	contributions.make_read_only()
	return {"status":"complete", "contributions":contributions}


## Notify source authorities only after the coordinator has verified the live
## native receipt. Providers without an acknowledgement contract keep their
## existing visuals and are intentionally skipped.
func acknowledge_section_install(section_key: Vector3i,
		provider_coverage: Array, receipt: Dictionary) -> Dictionary:
	if not receipt.is_read_only() or receipt.get("status") != "installed" \
			or receipt.get("sectionKey") != section_key or provider_coverage.is_empty():
		return _failed("invalid_static_section_install_acknowledgement")
	var acknowledgements: Array[Dictionary] = []
	for row_value: Variant in provider_coverage:
		if not row_value is Array or row_value.size() < 2:
			return _failed("invalid_static_section_provider_coverage_ack")
		var provider_id := String(row_value[0])
		var coverage_revision := String(row_value[1])
		var registration: Dictionary = _providers.get(provider_id, {})
		var owner: Object = registration.get("owner").get_ref() \
			if registration.get("owner") is WeakRef else null
		if not is_instance_valid(owner) \
				or owner.get_instance_id() != int(registration.get("ownerInstanceId", 0)):
			return _pending("static_section_install_ack_provider_owner_missing", {
				"providerId":provider_id})
		if not owner.has_method("acknowledge_section_install"):
			continue
		var acknowledged: Variant = owner.call("acknowledge_section_install",
			section_key, coverage_revision, receipt)
		if not acknowledged is Dictionary \
				or String(acknowledged.get("status", "")) not in ["acknowledged", "pending"]:
			return _failed("static_section_install_ack_provider_rejected", {
				"providerId":provider_id, "result":acknowledged})
		var row := {"providerId":provider_id,
			"coverageRevision":coverage_revision, "result":acknowledged}
		row.make_read_only()
		acknowledgements.append(row)
	acknowledgements.make_read_only()
	return {"status":"acknowledged", "sectionKey":section_key,
		"providerAcknowledgements":acknowledgements}


func is_snapshot_current(snapshot: Dictionary) -> bool:
	if snapshot.get("status") != "complete" or snapshot.get("worldId") != _world_id:
		return false
	var latest := capture_sections(snapshot.get("sections", []))
	return latest.get("status") == "complete" \
		and String(latest.get("censusDigest", "")) == String(snapshot.get("censusDigest", ""))


func _pending(reason: String, detail := {}) -> Dictionary:
	var result: Dictionary = {"status":"pending", "worldId":_world_id,
		"reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


func _failed(reason: String, detail := {}) -> Dictionary:
	var result: Dictionary = {"status":"failed", "worldId":_world_id,
		"reason":reason, "retryable":false}
	result.merge(detail, true)
	return result
