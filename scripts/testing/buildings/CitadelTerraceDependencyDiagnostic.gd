extends SceneTree

## Read-only captured-source inventory, NOT physical/load-path acceptance.
## Exact recorded references and conservative AABB contact candidates are
## separate evidence. No resolver, carving, Composer or generation is invoked.
const Restore = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const MAX_PAIRS := 5000000
const MAX_REFERENCES := 50000
var output := ""
var input_directory := ""
var deadline := 0
var checks: Dictionary = {}
var evidence: Dictionary = {}
var reference_work := 0
var pair_work := 0
var aborted := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	output = OS.get_environment("CITADEL_TERRACE_DEPENDENCY_REPORT")
	input_directory = OS.get_environment("CITADEL_CIVIC_REPLAY_INPUT")
	if not output.is_absolute_path() or FileAccess.file_exists(output):
		quit(2)
		return
	deadline = Time.get_ticks_msec() + 30000
	var worker := Thread.new()
	if worker.start(_work) != OK:
		_write_json(output, {"passed": false, "diagnosticCompleted": false, "reason": "worker_start_failed"})
		quit(2)
		return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	var saved := _write_json(output, report)
	print("Terrace dependency inventory completed=", report.diagnosticCompleted, " checks=", checks.size(), " no physical proof")
	quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var started := Time.get_ticks_usec()
	var hashes := _hashes()
	_inventory()
	_check("sources_unchanged", hashes == _hashes())
	_check("bounded_completion", not aborted and Time.get_ticks_msec() < deadline)
	return {"schema": "citadel-terrace-dependencies/v1", "passed": checks.values().all(func(value): return value == true),
		"diagnosticCompleted": evidence.get("inventoryWritten", false), "recipePassed": false, "physicalProofPerformed": false,
		"checks": checks, "evidence": evidence, "sourceHashes": hashes, "elapsedUsec": Time.get_ticks_usec() - started,
		"pairWork": pair_work, "referenceWork": reference_work, "internalDeadlineSeconds": 30,
		"limitations": "Captured retained caller only; no future Composer additions unless present in optional replay obstacle rows. Exact references may be stale derived facts, not fresh proof. AABB overlap/support windows are conservative candidates, not collision, load capacity, rooted support or carving permission. Absence of a direct contact is not proof that a transitive dependent is safe."}

func _inventory() -> void:
	_check("input_directory", input_directory.is_absolute_path() and DirAccess.dir_exists_absolute(input_directory))
	if not checks.input_directory: return
	var replay: Dictionary = {}
	var replay_path := input_directory.path_join("replay-inputs.bin")
	var capture_directory := input_directory
	if FileAccess.file_exists(replay_path):
		var loaded := _read_typed(replay_path)
		_check("optional_replay_read", loaded.ready)
		if not loaded.ready: return
		replay = loaded.value
		capture_directory = String(replay.get("inputBinding", {}).get("directory", ""))
		_check("replay_capture_directory_absolute", capture_directory.is_absolute_path())
		if not checks.replay_capture_directory_absolute: return
	var caller_path := capture_directory.path_join("caller-blueprint.bin")
	var loaded := _read_typed(caller_path)
	_check("caller_read", loaded.ready)
	if not loaded.ready: return
	var snapshot: Dictionary = loaded.value
	var capture_report := _read_json(capture_directory.path_join("report.json"))
	var capture_receipt: Dictionary = capture_report.get("receipt", {})
	_check("caller_hash_bound", capture_receipt.get("callerBlueprintCaptured", false) and capture_receipt.get("callerBlueprintSha256") == loaded.sha256)
	if not checks.caller_hash_bound: return
	var frozen := var_to_bytes(snapshot)
	var source = Restore.copy_blueprint(snapshot)
	_check("restored_typed_exact", frozen == var_to_bytes(source.snapshot()))
	if not checks.restored_typed_exact: return
	var ids: Dictionary = {}
	var terraces: Dictionary = {}
	var parts: Array = []
	var references: Array = []
	for part in source.parts:
		if not _budget(): return
		if ids.has(part.id):
			_check("unique_part_ids", false)
			return
		ids[part.id] = true
		var bounds: AABB = source.transformed_part_bounds(part)
		var row := {"id": part.id, "kind": part.kind, "semantic": part.semantic, "collision": part.collision_enabled,
			"physicalIntent": part.physical_intent, "bounds": bounds, "supportCandidate": source.is_structural_support_candidate(part)}
		parts.append(row)
		if part.semantic == "castle_inhabited_terrace_block" or String(part.id).begins_with("castle_terrace_block_"):
			terraces[part.id] = {"record": part.snapshot(), "bounds": bounds, "canonicalId": _canonical_id(part.id),
				"tagsMatch": part.kind == "foundation" and part.semantic == "castle_inhabited_terrace_block" and part.material_id == "stone_foundation" and part.rotation == Vector3.ZERO and part.collision_enabled and part.recipe.get("residenceCarved") == true and part.recipe.get("navigationRole") == "structural_mass",
				"explicitReferences": [], "partContacts": [], "roomContacts": [], "replayContacts": []}
	_check("unique_part_ids", true)
	_check("retained_terraces_present", not terraces.is_empty())
	if terraces.is_empty(): return
	_check("pair_inventory_within_limit", terraces.size() * (parts.size() + source.rooms.size() + replay.get("orderedObstacles", []).size()) <= MAX_PAIRS)
	if not checks.pair_inventory_within_limit: return
	for part in source.parts:
		_scan_references(part.recipe, "recipe", "part", part.id, ids, references, 0)
	for room: Dictionary in source.rooms:
		_scan_references(room, "room", "room", String(room.get("id", "")), ids, references, 0)
	_scan_references(source.recipe, "blueprint.recipe", "blueprint", source.id, ids, references, 0)
	if aborted: return
	var reverse: Dictionary = {}
	for reference: Dictionary in references:
		if terraces.has(reference.targetId): terraces[reference.targetId].explicitReferences.append(reference)
		if reference.ownerKind == "part" and reference.relation in ["required_support", "resolved_support", "anchor", "seat", "coverage"]:
			if not reverse.has(reference.targetId): reverse[reference.targetId] = []
			reverse[reference.targetId].append(reference.ownerId)
	var touched: Dictionary = {}
	for terrace_id: String in terraces:
		var terrace: Dictionary = terraces[terrace_id]
		var base: AABB = terrace.bounds
		for part: Dictionary in parts:
			if not _pair_budget(): return
			if part.id == terrace_id: continue
			var contact := _contact(base, part.bounds)
			if contact.is_empty(): continue
			contact["id"] = part.id
			contact["kind"] = part.kind
			contact["semantic"] = part.semantic
			contact["collision"] = part.collision
			contact["supportCandidate"] = part.supportCandidate
			terrace.partContacts.append(contact)
			touched[part.id] = true
		for room: Dictionary in source.rooms:
			if not _pair_budget(): return
			if not room.get("bounds") is AABB: continue
			var contact := _contact(base, room.bounds)
			if contact.is_empty(): continue
			contact["id"] = room.get("id", "")
			contact["role"] = room.get("role", "")
			terrace.roomContacts.append(contact)
		# Optional replay includes future-independent producers as exact bounds,
		# but has no full records for them. Report these separately, never invent
		# their physical relationships from names or collapse multiplicity.
		for i: int in range(replay.get("orderedObstacles", []).size()):
			if not _pair_budget(): return
			var row: Dictionary = replay.orderedObstacles[i]
			if row.get("origin") == "part" and ids.has(row.id): continue
			var contact := _contact(base, row.bounds)
			if contact.is_empty(): continue
			contact["record"] = row
			contact["originalIndex"] = i
			terrace.replayContacts.append(contact)
		var seen: Dictionary = {terrace_id: true}
		var queue: Array = [terrace_id]
		var cursor := 0
		while cursor < queue.size():
			if not _budget(): return
			var current: String = queue[cursor]
			cursor += 1
			for dependent: String in reverse.get(current, []):
				if seen.has(dependent): continue
				seen[dependent] = true
				queue.append(dependent)
		terrace["recordedSupportGraphReachableParts"] = queue.slice(1)
	var caller_unchanged: bool = frozen == var_to_bytes(source.snapshot()) and frozen == var_to_bytes(snapshot)
	_check("caller_immutable", caller_unchanged)
	_check("caller_file_unchanged", FileAccess.get_sha256(caller_path) == loaded.sha256)
	var artifact := {"callerPath": caller_path, "callerSha256": loaded.sha256, "terraces": terraces,
		"partRecords": parts, "allExactPartIdReferences": references,
		"referenceSemantics": "Exact ID matches in retained recipe/room keys and values. physicalSupportsPartId points from supporter to supported object and is NOT traversed as a dependency. Other support/anchor/seat/coverage edges are recorded declarations/derived facts only.",
		"contactSemantics": "AABB contact candidates within BuildingBlueprint.PHYSICAL_CONTACT_MARGIN, plus top support vertical gap [-0.14,0.26] from structural_support_at. NO support selection/resolution or rooted proof. Decorative/noncolliding contacts remain listed; zero-area/near-contact rows are distinguished from positive-volume overlap.",
		"domain": replay.get("domain"), "sourcePartCount": parts.size(), "sourceRoomCount": source.rooms.size(), "terraceCount": terraces.size()}
	var typed_path := output.get_base_dir().path_join("terrace-dependencies.bin")
	var json_path := output.get_base_dir().path_join("terrace-dependencies.json")
	_check("typed_inventory_saved", _write_typed(typed_path, artifact))
	_check("json_inventory_saved", _write_json(json_path, artifact))
	evidence = {"inventoryWritten": checks.typed_inventory_saved and checks.json_inventory_saved,
		"callerSha256": loaded.sha256, "callerPath": caller_path, "terraceCount": terraces.size(),
		"canonicalTerraceCount": terraces.values().filter(func(row): return row.canonicalId and row.tagsMatch).size(),
		"partCount": parts.size(), "roomCount": source.rooms.size(), "contactPartCount": touched.size(),
		"exactReferenceCount": references.size(), "jsonPath": json_path, "typedPath": typed_path,
		"typedSha256": FileAccess.get_sha256(typed_path), "optionalReplaySha256": FileAccess.get_sha256(replay_path) if not replay.is_empty() else ""}

func _contact(base: AABB, other: AABB) -> Dictionary:
	var overlap_x := minf(base.end.x, other.end.x) - maxf(base.position.x, other.position.x)
	var overlap_z := minf(base.end.z, other.end.z) - maxf(base.position.z, other.position.z)
	if overlap_x < -Blueprint.PHYSICAL_CONTACT_MARGIN or overlap_z < -Blueprint.PHYSICAL_CONTACT_MARGIN: return {}
	var overlap_y := minf(base.end.y, other.end.y) - maxf(base.position.y, other.position.y)
	var gap := float(other.position.y) - float(base.end.y)
	if overlap_y < -Blueprint.PHYSICAL_CONTACT_MARGIN and (gap < -0.14 or gap > 0.26): return {}
	return {"bounds": other, "xzOverlap": Rect2(Vector2(maxf(base.position.x, other.position.x), maxf(base.position.z, other.position.z)), Vector2(maxf(0, overlap_x), maxf(0, overlap_z))),
		"signedXZOverlap": Vector2(overlap_x, overlap_z), "verticalGapToTerraceTop": gap, "verticalOverlap": overlap_y,
		"volumeOverlap": overlap_y > 0 and overlap_x > 0 and overlap_z > 0,
		"possibleTopSupport": gap >= -0.14 and gap <= 0.26, "aabbOnly": true}

func _scan_references(value: Variant, path: String, owner_kind: String, owner_id: String, ids: Dictionary, rows: Array, depth: int) -> void:
	reference_work += 1
	if depth > 64 or reference_work > 2000000 or rows.size() >= MAX_REFERENCES or not _budget():
		aborted = true
		return
	if value is String or value is StringName:
		if ids.has(String(value)):
			rows.append({"ownerKind": owner_kind, "ownerId": owner_id, "path": path, "targetId": String(value), "relation": _relation(path)})
	elif value is Dictionary:
		for key: Variant in value:
			if (key is String or key is StringName) and ids.has(String(key)):
				rows.append({"ownerKind": owner_kind, "ownerId": owner_id, "path": path + ".<key>", "targetId": String(key), "relation": "exact_key_reference"})
			_scan_references(value[key], path + "." + str(key), owner_kind, owner_id, ids, rows, depth + 1)
			if aborted: return
	elif value is Array or value is PackedStringArray:
		for i: int in range(value.size()):
			_scan_references(value[i], path + "[%d]" % i, owner_kind, owner_id, ids, rows, depth + 1)
			if aborted: return

func _relation(path: String) -> String:
	if path.contains("physicalSupportsPartId"): return "supporter_to_supported"
	if path.contains("physicalRequiredSupportPartIds"): return "required_support"
	if path.contains("physicalAllowedSupportPartIds"): return "allowed_support"
	if path.contains("physicalSupportPartIds"): return "resolved_support"
	if path.contains("Anchor") or path.contains("anchor"): return "anchor"
	if path.contains("Seat") or path.contains("seat"): return "seat"
	if path.contains("Coverage") or path.contains("coverage"): return "coverage"
	return "other_exact_reference"

func _canonical_id(id: String) -> bool:
	var tokens := id.split("_")
	if tokens.size() != 6 or tokens[0] != "castle" or tokens[1] != "terrace" or tokens[2] != "block": return false
	if tokens[4] not in ["left", "right"] or not tokens[3].is_valid_int() or not tokens[5].is_valid_int(): return false
	var row := int(tokens[3])
	var segment := int(tokens[5])
	return row >= 0 and segment >= 0 and id == "castle_terrace_block_%02d_%s_%02d" % [row, tokens[4], segment]

func _pair_budget() -> bool:
	pair_work += 1
	return pair_work <= MAX_PAIRS and _budget()

func _budget() -> bool:
	if Time.get_ticks_msec() >= deadline: aborted = true
	return not aborted

func _check(label: String, value: bool) -> void:
	checks[label] = value

func _read_typed(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"ready": false}
	var value: Variant = file.get_var(false)
	var valid: bool = file.get_error() == OK and value is Dictionary
	file.close()
	return {"ready": valid, "value": value, "sha256": FileAccess.get_sha256(path)}

func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var value: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return value if value is Dictionary else {}

func _write_typed(path: String, value: Dictionary) -> bool:
	if FileAccess.file_exists(path): return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_var(value, false)
	file.flush()
	var valid: bool = file.get_error() == OK
	file.close()
	return valid

func _write_json(path: String, value: Dictionary) -> bool:
	if FileAccess.file_exists(path): return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(_json(value), "  "))
	file.flush()
	var valid: bool = file.get_error() == OK
	file.close()
	return valid

func _hashes() -> Dictionary:
	var result: Dictionary = {}
	for path: String in [get_script().resource_path, "res://scripts/buildings/FacadeOpeningBearingRecipe.gd", "res://scripts/buildings/BuildingBlueprint.gd"]:
		result[path] = FileAccess.get_sha256(path)
	return result

func _json(value: Variant) -> Variant:
	if value is Vector3: return {"x": value.x, "y": value.y, "z": value.z}
	if value is Vector2 or value is Vector2i: return {"x": value.x, "y": value.y}
	if value is AABB or value is Rect2: return {"position": _json(value.position), "size": _json(value.size), "end": _json(value.end)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[str(key)] = _json(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value: result.append(_json(item))
		return result
	return value
