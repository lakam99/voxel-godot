extends SceneTree

## Exact immutable component mapping only, not publication/contact acceptance.
const Recipe = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const History = preload("res://scripts/buildings/SurfaceHistoryField.gd")
const INPUTS := {
	"narrow": ["facade-whole-candidate-08/facade-candidate.bin", "f7f748e9a0bcd88b9152882d90705190ff884bac473a126762a64d812c6413b0"],
	"civic": ["facade-paving-assembly-contract-04/candidate.bin", "4fdf12e4b702efd29eac03532e64b93d4d28e6e06bbfabe09fd07884e5a1f31b"],
	"combined": ["facade-whole-candidate-09/facade-candidate.bin", "36ed79a46e014afd35c78fdf54cbbbb88730241165bd72c3c9491c8c7eb4d004"]}
var checks: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	checks.append({"label": label, "passed": passed})

func _read(key: String) -> Dictionary:
	var pair: Array = INPUTS[key]
	var path := "res://artifacts/citadel-visual-reset/" + String(pair[0])
	if FileAccess.get_sha256(path) != pair[1]: return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var count := file.get_length()
	if count <= 0 or count > 33554432:
		file.close()
		return {}
	var bytes := file.get_buffer(count)
	var complete := bytes.size() == count and file.get_error() == OK
	file.close()
	var decoded: Variant = bytes_to_var(bytes)
	if not complete or not decoded is Dictionary or var_to_bytes(decoded) != bytes or FileAccess.get_sha256(path) != pair[1]: return {}
	return decoded

func _map(snapshot: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for part in snapshot.parts:
		if not part is Dictionary or not part.get("id") is String or result.has(part.id): return {}
		result[part.id] = part
	return result

func _shell(snapshot: Dictionary) -> PackedByteArray:
	var copy := snapshot.duplicate()
	copy.erase("parts")
	return var_to_bytes(copy)

func _history(snapshot: Dictionary) -> PackedByteArray:
	var b = Recipe.copy_blueprint(snapshot)
	var history := History.new()
	history.configure(b.recipe, b.parts)
	return var_to_bytes([String(b.recipe.get("sourceBlueprintId", b.id)), b.recipe.get("pavingTreatments", []),
		history.route_corridors, history.tree_placements, history.history_events, history.history_event_cells])

func _mapping(narrow: Dictionary, civic: Dictionary, combined: Dictionary) -> Dictionary:
	var base := _map(narrow.beforeSnapshot)
	var expected := base.duplicate()
	var owners: Dictionary = {}
	var clashes: Array = []
	for component in [{"name": "narrow", "source": narrow}, {"name": "civic", "source": civic}]:
		if var_to_bytes(component.source.beforeSnapshot) != var_to_bytes(narrow.beforeSnapshot): return {"exact": false, "reason": "different_component_baseline"}
		for part in component.source.afterSnapshot.parts:
			if base.has(part.id) and var_to_bytes(base[part.id]) == var_to_bytes(part): continue
			if owners.has(part.id) and var_to_bytes(expected[part.id]) != var_to_bytes(part): clashes.append(part.id)
			expected[part.id] = part
			owners[part.id] = component.name
	var actual := _map(combined.afterSnapshot)
	var mismatches: Array = []
	var differences: Dictionary = {}
	for id in expected:
		if not actual.has(id) or var_to_bytes(expected[id]) != var_to_bytes(actual[id]):
			mismatches.append(id)
			var rows: Array = []
			if actual.has(id): _differences(expected[id], actual[id], "", rows)
			differences[id] = rows
	var original_order := true
	for index in range(narrow.beforeSnapshot.parts.size()):
		if combined.afterSnapshot.parts[index].id != narrow.beforeSnapshot.parts[index].id: original_order = false
	return {"exact": clashes.is_empty() and mismatches.is_empty() and actual.size() == expected.size() and original_order,
		"clashes": clashes, "mismatchedIds": mismatches, "differences": differences, "expectedPartCount": expected.size(), "actualPartCount": actual.size(),
		"originalOrderExact": original_order, "changedRecordOwners": owners}

func _differences(a: Variant, c: Variant, path: String, rows: Array) -> void:
	if rows.size() >= 32 or var_to_bytes(a) == var_to_bytes(c): return
	if a is Dictionary and c is Dictionary:
		for key in a:
			if c.has(key): _differences(a[key], c[key], path + "." + String(key), rows)
			else: rows.append({"path": path + "." + String(key), "reason": "missing_key"})
		for key in c:
			if not a.has(key): rows.append({"path": path + "." + String(key), "reason": "added_key"})
	elif a is Array and c is Array and a.size() == c.size():
		for index in range(a.size()): _differences(a[index], c[index], path + "[%d]" % index, rows)
	elif a is Vector3 and c is Vector3:
		for axis in range(3):
			if a[axis] != c[axis]: rows.append({"path": path + "." + ["x", "y", "z"][axis], "before": a[axis], "after": c[axis]})
	else: rows.append({"path": path, "before": a, "after": c})

func _run() -> void:
	var path := OS.get_environment("VOXEL_COMBINED_SOURCE_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var narrow := _read("narrow")
	var civic := _read("civic")
	var combined := _read("combined")
	var mapping: Dictionary = {}
	_check("all_bound_inputs", not narrow.is_empty() and not civic.is_empty() and not combined.is_empty())
	if checks[0].passed:
		mapping = _mapping(narrow, civic, combined)
		_check("exact_complete_record_union", mapping.exact)
		_check("same_baseline", var_to_bytes(narrow.beforeSnapshot) == var_to_bytes(combined.beforeSnapshot))
		_check("all_source_shells_exact", [narrow.afterSnapshot, civic.afterSnapshot, combined.afterSnapshot].all(func(snapshot): return _shell(snapshot) == _shell(narrow.beforeSnapshot)))
		_check("all_furniture_exact", var_to_bytes(narrow.furnitureSnapshot) == var_to_bytes(civic.furnitureSnapshot) and var_to_bytes(narrow.furnitureSnapshot) == var_to_bytes(combined.furnitureSnapshot))
		_check("all_reservations_exact", var_to_bytes(narrow.protectedReservations) == var_to_bytes(civic.protectedReservations) and var_to_bytes(narrow.protectedReservations) == var_to_bytes(combined.protectedReservations))
		var history := _history(combined.afterSnapshot)
		_check("history_and_canonical_publication_inputs_exact", history == _history(narrow.afterSnapshot) and history == _history(civic.afterSnapshot))
		var bad := combined.duplicate(true)
		bad.afterSnapshot.parts[0].position.x += 0.1
		_check("changed_geometry_rejected", not _mapping(narrow, civic, bad).exact)
		bad = combined.duplicate(true)
		bad.afterSnapshot.parts.pop_back()
		_check("missing_addition_rejected", not _mapping(narrow, civic, bad).exact)
	var passed := checks.size() == 9 and checks.all(func(row): return row.passed)
	var report := {"passed": passed, "checks": checks, "mapping": mapping, "inputBindings": INPUTS,
		"elapsedMsec": Time.get_ticks_msec() - started, "evidenceLevel": "immutable_complete_source_record_union",
		"doesNotProve": "Material-cache winners, static flush grouping, renderer/GPU, publication, contacts or physical gate-zero. Fresh combined lifecycle evidence remains required."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)
