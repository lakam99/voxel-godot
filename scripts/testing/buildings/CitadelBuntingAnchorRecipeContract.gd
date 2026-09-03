extends SceneTree

## Explicitly synthetic real BuildingParts and physical proof, not a generated
## source, visual publication, engineering load rating or gameplay acceptance.
const Recipe = preload("res://scripts/buildings/CitadelBuntingAnchorRecipe.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
var output := ""
var deadline := 0
var checks: Dictionary = {}
var evidence: Dictionary = {}
var stages: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	output = OS.get_environment("CITADEL_BUNTING_ANCHOR_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.file_exists(output.get_basename()+".bin"):
		quit(2)
		return
	deadline = Time.get_ticks_msec()+30000
	var worker := Thread.new()
	if worker.start(_work) != OK:
		quit(2)
		return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	var saved: bool = _write(report)
	print("Bunting anchor checks=",checks.size()," passed=",report.passed)
	quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var started := Time.get_ticks_usec()
	var before: Dictionary = _hashes()
	_exercise()
	var after: Dictionary = _hashes()
	checks["source_hashes_unchanged"] = before == after
	checks["internal_deadline"] = Time.get_ticks_msec() < deadline
	return {"passed":checks.values().all(func(value: Variant) -> bool: return value == true),
		"checks":checks,"evidence":evidence,"sourceHashesBefore":before,"sourceHashesAfter":after,
		"elapsedUsec":Time.get_ticks_usec()-started,"internalDeadlineSeconds":30,
		"scope":"Synthetic two independently grounded walls; real attachment sockets and physical validation, no scene/full source/gameplay acceptance."}

func _source():
	var source = Blueprint.new("synthetic_bunting",42,"masonry")
	for side: int in [-1,1]:
		var x: float = side*4.5
		source.add_part({"id":"root_%d"%side,"kind":"foundation","position":Vector3(x,0.25,0),"size":Vector3(1,0.5,2)})
		source.add_part({"id":"wall_%d"%side,"kind":"wall","position":Vector3(x,2.75,0),"size":Vector3(1,4.5,2)})
	source.add_part({"id":"line","kind":"beam","material":"ironwork","semantic":"citadel_bunting_rope","collision":false,"position":Vector3(0,3.5,0),"size":Vector3(12,0.035,0.035)})
	for index: int in range(3):
		source.add_part({"id":"flag_%d"%index,"kind":"pennant","semantic":"citadel_bunting","material":["wool_rust","linen","wool_moss"][index],"collision":false,
			"position":Vector3(float(index-1)*3.0,3.0-(0.15 if index == 1 else 0.0),0),"size":Vector3(0.6,0.68,0.055),
			"rotation":Vector3(0,0,deg_to_rad(-8.0 if index%2 == 0 else 8.0)),"recipe":{"variation":float(index)*0.006}})
	return source

func _assemblies() -> Array:
	return [{"ropeId":"line","pennantIds":["flag_0","flag_1","flag_2"]}]

func _apply(source, changes: Array):
	var snapshot: Dictionary = source.snapshot()
	var replacements: Dictionary = {}
	for record: Dictionary in changes: replacements[record.id] = record
	for index: int in range(snapshot.parts.size()):
		if replacements.has(snapshot.parts[index].id): snapshot.parts[index] = replacements[snapshot.parts[index].id].duplicate(true)
	return Copy.copy_blueprint(snapshot)

func _exercise() -> void:
	var source = _source()
	var assemblies: Array = _assemblies()
	var initial: PackedByteArray = var_to_bytes(source.snapshot())
	var input_bytes: PackedByteArray = var_to_bytes(assemblies)
	var result: Dictionary = Recipe.prepare(source,assemblies,[],_continue)
	evidence["positive"] = result
	checks["positive_ready"] = result.get("ready",false)
	checks["single_full_proof"] = result.get("physicalValidations") == 1 and stages.get("physical_validation_started") == 1
	checks["caller_immutable"] = initial == var_to_bytes(source.snapshot()) and input_bytes == var_to_bytes(assemblies)
	checks["exact_source_binding"] = result.get("sourceBytes") == initial
	if not checks.positive_ready: return
	var repeated: Dictionary = Recipe.prepare(source,assemblies,[],_continue)
	checks["deterministic_repeat"] = var_to_bytes(result) == var_to_bytes(repeated)
	var default_result: Dictionary = Recipe.prepare(source,assemblies,[])
	checks["default_callback_exact"] = var_to_bytes(result) == var_to_bytes(default_result)
	var reversed = Copy.copy_blueprint(source.snapshot())
	reversed.parts.reverse()
	var reordered: Dictionary = Recipe.prepare(reversed,assemblies,[],_continue)
	checks["source_order_invariant_geometry"] = reordered.get("ready",false) and var_to_bytes(result.changes) == var_to_bytes(reordered.get("changes")) and var_to_bytes(result.endpointFacts) == var_to_bytes(reordered.get("endpointFacts"))
	var staged = _apply(source,result.changes)
	checks["no_added_or_removed_members"] = staged.parts.size() == source.parts.size()
	var before_by_id: Dictionary = {}
	for part in source.parts: before_by_id[part.id] = part
	var rope = staged.find_part("line")
	checks["no_posts_or_door_geometry"] = result.changes.all(func(record: Dictionary) -> bool: return record.id in ["line","flag_0","flag_1","flag_2"])
	checks["fixed_yz_and_rope_style"] = rope.position.y == 3.5 and rope.position.z == 0 and rope.rotation == Vector3.ZERO and rope.size.y == before_by_id.line.size.y and rope.size.z == before_by_id.line.size.z and rope.material_id == before_by_id.line.material_id
	checks["actual_faces_bound_endpoints"] = absf(rope.position.x) < 0.000001 and rope.size.x < 12.0 and rope.position.x-rope.size.x*0.5 < -4.0 and rope.position.x+rope.size.x*0.5 > 4.0
	for index: int in range(3):
		var id := "flag_%d"%index
		var old = before_by_id[id]
		var new_part = staged.find_part(id)
		checks[id+"_style_sag_size_preserved"] = new_part.material_id == old.material_id and new_part.kind == old.kind and new_part.rotation == old.rotation and new_part.position.y == old.position.y and new_part.position.z == old.position.z and new_part.size == old.size and var_to_bytes(new_part.recipe) == var_to_bytes(old.recipe)
		checks[id+"_position_ratio_preserved"] = is_equal_approx((new_part.position.x-rope.position.x)/rope.size.x,old.position.x/12.0)
		var before_record: Dictionary = old.snapshot()
		var after_record: Dictionary = new_part.snapshot()
		before_record.erase("position")
		after_record.erase("position")
		checks[id+"_all_nonposition_fields_exact"] = var_to_bytes(before_record) == var_to_bytes(after_record)
	for id: String in ["root_-1","root_1","wall_-1","wall_1"]:
		checks[id+"_unchanged"] = var_to_bytes(staged.find_part(id).snapshot()) == var_to_bytes(before_by_id[id].snapshot())
	# Independent terminal validation in the TEST, not another per-candidate
	# proof hidden in the helper. Both explicit socket obligations must pass.
	var validated = Copy.copy_blueprint(staged.snapshot())
	Copy.clear_caches(validated)
	var terminal: Dictionary = validated.validate_physical_integrity_cancellable(_continue)
	checks["real_terminal_physical_pass"] = terminal.get("passed",false)
	var resolved_rope = validated.find_part("line")
	var anchor_ids: Array = resolved_rope.recipe.get("physicalRequiredAnchorPartIds",[])
	checks["two_distinct_required_anchors"] = anchor_ids.size() == 2 and anchor_ids[0] != anchor_ids[1]
	for fact: Dictionary in resolved_rope.recipe.get("physicalRequiredAnchorFacts",[]):
		checks["real_socket_"+fact.anchorId] = validated.has_rooted_attachment_socket(resolved_rope,fact)
	var preserved: Dictionary = Recipe.prepare(staged,assemblies,[],_continue)
	checks["valid_assembly_exact_noop"] = preserved.get("ready",false) and preserved.get("unchanged",false) and preserved.get("changes",[1]).is_empty()
	evidence["terminal"] = terminal
	_negative_controls(source)
	_cancel_controls(source)
	_mutation_controls(source)
	_domain_controls()

func _domain_controls() -> void:
	var source = Copy.copy_blueprint(_source().snapshot())
	var assemblies: Array = _assemblies()
	for id: String in ["line","flag_0","flag_1","flag_2"]:
		source.find_part(id).position += Vector3(0,2,5)
	var domain := {"leftAnchorIds":["wall_-1"],"rightAnchorIds":["wall_1"],"bounds":AABB(Vector3(-5,1,-1),Vector3(10,4,2))}
	assemblies[0]["placementDomain"] = domain
	var frozen := var_to_bytes(source.snapshot())
	var result: Dictionary = Recipe.prepare(source,assemblies,[],_continue)
	checks["finite_domain_relocation_ready"] = result.get("ready",false)
	checks["finite_domain_source_immutable"] = frozen == var_to_bytes(source.snapshot())
	evidence["domain_positive"] = result
	if not result.get("ready",false): return
	var staged = _apply(source,result.changes)
	var rope = staged.find_part("line")
	checks["finite_domain_actually_relocated_yz"] = rope.position.y != source.find_part("line").position.y and rope.position.z != source.find_part("line").position.z
	for id: String in ["line","flag_0","flag_1","flag_2"]:
		checks["domain_contains_"+id] = domain.bounds.encloses(staged.transformed_part_bounds(staged.find_part(id)))
	for id: String in assemblies[0].pennantIds:
		var before: Dictionary = source.find_part(id).snapshot()
		var after: Dictionary = staged.find_part(id).snapshot()
		checks["domain_relative_sag_"+id] = is_equal_approx(after.position.y-rope.position.y,before.position.y-source.find_part("line").position.y) and after.position.z-rope.position.z == before.position.z-source.find_part("line").position.z
		before.erase("position"); after.erase("position")
		checks["domain_preserves_flag_style_"+id] = var_to_bytes(before) == var_to_bytes(after)
	var no_op: Dictionary = Recipe.prepare(staged,assemblies,[],_continue)
	checks["domain_already_repaired_noop"] = no_op.get("ready",false) and no_op.get("changes",[1]).is_empty()
	var repeat: Dictionary = Recipe.prepare(source,assemblies,[],_continue)
	checks["domain_deterministic"] = var_to_bytes(result) == var_to_bytes(repeat)
	var exact_faces: Array = assemblies.duplicate(true)
	exact_faces[0].placementDomain.bounds.position.x = -4.0
	exact_faces[0].placementDomain.bounds.size.x = 8.0
	var exact_result: Dictionary = Recipe.prepare(source,exact_faces,[],_continue)
	checks["exact_face_domain_positive"] = exact_result.get("ready",false)
	if exact_result.get("ready",false):
		var exact_source = _apply(source,exact_result.changes)
		var exact_rope = exact_source.find_part("line")
		var half: Vector3 = Vector3(minf(exact_rope.size.y,exact_rope.size.z),exact_rope.size.y,exact_rope.size.z)*0.25
		var cap: float = half.x*2+Recipe.SOCKET_INSET
		var envelope: AABB = exact_faces[0].placementDomain.bounds
		checks["exact_face_represented_caps_within_limit"] = Recipe._inside_domain(exact_rope,envelope,cap,true)
		for mode: String in ["excess_x_embed","rope_y_overflow","rope_z_overflow","flag_x_overflow"]:
			var member = Recipe._part(exact_rope.snapshot())
			var is_rope := mode != "flag_x_overflow"
			match mode:
				"excess_x_embed": member.size.x = envelope.size.x+cap*4
				"rope_y_overflow": member.position.y = envelope.end.y
				"rope_z_overflow": member.position.z = envelope.end.z
				"flag_x_overflow":
					member=Recipe._part(exact_source.find_part("flag_0").snapshot())
					member.position.x=envelope.end.x
			checks["explicit_domain_"+mode+"_rejects"] = not Recipe._inside_domain(member,envelope,cap,is_rope)
	evidence["exact_faces"] = exact_result
	for mode: String in ["duplicate_sides","missing_owner","outside_flag_envelope","noncolliding_roof","protected_interior"]:
		var trial = Copy.copy_blueprint(source.snapshot())
		var inputs: Array = assemblies.duplicate(true)
		var protected: Array = []
		match mode:
			"duplicate_sides": inputs[0].placementDomain.rightAnchorIds = ["wall_-1"]
			"missing_owner": inputs[0].placementDomain.leftAnchorIds = ["absent"]
			"outside_flag_envelope": inputs[0].placementDomain.bounds = AABB(Vector3(-5,4.8,-1),Vector3(10,0.2,2))
			"noncolliding_roof": trial.add_part({"id":"roof_obstacle","kind":"roof","collision":false,"position":Vector3(0,3,0),"size":Vector3(2,4,2)})
			"protected_interior": protected.append(AABB(Vector3(-1,1,-1),Vector3(2,4,2)))
		var failed: Dictionary = Recipe.prepare(trial,inputs,protected,_continue)
		checks["domain_"+mode+"_fail_closed"] = not failed.get("ready",true) and not failed.has("changes")
		evidence["domain_"+mode] = failed
	for selected: bool in [false,true]:
		var trial = Copy.copy_blueprint(source.snapshot())
		var inputs: Array = assemblies.duplicate(true)
		# Narrow, real masonry mounting courses leave no alternate Y/Z lane.
		# Wide courses legitimately allowed the solver to avoid the first line.
		for side: int in [-1,1]:
			trial.find_part("root_%d"%side).position.y = 1.725
			trial.find_part("root_%d"%side).size.y = 3.45
			trial.find_part("wall_%d"%side).position.y = 3.50
			trial.find_part("wall_%d"%side).size = Vector3(1,0.10,0.12)
		var lone: Dictionary = Recipe.prepare(trial,inputs,[],_continue)
		checks["cross_assembly_lone_"+str(selected)+"_ready"] = lone.get("ready",false)
		if not lone.get("ready",false): continue
		var lone_source = _apply(trial,lone.changes)
		var other := {"ropeId":"other_line","pennantIds":[]}
		for id: String in ["line","flag_0","flag_1","flag_2"]:
			var record: Dictionary = (trial if selected else lone_source).find_part(id).snapshot()
			record.id = "other_"+id
			trial.add_part(record)
			trial.parts.back().size = record.size
			if id != "line": other.pennantIds.append(record.id)
		if selected:
			other["placementDomain"] = domain.duplicate(true)
			inputs.append(other)
		var failed: Dictionary = Recipe.prepare(trial,inputs,[],_continue)
		checks["cross_assembly_"+str(selected)+"_rejected"] = not failed.get("ready",true) and not failed.has("changes")
		evidence["cross_assembly_"+str(selected)] = failed

func _negative_controls(source) -> void:
	for mode: String in ["missing_left","unrooted_left","forged_root_cache","middle_contact_only","intervening_solid","protected_span","crowded_pennants","unsupported_domain","duplicate_member"]:
		var trial = Copy.copy_blueprint(source.snapshot())
		var assemblies: Array = _assemblies()
		var protected: Array = []
		match mode:
			"missing_left": trial.parts = trial.parts.filter(func(part) -> bool: return part.id != "wall_-1")
			"unrooted_left", "forged_root_cache":
				trial.parts = trial.parts.filter(func(part) -> bool: return part.id != "root_-1")
				if mode == "forged_root_cache": trial.find_part("wall_-1").recipe["physicalRoot"] = true
			"middle_contact_only":
				trial.parts = trial.parts.filter(func(part) -> bool: return part.id in ["line","flag_0","flag_1","flag_2"])
				trial.add_part({"id":"middle_only","kind":"foundation","position":Vector3(0,2,0),"size":Vector3(1,4,1)})
			"intervening_solid": trial.add_part({"id":"blocking_crate","kind":"crate","position":Vector3(0,3.5,0),"size":Vector3(1,1,1)})
			"protected_span": protected.append(AABB(Vector3(-0.5,3,-0.5),Vector3.ONE))
			"crowded_pennants":
				for id: String in assemblies[0].pennantIds: trial.find_part(id).size.x = 2.5
				var original_spacing_clear := true
				for first: int in range(3):
					for second: int in range(first+1,3):
						var measured: Dictionary = Recipe.Admission.measure(Recipe._pose(trial.find_part("flag_%d"%first)),Recipe._pose(trial.find_part("flag_%d"%second)))
						original_spacing_clear = original_spacing_clear and measured.get("valid",false) and measured.get("clear",false)
				checks["crowded_pennants_original_spacing_clear"] = original_spacing_clear
			"unsupported_domain": assemblies[0]["placementBounds"] = AABB(Vector3(-10,0,-10),Vector3(20,10,20))
			"duplicate_member": assemblies[0].pennantIds.append("flag_0")
		var initial: PackedByteArray = var_to_bytes(trial.snapshot())
		var result: Dictionary = Recipe.prepare(trial,assemblies,protected,_continue)
		checks[mode+"_failed_no_partial"] = result.get("ready") == false and not result.has("changes") and not result.has("endpointFacts") and not result.has("sourceBytes")
		checks[mode+"_immutable"] = initial == var_to_bytes(trial.snapshot())
		if mode == "crowded_pennants":
			checks["crowded_pennants_exact_rejection"] = result.get("reason") == "bunting_tested_placements_rejected" and int(result.get("detail",{}).get("detail",{}).get("rejections",{}).get("bunting_pennants_overlap",0)) > 0
		evidence[mode] = result

func _cancel_controls(source) -> void:
	for target: String in ["bunting_started","physical_resolve_support","bunting_proof_completed","bunting_candidate","bunting_clearance","bunting_completed"]:
		var initial: PackedByteArray = var_to_bytes(source.snapshot())
		var state: Dictionary = {"rejected":false,"afterFalse":0,"seen":false}
		var result: Dictionary = Recipe.prepare(source,_assemblies(),[],func(stage: String) -> bool:
			if state.rejected: state.afterFalse += 1
			if stage == target: state.seen = true; state.rejected = true
			return not state.rejected and Time.get_ticks_msec() < deadline)
		checks["cancel_"+target] = state.seen and state.afterFalse == 0 and result == {"ready":false,"reason":"cancelled"} and initial == var_to_bytes(source.snapshot())
		evidence["cancel_"+target] = {"state":state,"result":result}

func _mutation_controls(source) -> void:
	for mode: String in ["source_started","source_completed","assembly_callback","protected_callback"]:
		var trial = Copy.copy_blueprint(source.snapshot())
		var assemblies: Array = _assemblies()
		var protected: Array = []
		var state: Dictionary = {"mutated":false}
		var at: String = "bunting_completed" if mode == "source_completed" else "bunting_started"
		var result: Dictionary = Recipe.prepare(trial,assemblies,protected,func(stage: String) -> bool:
			if stage == at and not state.mutated:
				state.mutated = true
				match mode:
					"source_started", "source_completed": trial.recipe["callbackMutation"] = true
					"assembly_callback": assemblies[0]["callbackMutation"] = true
					"protected_callback": protected.append(AABB(Vector3(100,100,100),Vector3.ONE))
			return Time.get_ticks_msec() < deadline)
		checks[mode+"_binding_rejected"] = state.mutated and result == {"ready":false,"reason":"bunting_source_changed"}
		evidence[mode] = result

func _continue(stage: String) -> bool:
	stages[stage] = int(stages.get(stage,0))+1
	return Time.get_ticks_msec() < deadline

func _hashes() -> Dictionary:
	var result: Dictionary = {}
	var pending: Array[String] = [get_script().resource_path,"res://project.godot","res://tools/run-building-contract.ps1"]
	var regex := RegEx.create_from_string('["\'](res://[^"\'\\r\\n]+)["\']')
	while not pending.is_empty():
		var path: String = pending.pop_back()
		if result.has(path): continue
		result[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
		if String(result[path]).length() != 64: checks["source_hashes_valid"] = false; continue
		if path.get_extension() != "gd": continue
		for matched: RegExMatch in regex.search_all(FileAccess.get_file_as_string(path)):
			var dependency: String = matched.get_string(1)
			if dependency.get_extension() in ["gd","gdshader"]: pending.append(dependency)
	return result

func _write(report: Dictionary) -> bool:
	var file := FileAccess.open(output.get_basename()+".bin",FileAccess.WRITE)
	if file == null: return false
	file.store_var(report,false); file.flush()
	var saved: bool = file.get_error() == OK
	file.close()
	file = FileAccess.open(output,FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(_json(report),"\t",true,true)); file.flush()
	saved = saved and file.get_error() == OK
	file.close()
	return saved

func _json(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[str(key)] = _json(value[key])
		return result
	if value is Array: return value.map(_json)
	if value is PackedByteArray:
		var hash_context := HashingContext.new()
		hash_context.start(HashingContext.HASH_SHA256)
		hash_context.update(value)
		return {"type":"PackedByteArray","size":value.size(),"sha256":hash_context.finish().hex_encode()}
	if value is Vector3: return {"type":"Vector3","value":[value.x,value.y,value.z]}
	return value
