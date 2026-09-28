extends SceneTree

## Synthetic producer-style membership contract only. No anchoring, physical
## validation, source generation, publication or gameplay acceptance.
const Manifest = preload("res://scripts/buildings/CitadelBuntingAssemblyManifest.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
var checks: Dictionary = {}
var evidence: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("CITADEL_BUNTING_MANIFEST_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.file_exists(output.get_basename()+".bin"):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var hashes: Dictionary = _hashes()
	_exercise()
	var after: Dictionary = _hashes()
	checks["source_hashes_valid"] = hashes.values().all(func(value: Variant) -> bool: return String(value).length() == 64)
	checks["sources_unchanged"] = hashes == after
	checks["bounded_30_seconds"] = Time.get_ticks_msec()-started < 30000
	var report := {"passed":checks.values().all(func(value: Variant) -> bool: return value == true),"checks":checks,"evidence":evidence,
		"elapsedMsec":Time.get_ticks_msec()-started,"sourceHashesBefore":hashes,"sourceHashesAfter":after,
		"scope":"Synthetic producer-authored complete assembly inventory; no geometry support, physical or gameplay acceptance."}
	var saved: bool = _write(output,report)
	print("Bunting manifest checks=",checks.size()," passed=",report.passed)
	quit(0 if saved and report.passed else 1)

func _source():
	var source = Blueprint.new("synthetic_membership",7,"masonry")
	source.recipe = {"unrelated":{"unchanged":[1,"keep"]}}
	source.rooms = [{"id":"unrelated_room","bounds":AABB(Vector3.ZERO,Vector3(4,3,4))}]
	for id: String in ["span.a","other-owner-span"]:
		source.add_part({"id":id,"kind":"beam","semantic":"citadel_bunting_rope","collision":false,"position":Vector3(0,4,0),"size":Vector3(5,0.035,0.035)})
	for id: String in ["cloth.x","different-pattern","third.flag"]:
		source.add_part({"id":id,"kind":"pennant","semantic":"citadel_bunting","collision":false,"position":Vector3(0,3.5,0),"size":Vector3(0.4,0.6,0.05)})
	source.add_part({"id":"unrelated_wall","kind":"wall","size":Vector3(1,3,1)})
	return source

func _records() -> Array:
	# Deliberately unrelated naming and non-geometric member order. Ownership
	# comes from the producer, never a prefix, seed, position or inferred grouping.
	return [{"ropeId":"other-owner-span","pennantIds":["third.flag"]},
		{"ropeId":"span.a","pennantIds":["different-pattern","cloth.x"]}]

func _exercise() -> void:
	var source = _source()
	var records: Array = _records()
	var original: Dictionary = source.snapshot()
	var input_bytes: PackedByteArray = var_to_bytes(records)
	var declared: Dictionary = Manifest.declare(source,records)
	checks["complete_literal_records_declared"] = declared.get("ready",false) and declared.get("ropeCount") == 2 and declared.get("pennantCount") == 3
	var expected: Dictionary = original.duplicate(true)
	expected.recipe[Manifest.KEY] = _records()
	checks["only_manifest_added"] = _equal(expected,source.snapshot()) and input_bytes == var_to_bytes(records)
	var read: Dictionary = Manifest.read(source)
	checks["read_matches_declaration_and_order"] = _equal(read,declared) and _equal(read.get("records"),records)
	var before: PackedByteArray = var_to_bytes(source.snapshot())
	checks["repeat_declare_idempotent"] = _equal(declared,Manifest.declare(source,records)) and before == var_to_bytes(source.snapshot())
	records[0].pennantIds.clear()
	declared.records.clear()
	read.records[1].pennantIds.reverse()
	checks["input_and_result_alias_isolation"] = before == var_to_bytes(source.snapshot()) and _equal(Manifest.read(source).records,_records())
	source.parts.reverse()
	checks["source_part_order_independent"] = _equal(Manifest.read(source).records,_records())
	var empty = Blueprint.new("empty",0,"masonry")
	checks["missing_even_empty_is_explicit"] = Manifest.read(empty).get("reason") == "missing_bunting_manifest"
	checks["explicit_empty_declaration_valid"] = Manifest.declare(empty,[]).get("ready",false) and Manifest.read(empty).get("records",[1]).is_empty()
	empty.recipe[Manifest.KEY] = _records()
	checks["metadata_without_parts_rejected"] = Manifest.read(empty).get("ready") == false
	checks["null_source_rejected"] = Manifest.read(null).get("ready") == false and Manifest.declare(null,[]).get("ready") == false
	for mode: String in ["missing_manifest","wrong_collection","omitted_assembly","omitted_pennant","empty_pennants","duplicate_rope","duplicate_pennant","cross_assembly_duplicate","missing_rope","missing_pennant","wrong_rope_kind","wrong_pennant_kind","wrong_semantic","nonfinite_position","nonfinite_rotation","zero_size","collision_enabled","duplicate_source_id","extra_rope","extra_pennant","foreign_member","null_part","invalid_member_type","extra_record_field"]:
		_negative(mode)

func _negative(mode: String) -> void:
	var source = _source()
	source.recipe[Manifest.KEY] = _records()
	var records: Array = source.recipe[Manifest.KEY]
	match mode:
		"missing_manifest": source.recipe.erase(Manifest.KEY)
		"wrong_collection": source.recipe[Manifest.KEY] = {}
		"omitted_assembly": records.pop_back()
		"omitted_pennant": records[1].pennantIds.pop_back()
		"empty_pennants": records[0].pennantIds.clear()
		"duplicate_rope": records.append(records[0].duplicate(true))
		"duplicate_pennant": records[1].pennantIds.append("cloth.x")
		"cross_assembly_duplicate": records[0].pennantIds.append("cloth.x")
		"missing_rope": records[0].ropeId = "absent"
		"missing_pennant": records[0].pennantIds[0] = "absent"
		"wrong_rope_kind": source.parts[0].kind = "pennant"
		"wrong_pennant_kind": source.parts[2].kind = "beam"
		"wrong_semantic": source.parts[2].semantic = "unrelated"
		"nonfinite_position": source.parts[0].position.x = INF
		"nonfinite_rotation": source.parts[2].rotation.z = NAN
		"zero_size": source.parts[2].size.x = 0.0
		"collision_enabled": source.parts[2].collision_enabled = true
		"duplicate_source_id": source.parts[5].id = source.parts[0].id
		"extra_rope": source.add_part({"id":"extra","kind":"beam","semantic":"citadel_bunting_rope","collision":false})
		"extra_pennant": source.add_part({"id":"extra","kind":"pennant","semantic":"citadel_bunting","collision":false})
		"foreign_member": records[0].pennantIds[0] = "unrelated_wall"
		"null_part": source.parts.append(null)
		"invalid_member_type": records[0].pennantIds[0] = 17
		"extra_record_field": records[0]["unexpected"] = true
	# Snapshot cannot represent null parts; bind the actual inventory explicitly.
	var before: PackedByteArray = _source_bytes(source)
	var result: Dictionary = Manifest.read(source)
	checks[mode+"_read_rejected"] = result.get("ready") == false and not result.has("records")
	checks[mode+"_read_immutable"] = before == _source_bytes(source)
	if source.recipe.get(Manifest.KEY) is Array:
		var proposed: Array = source.recipe[Manifest.KEY].duplicate(true)
		var declaration: Dictionary = Manifest.declare(source,proposed)
		checks[mode+"_declare_atomic_failure"] = declaration.get("ready") == false and not declaration.has("records") and before == _source_bytes(source)
	evidence[mode] = result

func _source_bytes(source) -> PackedByteArray:
	var records: Array = []
	for part in source.parts: records.append(part.snapshot() if part != null else null)
	return var_to_bytes([source.id,source.seed,source.style,source.recipe,source.rooms,records])

func _equal(a: Variant,b: Variant) -> bool: return var_to_bytes(a) == var_to_bytes(b)

func _hashes() -> Dictionary:
	var result: Dictionary = {}
	var pending: Array[String] = [get_script().resource_path,"res://tools/run-building-contract.mjs"]
	var regex := RegEx.create_from_string('["\'](res://[^"\'\\r\\n]+)["\']')
	while not pending.is_empty():
		var path: String = pending.pop_back()
		if result.has(path): continue
		result[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
		if String(result[path]).length() != 64 or path.get_extension() != "gd": continue
		for matched: RegExMatch in regex.search_all(FileAccess.get_file_as_string(path)):
			var dependency: String = matched.get_string(1)
			if dependency.get_extension() in ["gd","gdshader"]: pending.append(dependency)
	return result

func _write(output: String, report: Dictionary) -> bool:
	var file := FileAccess.open(output.get_basename()+".bin",FileAccess.WRITE)
	if file == null: return false
	file.store_var(report,false); file.flush()
	var saved: bool = file.get_error() == OK
	file.close()
	file = FileAccess.open(output,FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(report,"\t",true,true)); file.flush()
	saved = saved and file.get_error() == OK
	file.close()
	return saved
