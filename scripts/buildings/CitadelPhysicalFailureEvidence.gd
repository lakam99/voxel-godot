extends RefCounted

## Read-only projection of an already resolved physical proof. Never validates,
## repairs or recursively follows dependencies; incomplete evidence stays explicit.
const MAX_FAILURES := 16
const MAX_DEPENDENCIES_PER_FAILURE := 64
const MAX_DEPENDENCY_RECORDS := 256
const MAX_VIOLATIONS := 128
const MAX_BYTES := 1048576

static func collect(proof, report: Dictionary) -> Dictionary:
	var parts: Dictionary = {}
	for part in proof.parts:
		if part == null: continue
		if not parts.has(String(part.id)): parts[String(part.id)] = []
		parts[String(part.id)].append(part)
	var checks: Dictionary = {}
	var failed: Dictionary = {}
	for row: Dictionary in report.get("checks", []):
		var id := String(row.get("partId", ""))
		if not checks.has(id): checks[id] = []
		checks[id].append(row)
		if not bool(row.get("passed", false)): failed[id] = true
	var ids: Array = failed.keys()
	ids.sort()
	var result := {"schema": "citadel_physical_failure_evidence/v1", "complete": true,
		"failedPartTotal": ids.size(), "failedPartEmitted": 0,
		"dependencyTotal": 0, "dependencyEmitted": 0,
		"violationTotal": 0, "violationEmitted": 0,
		"failures": [], "overflowReasons": [], "malformedFields": [], "malformedFieldTotal": 0, "malformedFieldEmitted": 0}
	if ids.size() > MAX_FAILURES: _overflow(result, "failed_part_limit")
	var violations: Array = report.get("violations", []).duplicate()
	violations.sort()
	for id: String in ids:
		var references: Dictionary = {}
		var required := {"support": [], "anchor": []}
		var discovered := {"support": [], "anchor": []}
		for part in parts.get(id, []):
			for key in ["physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds", "physicalRequiredAnchorPartIds"]:
				for ref in _reference_ids(part.recipe.get(key, []), id, key, result):
					references[String(ref)] = true
					if key != "physicalRequiredSeatPartIds":
						_add_unique(required.anchor if key == "physicalRequiredAnchorPartIds" else required.support, String(ref))
		for row: Dictionary in checks[id]:
			for key in ["supportPartIds", "anchorPartIds", "requiredSupportPartIds", "requiredSeatPartIds", "requiredAnchorPartIds"]:
				for ref in _reference_ids(row.get(key, []), id, key, result):
					references[String(ref)] = true
					if key in ["supportPartIds", "anchorPartIds"]:
						_add_unique(discovered.anchor if key == "anchorPartIds" else discovered.support, String(ref))
					elif key in ["requiredSupportPartIds", "requiredAnchorPartIds"]:
						_add_unique(required.anchor if key == "requiredAnchorPartIds" else required.support, String(ref))
		var dependency_ids: Array = references.keys()
		dependency_ids.sort()
		result.dependencyTotal += dependency_ids.size()
		var matching: Array = []
		for violation in violations:
			if String(violation).begins_with(id + " "): matching.append(violation)
		result.violationTotal += matching.size()
		if result.failedPartEmitted >= MAX_FAILURES: continue
		var missing := {"support": [], "anchor": []}
		for category in ["support", "anchor"]:
			for ref in required[category]:
				if not discovered[category].has(ref): missing[category].append(ref)
			missing[category].sort()
		var entry := {"partId": id, "checkRows": _sorted_rows(checks[id]),
			"part": _part_record(id, parts, result), "violations": [],
			"requiredMinusDiscovered": missing, "dependencies": []}
		if entry.part.occurrenceCount > 2: _overflow(result, "duplicate_geometry_limit")
		for violation in matching:
			if result.violationEmitted >= MAX_VIOLATIONS:
				_overflow(result, "violation_limit")
				break
			entry.violations.append(violation)
			result.violationEmitted += 1
		if dependency_ids.size() > MAX_DEPENDENCIES_PER_FAILURE: _overflow(result, "per_failure_dependency_limit")
		for dependency_id: String in dependency_ids.slice(0, MAX_DEPENDENCIES_PER_FAILURE):
			if result.dependencyEmitted >= MAX_DEPENDENCY_RECORDS:
				_overflow(result, "total_dependency_limit")
				break
			var dependency := _part_record(dependency_id, parts, result)
			if dependency.occurrenceCount > 2: _overflow(result, "duplicate_geometry_limit")
			dependency["partId"] = dependency_id
			dependency["checkRows"] = _sorted_rows(checks.get(dependency_id, []))
			entry.dependencies.append(dependency)
			result.dependencyEmitted += 1
		result.failures.append(entry)
		result.failedPartEmitted += 1
	result.malformedFields = _sorted_rows(result.malformedFields)
	result.malformedFieldEmitted = result.malformedFields.size()
	result.overflowReasons.sort()
	# Measure the actual two-level Phase A nesting (including wrapper overhead),
	# rather than letting pretty-print indentation silently exceed the payload cap.
	if JSON.stringify({"structuralCompletionFailure": {"physicalFailureEvidence": result}}, "\t").to_utf8_buffer().size() > MAX_BYTES:
		_overflow(result, "diagnostic_byte_limit")
		result.failures = []
		result.failedPartEmitted = 0
		result.dependencyEmitted = 0
		result.violationEmitted = 0
		result.malformedFields = []
		result.malformedFieldEmitted = 0
		result.overflowReasons.sort()
	return result

static func _part_record(id: String, parts: Dictionary, result: Dictionary) -> Dictionary:
	var records: Array = []
	for part in parts.get(id, []):
		var record := {"id": String(part.id), "kind": String(part.kind), "semantic": String(part.semantic),
			"position": part.position, "rotation": part.rotation, "size": part.size,
			"collision": bool(part.collision_enabled), "physicalIntent": String(part.physical_intent),
			"physicalRoot": bool(part.recipe.get("physicalRoot", false))}
		for pair in [["requiredSupportPartIds", "physicalRequiredSupportPartIds"], ["requiredSeatPartIds", "physicalRequiredSeatPartIds"], ["requiredAnchorPartIds", "physicalRequiredAnchorPartIds"]]:
			record[pair[0]] = _reference_ids(part.recipe.get(pair[1], []), id, pair[1], result)
			record[pair[0]].sort()
		records.append(record)
	# Two records reveal ambiguity without allowing duplicate IDs to inflate output.
	records = _sorted_rows(records)
	return {"occurrenceCount": records.size(), "records": records.slice(0, 2)}

static func _sorted_rows(rows: Array) -> Array:
	var copied := rows.duplicate(true)
	copied.sort_custom(func(a, b): return JSON.stringify(a) < JSON.stringify(b))
	return copied

static func _reference_ids(value: Variant, owner: String, field: String, result: Dictionary) -> Array:
	var ids: Array = []
	if not value is Array:
		_malformed(result, owner, field, -1, typeof(value))
		return ids
	for index in range(value.size()):
		var candidate: Variant = value[index]
		if not candidate is String or candidate.is_empty() or candidate != candidate.strip_edges():
			_malformed(result, owner, field, index, typeof(candidate))
		else:
			ids.append(candidate)
	return ids

static func _malformed(result: Dictionary, owner: String, field: String, index: int, type: int) -> void:
	_overflow(result, "malformed_reference_field")
	# Observation count: reference collection and geometry projection may both
	# encounter the same malformed declaration. This is not a unique-field count.
	result.malformedFieldTotal += 1
	if result.malformedFields.size() < MAX_VIOLATIONS:
		result.malformedFields.append({"ownerId": owner, "field": field, "index": index, "type": type})
	else:
		_overflow(result, "malformed_field_limit")

static func _add_unique(values: Array, value: String) -> void:
	if not values.has(value): values.append(value)

static func _overflow(result: Dictionary, reason: String) -> void:
	result.complete = false
	_add_unique(result.overflowReasons, reason)
