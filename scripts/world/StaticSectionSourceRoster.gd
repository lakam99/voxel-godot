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


func release_section_capture_demand(section_key: Vector3i) -> void:
	# Capture subscribers follow render demand, independently of installed-slot
	# acknowledgement. Releasing a subscriber must not retire a visible slot.
	for registration: Dictionary in _providers.values():
		var owner_ref: WeakRef = registration.get("owner")
		var owner: Object = owner_ref.get_ref() if owner_ref != null else null
		if is_instance_valid(owner) and owner.has_method("release_section_capture_demand"):
			owner.call("release_section_capture_demand", section_key)


## Every provider must answer every requested section. A zero-member answer is
## accepted only as an explicit revisioned `empty` coverage record.
func capture_sections(requested_sections: Array,
		phase_observer: Callable = Callable()) -> Dictionary:
	var provider_phase_usec := {}
	var result := _capture_sections_impl(requested_sections, provider_phase_usec,
		phase_observer)
	var profiled := result.duplicate(false)
	var frozen_provider_timings := provider_phase_usec.duplicate(false)
	frozen_provider_timings.make_read_only()
	profiled["providerPhaseUsec"] = frozen_provider_timings
	if result.is_read_only():
		profiled.make_read_only()
	return profiled


func _capture_sections_impl(requested_sections: Array,
		provider_phase_usec: Dictionary, phase_observer: Callable) -> Dictionary:
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
	var source_identities: Dictionary = {}
	var provider_snapshot_revisions: Dictionary = {}
	var provider_coverage_revisions: Dictionary = {}
	var removal_revisions: Dictionary = {}
	var removal_provider_ids: Dictionary = {}
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
		_emit_capture_phase(phase_observer, "provider_census_capture", {
			"providerId":provider_id, "sections":callback_sections})
		var provider_started_usec := Time.get_ticks_usec()
		var raw: Variant = owner.call(method, _world_id, callback_sections)
		provider_phase_usec[provider_id] = Time.get_ticks_usec() - provider_started_usec
		if not raw is Dictionary:
			return _failed("static_source_provider_returned_non_dictionary", {"providerId":provider_id})
		var provider: Dictionary = raw
		var coverage_status := String(provider.get("status", ""))
		if coverage_status == "pending":
			var provider_details := {}
			for detail_key in ["chunk", "sourceId", "sourcePartId", "cell", "blockType",
					"missingCategories", "categoryEvidence",
					"supportPolicyDiagnostic", "producerStatus",
					"sourceChunkKey",
					"family", "materialClass", "meshFingerprintStatus",
					"meshContentDigest", "declaredMeshContentDigest",
					"materialContentDigest", "declaredMaterialContentDigest",
					"meshDigestLength",
					"declaredMeshDigestLength", "meshDigestMatches",
					"materialDigestLength", "declaredMaterialDigestLength",
					"materialDigestMatches", "resourceDescriptorRevisionLength",
					"snapshotRemovedPropsRevision",
					"currentRemovedPropsRevision", "snapshotSourceRevision", "currentSourceRevision"]:
				if provider.has(detail_key):
					provider_details[detail_key] = provider[detail_key]
			var capture_progress_value: Variant = provider.get("captureProgress", null)
			if capture_progress_value is Dictionary:
				var capture_progress: Dictionary = capture_progress_value
				var completed_categories: Array = capture_progress.get("completedCategories", []) \
					if capture_progress.get("completedCategories", []) is Array else []
				completed_categories.make_read_only()
				var capture_summary := {
					"phase":String(capture_progress.get("phase", "")),
					"surfaceAttempt":int(capture_progress.get("surfaceAttempt", 0)),
					"detailAttempt":int(capture_progress.get("detailAttempt", 0)),
					"detailAttempts":int(capture_progress.get("detailAttempts", 0)),
					"undergroundColumn":int(capture_progress.get("undergroundColumn", 0)),
					"undergroundCandidateCount":int(capture_progress.get(
						"undergroundCandidateCount", 0)),
					"undergroundAttempt":int(capture_progress.get("undergroundAttempt", 0)),
					"sourceCount":int(capture_progress.get("sourceCount", 0)),
					"completedCategories":completed_categories}
				capture_summary.make_read_only()
				provider_details["captureProgress"] = capture_summary
			var validation_value: Variant = provider.get("snapshotValidation", {})
			if validation_value is Dictionary:
				provider_details["snapshotValidationStatus"] = String(
					validation_value.get("status", ""))
				provider_details["snapshotValidationReason"] = String(
					validation_value.get("reason", ""))
			provider_details.make_read_only()
			var pending_detail := {
				"providerId":provider_id,
				"providerReason":String(provider.get("reason", "coverage_pending")),
				"providerDetails":provider_details,
				"retryable":bool(provider.get("retryable", true))
			}
			var continuation_value: Variant = provider.get("continuationHint", null)
			var continuation_hint := _validated_continuation_hint(continuation_value)
			if not continuation_hint.is_empty():
				pending_detail["continuationHint"] = continuation_hint
			return _pending("static_source_provider_pending", pending_detail)
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
		var identity_map: Dictionary = {}
		var provider_identity_value: Variant = provider.get("sourceIdentities", {})
		var provider_identities: Dictionary = provider_identity_value \
			if provider_identity_value is Dictionary else {}
		var local_source_revisions: Dictionary = {}
		for raw_identity_value: Variant in source_revision_map:
			if not raw_identity_value is String \
					or not source_revision_map[raw_identity_value] is String:
				return _failed("invalid_static_source_revision_entry", {"providerId":provider_id})
			var raw_identity := String(raw_identity_value)
			var identity_value: Variant = provider_identities.get(raw_identity, null)
			var source_id := raw_identity
			var source_part_id := raw_identity
			if identity_value is Dictionary:
				source_id = String(identity_value.get("sourceId", ""))
				source_part_id = String(identity_value.get("sourcePartId", ""))
			if source_id.is_empty() or source_part_id.is_empty():
				return _failed("invalid_static_source_identity", {"providerId":provider_id})
			var identity_key := _source_part_identity_key(source_id, source_part_id)
			if identity_key.is_empty() or local_source_revisions.has(identity_key):
				return _failed("duplicate_static_source_identity", {"providerId":provider_id})
			var normalized_identity := {"sourceId":source_id, "sourcePartId":source_part_id}
			normalized_identity.make_read_only()
			identity_map[identity_key] = normalized_identity
			local_source_revisions[identity_key] = String(source_revision_map[raw_identity_value])
		var local_coverage_revisions: Dictionary = {}
		var local_contributor_ids: Dictionary = {}
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
			var raw_parts: Variant = row.get("sourceParts", null)
			var raw_ids: Variant = row.get("sourcePartIds", null)
			if row_status not in ["complete", "empty"] or coverage_revision.is_empty() \
					or (not raw_parts is Array and not raw_ids is Array):
				return _failed("invalid_static_source_section_coverage", {"providerId":provider_id})
			var ids: Array[String] = []
			var parts: Array = raw_parts if raw_parts is Array else []
			if not raw_parts is Array:
				for raw_id: Variant in raw_ids:
					parts.append({"sourceId":String(raw_id), "sourcePartId":String(raw_id)})
			for part_value: Variant in parts:
				if not part_value is Dictionary:
					return _failed("invalid_static_source_contributor_identity", {"providerId":provider_id})
				var source_id := String(part_value.get("sourceId", ""))
				var source_part_id := String(part_value.get("sourcePartId", ""))
				var identity_key := _source_part_identity_key(source_id, source_part_id)
				if identity_key.is_empty() or identity_key in ids:
					return _failed("invalid_static_source_contributor_id", {"providerId":provider_id})
				if not local_source_revisions.has(identity_key) \
						or String(local_source_revisions[identity_key]).is_empty():
					return _failed("static_source_contributor_revision_missing", {
						"providerId":provider_id, "sourceId":source_id,
						"sourcePartId":source_part_id
					})
				ids.append(identity_key)
				local_contributor_ids[identity_key] = true
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
			for identity_key in ids:
				if identity_key in merged:
					return _failed("duplicate_static_source_contributor", {
						"sourceIdentity":identity_key})
				merged.append(identity_key)
		if local_source_revisions.size() != local_contributor_ids.size():
			return _failed("static_source_revision_membership_mismatch", {"providerId":provider_id})
		for identity_key_value: Variant in local_source_revisions:
			var identity_key := String(identity_key_value)
			var revision: String = local_source_revisions[identity_key_value]
			var identity: Dictionary = identity_map.get(identity_key, {})
			if identity.is_empty() or revision.is_empty():
				return _failed("invalid_static_source_revision_entry", {"providerId":provider_id})
			if source_provider_ids.has(identity_key) and String(source_provider_ids[identity_key]) != provider_id:
				return _failed("static_source_contributor_owned_by_multiple_providers", {
					"sourceId":identity.sourceId, "sourcePartId":identity.sourcePartId
				})
			source_provider_ids[identity_key] = provider_id
			source_identities[identity_key] = identity
			if source_revisions.has(identity_key) and String(source_revisions[identity_key]) != revision:
				return _failed("conflicting_static_source_revision", {
					"sourceId":identity.sourceId, "sourcePartId":identity.sourcePartId})
			source_revisions[identity_key] = revision
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
				var source_id := String(removal.get("sourceId", ""))
				var part_id := String(removal.get("sourcePartId", ""))
				var identity_key := _source_part_identity_key(source_id, part_id)
				var revision := String(removal.get("sourceRevision", ""))
				if identity_key.is_empty() or revision.is_empty() \
						or removal.get("sectionKey") != section_value \
						or identity_key in contributors_by_section[section_value]:
					return _failed("invalid_or_current_static_source_removal", {
						"providerId":provider_id, "sourceId":source_id,
						"sourcePartId":part_id})
				if removal_revisions.has(identity_key) \
						and String(removal_revisions[identity_key]) != revision:
					return _failed("conflicting_static_source_removal_revision", {
						"sourceId":source_id, "sourcePartId":part_id})
				if removal_provider_ids.has(identity_key) \
						and removal_provider_ids[identity_key] != provider_id:
					return _failed("static_source_removal_owned_by_multiple_providers", {
						"sourceId":source_id, "sourcePartId":part_id})
				removal_provider_ids[identity_key] = provider_id
				var section_removals: Array = removals_by_section[section_value]
				for existing_value: Variant in section_removals:
					if _source_part_identity_key(String(existing_value.get("sourceId", "")),
							String(existing_value.get("sourcePartId", ""))) == identity_key:
						return _failed("duplicate_static_source_removal", {
							"sourcePartId":part_id, "section":section_value})
				var sealed_removal := removal.duplicate(false)
				sealed_removal["providerId"] = provider_id
				sealed_removal.make_read_only()
				section_removals.append(sealed_removal)
				removal_revisions[identity_key] = revision
				provider_section_revisions.append([provider_id,
					[section_value.x, section_value.y, section_value.z], "removed",
					part_id, source_id, revision])
		provider_snapshot_revisions[provider_id] = authority_revision
		local_coverage_revisions.make_read_only()
		provider_coverage_revisions[provider_id] = local_coverage_revisions
		provider_generations.append([provider_id, int(registration.registrationGeneration),
			int(registration.ownerInstanceId), authority_revision])
	for part_id_value: Variant in removal_revisions:
		var identity_key := String(part_id_value)
		if source_revisions.has(identity_key) and (
				String(source_revisions[identity_key]) != String(removal_revisions[identity_key])
				or String(source_provider_ids.get(identity_key, "")) != String(removal_provider_ids.get(identity_key, ""))):
			return _failed("static_source_removal_is_current_contributor", {
				"sourceIdentity":identity_key})
	for section in sections:
		var contributors: Array = contributors_by_section[section]
		contributors.sort()
		contributors.make_read_only()
		contributors_by_section[section] = contributors
		var section_removals: Array = removals_by_section[section]
		for removal_value: Dictionary in section_removals:
			var removed_identity := _source_part_identity_key(String(removal_value.sourceId),
				String(removal_value.sourcePartId))
			if removed_identity in contributors:
				return _failed("invalid_or_current_static_source_removal", {
					"sourceIdentity":removed_identity, "section":section})
		section_removals.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return _source_part_identity_key(String(a.get("sourceId", "")),
				String(a.get("sourcePartId", ""))) < _source_part_identity_key(
				String(b.get("sourceId", "")), String(b.get("sourcePartId", ""))))
		section_removals.make_read_only()
		removals_by_section[section] = section_removals
	contributors_by_section.make_read_only()
	source_revisions.make_read_only()
	source_provider_ids.make_read_only()
	source_identities.make_read_only()
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
		"sourceIdentities":source_identities,
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
		section_key: Vector3i, candidate_generation := 1,
		phase_observer: Callable = Callable()) -> Dictionary:
	var provider_phase_usec: Dictionary = {}
	var result := _capture_section_contributions_impl(census, section_key,
		candidate_generation, provider_phase_usec, phase_observer)
	var profiled := result.duplicate(false)
	var timings := provider_phase_usec.duplicate(false)
	timings.make_read_only()
	profiled["providerPhaseUsec"] = timings
	if result.is_read_only(): profiled.make_read_only()
	return profiled


func _capture_section_contributions_impl(census: Dictionary,
		section_key: Vector3i, candidate_generation: int,
		provider_phase_usec: Dictionary, phase_observer: Callable) -> Dictionary:
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
		_emit_capture_phase(phase_observer, "provider_contribution_capture", {
			"providerId":provider_id, "sectionKey":section_key})
		var provider_started_usec := Time.get_ticks_usec()
		var accepts_generation := false
		for method_value: Variant in owner.get_method_list():
			if method_value is Dictionary \
					and String(method_value.get("name", "")) == "capture_static_section_contribution":
				accepts_generation = method_value.get("args", []).size() >= 3
				break
		var captured: Dictionary = owner.call("capture_static_section_contribution",
			census, section_key, candidate_generation) if accepts_generation else \
			owner.call("capture_static_section_contribution", census, section_key)
		provider_phase_usec[provider_id] = Time.get_ticks_usec() - provider_started_usec
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


static func _emit_capture_phase(observer: Callable, phase: String,
		details: Dictionary) -> void:
	if observer.is_valid():
		observer.call(phase, details)


## Notify source authorities only after the coordinator has verified the live
## native receipt. Providers without an acknowledgement contract keep their
## existing visuals and are intentionally skipped.
func acknowledge_section_install(section_key: Vector3i,
		provider_coverage: Array, receipt: Dictionary,
		current_census: Dictionary = {}) -> Dictionary:
	if not receipt.is_read_only() or receipt.get("status") != "installed" \
			or receipt.get("sectionKey") != section_key or provider_coverage.is_empty():
		return _failed("invalid_static_section_install_acknowledgement")
	var acknowledgements: Array[Dictionary] = []
	var provider_phase_usec: Dictionary = {}
	var has_pending_provider := false
	var pending_reason := ""
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
		var provider_started_usec := Time.get_ticks_usec()
		var acknowledged: Variant
		if owner.has_method("acknowledge_section_install_with_census") \
				and current_census.get("status") == "complete":
			var provider_census := _provider_acknowledgement_census(
				current_census, provider_id, section_key)
			if provider_census.get("status") != "complete":
				return _pending("static_section_ack_provider_census_unavailable", {
					"providerId":provider_id, "providerCensus":provider_census})
			acknowledged = owner.call("acknowledge_section_install_with_census",
				section_key, coverage_revision, receipt, provider_census)
		else:
			acknowledged = owner.call("acknowledge_section_install",
				section_key, coverage_revision, receipt)
		provider_phase_usec[provider_id] = Time.get_ticks_usec() - provider_started_usec
		if not acknowledged is Dictionary \
				or String(acknowledged.get("status", "")) not in ["acknowledged", "pending"]:
			return _failed("static_section_install_ack_provider_rejected", {
				"providerId":provider_id, "result":acknowledged,
				"providerPhaseUsec":provider_phase_usec.duplicate(false)})
		var row := {"providerId":provider_id,
			"coverageRevision":coverage_revision, "result":acknowledged}
		row.make_read_only()
		acknowledgements.append(row)
		has_pending_provider = has_pending_provider \
			or String(acknowledged.get("status", "")) == "pending"
		if String(acknowledged.get("status", "")) == "pending" and pending_reason.is_empty():
			pending_reason = String(acknowledged.get("reason", "static_section_provider_ack_pending"))
	acknowledgements.make_read_only()
	provider_phase_usec.make_read_only()
	return {"status":"pending" if has_pending_provider else "acknowledged",
		"retryable":has_pending_provider, "reason":pending_reason,
		"sectionKey":section_key,
		"providerAcknowledgements":acknowledgements,
		"providerPhaseUsec":provider_phase_usec}


## Build the exact current provider view from the coordinator's already
## recaptured immutable census. This avoids making ACK providers rescan the
## world after the coordinator has compared the candidate census digest.
func _provider_acknowledgement_census(census: Dictionary, provider_id: String,
		section_key: Vector3i) -> Dictionary:
	var expected_by_section: Variant = census.get("expectedContributorsBySection", {})
	var provider_by_identity: Variant = census.get("sourceProviderIds", {})
	var identities: Variant = census.get("sourceIdentities", {})
	var revisions: Variant = census.get("sourceRevisions", {})
	var provider_revisions: Variant = census.get("providerSnapshotRevisions", {})
	var coverage_by_provider: Variant = census.get("providerCoverageRevisions", {})
	var section_values: Variant = expected_by_section.get(section_key, []) \
		if expected_by_section is Dictionary else null
	if census.get("status") != "complete" or not census.is_read_only() \
			or not section_values is Array or not section_values.is_read_only() \
			or not provider_by_identity is Dictionary or not provider_by_identity.is_read_only() \
			or not identities is Dictionary or not identities.is_read_only() \
			or not revisions is Dictionary or not revisions.is_read_only() \
			or not provider_revisions is Dictionary or not provider_revisions.is_read_only() \
			or not coverage_by_provider is Dictionary or not coverage_by_provider.is_read_only():
		return _pending("static_section_ack_census_unsealed")
	var source_ids: Array[String] = []
	var source_revisions: Dictionary = {}
	for identity_value: Variant in section_values:
		var identity_key := String(identity_value)
		if String(provider_by_identity.get(identity_key, "")) != provider_id:
			continue
		var identity_value_record: Variant = identities.get(identity_key, null)
		if not identity_value_record is Dictionary or not identity_value_record.is_read_only():
			return _pending("static_section_ack_source_identity_missing", {
				"providerId":provider_id, "identityKey":identity_key})
		var source_id := String(identity_value_record.get("sourceId", ""))
		var revision := String(revisions.get(identity_key, ""))
		if source_id.is_empty() or revision.is_empty():
			return _pending("static_section_ack_source_revision_missing", {
				"providerId":provider_id, "identityKey":identity_key})
		if source_revisions.has(source_id) and String(source_revisions[source_id]) != revision:
			return _failed("static_section_ack_source_revision_conflict", {
				"providerId":provider_id, "sourceId":source_id})
		source_ids.append(source_id)
		source_revisions[source_id] = revision
	source_ids.sort()
	source_ids.make_read_only()
	source_revisions.make_read_only()
	var coverage_map: Variant = coverage_by_provider.get(provider_id, {})
	var coverage_revision := String(coverage_map.get(section_key, "")) \
		if coverage_map is Dictionary else ""
	var section := {"status":"complete" if not source_ids.is_empty() else "empty",
		"sourcePartIds":source_ids, "coverageRevision":coverage_revision}
	section.make_read_only()
	var sections := {section_key:section}
	sections.make_read_only()
	var provider_source_revisions := String(provider_revisions.get(provider_id, ""))
	if provider_source_revisions.is_empty() or coverage_revision.is_empty():
		return _pending("static_section_ack_provider_revision_missing", {
			"providerId":provider_id, "sectionKey":section_key})
	var removals_by_section: Dictionary = {}
	var all_removals: Variant = census.get("removalsBySection", {})
	var provider_removals: Array[Dictionary] = []
	var section_removals: Variant = all_removals.get(section_key, []) \
		if all_removals is Dictionary else null
	if not section_removals is Array or not section_removals.is_read_only():
		return _pending("static_section_ack_removal_census_unsealed", {
			"providerId":provider_id, "sectionKey":section_key})
	for removal_value: Variant in section_removals:
		if removal_value is Dictionary \
				and String(removal_value.get("providerId", "")) == provider_id:
			provider_removals.append(removal_value)
	provider_removals.make_read_only()
	removals_by_section[section_key] = provider_removals
	removals_by_section.make_read_only()
	var result := {"status":"complete", "worldId":census.get("worldId", ""),
		"authorityRevision":provider_source_revisions, "sections":sections,
		"sourceRevisions":source_revisions, "removalsBySection":removals_by_section}
	result.make_read_only()
	return result


## Release source-owned render claims before a stream owner drops the accepted
## section receipt. Providers without a release contract have no owner lease to
## retire; a pending release remains retryable under the coordinator's receipt.
func release_section_install(section_key: Vector3i,
		provider_coverage: Array, receipt: Dictionary) -> Dictionary:
	if not receipt.is_read_only() or receipt.get("status") != "installed" \
			or receipt.get("sectionKey") != section_key or provider_coverage.is_empty():
		return _failed("invalid_static_section_install_release")
	var releases: Array[Dictionary] = []
	var has_pending_provider := false
	for row_value: Variant in provider_coverage:
		if not row_value is Array or row_value.size() < 2:
			return _failed("invalid_static_section_provider_coverage_release")
		var provider_id := String(row_value[0])
		var coverage_revision := String(row_value[1])
		var registration: Dictionary = _providers.get(provider_id, {})
		var owner: Object = registration.get("owner").get_ref() \
			if registration.get("owner") is WeakRef else null
		if not is_instance_valid(owner) \
				or owner.get_instance_id() != int(registration.get("ownerInstanceId", 0)):
			return _pending("static_section_install_release_provider_owner_missing", {
				"providerId":provider_id})
		if not owner.has_method("release_section_install"):
			continue
		var released: Variant = owner.call("release_section_install",
			section_key, coverage_revision, receipt)
		if not released is Dictionary \
				or String(released.get("status", "")) not in ["acknowledged", "pending"]:
			return _failed("static_section_install_release_provider_rejected", {
				"providerId":provider_id, "result":released})
		var row := {"providerId":provider_id,
			"coverageRevision":coverage_revision, "result":released}
		row.make_read_only()
		releases.append(row)
		has_pending_provider = has_pending_provider \
			or String(released.get("status", "")) == "pending"
	releases.make_read_only()
	return {"status":"pending" if has_pending_provider else "acknowledged",
		"retryable":has_pending_provider, "sectionKey":section_key,
		"providerReleases":releases}


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


static func _source_part_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


static func _validated_continuation_hint(value: Variant) -> Dictionary:
	if not value is Dictionary or not value.is_read_only() \
			or String(value.get("schema", "")) \
				!= "static-section-provider-continuation/v1":
		return {}
	var stage := String(value.get("stage", ""))
	var cursor_value: Variant = value.get("cursor", null)
	if stage.is_empty() or stage.length() > 48 or not cursor_value is int \
			or int(cursor_value) < 0 or int(cursor_value) > 1_000_000:
		return {}
	var hint := {"schema":"static-section-provider-continuation/v1",
		"stage":stage, "cursor":int(cursor_value)}
	hint.make_read_only()
	return hint


func _failed(reason: String, detail := {}) -> Dictionary:
	var result: Dictionary = {"status":"failed", "worldId":_world_id,
		"reason":reason, "retryable":false}
	result.merge(detail, true)
	return result
