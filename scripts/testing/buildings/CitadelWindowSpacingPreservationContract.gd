extends SceneTree
## Byte-level visual/source preservation audit of before/after recipe captures.
const BEFORE := "res://artifacts/citadel-runtime-integration/facade-input-capture-01/input.bin"
const AFTER := "res://artifacts/citadel-runtime-integration/facade-input-capture-03/input.bin"
const BEFORE_SHA := "796a2375d8d6209d3a779f73d18ad638e0efee1b40e1d7407074ba0a20ac81e7"
const AFTER_SHA := "1935cc9ecab553c91c453f2a8ac715e90062fc363a244d880b153a5af9d66f2c"
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Interior = preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const Shop = preload("res://scripts/buildings/CitadelShopRecipe.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("CITADEL_SPACING_PRESERVATION_REPORT")
	var before_input: Dictionary = _input("BEFORE",BEFORE,BEFORE_SHA)
	var after_input: Dictionary = _input("AFTER",AFTER,AFTER_SHA)
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.file_exists(output.get_basename()+".bin") or before_input.is_empty() or after_input.is_empty(): quit(2); return
	var source_hashes: Dictionary = _hashes()
	var old: Dictionary=_read(before_input.path)
	var new: Dictionary=_read(after_input.path)
	if not _valid_capture(old) or not _valid_capture(new): quit(2); return
	var old_bytes: PackedByteArray = var_to_bytes(old)
	var new_bytes: PackedByteArray = var_to_bytes(new)
	var before_by_id := {}
	for part: Dictionary in old.blueprint.parts: before_by_id[part.id]=part
	var checks := {"part_count_preserved":old.blueprint.parts.size()==new.blueprint.parts.size(),
		"rooms_and_access_preserved":var_to_bytes(old.blueprint.rooms)==var_to_bytes(new.blueprint.rooms)}
	var changed: Array=[]
	var unexpected: Array=[]
	for part: Dictionary in new.blueprint.parts:
		if not before_by_id.has(part.id): unexpected.append({"id":part.id,"reason":"new_part"}); continue
		var before: Dictionary=before_by_id[part.id]
		if var_to_bytes(before)==var_to_bytes(part): continue
		changed.append({"id":part.id,"semantic":part.semantic,"beforePosition":before.position,"afterPosition":part.position,"beforeSize":before.size,"afterSize":part.size})
		var permitted: Dictionary=part.duplicate(true)
		if part.semantic=="citadel_urban_facade":
			permitted.position.z=before.position.z
			permitted.size.z=before.size.z
		elif part.semantic in ["citadel_urban_window","citadel_household_window_box"]:
			permitted.position.z=before.position.z
		else:
			unexpected.append({"id":part.id,"reason":"unrelated_geometry_changed"}); continue
		if var_to_bytes(permitted)!=var_to_bytes(before): unexpected.append({"id":part.id,"reason":"non_z_geometry_or_metadata_changed"})
	checks.only_facade_window_and_box_z_changed=unexpected.is_empty()
	checks.actually_changes_required_geometry=not changed.is_empty()
	var policy_proof: Dictionary = _policy_proof(old,new)
	checks["furniture_and_policy_preserved"] = policy_proof.passed
	var tamper_controls: Dictionary = _tamper_controls(old,new,policy_proof)
	checks["tamper_negative_controls"] = tamper_controls.passed
	checks["captured_inputs_immutable"] = old_bytes == var_to_bytes(old) and new_bytes == var_to_bytes(new)
	var policy_differences: Array=[]
	for key: String in old.policy:
		if var_to_bytes(old.policy[key])==var_to_bytes(new.policy.get(key)): continue
		if old.policy[key] is Array and new.policy.get(key) is Array and old.policy[key].size()==new.policy[key].size():
			for index in range(old.policy[key].size()):
				var a: Variant=old.policy[key][index]
				var b: Variant=new.policy[key][index]
				if var_to_bytes(a)==var_to_bytes(b): continue
				var fields := {}
				if a is Dictionary and b is Dictionary:
					for field: String in a:
						if var_to_bytes(a[field])!=var_to_bytes(b.get(field)): fields[field]={"before":str(a[field]),"after":str(b.get(field))}
				policy_differences.append({"key":key,"index":index,"id":a.get("id","") if a is Dictionary else "","fields":fields})
		else: policy_differences.append({"key":key,"reason":"changed_type_or_count"})
	var after_hashes: Dictionary = _hashes()
	checks["source_hashes_valid"] = source_hashes.values().all(func(value: Variant) -> bool: return String(value).length() == 64)
	checks["sources_unchanged"] = source_hashes == after_hashes
	checks["capture_hashes_unchanged"] = FileAccess.get_sha256(before_input.path) == before_input.sha256 and FileAccess.get_sha256(after_input.path) == after_input.sha256
	var report := {"passed":checks.values().all(func(value):return value==true),"checks":checks,"changed":changed,"unexpected":unexpected,"policyDifferences":policy_differences,"policyProof":policy_proof,"tamperControls":tamper_controls,"totalParts":new.blueprint.parts.size(),"beforeSha":before_input.sha256,"afterSha":after_input.sha256,"inputs":{"before":before_input,"after":after_input},"sourceHashesBefore":source_hashes,"sourceHashesAfter":after_hashes,"scope":"Exact captured-source preservation audit. Only producer-reconstructed window furniture/view volumes and their exact obstacle bounds may translate; all other policy bytes preserved. Rendered appearance, complete structural acceptance and gameplay remain unproven."}
	var binary := FileAccess.open(output.get_basename()+".bin",FileAccess.WRITE)
	if binary == null: quit(2); return
	binary.store_var(report,false); binary.flush()
	var binary_saved: bool = binary.get_error() == OK
	binary.close()
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(_json(report),"\t",true,true)); file.flush()
	var saved := file.get_error()==OK; file.close()
	quit(0 if saved and binary_saved and report.passed else 1)
func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null: return {}
	var value: Variant = file.get_var(false)
	var valid: bool = file.get_error() == OK and value is Dictionary
	file.close()
	return value if valid else {}

func _input(side: String, default_path: String, default_sha: String) -> Dictionary:
	var path := OS.get_environment("CITADEL_SPACING_"+side+"_INPUT")
	var sha := OS.get_environment("CITADEL_SPACING_"+side+"_SHA256").to_lower()
	if path.is_empty() != sha.is_empty(): return {}
	if path.is_empty(): path = default_path; sha = default_sha
	if not (path.begins_with("res://") or path.is_absolute_path()) or sha.length() != 64 or FileAccess.get_sha256(path) != sha: return {}
	return {"path":path,"sha256":sha}

func _valid_capture(capture: Dictionary) -> bool:
	if not capture.get("blueprint") is Dictionary or not capture.get("policy") is Dictionary: return false
	if not capture.blueprint.get("parts") is Array or not capture.blueprint.get("rooms") is Array: return false
	for key: String in ["furnitureParts","protectedObstacles","reservedVolumes"]:
		if not capture.policy.get(key) is Array: return false
	var ids: Dictionary = {}
	for part: Variant in capture.blueprint.parts:
		if not part is Dictionary or not part.get("id") is String or ids.has(part.id): return false
		ids[part.id] = true
	return true

func _oracle(capture: Dictionary) -> Dictionary:
	var snapshot: Dictionary = capture.blueprint
	var source = Blueprint.new(snapshot.id,snapshot.seed,snapshot.style)
	source.set_room_records(snapshot.rooms.duplicate(true))
	# InteriorProgram consumes only windows, room records and blueprint identity.
	# Replay the REAL producer, not delta addition or a copied float expression.
	var windows: Dictionary = {}
	for record: Dictionary in snapshot.parts:
		if record.kind != "window": continue
		var part = source.add_part(record)
		part.size = record.size
		windows[record.id] = record
	var plan = Plan.new("window_spacing_oracle",snapshot.seed,snapshot.id)
	var reservations: Array[AABB] = []
	for value: Variant in capture.policy.reservedVolumes:
		if not value is AABB: return {"ready":false,"reason":"invalid_reservation"}
		reservations.append(value)
	plan.set_protected_access_reservations(reservations)
	var program: Dictionary = Interior.apply_to_plan(source,plan)
	var records: Dictionary = {}
	for record: Dictionary in plan.snapshot().parts:
		if records.has(record.id): return {"ready":false,"reason":"duplicate_oracle_furniture"}
		records[record.id] = record
	# This calls the production Transform3D * bottom-origin AABB expression.
	# Replacing it with old.bounds + delta can change float32 extents by an ULP.
	var obstacles: Dictionary = Shop.furnishing_obstacles({"parts":capture.policy.furnitureParts},capture.policy.reservedVolumes)
	if not obstacles.get("ready",false): return obstacles
	return {"ready":true,"windows":windows,"furniture":records,"obstacles":obstacles.obstacles,"program":program}

func _policy_proof(old: Dictionary, new: Dictionary) -> Dictionary:
	var checks: Dictionary = {}
	var errors: Array = []
	var changed_items: Array = []
	var changed_obstacles: Array = []
	var old_oracle: Dictionary = _oracle(old)
	var new_oracle: Dictionary = _oracle(new)
	if not old_oracle.get("ready",false) or not new_oracle.get("ready",false):
		return {"passed":false,"reason":"production_oracle_failed","before":old_oracle,"after":new_oracle}
	checks["policy_key_order_exact"] = _equal(old.policy.keys(),new.policy.keys())
	checks["furniture_count_exact"] = old.policy.furnitureParts.size() == new.policy.furnitureParts.size()
	checks["obstacle_count_exact"] = old.policy.protectedObstacles.size() == new.policy.protectedObstacles.size()
	checks["old_obstacles_match_producer"] = _equal(old.policy.protectedObstacles,old_oracle.obstacles)
	checks["new_obstacles_match_producer"] = _equal(new.policy.protectedObstacles,new_oracle.obstacles)
	var expected: Dictionary = old.policy.duplicate(true)
	var moved_windows: Dictionary = {}
	for id: String in old_oracle.windows:
		if not new_oracle.windows.has(id): errors.append({"id":id,"reason":"missing_source_window"}); continue
		var a: Dictionary = old_oracle.windows[id]
		var b: Dictionary = new_oracle.windows[id]
		if _equal(a,b): continue
		var normalized: Dictionary = b.duplicate(true)
		normalized.position.z = a.position.z
		if a.semantic != "citadel_urban_window" or not a.position.is_finite() or not b.position.is_finite() or not _equal(a,normalized):
			errors.append({"id":id,"reason":"window_change_not_finite_z_translation"}); continue
		moved_windows[id] = {"before":a.position,"after":b.position,"delta":b.position-a.position,"items":[]}
	var accepted_items: Dictionary = {}
	var furniture_ids: Dictionary = {}
	for index: int in range(mini(old.policy.furnitureParts.size(),new.policy.furnitureParts.size())):
		var a: Dictionary = old.policy.furnitureParts[index]
		var b: Dictionary = new.policy.furnitureParts[index]
		if a.id != b.id or furniture_ids.has(a.id): errors.append({"index":index,"reason":"furniture_identity_or_order_changed"}); continue
		furniture_ids[a.id] = true
		if _equal(a,b): continue
		var window_id: String = String(a.recipe.get("interiorProgramWindowId",""))
		if not moved_windows.has(window_id) or b.recipe.get("interiorProgramWindowId") != window_id or a.semantic not in ["window_sill_plant","window_sill_candle"]:
			errors.append({"id":a.id,"reason":"unrelated_furniture_changed"}); continue
		if not _equal(a,old_oracle.furniture.get(a.id)) or not _equal(b,new_oracle.furniture.get(b.id)):
			errors.append({"id":a.id,"reason":"not_exact_production_window_furniture"}); continue
		var old_view: Variant = a.recipe.get("viewVolume")
		var new_view: Variant = b.recipe.get("viewVolume")
		if not a.position.is_finite() or not b.position.is_finite() or not _finite_bounds(old_view) or not _finite_bounds(new_view):
			errors.append({"id":a.id,"reason":"nonfinite_window_geometry"}); continue
		var normalized: Dictionary = b.duplicate(true)
		normalized.position.z = a.position.z
		var view: AABB = new_view
		view.position.z = old_view.position.z
		normalized.recipe.viewVolume = view
		if not _equal(a,normalized): errors.append({"id":a.id,"reason":"nontranslation_furniture_field_changed"}); continue
		expected.furnitureParts[index] = b.duplicate(true)
		accepted_items[a.id] = window_id
		moved_windows[window_id].items.append(a.id)
		changed_items.append({"id":a.id,"windowId":window_id,"index":index,"beforePosition":a.position,"afterPosition":b.position,"beforeViewVolume":old_view,"afterViewVolume":new_view})
	var obstacle_ids: Dictionary = {}
	var matched_obstacles: Dictionary = {}
	for index: int in range(mini(old.policy.protectedObstacles.size(),new.policy.protectedObstacles.size())):
		var a: Dictionary = old.policy.protectedObstacles[index]
		var b: Dictionary = new.policy.protectedObstacles[index]
		if a.id != b.id or obstacle_ids.has(a.id): errors.append({"index":index,"reason":"obstacle_identity_or_order_changed"}); continue
		obstacle_ids[a.id] = true
		if _equal(a,b): continue
		var item_id: String = String(a.id).trim_prefix("furnishing:")
		if a.id != "furnishing:"+item_id or not accepted_items.has(item_id) or not _finite_bounds(a.bounds) or not _finite_bounds(b.bounds):
			errors.append({"id":a.id,"reason":"unrelated_obstacle_changed"}); continue
		var normalized: Dictionary = b.duplicate(true)
		normalized.bounds = a.bounds
		if not _equal(a,normalized) or not _equal(a,old_oracle.obstacles[index]) or not _equal(b,new_oracle.obstacles[index]):
			errors.append({"id":a.id,"reason":"not_exact_production_obstacle_translation"}); continue
		expected.protectedObstacles[index] = b.duplicate(true)
		matched_obstacles[item_id] = true
		changed_obstacles.append({"id":a.id,"itemId":item_id,"windowId":accepted_items[item_id],"index":index,"beforeBounds":a.bounds,"afterBounds":b.bounds,"derivedExtentDelta":b.bounds.size-a.bounds.size})
	for id: String in moved_windows:
		var items: Array = moved_windows[id].items
		if items.size() != 2 or not items.has("interior_window_%s_plant"%id) or not items.has("interior_window_%s_candle"%id):
			errors.append({"id":id,"reason":"changed_window_missing_exact_plant_candle_pair"})
	for id: String in accepted_items:
		if not matched_obstacles.has(id): errors.append({"id":id,"reason":"changed_item_missing_obstacle_translation"})
	checks["recorded_24_windows_48_items_48_obstacles"] = moved_windows.size() == 24 and changed_items.size() == 48 and changed_obstacles.size() == 48
	checks["only_proven_policy_replacements"] = _equal(expected,new.policy)
	checks["all_provenance_checks"] = errors.is_empty()
	return {"passed":checks.values().all(func(value: Variant) -> bool: return value == true),"checks":checks,"errors":errors,"changedWindows":moved_windows,"changedItems":changed_items,"changedObstacles":changed_obstacles,"rawPolicyBytesEqual":_equal(old.policy,new.policy),"arithmetic":"Both captured sides independently replay actual Interior.apply_to_plan and Shop.furnishing_obstacles; no old+delta approximation or float tolerance. All other policy bytes/order identical."}

func _tamper_controls(old: Dictionary, new: Dictionary, positive: Dictionary) -> Dictionary:
	if not positive.get("passed",false) or positive.changedItems.is_empty() or positive.changedObstacles.is_empty():
		return {"passed":false,"reason":"positive_control_or_tamper_target_missing"}
	var item_index: int = positive.changedItems[0].index
	var obstacle_index: int = positive.changedObstacles[0].index
	var unrelated_index := -1
	for index: int in range(new.policy.furnitureParts.size()):
		var item: Dictionary = new.policy.furnitureParts[index]
		if not positive.changedWindows.has(String(item.recipe.get("interiorProgramWindowId",""))) and _equal(item,old.policy.furnitureParts[index]):
			unrelated_index = index
			break
	if unrelated_index < 0: return {"passed":false,"reason":"unchanged_unrelated_furniture_missing"}
	var results: Dictionary = {}
	for mode: String in ["unrelated_position","sill_size","sill_material","sill_rotation","wrong_window_id","wrong_view_volume","forged_obstacle","reservation_change","new_policy_key"]:
		var trial: Dictionary = new.duplicate(true)
		var item: Dictionary = trial.policy.furnitureParts[item_index]
		match mode:
			"unrelated_position": trial.policy.furnitureParts[unrelated_index].position.x += 0.25
			"sill_size": item.occupiedSize.x += 0.125
			"sill_material": item.material = "tampered_material"
			"sill_rotation": item.rotation.y += 0.125
			"wrong_window_id": item.recipe.interiorProgramWindowId = "nonexistent_window"
			"wrong_view_volume":
				var bounds: AABB = item.recipe.viewVolume
				bounds.position.z += 0.25
				item.recipe.viewVolume = bounds
			"forged_obstacle":
				var bounds: AABB = trial.policy.protectedObstacles[obstacle_index].bounds
				bounds.position.z += 0.25
				trial.policy.protectedObstacles[obstacle_index].bounds = bounds
			"reservation_change":
				trial.policy.reservedVolumes.append(AABB(Vector3(100.0,100.0,100.0),Vector3.ONE))
			"new_policy_key": trial.policy["unexpected_policy_entry"] = true
		var tampered_bytes: PackedByteArray = var_to_bytes(trial)
		var rejected: Dictionary = _policy_proof(old,trial)
		var guard_failed := false
		var expected_reason := "not_exact_production_window_furniture"
		if mode in ["unrelated_position","wrong_window_id"]: expected_reason = "unrelated_furniture_changed"
		if mode in ["forged_obstacle","reservation_change"]:
			guard_failed = rejected.get("checks",{}).get("new_obstacles_match_producer") == false
		elif mode == "new_policy_key":
			guard_failed = rejected.get("checks",{}).get("policy_key_order_exact") == false
		else:
			for error: Dictionary in rejected.get("errors",[]):
				if error.get("reason") == expected_reason: guard_failed = true
		results[mode] = {"passed":rejected.get("passed") == false and guard_failed and tampered_bytes != var_to_bytes(new) and tampered_bytes == var_to_bytes(trial),
			"rejected":rejected.get("passed") == false,"expectedGuardFailed":guard_failed,
			"checks":rejected.get("checks",{}),"errors":rejected.get("errors",[])}
	return {"passed":results.size() == 9 and results.values().all(func(row: Dictionary) -> bool: return row.passed),"cases":results,
		"changedItemId":new.policy.furnitureParts[item_index].id,"unrelatedItemId":new.policy.furnitureParts[unrelated_index].id,
		"obstacleId":new.policy.protectedObstacles[obstacle_index].id,"scope":"Private final-capture clones only; original captures and production oracle unchanged."}

func _finite_bounds(value: Variant) -> bool:
	return value is AABB and value.position.is_finite() and value.size.is_finite() and value.end.is_finite() and value.size.x > 0.0 and value.size.y > 0.0 and value.size.z > 0.0

func _equal(a: Variant, b: Variant) -> bool: return var_to_bytes(a) == var_to_bytes(b)

func _hashes() -> Dictionary:
	var result: Dictionary = {}
	var pending: Array[String] = [get_script().resource_path]
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

func _json(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[str(key)] = _json(value[key])
		return result
	if value is Array: return value.map(_json)
	if value is Vector3: return {"type":"Vector3","value":[value.x,value.y,value.z]}
	if value is AABB: return {"type":"AABB","position":_json(value.position),"size":_json(value.size)}
	return value
