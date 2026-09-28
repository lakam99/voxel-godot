extends SceneTree

## Source-only synthetic placement of TWO REAL street-house producers. No
## castle/recipe rebuild, anchoring proof, scene publication or gameplay claim.
const Domain = preload("res://scripts/buildings/CitadelMarketBuntingDomain.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Aperture = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const Houses = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const LEFT := "test_house_alpha"
const RIGHT := "test_house_omega"
const PLAZA := "test_public_square"
var checks: Dictionary = {}
var evidence: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("CITADEL_MARKET_BUNTING_DOMAIN_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.file_exists(output.get_basename()+".bin"):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var hashes: Dictionary = _hashes()
	_exercise()
	_sampled_recipe_variants()
	var after: Dictionary = _hashes()
	checks["valid_source_hashes"] = hashes.values().all(func(value: Variant) -> bool: return String(value).length() == 64)
	checks["source_hashes_unchanged"] = hashes == after
	checks["bounded_30_seconds"] = Time.get_ticks_msec() - started < 30000
	var report := {"passed": checks.values().all(func(value: Variant) -> bool: return value == true), "checks": checks,
		"evidence": evidence, "elapsedMsec": Time.get_ticks_msec()-started, "sourceHashesBefore": hashes, "sourceHashesAfter": after,
		"scope": "Synthetic associations of actual street-house producers; domain/ownership only, not rooted support, assembly fit or gameplay acceptance."}
	var saved: bool = _write(output, report)
	print("Market bunting domain checks=", checks.size(), " passed=", report.passed)
	quit(0 if saved and report.passed else 1)

func _source():
	var source = Blueprint.new("synthetic_market_domain", 19, "masonry")
	# Positive synthetic terrain level: the ordinary producer intentionally emits
	# no grounded foundation at top_y <= .02, which cannot satisfy its manifest.
	var base_y := 2.0
	var left_ok: bool = Urban.add_street_house(source, LEFT, Vector3(-8,base_y,0), 6.0, 8.0, 8.8, 1.0, base_y, "plaster_warm", 0.0)
	var right_ok: bool = Urban.add_street_house(source, RIGHT, Vector3(8,base_y,0), 6.0, 8.0, 9.4, -1.0, base_y, "plaster_warm", 0.0)
	checks["actual_house_producers_ready"] = left_ok and right_ok
	if not left_ok or not right_ok: return source
	var left_foundation: AABB = source.transformed_part_bounds(_part(source, LEFT+"_foundation"))
	var right_foundation: AABB = source.transformed_part_bounds(_part(source, RIGHT+"_foundation"))
	var plaza_top: float = maxf(left_foundation.end.y, right_foundation.end.y)
	var plaza_thickness := 0.1
	source.add_part({"id": PLAZA, "kind": "ground_patch", "semantic": "citadel_market_plaza", "material": "cobblestone",
		"collision": false, "position": Vector3(0,plaza_top-plaza_thickness*0.5,0), "size": Vector3(20,plaza_thickness,6),
		"recipe":{"physicalIntent":"visual_detail", "pavingRegion":"citadel_courtyard"}})
	source.add_part({"id":"a_rope", "kind":"beam", "semantic":"citadel_bunting_rope", "collision":false,
		"position":Vector3(0,5,0), "size":Vector3(8,0.035,0.035)})
	source.add_part({"id":"a_flag", "kind":"pennant", "semantic":"citadel_bunting", "collision":false,
		"position":Vector3(0,4.6,0), "size":Vector3(0.5,0.7,0.05)})
	source.recipe["citadelBuntingAssemblies"] = [{"ropeId":"a_rope", "pennantIds":["a_flag"]}]
	return source

func _exercise() -> void:
	var source = _source()
	var before: PackedByteArray = _bytes(source)
	var result: Dictionary = Domain.build(source, LEFT, RIGHT, PLAZA)
	checks["producer_domain_ready"] = result.get("ready") == true
	checks["source_all_records_immutable"] = before == _bytes(source)
	evidence["producerResult"] = result
	if not result.get("ready", false): return
	var left_ids: Array = _declared_ids(source, LEFT)
	var right_ids: Array = _declared_ids(source, RIGHT)
	checks["only_declared_front_facades"] = result.domain.leftAnchorIds == left_ids and result.domain.rightAnchorIds == right_ids
	checks["chimneys_not_anchors"] = not result.domain.leftAnchorIds.has(LEFT+"_chimney") and not result.domain.rightAnchorIds.has(RIGHT+"_chimney")
	var left_bounds: AABB = _envelope(source, left_ids)
	var right_bounds: AABB = _envelope(source, right_ids)
	var plaza_bounds: AABB = source.transformed_part_bounds(_part(source, PLAZA))
	var lower := Vector3(left_bounds.end.x, maxf(plaza_bounds.end.y, maxf(left_bounds.position.y,right_bounds.position.y)),
		maxf(plaza_bounds.position.z,maxf(left_bounds.position.z,right_bounds.position.z)))
	var upper := Vector3(right_bounds.position.x,minf(left_bounds.end.y,right_bounds.end.y),
		minf(plaza_bounds.end.z,minf(left_bounds.end.z,right_bounds.end.z)))
	checks["exact_physical_domain_no_padding"] = result.domain.bounds == AABB(lower,upper-lower)
	checks["plaza_covers_both_anchor_faces"] = plaza_bounds.position.x <= lower.x and plaza_bounds.end.x >= upper.x
	var expected_rooms: Array[AABB] = []
	for room: Dictionary in source.rooms: expected_rooms.append(room.bounds)
	checks["actual_protected_rooms"] = var_to_bytes(result.protectedRooms) == var_to_bytes(expected_rooms)
	checks["repeat_exact"] = var_to_bytes(result) == var_to_bytes(Domain.build(source,LEFT,RIGHT,PLAZA))
	source.parts.reverse()
	source.rooms.reverse()
	checks["inventory_order_invariant"] = var_to_bytes(result) == var_to_bytes(Domain.build(source,LEFT,RIGHT,PLAZA))
	result.domain.leftAnchorIds.clear()
	result.protectedRooms.clear()
	checks["result_not_caller_alias"] = Domain.build(source,LEFT,RIGHT,PLAZA).domain.leftAnchorIds == left_ids
	checks["swapped_associations_reject"] = _failed(Domain.build(source,RIGHT,LEFT,PLAZA))
	checks["duplicate_associations_reject"] = _failed(Domain.build(source,LEFT,LEFT,PLAZA))
	checks["missing_house_reject"] = _failed(Domain.build(source,"absent",RIGHT,PLAZA))
	checks["missing_plaza_reject"] = _failed(Domain.build(source,LEFT,RIGHT,"absent"))
	checks["null_source_reject"] = _failed(Domain.build(null,LEFT,RIGHT,PLAZA))
	for mode: String in ["missing_manifest","malformed_record","wrong_record_identity","wrong_room_link","missing_room","duplicate_room","bad_room_bounds",
		"bad_room_flag","wrong_door_link","door_wrong_room","door_faces_away","missing_facades","duplicate_facade_key","foreign_facade_key",
		"stale_geometry","wrong_facade_kind","noncolliding_facade","rotated_facade","nonfinite_facade","wrong_domain","duplicate_part","null_part",
		"plaza_too_narrow","plaza_no_z_overlap","plaza_above_facades","plaza_nonfinite","plaza_colliding","plaza_wrong_kind",
		"plaza_wrong_intent","plaza_wrong_region","plaza_wrong_semantic","active_cache"]:
		_negative(mode)
	# Rooms beyond the two associated houses are still protected, without adding
	# any extra facade/chimney candidates or borrowing a caller's mutable array.
	var extra = _source()
	var other_room := AABB(Vector3(40,0,0),Vector3(3,3,3))
	extra.rooms.append({"id":"z_other_room","citadelUrbanRoom":true,"bounds":other_room})
	var extra_result: Dictionary = Domain.build(extra,LEFT,RIGHT,PLAZA)
	checks["all_urban_rooms_protected"] = extra_result.get("ready",false) and extra_result.protectedRooms.size() == 3 and extra_result.protectedRooms.has(other_room)
	_augmented_declaration_controls()

func _sampled_recipe_variants() -> void:
	# The production failure was seed-specific only because the chimney preflight
	# can omit optional bunting. Exercise the exact recipe seed and its immediate
	# layout neighbours at the producer/domain boundary so a stale plaza-type
	# assumption cannot hide behind that optional emission again.
	var rows: Array = []
	for seed: int in [2100258698, 2100258699, 2100258700, 2100258701, 2100258702]:
		var source = Blueprint.new("sampled_market_%d" % seed, seed, "masonry")
		var grammar := {"courtyardWidth":104.0, "courtyardDepth":84.0}
		source.set_recipe({"castleGrammar":grammar})
		var reset: Dictionary = Urban.reset_street_house_structural_manifest(source)
		var front_z := -42.0
		var keep_front_z := 8.0
		var base_y := 0.62
		var layout: Dictionary = Urban.sample_urban_layout(seed,grammar,front_z,keep_front_z,base_y)
		var sequence: Dictionary = Urban.add_street_sequence(source,front_z,keep_front_z,base_y,0.0,layout) if reset.get("ready",false) else {"ready":false,"reason":"manifest_reset_failed"}
		var pair: Dictionary = source.recipe.get("citadelMarketHousePair",{}) as Dictionary
		var result: Dictionary = Domain.build(source,String(pair.get("leftHouseId","")),String(pair.get("rightHouseId","")),String(pair.get("plazaPartId",""))) if sequence.get("ready",false) else {"ready":false,"reason":sequence.get("reason","")}
		var plaza = _part(source,String(pair.get("plazaPartId","")))
		var passed: bool = result.get("ready",false) and plaza != null and not plaza.collision_enabled \
			and plaza.kind == "ground_patch" and plaza.physical_intent == "visual_detail"
		checks["sampled_recipe_%d_visual_plaza_domain_ready" % seed] = passed
		rows.append({"seed":seed,"passed":passed,"sequence":sequence,"domain":result,
			"plaza":plaza.snapshot() if plaza != null else {}})
	evidence["sampledRecipeVariants"] = rows

func _augmented_declaration_controls() -> void:
	var source = _source()
	var expected: Dictionary = Domain.build(source,LEFT,RIGHT,PLAZA)
	var key: String = source.recipe[Houses.KEY][LEFT].facadeDeclarationKeys[0]
	var declaration: Dictionary = source.recipe.facadeApertures[key].duplicate(true)
	var wall_domain: AABB = declaration.wallDomain
	# Actual BuildingPart construction beam + actual declaration sealing, with
	# synthetic dimensions. This is NOT an OpeningHead physical admission claim.
	# Its protruding ends intentionally cannot enlarge the masonry-only envelope.
	var head_id := "synthetic_completed_timber_head"
	source.add_part({"id":head_id,"kind":"beam","material":"timber_beam",
		"position":wall_domain.get_center(),"size":Vector3(wall_domain.size.x+0.2,0.4,wall_domain.size.z+2.0),
		"collision":true,"semantic":"citadel_opening_head_band","physicalIntent":"structural_mass",
		"recipe":{"physicalIntent":"structural_mass","preserveBearingFaces":true}})
	declaration.partIds.append(head_id)
	_reseal_declaration(source,key,declaration)
	var by_id: Dictionary = {}
	for part in source.parts: by_id[part.id] = part
	checks["mixed_declaration_full_seal_valid"] = Aperture.validate(source.recipe.facadeApertures[key],by_id)
	var before: PackedByteArray = _bytes(source)
	var result: Dictionary = Domain.build(source,LEFT,RIGHT,PLAZA)
	checks["completed_timber_head_excluded_exact_domain"] = result.get("ready",false) and var_to_bytes(result) == var_to_bytes(expected)
	checks["mixed_declaration_source_immutable"] = before == _bytes(source)
	# Ignoring a non-masonry member must NOT skip its complete declaration seal.
	var head = _part(source,head_id)
	head.position.y += 0.125
	before = _bytes(source)
	result = Domain.build(source,LEFT,RIGHT,PLAZA)
	checks["ignored_head_stale_seal_rejected"] = result.get("reason") == "stale_market_facade_declaration" and _failed(result) and before == _bytes(source)
	# A beam claiming facade masonry must still satisfy every wall guard, even
	# after the full declaration is legitimately re-sealed with its changed type.
	head.semantic = "citadel_urban_facade"
	_reseal_declaration(source,key,source.recipe.facadeApertures[key])
	before = _bytes(source)
	result = Domain.build(source,LEFT,RIGHT,PLAZA)
	checks["sealed_fake_masonry_beam_rejected"] = result.get("reason") == "invalid_market_facade_member" and _failed(result) and before == _bytes(source)
	evidence["augmentedDeclaration"] = {"headId":head_id,"positiveDomain":expected,"fakeWallFailure":result,
		"scope":"Synthetic post-completion declaration shape, real part/seal APIs; no physical admission."}

func _reseal_declaration(source, key: String, value: Dictionary) -> void:
	var declaration: Dictionary = value.duplicate(true)
	declaration.erase("sourceBinding")
	var members: Array = []
	for id: String in declaration.partIds: members.append(_part(source,id))
	source.recipe.facadeApertures[key] = Aperture.seal(declaration,members)

func _negative(mode: String) -> void:
	var source = _source()
	var record: Dictionary = source.recipe[Houses.KEY][LEFT]
	var key: String = record.facadeDeclarationKeys[0]
	var declaration: Dictionary = source.recipe.facadeApertures[key]
	var facade = _part(source, declaration.partIds[0])
	var plaza = _part(source, PLAZA)
	var reseal := false
	match mode:
		"missing_manifest": source.recipe.erase(Houses.KEY)
		"malformed_record": source.recipe[Houses.KEY][LEFT] = []
		"wrong_record_identity": record.producerPrefix = "another"
		"wrong_room_link": record.roomId = RIGHT+"_interior"
		"missing_room": source.rooms.remove_at(0)
		"duplicate_room": source.rooms.append(source.rooms[0].duplicate(true))
		"bad_room_bounds": source.rooms[0].bounds = AABB(Vector3.ZERO,Vector3(-1,3,3))
		"bad_room_flag": source.rooms[0].citadelUrbanRoom = 1
		"wrong_door_link": record.doorId = RIGHT+"_door"
		"door_wrong_room": _part(source, record.doorId).recipe.roomId = "wrong"
		"door_faces_away": _part(source, record.doorId).position.x = -100.0
		"missing_facades": source.recipe.erase("facadeApertures")
		"duplicate_facade_key": record.facadeDeclarationKeys.append(key)
		"foreign_facade_key": record.facadeDeclarationKeys[0] = source.recipe[Houses.KEY][RIGHT].facadeDeclarationKeys[0]
		"stale_geometry": facade.position.y += 0.2
		"wrong_facade_kind":
			facade.kind = "beam"
			reseal = true
		"noncolliding_facade":
			facade.collision_enabled = false
			reseal = true
		"rotated_facade":
			facade.rotation.y = 0.2
			reseal = true
		"nonfinite_facade": facade.size.y = INF
		"wrong_domain":
			declaration.wallDomain = AABB(Vector3(30,2,0),Vector3(0.3,4,6))
			reseal = true
		"duplicate_part": source.parts.append(source.parts[0])
		"null_part": source.parts.append(null)
		"plaza_too_narrow": plaza.size.x = 1.0
		"plaza_no_z_overlap": plaza.position.z = 100.0
		"plaza_above_facades": plaza.position.y = 100.0
		"plaza_nonfinite": plaza.position.x = INF
		"plaza_colliding": plaza.collision_enabled = true
		"plaza_wrong_kind": plaza.kind = "foundation"
		"plaza_wrong_intent":
			plaza.physical_intent = "walkable_surface"
			plaza.recipe.physicalIntent = "walkable_surface"
		"plaza_wrong_region": plaza.recipe.pavingRegion = "another_region"
		"plaza_wrong_semantic": plaza.semantic = "unrelated_paving"
		"active_cache": source._validation_cache_active = true
	if reseal:
		var members: Array = []
		for id: String in declaration.partIds: members.append(_part(source,id))
		declaration.erase("sourceBinding")
		source.recipe.facadeApertures[key] = Aperture.seal(declaration,members)
	var before: PackedByteArray = _bytes(source)
	var result: Dictionary = Domain.build(source,LEFT,RIGHT,PLAZA)
	checks[mode+"_rejected_without_output"] = _failed(result)
	checks[mode+"_input_immutable"] = before == _bytes(source)
	evidence[mode] = result

func _declared_ids(source, house: String) -> Array:
	var result: Array = []
	for key: String in source.recipe[Houses.KEY][house].facadeDeclarationKeys: result.append_array(source.recipe.facadeApertures[key].partIds)
	result.sort()
	return result

func _part(source, id: String):
	for part in source.parts:
		if part != null and part.id == id: return part
	return null

func _envelope(source, ids: Array) -> AABB:
	var result: AABB = source.transformed_part_bounds(_part(source,ids[0]))
	for id: String in ids.slice(1): result = result.merge(source.transformed_part_bounds(_part(source,id)))
	return result

func _failed(result: Dictionary) -> bool:
	return result.get("ready") == false and result.get("reason","") != "" and not result.has("domain") and not result.has("protectedRooms")

func _bytes(source) -> PackedByteArray:
	var parts: Array = []
	for part in source.parts: parts.append(part.snapshot() if part != null else null)
	return var_to_bytes([source.id,source.recipe,source.rooms,parts,source._validation_cache_active])

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
	file.store_var(report,false)
	file.flush()
	var saved: bool = file.get_error() == OK
	file.close()
	file = FileAccess.open(output,FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(report,"\t",true,true))
	file.flush()
	saved = saved and file.get_error() == OK
	file.close()
	return saved
