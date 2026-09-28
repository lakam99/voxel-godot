extends SceneTree

## Source-only street producer / captured keep inventory. Not full Composer,
## Recipe, structural proof, scene collision, navigation or gameplay acceptance.
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Restore = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const SOURCE := "res://artifacts/citadel-runtime-integration/candidate-recipe-09/caller-blueprint.bin"
const SOURCE_SHA := "57ab941d9e714bb91415ee28b59efcbe8fde1b5c65699401c9df9178a561db12"
const MAX_PAIRS := 2000000
var output := ""
var deadline := 0
var stopped := false
var checks: Dictionary = {}
var evidence: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	output = OS.get_environment("CITADEL_STREET_KEEP_BOUNDARY_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.file_exists(output.get_basename()+".bin"):
		quit(2); return
	deadline = Time.get_ticks_msec()+30000
	var worker := Thread.new()
	if worker.start(_work)!=OK:
		_write({"passed":false,"diagnosticCompleted":false,"reason":"worker_start_failed"})
		quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	var saved: bool = _write(report)
	print("Street/keep source inventory completed=",report.diagnosticCompleted," checks=",checks.size()," passed=",report.passed," intersections=",evidence.get("positiveIntersectionCount",0))
	quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var started := Time.get_ticks_usec()
	var hashes: Dictionary = _hashes()
	_inventory()
	var after: Dictionary = _hashes()
	checks["bound_sources_unchanged"] = hashes==after
	checks["deadline"] = _continue()
	return {"schema":"citadel-street-keep-boundary/v1","passed":checks.values().all(func(value): return value==true),
		"diagnosticCompleted":evidence.get("pairInventoryComplete",false),"checks":checks,"evidence":evidence,
		"sourceHashesBefore":hashes,"sourceHashesAfter":after,"elapsedUsec":Time.get_ticks_usec()-started,"internalDeadlineSeconds":30,
		"scope":"Fresh ordinary street producer using captured scalars and current layout sampled from the actual retained keep boundary. Archived layout remains comparison evidence. Requires historical overlap and corrected current clearance, not full geometry equality. No full Recipe, physics, navigation or gameplay acceptance."}

func _inventory() -> void:
	checks["exact_caller_hash"] = FileAccess.get_sha256(SOURCE)==SOURCE_SHA
	if not checks.exact_caller_hash: return
	var file := FileAccess.open(SOURCE,FileAccess.READ)
	if file==null: checks["typed_caller_read"]=false; return
	var value: Variant = file.get_var(false)
	checks["typed_caller_read"] = file.get_error()==OK and value is Dictionary
	file.close()
	if not checks.typed_caller_read: return
	var snapshot: Dictionary = value
	var source = Restore.copy_blueprint(snapshot)
	var original: PackedByteArray = var_to_bytes(snapshot)
	checks["restored_snapshot_exact"] = original==var_to_bytes(source.snapshot())
	var grammar: Dictionary = source.recipe.get("castleGrammar",{})
	var layout: Dictionary = source.recipe.get("urbanPoc",{})
	checks["captured_inputs_present"] = not grammar.is_empty() and not layout.is_empty() and source.recipe.has("foundationHeight")
	if not checks.captured_inputs_present: return
	var base := float(source.recipe.foundationHeight)
	var depth := float(grammar.get("courtyardDepth",84.0))
	var front := -depth*0.5
	var keep_front := depth*float(grammar.get("keepOffset",{}).get("z",0.14))-float(grammar.get("keepDepth",28.0))*0.5
	var variation := float(source.seed%19)/100.0-0.09
	var inputs: Dictionary = {"seed":source.seed,"context":source.recipe.get("context",{}),"grammar":grammar,"layout":layout,"frontZ":front,"keepFrontZ":keep_front,"baseY":base,"variation":variation}
	var inputs_before: PackedByteArray = var_to_bytes(inputs)
	evidence["inputs"] = inputs
	var keeps: Array = source.parts.filter(func(part): return part.collision_enabled and String(part.id).begins_with("castle_keep_"))
	checks["actual_keep_boundary_available"]=not keeps.is_empty()
	if not checks.actual_keep_boundary_available: return
	var minimum_keep_z := INF
	for part in keeps:
		var bounds: AABB=source.transformed_part_bounds(part)
		minimum_keep_z=minf(minimum_keep_z,bounds.position.z)
	var rear: float=Urban.street_rear_boundary(source,keep_front)
	var expected_rear: float=minf(keep_front-5.0,minimum_keep_z-0.25)
	checks["independent_actual_keep_boundary"]=is_finite(rear) and rear==expected_rear
	var reversed = Restore.copy_blueprint(snapshot)
	reversed.parts.reverse()
	checks["boundary_parts_order_invariant"]=Urban.street_rear_boundary(reversed,keep_front)==rear
	evidence["rearBoundary"]={"actual":rear,"independent":expected_rear,"minimumKeepZ":minimum_keep_z,"nominalRearZ":keep_front-5.0,"clearance":0.25}
	if not checks.independent_actual_keep_boundary: return
	_malformed_boundary_controls(keeps[0],front,keep_front,base,variation,layout)
	var sampled_layout: Dictionary = Urban.sample_urban_layout(source.seed,grammar,front,keep_front,base,rear)
	var sampled_before: PackedByteArray=var_to_bytes(sampled_layout)
	evidence["currentSampledLayout"] = sampled_layout
	for key: String in ["laneCenters","rowCenterPhases","rowWidthBiases","rowStoreyBonuses","marketTerraceRise","marketStalls"]:
		checks["sampled_street_inputs_preserved_"+key]=var_to_bytes(sampled_layout.get(key))==var_to_bytes(layout.get(key))
	var street = Blueprint.new(source.id,source.seed,source.style)
	var started := Time.get_ticks_usec()
	var receipt: Dictionary = Urban.add_street_sequence(street,front,keep_front,base,variation,sampled_layout)
	evidence["producerReceipt"] = receipt
	evidence["producerUsec"] = Time.get_ticks_usec()-started
	checks["street_producer_ready"] = receipt.get("ready")==true
	checks["input_scalars_layout_unchanged"] = inputs_before==var_to_bytes(inputs)
	checks["sampled_layout_unchanged"]=sampled_before==var_to_bytes(sampled_layout)
	if not checks.street_producer_ready or not _continue(): return
	evidence["availableStreetDepth"] = keep_front-front-5.0
	checks["street_span_within_actual_domain"] = float(receipt.rowGeometry.usableDepth)<=keep_front-front-5.0
	checks["street_span_matches_actual_rear"]=float(receipt.rowGeometry.usableDepth)==rear-front
	checks["intentional_historical_span_divergence"]=float(receipt.rowGeometry.usableDepth)<42.0
	var civic: Dictionary=Urban.civic_commons_layout(front,keep_front,base,sampled_layout)
	checks["actual_civic_consumer_same_rows"]=civic.get("ready")==true and var_to_bytes(civic.get("rowGeometry"))==var_to_bytes(receipt.rowGeometry)
	var market_z: float=front+(rear-front)*0.655
	var trees: Array=Urban.market_edge_tree_sites(source.seed,float(sampled_layout.marketLaneX),market_z,base+float(sampled_layout.marketTerraceRise)+0.345,sampled_layout.marketStalls)
	checks["actual_market_tree_consumer_same_span"]=not trees.is_empty() and var_to_bytes(sampled_layout.treePlacements.slice(0,trees.size()))==var_to_bytes(trees)
	evidence["actualConsumers"]={"civic":civic,"marketZ":market_z,"marketTrees":trees,"historicalUsableDepth":42.0,"currentUsableDepth":receipt.rowGeometry.usableDepth}
	_boundary_controls(source.seed,grammar,front,base,variation)
	var rows: Array = street.parts.filter(func(part): return part.collision_enabled and String(part.id).begins_with("urban_row_"))
	var historical: Array = source.parts.filter(func(part): return String(part.id).begins_with("urban_row_"))
	checks["nonempty_street_and_keep"] = not rows.is_empty() and not keeps.is_empty()
	checks["bounded_pair_count"] = rows.size()*keeps.size()<=MAX_PAIRS
	if not checks.nonempty_street_and_keep or not checks.bounded_pair_count: return
	var old_by_id: Dictionary = {}
	for part in historical: old_by_id[part.id]=part.snapshot()
	var changed: Array = []; var added: Array = []; var matched := 0
	for part in street.parts:
		if not String(part.id).begins_with("urban_row_"): continue
		if not _continue(): return
		if not old_by_id.has(part.id): added.append(part.id); continue
		if var_to_bytes(part.snapshot())==var_to_bytes(old_by_id[part.id]): matched+=1
		else: changed.append(part.id)
		old_by_id.erase(part.id)
	evidence["historicalComparison"] = {"exactRecordMatches":matched,"changedIds":changed,"newIds":added,"historicalOnlyIds":old_by_id.keys(),"exact":changed.is_empty() and added.is_empty() and old_by_id.is_empty(),"historicalEqualityRequired":false}
	evidence["currentRowGeometry"] = rows.map(func(part): return _geometry(street,part))
	var furthest_row_z := -INF
	for part in rows:
		var represented: AABB=street.transformed_part_bounds(part)
		furthest_row_z=maxf(furthest_row_z,represented.end.z)
	evidence["representedApproach"]={"furthestCollidingRowZ":furthest_row_z,"keepFrontZ":keep_front,"remainingApproach":keep_front-furthest_row_z,"requiredApproach":5.0}
	checks["represented_rows_preserve_approach"]=furthest_row_z<=keep_front-5.0
	checks["represented_rows_preserve_actual_keep_clearance"]=furthest_row_z<=rear
	evidence["retainedKeepGeometry"] = keeps.map(func(part): return _geometry(source,part))
	evidence["capturedRowGeometry"] = historical.filter(func(part): return part.collision_enabled).map(func(part): return _geometry(source,part))
	var street_before: PackedByteArray = var_to_bytes(street.snapshot())
	var current_design: Dictionary = _house_design(street.parts)
	var historical_design: Dictionary = _house_design(historical)
	evidence["houseDesign"]={"current":current_design,"historical":historical_design}
	checks["same_house_count_and_design"] = not current_design.is_empty() and var_to_bytes(current_design)==var_to_bytes(historical_design)
	var current_pairs: Dictionary = _pairs(source,rows,keeps)
	var historical_pairs: Dictionary = _pairs(source,historical.filter(func(part): return part.collision_enabled),keeps)
	evidence["current"] = current_pairs; evidence["historical"] = historical_pairs
	evidence["positiveIntersectionCount"] = current_pairs.pairs.size()
	evidence["pairInventoryComplete"] = current_pairs.complete and historical_pairs.complete
	checks["all_pairs_visited"] = evidence.pairInventoryComplete
	checks["historical_positive_overlap"] = not historical_pairs.pairs.is_empty()
	checks["current_no_keep_overlap"] = current_pairs.pairs.is_empty() and current_pairs.complete
	checks["source_and_generated_records_immutable"] = original==var_to_bytes(source.snapshot()) and street_before==var_to_bytes(street.snapshot())
	checks["caller_file_unchanged"] = FileAccess.get_sha256(SOURCE)==SOURCE_SHA

func _pairs(source, rows: Array, keeps: Array) -> Dictionary:
	var pairs: Array = []; var tested := 0; var shared_tests := 0
	var member_records: Dictionary = {}
	var started := Time.get_ticks_usec()
	for row in rows:
		var row_bounds: AABB = source.transformed_part_bounds(row)
		for keep in keeps:
			if tested>=MAX_PAIRS or not _continue(): return {"complete":false,"pairs":pairs,"testedPairs":tested}
			tested+=1
			var keep_bounds: AABB = source.transformed_part_bounds(keep)
			var overlap: AABB = row_bounds.intersection(keep_bounds)
			# Zero-margin positive broadphase; near/touching contacts are not reported as penetration.
			if overlap.size.x<=0.0 or overlap.size.y<=0.0 or overlap.size.z<=0.0: continue
			shared_tests+=1
			if not source.transformed_parts_overlap(row,keep,0.0): continue
			pairs.append({"rowId":row.id,"keepId":keep.id,"rowBounds":row_bounds,"keepBounds":keep_bounds,"aabbIntersection":overlap,"sharedTransformedOverlap":true,"margin":0.0})
			member_records[row.id]=row.snapshot(); member_records[keep.id]=keep.snapshot()
	return {"complete":true,"pairs":pairs,"intersectingMemberRecords":member_records,"potentialPairs":rows.size()*keeps.size(),"testedPairs":tested,"sharedOverlapCalls":shared_tests,"elapsedUsec":Time.get_ticks_usec()-started}

func _house_design(parts: Array) -> Dictionary:
	var houses: Dictionary = {}
	for part in parts:
		if not String(part.id).begins_with("urban_row_"): continue
		var tokens: PackedStringArray = String(part.id).split("_")
		if tokens.size()<5: continue
		var id: String = "_".join(tokens.slice(0,4))
		if not houses.has(id): houses[id]={"materials":[],"foundationWidth":0.0,"foundationHeight":0.0,"foundationX":0.0}
		if not houses[id].materials.has(part.material_id): houses[id].materials.append(part.material_id)
		if part.id==id+"_foundation":
			houses[id].foundationWidth=part.size.x; houses[id].foundationHeight=part.size.y; houses[id].foundationX=part.position.x
	for id: String in houses: houses[id].materials.sort()
	return houses

func _boundary_controls(seed: int, grammar: Dictionary, front: float, base: float, variation: float) -> void:
	var cases: Array=[]
	# Synthetic span controls through ordinary sampler/consumers, not alternative site geometry.
	for available: float in [41.75,42.0,42.25]:
		if not _continue(): return
		var keep: float=front+5.0+available
		var layout: Dictionary=Urban.sample_urban_layout(seed,grammar,front,keep,base)
		var rows: Dictionary=Urban.street_row_geometry(front,keep,layout)
		var civic: Dictionary=Urban.civic_commons_layout(front,keep,base,layout)
		var tree_y: float=base+float(layout.marketTerraceRise)+0.345
		var trees: Array=Urban.market_edge_tree_sites(seed,float(layout.marketLaneX),front+(keep-front-5.0)*0.655,tree_y,layout.marketStalls)
		var label: String=str(available)
		checks["span_exact_"+label]=rows.get("ready")==true and float(rows.get("usableDepth",-1))==keep-front-5.0
		checks["civic_consumer_same_rows_"+label]=civic.get("ready")==true and var_to_bytes(civic.get("rowGeometry"))==var_to_bytes(rows)
		checks["market_tree_consumer_same_span_"+label]=not trees.is_empty() and var_to_bytes(layout.treePlacements.slice(0,trees.size()))==var_to_bytes(trees)
		cases.append({"availableDepth":available,"rows":rows,"civicReady":civic.get("ready"),"marketZ":front+(keep-front-5.0)*0.655,"marketTrees":trees})
	var small = Blueprint.new("synthetic-too-short",seed,"masonry")
	var before: PackedByteArray=var_to_bytes(small.snapshot())
	var short_layout: Dictionary=Urban.sample_urban_layout(seed,grammar,front,front+6.0,base)
	var rejected: Dictionary=Urban.add_street_sequence(small,front,front+6.0,base,variation,short_layout)
	checks["too_short_rejected_without_partial_source"]=rejected.get("ready")==false and before==var_to_bytes(small.snapshot())
	evidence["syntheticBoundaryControls"]={"cases":cases,"tooShortReceipt":rejected}

func _geometry(blueprint, part) -> Dictionary:
	return {"id":part.id,"kind":part.kind,"semantic":part.semantic,"position":part.position,"rotation":part.rotation,"size":part.size,"bounds":blueprint.transformed_part_bounds(part)}

func _malformed_boundary_controls(keep, front: float, keep_front: float, base: float, variation: float, layout: Dictionary) -> void:
	for invalid: String in ["nonfinite_position","zero_size","empty_source","no_qualifying_keep"]:
		var malformed = Blueprint.new("synthetic-malformed-keep",0,"masonry")
		if invalid!="empty_source":
			var part = malformed.add_part(keep.snapshot())
			if invalid=="nonfinite_position": part.position.z=NAN
			elif invalid=="zero_size": part.size=Vector3.ZERO
			else:
				part.collision_enabled=false
				var unrelated = malformed.add_part(keep.snapshot())
				unrelated.id="unrelated_colliding_structure"
		var before: PackedByteArray=var_to_bytes(malformed.snapshot())
		var rejected: float=Urban.street_rear_boundary(malformed,keep_front)
		checks["malformed_boundary_"+invalid]=is_nan(rejected) and before==var_to_bytes(malformed.snapshot())
		var rejected_layout: Dictionary=layout.duplicate(true)
		rejected_layout["streetRearZ"]=rejected
		var empty = Blueprint.new("synthetic-rejected-street",0,"masonry")
		var empty_before: PackedByteArray=var_to_bytes(empty.snapshot())
		var receipt: Dictionary=Urban.add_street_sequence(empty,front,keep_front,base,variation,rejected_layout)
		checks["malformed_boundary_no_emission_"+invalid]=receipt.get("ready")==false and receipt.get("reason")=="invalid_street_rear_boundary" and empty_before==var_to_bytes(empty.snapshot())

func _continue() -> bool:
	stopped = stopped or Time.get_ticks_msec()>=deadline
	return not stopped

func _hashes() -> Dictionary:
	var result: Dictionary = {}
	var pending: Array[String] = [SOURCE,get_script().resource_path]
	var invalid: Array[String] = []
	# Match whole quoted paths, never the .gd prefix of a .gdshader filename.
	var regex := RegEx.create_from_string('["\'](res://[^"\'\\r\\n]+)["\']')
	while not pending.is_empty():
		var path: String = pending.pop_back()
		if result.has(path) or invalid.has(path): continue
		var digest: String = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
		if digest.length()!=64: invalid.append(path); continue
		result[path]=digest
		if path.get_extension() not in ["gd","gdshader"]: continue
		for match_value: RegExMatch in regex.search_all(FileAccess.get_file_as_string(path)):
			var dependency: String = match_value.get_string(1)
			if dependency.get_extension() in ["gd","gdshader"]: pending.append(dependency)
	# Fail the report on an invalid binding, even if both hash passes miss the same file.
	checks["source_hash_closure_complete"]=checks.get("source_hash_closure_complete",true) and invalid.is_empty()
	if not invalid.is_empty(): evidence["invalidHashSources"]=invalid
	return result

func _write(report: Dictionary) -> bool:
	var typed := FileAccess.open(output.get_basename()+".bin",FileAccess.WRITE)
	if typed==null: return false
	typed.store_var(report,false); typed.flush()
	var saved: bool = typed.get_error()==OK
	typed.close()
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: return false
	file.store_string(JSON.stringify(_json(report),"\t",true,true)); file.flush()
	saved = saved and file.get_error()==OK
	file.close()
	return saved

func _json(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[str(key)]=_json(value[key])
		return result
	if value is Array: return value.map(_json)
	if value is Vector3: return {"type":"Vector3","value":[value.x,value.y,value.z]}
	if value is Vector2: return {"type":"Vector2","value":[value.x,value.y]}
	if value is AABB or value is Rect2: return {"type":type_string(typeof(value)),"position":_json(value.position),"size":_json(value.size)}
	return value
