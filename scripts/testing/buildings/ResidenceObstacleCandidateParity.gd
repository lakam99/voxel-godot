extends SceneTree

## Actual candidate placement parity against d093c89, source-only. No game.
const Builder = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Sampler = preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
const Planner = preload("res://scripts/buildings/CastleCourtyardDistrictPlacementPlanner.gd")
const Original = preload("res://artifacts/citadel-runtime-integration/residence-obstacle-original/CastleCourtyardDistrictPlacementPlanner.gd")
const ORIGINAL_SHA := "d1005fb22ef2dd63b9f2839022574e441184e69893c2784bbd87d2f94bc8dfae"
const GEOMETRY_PATH := "res://artifacts/citadel-runtime-integration/residence-obstacle-original/CastleResidencePlacementGeometry.gd"
const GEOMETRY_SHA := "fcd37306189d0f1bdf40608bf9e3ff11c57e9aaf61458fb709b60b56b6901fee"
const OPTIONS := {"fixedClearance":0.04,"residenceClearance":0.08,"pairClearance":2.60,"boundaryClearance":0.90}
const SEED := 541151883
const CONTEXT := {"biome":"forest","siteKey":"citadel-site-v1:14:atlas-30895044:-1,0","citadelScale":1.25,"settlementTier":"city","style":"masonry"}
var deadline := 0
var output := ""
var checks: Dictionary = {}
var callbacks: Dictionary = {}
var stream: HashingContext
var rejected := false

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	output=OS.get_environment("RESIDENCE_OBSTACLE_CANDIDATE_REPORT")
	if not output.is_absolute_path(): quit(2); return
	deadline=Time.get_ticks_msec()+210000
	var hashes := _hashes()
	checks.original_planner_pinned=FileAccess.get_sha256("res://artifacts/citadel-runtime-integration/residence-obstacle-original/CastleCourtyardDistrictPlacementPlanner.gd")==ORIGINAL_SHA
	checks.original_geometry_pinned=FileAccess.get_sha256(GEOMETRY_PATH)==GEOMETRY_SHA
	var inputs := _ordinary_inputs(SEED,CONTEXT)
	checks.actual_inputs_ready=inputs.get("ready",false) and inputs.intents.size()==10
	if not checks.values().all(func(value): return value==true): _finish({"reason":"input_or_oracle_failed"},hashes); return
	var before := _input_snapshot(inputs)
	var old := _measured_plan(Original,inputs)
	var current := _measured_plan(Planner,inputs)
	checks.old_and_current_ready=old.plan.get("status")=="ready" and current.plan.get("status")=="ready"
	checks.complete_plan_bytes_equal=var_to_bytes(old.plan)==var_to_bytes(current.plan)
	checks.callback_sequence_equal=old.callbackSha256==current.callbackSha256 and old.callbacks==current.callbacks
	checks.inputs_unchanged=var_to_bytes(before)==var_to_bytes(_input_snapshot(inputs))
	checks.no_cancellation=not old.cancelled and not current.cancelled
	checks.ten_residences=current.plan.get("placements",[]).size()==10
	checks.deadline=Time.get_ticks_msec()<deadline
	var binary := {"inputs":before,"original":old,"current":current}
	var file := FileAccess.open(output.get_basename()+".bin",FileAccess.WRITE)
	checks.binary_written=file!=null
	if file!=null:
		file.store_var(binary,false); file.flush()
		checks.binary_written=file.get_error()==OK
		file.close()
	_finish({"seed":SEED,"context":CONTEXT,"oldUsec":old.elapsedUsec,"currentUsec":current.elapsedUsec,
		"oldCallbacks":old.callbacks,"currentCallbacks":current.callbacks,"callbackSha256":current.callbackSha256,
		"completePlanSha256":_sha(var_to_bytes(current.plan)),"inputSha256":_sha(var_to_bytes(before)),
		"originalStatus":old.plan.get("status"),"currentStatus":current.plan.get("status"),
		"partCounts":inputs.intents.map(func(intent): return intent.sourceBlueprint.parts.size()),
		"structureCount":inputs.structureParts.size(),"telemetry":current.plan.get("telemetry",{})},hashes)

func _measured_plan(owner, inputs: Dictionary) -> Dictionary:
	callbacks={}; rejected=false
	stream=HashingContext.new(); stream.start(HashingContext.HASH_SHA256)
	var started := Time.get_ticks_usec()
	var result: Dictionary=owner.plan(inputs.intents,inputs.streetRecords,inputs.structureParts,inputs.courtyardBounds,OPTIONS,_continue)
	return {"plan":result,"elapsedUsec":Time.get_ticks_usec()-started,"callbacks":callbacks.duplicate(),
		"callbackSha256":stream.finish().hex_encode(),"cancelled":rejected}

func _continue(stage: String) -> bool:
	callbacks[stage]=int(callbacks.get(stage,0))+1
	stream.update((stage+"\n").to_utf8_buffer())
	if rejected: checks.no_callbacks_after_cancel=false; return false
	rejected=Time.get_ticks_msec()>=deadline
	return not rejected

func _input_snapshot(inputs: Dictionary) -> Dictionary:
	var result := inputs.duplicate(true)
	for index in range(result.intents.size()):
		result.intents[index].sourceBlueprint=inputs.intents[index].sourceBlueprint.snapshot()
	return result

func _sha(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256); context.update(bytes)
	return context.finish().hex_encode()

func _hashes() -> Dictionary:
	var result: Dictionary={}
	var pending: Array[String]=[get_script().resource_path]
	var regex := RegEx.create_from_string("[\"'](res://[^\"'\\r\\n]+)[\"']")
	while not pending.is_empty():
		var path: String=pending.pop_back()
		if result.has(path): continue
		result[path]=FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
		if String(result[path]).length()!=64: checks.source_hashes_valid=false; continue
		for matched: RegExMatch in regex.search_all(FileAccess.get_file_as_string(path)):
			var dependency := matched.get_string(1)
			if dependency.get_extension() in ["gd","gdshader"]: pending.append(dependency)
	return result

func _finish(evidence: Dictionary, hashes: Dictionary) -> void:
	var after := _hashes()
	checks.sources_unchanged=hashes==after
	var report := {"passed":checks.values().all(func(value): return value==true),"checks":checks,"evidence":evidence,
		"sourceHashesBefore":hashes,"sourceHashesAfter":after,"internalDeadlineSeconds":210,
		"scope":"Actual sampled candidate courtyard placement and complete plan/telemetry parity against frozen original. No full Urban recipe, physical integrity, runtime publication or visual acceptance."}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t",true,true)); file.flush()
	var saved := file.get_error()==OK
	file.close()
	print("RESIDENCE CANDIDATE PARITY ",checks.size()," checks passed=",report.passed)
	quit(0 if saved and report.passed else 1)

func _ordinary_inputs(seed: int, input_context: Dictionary) -> Dictionary:
	var context := input_context.duplicate(true)
	var compound: Dictionary = Sampler.sample_compound(seed, "castle", context)
	var members: Array = compound.get("members", []) as Array
	var grammar: Dictionary = compound.get("castleGrammar", {}) as Dictionary
	var keep_recipe: Dictionary = Builder.member_recipe(members, "keep")
	var courtyard_recipe: Dictionary = Builder.member_recipe(members, "courtyard")
	var tower_recipes: Array = Builder.member_recipes(members, "tower")
	if keep_recipe.is_empty() or courtyard_recipe.is_empty():
		return {"ready": false, "reason": "missing_sampled_castle_members"}
	var courtyard_width := float(grammar.get("courtyardWidth", courtyard_recipe.get("width", 46.0)))
	var courtyard_depth := float(grammar.get("courtyardDepth", courtyard_recipe.get("depth", 42.0)))
	var tower_span := float(grammar.get("towerSpan", (tower_recipes[0] as Dictionary).get("width", 6.4) if not tower_recipes.is_empty() else 6.4))
	var tower_count := clampi(int(grammar.get("towerCount", 4)), 4, 8)
	var tower_height_base := float(grammar.get("towerHeightBase", float((tower_recipes[0] as Dictionary).get("floorHeight", 3.6)) * 3.4 if not tower_recipes.is_empty() else 12.4))
	var tower_height_variation := float(grammar.get("towerHeightVariation", 0.16))
	var keep_width := minf(float(grammar.get("keepWidth", float(keep_recipe.get("width", 26.0)) * 0.52)), courtyard_width - tower_span * 2.50)
	var keep_depth := minf(float(grammar.get("keepDepth", float(keep_recipe.get("depth", 24.0)) * 0.48)), courtyard_depth - tower_span * 2.50)
	var keep_height := float(grammar.get("keepHeight", float(keep_recipe.get("floorHeight", 3.7)) * float(maxi(3, int(keep_recipe.get("floorCount", 4))))))
	var keep_reference_floor_height := clampf(float(keep_recipe.get("floorHeight", 3.70)), 3.20, 4.20)
	var keep_storey_count := clampi(roundi(keep_height / keep_reference_floor_height), 3, 24)
	var keep_floor_height := keep_height / float(keep_storey_count)
	var foundation_height := 0.62
	var keep_foundation_height := foundation_height + Builder.citadel_keep_terrace_elevation(grammar)
	var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
	var keep_center := Vector3(0.0, 0.0, courtyard_depth * float(keep_offset.get("z", 0.14)))
	var variation := float(seed % 19) / 100.0 - 0.09
	var masonry_palette: Dictionary = grammar.get("citadelMasonry", {}) as Dictionary
	var fortification_material := String(masonry_palette.get("fortification", "fired_brick"))
	var palace_grammar: Dictionary = grammar.get("palaceGrammar", {}) as Dictionary
	var tower_specs: Array[Dictionary] = Builder.tower_specs_for_grammar(seed, courtyard_width, courtyard_depth, tower_count, tower_span, tower_height_base, tower_height_variation, int(grammar.get("towerPhase", 0)))
	var source_blueprint = Blueprint.new("compound.castle.%d.%s" % [seed, String(context.siteKey)], seed, "masonry")
	Builder.add_keep(source_blueprint, keep_center, keep_width, keep_depth, keep_height, keep_storey_count, keep_floor_height, keep_foundation_height, variation, fortification_material, palace_grammar)
	for index in range(tower_specs.size()):
		var tower_spec: Dictionary = tower_specs[index]
		Builder.add_tower(source_blueprint, "castle_tower_%02d" % (index + 1), tower_spec.get("position", Vector3.ZERO) as Vector3, float(tower_spec.get("span", tower_span)), float(tower_spec.get("height", tower_height_base)), foundation_height, variation + float(index) * 0.006, fortification_material)
	var structure_parts: Array[Dictionary] = Builder.keep_collision_footprints(source_blueprint.parts)
	var program: Array = grammar.get("courtyardProgram", []) as Array
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var lot_pairs: Array = grid.get("lotPairs", []) as Array
	var street_records: Array = grid.get("streetRecords", []) as Array
	if String(grid.get("mode", "")) != "district_grid" or program.size() != lot_pairs.size() * 2 or street_records.is_empty():
		return {"ready": false, "reason": "invalid_sampled_district_domain", "programCount": program.size(), "lotPairCount": lot_pairs.size(), "streetCount": street_records.size()}
	var intents: Array = []
	for index in range(0, program.size(), 2):
		var pair_index := index >> 1
		var lot_pair: Dictionary = lot_pairs[pair_index]
		var sources: Array = [program[index], program[index + 1]]
		for side_index in range(2):
			var source: Dictionary = sources[side_index]
			var side := "left" if side_index == 0 else "right"
			if not Builder.sampled_district_lot_binding_valid(source, lot_pair, side) or not Builder.sampled_residence_authority_valid(source, lot_pair, side):
				return {"ready": false, "reason": "sampled_authority_mismatch", "pairIndex": pair_index, "side": side}
			var identity := String(source.get("id", ""))
			var family := String(source.get("residenceFamily", ""))
			var recipe: Dictionary = (source.get("residenceRecipe", {}) as Dictionary).duplicate(true)
			var residence_blueprint = Builder.courtyard_residence_blueprint_from_recipe(family, recipe)
			if residence_blueprint == null:
				return {"ready": false, "reason": "source_blueprint_failed", "intentId": identity}
			var source_spec := source.duplicate(true)
			source_spec["residenceFacadeMaterial"] = Builder.residence_facade_material(seed, identity, masonry_palette)
			intents.append({
				"id": identity,
				"pairIndex": pair_index,
				"side": side,
				"family": family,
				"recipe": recipe,
				"recipeHash": String(source.get("residenceRecipeHash", "")),
				"sourceBlueprint": residence_blueprint,
				"sourceBlueprintSignature": residence_blueprint.deterministic_signature(),
				"sourceSpec": source_spec,
				"nominalCenter": Vector3(float(source.get("gridCenterX")), 0.0, float(source.get("gridCenterZ"))),
				"frontDirection": String(source.get("frontDirection", "")),
				"elevation": float(source.get("terraceElevation")),
				"foundationElevation": foundation_height
			})
	return {
		"ready": intents.size() == program.size(),
		"compound": compound,
		"grammar": grammar,
		"program": program,
		"lotPairs": lot_pairs,
		"streetRecords": street_records,
		"structureParts": structure_parts,
		"intents": intents,
		"courtyardBounds": {"minX": -courtyard_width * 0.5, "maxX": courtyard_width * 0.5, "minZ": -courtyard_depth * 0.5, "maxZ": courtyard_depth * 0.5},
		"sourceBlueprintPartCount": source_blueprint.parts.size(),
		"sourceBlueprintSignature": source_blueprint.deterministic_signature()
	}
