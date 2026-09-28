extends SceneTree

## Captured real failed caller. Source-only proposed terrace reconciliation,
## not full Recipe, physical integrity, visual or gameplay acceptance.
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Infill = preload("res://scripts/buildings/CivicHouseInfillRecipe.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Terraces = preload("res://scripts/buildings/ResidentialTerraceCarvingRecipe.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Occupancy = preload("res://scripts/buildings/ReplacementBoxOccupancy.gd")
const SOURCE := "res://artifacts/citadel-runtime-integration/candidate-recipe-09/caller-blueprint.bin"
const SOURCE_SHA := "57ab941d9e714bb91415ee28b59efcbe8fde1b5c65699401c9df9178a561db12"
var output := ""
var deadline := 0
var checks: Dictionary={}
var evidence: Dictionary={}
var stopped := false
var cancel_at := 0
var calls := 0
var phase := "controls"

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	output=OS.get_environment("CITADEL_TERRACE_RECONCILIATION_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	var requested := OS.get_environment("CITADEL_TERRACE_RECONCILIATION_PHASE")
	if not requested.is_empty(): phase=requested
	if phase not in ["controls","composer"]: quit(2); return
	deadline=Time.get_ticks_msec()+30000
	var worker := Thread.new()
	if worker.start(_work)!=OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary=worker.wait_to_finish()
	var typed := FileAccess.open(output.get_basename()+".bin",FileAccess.WRITE)
	if typed==null: quit(2); return
	typed.store_var(report,false); typed.flush()
	var typed_saved: bool=typed.get_error()==OK
	typed.close()
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(_json(report),"\t",true,true)); file.flush()
	var saved := file.get_error()==OK
	file.close()
	print("Terrace reconciliation checks=",checks.size()," passed=",report.passed," result=",evidence.get("result",{}).get("reason",""))
	quit(0 if saved and typed_saved and report.passed else 1)

func _work() -> Dictionary:
	var started := Time.get_ticks_usec()
	var hashes := _hashes()
	_exercise()
	evidence["sourceHashesBefore"]=hashes; evidence["sourceHashesAfter"]=_hashes()
	checks["all_bound_sources_unchanged"]=hashes==evidence.sourceHashesAfter
	checks["caller_hash_after"]=FileAccess.get_sha256(SOURCE)==SOURCE_SHA
	checks["deadline"]=not stopped and Time.get_ticks_msec()<deadline
	return {"passed":checks.values().all(func(value): return value==true),"phase":phase,"checks":checks,"evidence":evidence,"elapsedUsec":Time.get_ticks_usec()-started,
		"scope":"captured source-only terrace and residence preparation; no full recipe, physical integrity, rendering, publication or gameplay"}

func _exercise() -> void:
	checks["exact_caller_hash"]=FileAccess.get_sha256(SOURCE)==SOURCE_SHA
	if not checks.exact_caller_hash: return
	var file := FileAccess.open(SOURCE,FileAccess.READ)
	if file==null: checks["caller_read"]=false; return
	var loaded: Variant=file.get_var(false)
	checks["caller_read"]=file.get_error()==OK and loaded is Dictionary
	file.close()
	if not checks.caller_read: return
	var snapshot: Dictionary=loaded
	var source = Copy.copy_blueprint(snapshot)
	var before := var_to_bytes(source.snapshot())
	var grammar: Dictionary=source.recipe.castleGrammar
	var base := float(source.recipe.foundationHeight)
	var depth := float(grammar.courtyardDepth)
	var front := -depth*0.5
	var keep_front := depth*float(grammar.get("keepOffset",{}).get("z",0.14))-float(grammar.keepDepth)*0.5
	var variation := float(source.seed%19)/100.0-0.09
	var layout: Dictionary=source.recipe.urbanPoc
	var environment: Dictionary=Urban._civic_infill_environment(source,grammar,front,keep_front,base,variation,layout,_continue)
	checks["environment_ready"]=environment.ready
	if not environment.ready: evidence.result=environment; return
	var standalone = Copy.copy_blueprint(snapshot)
	var standalone_receipt: Dictionary=Urban.add_civic_quarter(standalone,front,keep_front,base,variation,layout)
	checks["standalone_ready"]=standalone_receipt.ready
	if not standalone_receipt.ready: return
	var paving_parts: Array=standalone.parts.filter(func(part): return part.id=="urban_civic_quarter_paving")
	checks["one_paving"]=paving_parts.size()==1
	if not checks.one_paving: return
	var box: AABB=standalone.transformed_part_bounds(paving_parts[0])
	var paving := Rect2(Vector2(box.position.x,box.position.z),Vector2(box.size.x,box.size.z))
	var producer := func(target, spec: Dictionary): Urban._add_civic_house(target,spec,base,variation)
	var env_before := var_to_bytes(environment.blueprint.snapshot())
	var result := Infill.prepare_with_terrace_reconciliation(environment.blueprint,Urban.civic_house_specs(keep_front),producer,paving,base,_continue)
	evidence.result=result
	checks["source_unchanged"]=before==var_to_bytes(source.snapshot()) and env_before==var_to_bytes(environment.blueprint.snapshot())
	checks["actual_reconciliation_ready"]=result.ready
	if not result.ready: return
	checks["two_houses"]=result.specs.size()==2
	checks["actual_source_validated"]=result.terraceReconciliation.actualCarvedSourceValidated
	checks["real_carves"]=not result.terraceReplacements.is_empty()
	# Complete check groups get separate bounded runs; neither increases the
	# deadline or claims coverage from the other unexecuted phase.
	if phase=="controls":
		var repeated: Dictionary=Infill.prepare_with_terrace_reconciliation(environment.blueprint,Urban.civic_house_specs(keep_front),producer,paving,base,_continue)
		checks["deterministic_complete_result"]=var_to_bytes(result)==var_to_bytes(repeated)
		_commit_controls(environment.blueprint.snapshot(),result)
		_geometry_controls(environment.blueprint,result)
		var raised: Array=result.terraceOriginals.values().filter(func(record): return record.size.y>1.0)
		checks["raised_dependency_fixture_available"]=not raised.is_empty()
		if not raised.is_empty(): _negative_controls(snapshot,raised[0])
		return
	var composed = Copy.copy_blueprint(snapshot)
	var receipt: Dictionary=Urban.add_civic_quarter(composed,front,keep_front,base,variation,layout,environment.blueprint,_continue)
	evidence["composerReceipt"]=receipt
	checks["actual_composer_ready"]=receipt.get("ready")==true
	if not checks.actual_composer_ready: return
	var expected: Dictionary=_realized(snapshot,result.terraceReplacements)
	var realized: Dictionary=composed.snapshot()
	checks["composer_exact_retained_prefix"]=var_to_bytes(realized.parts.slice(0,expected.parts.size()))==var_to_bytes(expected.parts)
	checks["composer_existing_rooms_unchanged"]=var_to_bytes(realized.rooms.slice(0,snapshot.rooms.size()))==var_to_bytes(snapshot.rooms)
	var expected_house_source = Copy.copy_blueprint(expected)
	var actual_by_id: Dictionary={}
	for record: Dictionary in realized.parts: actual_by_id[record.id]=record
	for spec: Dictionary in result.specs:
		producer.call(expected_house_source,spec)
		var house = Copy.copy_blueprint({"id":"expected-house","seed":source.seed,"style":source.style,"recipe":{},"rooms":[],"parts":[]})
		producer.call(house,spec)
		checks["composer_house_records_"+spec.id]=house.parts.all(func(part): return var_to_bytes(part.snapshot())==var_to_bytes(actual_by_id.get(part.id)))
	checks["composer_exact_house_recipe_and_rooms"]=var_to_bytes(realized.recipe)==var_to_bytes(expected_house_source.recipe) and var_to_bytes(realized.rooms)==var_to_bytes(expected_house_source.rooms)
	checks["environment_still_immutable"]=env_before==var_to_bytes(environment.blueprint.snapshot())
	evidence["realizedSource"]=realized

func _realized(snapshot: Dictionary, replacements: Dictionary) -> Dictionary:
	var expected: Dictionary=snapshot.duplicate(true)
	var records: Array=[]
	for record: Dictionary in snapshot.parts:
		if replacements.has(record.id): records.append_array(replacements[record.id])
		else: records.append(record)
	expected.parts=records
	return expected

func _commit_controls(snapshot: Dictionary, result: Dictionary) -> void:
	var source = Copy.copy_blueprint(snapshot)
	var committed: Dictionary=Terraces.commit(source,result.terraceOriginals,result.terraceReplacements)
	checks["commit_ready"]=committed.get("ready")==true
	checks["commit_full_typed_snapshot"]=var_to_bytes(source.snapshot())==var_to_bytes(_realized(snapshot,result.terraceReplacements))
	var stale = Copy.copy_blueprint(snapshot)
	for part in stale.parts:
		if result.terraceOriginals.has(part.id): part.recipe["fixtureRevision"]=1; break
	var before: PackedByteArray=var_to_bytes(stale.snapshot())
	var rejected: Dictionary=Terraces.commit(stale,result.terraceOriginals,result.terraceReplacements)
	checks["changed_original_commit_rejected_atomically"]=rejected.get("reason")=="stale_terrace_commit_source" and before==var_to_bytes(stale.snapshot())
	evidence["commit"]=committed

func _negative_controls(snapshot: Dictionary, original: Dictionary) -> void:
	var tiny: Dictionary=snapshot.duplicate(true)
	# Explicit synthetic geometry; canonical producer tags/Y retained, integer XZ for isolated cuts.
	original=original.duplicate(true); original.position=Vector3(0,original.position.y,0); original.size=Vector3(4,original.size.y,4)
	tiny.parts=[original]; tiny.rooms=[]
	var source = Copy.copy_blueprint(tiny)
	var bounds: AABB=source.transformed_part_bounds(source.parts[0])
	var cut := Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z))
	checks["synthetic_canonical_eligible"]=Terraces.replaceable(source.parts[0],source.recipe)
	for field: String in ["id","semantic","position","residenceCarved","navigationRole"]:
		var part = Part.new(original)
		match field:
			"id": part.id+="_forged"
			"semantic": part.semantic="unrelated"
			"position": part.position.y+=0.25
			_: part.recipe[field]=false
		checks["mutable_classification_reject_"+field]=not Terraces.replaceable(part,source.recipe)
	for location: String in ["part","room","root"]:
		var fixture = Copy.copy_blueprint(tiny)
		var nested: Dictionary={"outer":[{"reference":original.id}]}
		if location=="part": fixture.add_part({"id":"foreign","position":Vector3(1000,1000,1000),"recipe":nested})
		elif location=="room": fixture.rooms=[nested]
		else: fixture.recipe["nestedFixture"]=nested
		_reject("nested_"+location,fixture,[cut],"referenced_terrace_requires_dependency_reconciliation")
	for embedded: bool in [false,true]:
		var contact = Copy.copy_blueprint(tiny)
		contact.add_part({"id":"ground_root","kind":"foundation","position":Vector3(0,bounds.position.y*0.5,0),"size":Vector3(4,bounds.position.y,4),"recipe":{"physicalRoot":true}})
		contact.add_part({"id":"surviving_contact","kind":"wall","collision":not embedded,"position":Vector3(0,bounds.get_center().y if embedded else bounds.end.y+0.25,0),"size":Vector3(0.5,0.5,0.5),"physicalIntent":"facade_attachment" if embedded else "structural_mass"})
		_reject("contact_preserved_"+str(embedded),contact,[cut],"terrace_dependent_anchor_lost" if embedded else "terrace_dependent_rooted_support_lost")
	var gap_source = Copy.copy_blueprint(tiny)
	gap_source.add_part({"id":"ground_root","kind":"foundation","position":Vector3(0,bounds.position.y*0.5,0),"size":Vector3(4,bounds.position.y,4),"recipe":{"physicalRoot":true}})
	var gap_part = gap_source.add_part({"id":"gap_dependent","kind":"wall","position":Vector3(0,bounds.end.y+0.10+0.25,0),"size":Vector3(0.5,0.5,0.5),"physicalIntent":"structural_mass"})
	var gap_bounds: AABB=gap_source.transformed_part_bounds(gap_part)
	var support_proof = Copy.copy_blueprint(gap_source.snapshot())
	var resolved: bool=support_proof.resolve_physical_contracts_cancellable(_continue)
	var supported = support_proof.find_part("gap_dependent")
	checks["gap_010_real_sole_rooted_support"]=resolved and supported.recipe.get("physicalSupportPartIds",[])==[original.id] and support_proof.has_rooted_support_chain(supported,{})
	checks["gap_exceeds_contact_not_support_reach"]=gap_bounds.position.y-bounds.end.y>source.PHYSICAL_CONTACT_MARGIN and gap_bounds.position.y-bounds.end.y<source.STRUCTURAL_SUPPORT_MAX_GAP and gap_bounds.position.y-bounds.position.y>source.STRUCTURAL_SUPPORT_MAX_GAP
	evidence["gap010"]={"requestedGap":0.10,"actualGap":float(gap_bounds.position.y)-float(bounds.end.y),"groundGap":float(gap_bounds.position.y)-float(bounds.position.y),"terraceHeight":float(bounds.size.y)}
	_reject("gap_010_sole_support_carve_rejected",gap_source,[cut],"terrace_dependent_rooted_support_lost")
	var peer: Dictionary=original.duplicate(true)
	peer.id="castle_terrace_block_%02d_right_9999" % int(String(original.id).split("_")[3]); peer.position.x=4.0
	var touching = Copy.copy_blueprint(tiny); touching.add_part(peer)
	var touching_before: PackedByteArray=var_to_bytes(touching.snapshot())
	var audited: Dictionary=Terraces.prepare(touching,[cut],_continue)
	checks["uncut_eligible_terrace_reproved"]=Terraces.replaceable(touching.parts[1],touching.recipe) and audited.get("ready")==true and audited.dependencies.reprovedIds.has(peer.id) and touching_before==var_to_bytes(touching.snapshot())
	var inherited = Copy.copy_blueprint(tiny); peer.position.x=10.0; inherited.add_part(peer)
	inherited.parts[0].recipe["nested"]={"support":[peer.id]}
	_reject("two_removed_inherited_reference",inherited,[Rect2(-2,-2,2,4),Rect2(8,-2,4,4)],"referenced_terrace_requires_dependency_reconciliation")
	for cuts: Array in [[],[Rect2()],[Rect2(0,0,-1,1)],[Rect2(NAN,0,1,1)],["invalid"]]:
		_reject("invalid_cut_"+str(checks.size()),source,cuts,"invalid_terrace_carving_input" if cuts.is_empty() else "invalid_residence_footprint")
	for occurrence: int in [1,2,3]:
		calls=0; cancel_at=occurrence
		_reject("cancel_"+str(occurrence),source,[cut],"cancelled",_cancel)
		checks["no_callback_after_false_"+str(occurrence)]=calls==occurrence

func _reject(label: String, source, cuts: Array, reason: String, callback: Callable=Callable()) -> void:
	var before: PackedByteArray=var_to_bytes(source.snapshot())
	var result: Dictionary=Terraces.prepare(source,cuts,callback)
	checks[label]=result.get("ready")==false and result.get("reason")==reason and not result.has("blueprint") and not result.has("replacements") and before==var_to_bytes(source.snapshot())
	if not checks[label]: evidence[label]=result

func _cancel(_label: String) -> bool:
	calls+=1
	return calls<cancel_at

func _geometry_controls(source, result: Dictionary) -> void:
	var cuts: Array[Dictionary]=[]
	for rect: Rect2 in result.terraceReconciliation.footprints: cuts.append({"rect":rect})
	for id: String in result.terraceOriginals:
		var old: AABB=source.transformed_part_bounds(Part.new(result.terraceOriginals[id]))
		var solids: Array=[]
		var inside := true
		for record: Dictionary in result.terraceReplacements[id]:
			var box: AABB=source.transformed_part_bounds(Part.new(record))
			solids.append(Terraces._box(box))
			inside=inside and old.encloses(box) and not cuts.any(func(cut): return Rect2(Vector2(box.position.x,box.position.z),Vector2(box.size.x,box.size.z)).intersects(cut.rect))
		for cut: Dictionary in cuts: solids.append([float(cut.rect.position.x),float(old.position.y),float(cut.rect.position.y),float(cut.rect.end.x),float(old.end.y),float(cut.rect.end.y)])
		checks["exact_occupancy_"+id]=inside and Occupancy.cover(Terraces._box(old),solids).get("covered",false)
	# Exact float32 endpoints from failed 03; not rounded report-string arithmetic.
	var low: float=Vector3(-13.3109722137451,0,0).x
	var high: float=Vector3(-10.1272020339966,0,0).x
	var axis: Dictionary=Terraces._axis_segments(low,high)
	checks["03_requires_two_solids"]=not Terraces._represented_axis(low,high).ready and axis.get("segments",[]).size()==2
	evidence["oddParityAxis"]=axis
	if axis.ready:
		var intervals: Array=[]
		for segment: Dictionary in axis.segments:
			var center := Vector3(segment.center,0,0); var half := Vector3(segment.size,0,0)*0.5
			intervals.append([float((center-half).x),0.0,0.0,float((center+half).x),1.0,1.0])
		checks["03_exact_union"]=Occupancy.cover([low,0.0,0.0,high,1.0,1.0],intervals).get("covered",false) and intervals.all(func(box): return box[0]>=low and box[3]<=high)
	# The actual 04 strip is checked by the exact occupancy control above; retain its two planes numerically.
	evidence["04_strip_planes"]=[1.9727983474731445,1.9727985858917236]
	var strip: Dictionary=result.terraceOriginals.get("castle_terrace_block_02_right_02",{})
	checks["04_original_strip_case_present"]=not strip.is_empty()
	if not strip.is_empty():
		var old: AABB=source.transformed_part_bounds(Part.new(strip))
		var rect := Rect2(Vector2(old.position.x,old.position.z),Vector2(old.size.x,old.size.z))
		checks["04_strict_planes_differ_from_default"]=var_to_bytes(Castle.subtract_courtyard_egress_corridors(rect,cuts,true))!=var_to_bytes(Castle.subtract_courtyard_egress_corridors(rect,cuts))
	for rect: Rect2 in [Rect2(0,0,10,10),Rect2(-5,-13.3109722137451,43.33,20),Rect2(1,2,0.03,4)]:
		var holes: Array[Dictionary]=[{"rect":Rect2(2,2,3,4)},{"rect":Rect2(-20,-20,21,24)},{"rect":Rect2()}]
		checks["legacy_byte_parity_"+str(checks.size())]=var_to_bytes(Castle.subtract_courtyard_egress_corridors(rect,holes))==var_to_bytes(_legacy_subtract(rect,holes))

func _legacy_subtract(initial: Rect2, holes: Array[Dictionary]) -> Array[Rect2]:
	# Independent pre-change Castle algorithm oracle: intersection endpoints and .04 pruning.
	var result: Array[Rect2]=[initial]
	for hole: Dictionary in holes:
		if hole.rect.size.x<=0 or hole.rect.size.y<=0: continue
		var next: Array[Rect2]=[]
		for rect: Rect2 in result:
			var overlap := rect.intersection(hole.rect)
			if overlap.size.x<=0.0001 or overlap.size.y<=0.0001: next.append(rect); continue
			for piece: Rect2 in [Rect2(rect.position.x,rect.position.y,overlap.position.x-rect.position.x,rect.size.y),Rect2(overlap.end.x,rect.position.y,rect.end.x-overlap.end.x,rect.size.y),Rect2(overlap.position.x,rect.position.y,overlap.size.x,overlap.position.y-rect.position.y),Rect2(overlap.position.x,overlap.end.y,overlap.size.x,rect.end.y-overlap.end.y)]:
				if piece.size.x>0.04 and piece.size.y>0.04: next.append(piece)
		result=next
	return result

func _hashes() -> Dictionary:
	var hashes: Dictionary={SOURCE:FileAccess.get_sha256(SOURCE)}
	var pending: Array[String]=[get_script().resource_path]
	var pattern := RegEx.create_from_string('res://[^"\'\\s]+\\.gd')
	while not pending.is_empty():
		var path: String=pending.pop_back()
		if hashes.has(path): continue
		hashes[path]=FileAccess.get_sha256(path)
		for matched: RegExMatch in pattern.search_all(FileAccess.get_file_as_string(path)): pending.append(matched.get_string())
	return hashes

func _json(value: Variant) -> Variant:
	if value is Dictionary:
		var mapped: Dictionary={}
		for key: Variant in value: mapped[str(key)]=_json(value[key])
		return mapped
	if value is Array: return value.map(_json)
	if value is Vector3: return {"type":"Vector3","value":[value.x,value.y,value.z]}
	if value is Vector2: return {"type":"Vector2","value":[value.x,value.y]}
	if value is Rect2 or value is AABB: return {"type":type_string(typeof(value)),"position":_json(value.position),"size":_json(value.size)}
	return value

func _continue(_label: String) -> bool:
	stopped=stopped or Time.get_ticks_msec()>=deadline
	return not stopped
