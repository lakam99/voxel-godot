extends SceneTree
## Source attribution on a historical caller before structural completion, with
## one actual full physical proof per variant. Never invents proofChecks or
## claims this caller is the later post-completion source.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Planes = preload("res://scripts/buildings/ThresholdBearingConstructionPlanes.gd")
const Connection = preload("res://scripts/buildings/OpeningHeadConnectionRecipe.gd")
const Seats = preload("res://scripts/buildings/ThresholdBearingSeatRecipe.gd")
const Housing = preload("res://scripts/buildings/ThresholdBearingHousingRecipe.gd")
const Thresholds = preload("res://scripts/buildings/CitadelThresholdBearingRecipe.gd")
const Composer = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate-recipe-02/caller-blueprint.bin"
const SHA := "114a393279c1ae7676fca8f3ca9a9d7688c86c8cb0d587dbe203ab2a8d0a66b3"
const TARGET := "urban_row_03_left_door_threshold"
var output := ""
var proof_deadline := 0
var proof_last_stage := ""
func _continue_proof(stage: String) -> bool:
	proof_last_stage=stage
	return Time.get_ticks_msec()<proof_deadline

func _typed(name: String,value: Dictionary) -> bool:
	var file := FileAccess.open(output.get_base_dir().path_join(name),FileAccess.WRITE)
	if file==null: return false
	file.store_var(value,false); file.flush()
	var ok := file.get_error()==OK
	file.close()
	return ok

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	output=OS.get_environment("CITADEL_CANDIDATE_THRESHOLD_OUTPUT")
	if output.is_empty() or not output.is_absolute_path(): quit(2); return
	var worker := Thread.new()
	if worker.start(_diagnose)!=OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary=worker.wait_to_finish()
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.flush()
	var written := file.get_error()==OK
	file.close()
	if not written: quit(2); return
	print("THRESHOLD DIAGNOSTIC completed=",report.get("diagnosticCompleted",false)," directGroundSeat=",report.get("directGroundResult",{}))
	quit(0 if report.get("diagnosticCompleted",false) else 1)

func _diagnose() -> Dictionary:
	var started := Time.get_ticks_usec()
	var hashes: Dictionary={}
	for script in [get_script(),Copy,Planes,Connection,Seats,Housing,Thresholds,Composer,Blueprint]: hashes[script.resource_path]=FileAccess.get_sha256(script.resource_path)
	hashes["res://scripts/buildings/StreetRowDepthPacking.gd"]=FileAccess.get_sha256("res://scripts/buildings/StreetRowDepthPacking.gd")
	if FileAccess.get_sha256(INPUT)!=SHA: return {"reason":"input_hash_mismatch"}
	var file := FileAccess.open(INPUT,FileAccess.READ)
	if file==null: return {"reason":"input_open_failed"}
	var raw: Variant=file.get_var(false)
	file.close()
	if not raw is Dictionary: return {"reason":"input_not_dictionary"}
	var original_raw: Dictionary=raw
	var replacement: Dictionary={"packed":false}
	if OS.get_environment("CITADEL_THRESHOLD_PACKED")=="1":
		replacement=_packed_source(raw)
		if not replacement.get("ready",false): return {"reason":"packed_replacement_failed","detail":replacement}
		raw=replacement.source
		replacement.erase("source")
	var b = Copy.copy_blueprint(raw)
	var original := var_to_bytes(b.snapshot())
	var proof_input: Dictionary=b.snapshot()
	if not _typed("proof-source.bin",proof_input): return {"reason":"proof_source_write_failed"}
	var proof = Copy.copy_blueprint(proof_input)
	Copy.clear_caches(proof)
	var work: Dictionary=Copy.validation_grid_work(proof)
	if not work.ready: return {"reason":"physical_work_rejected","work":work}
	proof_deadline=Time.get_ticks_msec()+15000
	var proof_started := Time.get_ticks_usec()
	var physical: Dictionary=proof.validate_physical_integrity_cancellable(_continue_proof)
	var proof_elapsed := Time.get_ticks_usec()-proof_started
	if not _typed("physical.bin",physical): return {"reason":"physical_report_write_failed"}
	if physical.get("cancelled",false) or physical.get("checkedPartCount",0)!=b.parts.size():
		return {"reason":"ordinary_proof_incomplete","lastStage":proof_last_stage,"elapsedUsec":proof_elapsed}
	var checks: Dictionary={}
	for row: Dictionary in physical.checks:
		if checks.has(row.partId): return {"reason":"duplicate_actual_check"}
		checks[row.partId]=row
	var bound: Dictionary=Thresholds._proof_seats(proof_input,proof_input,checks)
	if not bound.ready: return {"reason":"real_proof_seats_rejected","detail":bound}
	var threshold = b.find_part(TARGET)
	var foundation = b.find_part("urban_row_03_left_foundation")
	if threshold==null or foundation==null: return {"reason":"target_missing"}
	var normalization: Dictionary=Planes.normalize(threshold,foundation)
	if not normalization.ready: return {"reason":"normalization_failed","normalization":normalization}
	var old_size: Vector3=threshold.size
	threshold.size=normalization.record.size
	# Identical domain and stored Y dispatch to Thresholds._candidate, without
	# invoking collision admission or furnishing reconstruction. The ordinary
	# physical proof above supplies the separately bound seat authorization.
	var bottom: float=foundation.position.y-foundation.size.y*0.5
	var top: float=foundation.position.y+foundation.size.y*0.5
	var domain: Array=[float(threshold.position.x)-float(threshold.size.x)*0.5,bottom,
		float(threshold.position.z)-float(threshold.size.z)*0.5,
		float(threshold.position.x)+float(threshold.size.x)*0.5,top,
		float(threshold.position.z)+float(threshold.size.z)*0.5]
	var fitted: Dictionary=Connection._inside_box(domain)
	if fitted.is_empty(): return {"reason":"candidate_unrepresentable"}
	var center: Vector3=fitted.position
	var size: Vector3=fitted.size
	center.y=foundation.position.y; size.y=foundation.size.y
	var before := var_to_bytes(b.snapshot())
	var result: Dictionary=Seats.prepare(b,threshold,center,size,2,{})
	var proven_result: Dictionary=Seats.prepare(b,threshold,center,size,2,bound.records)
	var inventory: Array=[]
	var upper: float=float(threshold.position.y)-float(threshold.size.y)*0.5
	for part in b.parts:
		if part==threshold or part.kind!="foundation" or not part.collision_enabled or part.rotation!=Vector3.ZERO: continue
		var intent: String=part.physical_intent
		if intent.is_empty(): intent=b.inferred_physical_intent(part)
		if intent not in ["structural_mass","structural_root"] or not Seats._finite_part(part) or not Seats._full_box_source(part): continue
		var bounds := Planes._bounds(part.position,part.size)
		if float(bounds[4])>=upper: continue
		var patch: Dictionary=Seats._inset_patch(center,size,part)
		if patch.is_empty(): continue
		var grounded: bool=float(bounds[1])==0.0 and b.is_grounded_structural_root(part)
		var slack: Array=[]
		for axis in [0,2]:
			slack.append(float(part.size[axis])*0.5-Housing.INSET-absf(float(center[axis])-float(part.position[axis]))-float(size[axis])*0.5)
		inventory.append({"id":part.id,"snapshot":part.snapshot(),"bounds":bounds,"directGroundEligible":grounded,
			"ordinaryProofAuthorized":bound.records.has(part.id),"actualCheck":checks.get(part.id,{}),"patch":patch,"housingInsetSlackXZ":slack,
			"geometryOnlyHousing":Housing.prepare(part,upper,center,size)})
	inventory.sort_custom(func(a: Dictionary,c: Dictionary) -> bool:
		return float(a.bounds[4])>float(c.bounds[4]) if a.bounds[4]!=c.bounds[4] else String(a.id)<String(c.id))
	var selected_direct := ""
	var selected_proven := ""
	for row: Dictionary in inventory:
		if selected_direct.is_empty() and row.directGroundEligible: selected_direct=row.id
		if selected_proven.is_empty() and (row.directGroundEligible or row.ordinaryProofAuthorized): selected_proven=row.id
	var immutable := before==var_to_bytes(b.snapshot())
	var threshold_snapshot: Dictionary=threshold.snapshot()
	threshold.size=old_size
	immutable=immutable and original==var_to_bytes(b.snapshot())
	var report := {"diagnosticCompleted":true,"passed":false,"inputPath":INPUT,"inputSha256":SHA,"sourceHashes":hashes,
		"evidenceLevel":"Historical unpacked pre-structural caller geometry; NOT run04 post-completion state. One full ordinary cancellable physical proof, real matched _proof_seats; no invented checks. Geometry-only housing observations are not collision admission.",
		"directGroundResult":result,"selectedDirectGroundId":selected_direct,"candidateCenter":center,"candidateSize":size,"candidateDomain":domain,
		"provenSeatResult":proven_result,"selectedProvenSeatId":selected_proven,"physicalProofElapsedUsec":proof_elapsed,"proofLastStage":proof_last_stage,
		"normalizedThreshold":threshold_snapshot,"foundation":foundation.snapshot(),"normalization":normalization,
		"candidateSeats":inventory,"inputUnchanged":immutable,"globalPhysicalValidations":1,"proofChecksSupplied":true,"syntheticChecksSupplied":false,
		"physicalViolationCount":physical.violations.size(),"checkedPartCount":physical.checkedPartCount,
		"exactRun04FailureReproduced":proven_result.get("reason","")=="threshold_housing_footprint_outside_seat",
		"elapsedUsec":Time.get_ticks_usec()-started}
	report["replacement"]=replacement
	report["originalThresholdBytesExact"]=var_to_bytes(Thresholds._snapshot_part(original_raw,TARGET))==var_to_bytes(Thresholds._snapshot_part(proof_input,TARGET))
	report["originalSelectedSeatBytesExact"]=var_to_bytes(Thresholds._snapshot_part(original_raw,selected_proven))==var_to_bytes(Thresholds._snapshot_part(proof_input,selected_proven))
	if replacement.get("packed",false):
		report.evidenceLevel="Packed producer-delta variant of locked unpacked pre-completion source. Exact original-value guards preserve all unrelated fields/parts; one real full proof. NOT post-completion or full recipe parity."
	if not _typed("geometry.bin",report): return {"reason":"typed_output_write_failed"}
	for path: String in hashes:
		if FileAccess.get_sha256(path)!=hashes[path]: return {"reason":"source_changed_during_diagnostic","path":path}
	return report

func _packed_source(raw: Dictionary) -> Dictionary:
	var layout: Dictionary=raw.recipe.urbanPoc
	var geometry: Dictionary=Composer.street_row_geometry(layout.frontZ,layout.keepFrontZ,layout)
	if not geometry.get("ready",false): return geometry
	var source: Dictionary=raw.duplicate(true)
	var changed: Array=[]
	var counts: Dictionary={}
	# Same actual producer inputs as CitadelStreetRowPackingContract._houses.
	var palette := ["painted_brick_cream","painted_brick_sage","painted_brick_rose","painted_brick_ochre","painted_brick_azure","painted_brick_plum"]
	for row in range(4):
		for side in [-1,1]:
			var width := 7.4+float((row+side+5)%3)*0.9+float(layout.rowWidthBiases[row])
			var height := 3.1*float(2+((row+(1 if side>0 else 0))%2)+int(layout.rowStoreyBonuses[row]))
			var center := Vector3(float(layout.laneCenters[row])+side*((5.8 if row!=2 else 16.0)*0.5+width*0.5),0,geometry.centers[row])
			var ground := float(raw.recipe.foundationHeight)+(0.0 if row<2 else float(layout.marketTerraceRise)*float(row-1))
			var id := "urban_row_%02d_%s"%[row,"right" if side>0 else "left"]
			var variants: Array=[]
			for packed in [false,true]:
				var depth := float(geometry.rowDepths[row]) if packed else float(geometry.segmentDepth)*(0.82 if row==1 else 0.90)
				var generated = Blueprint.new("row_geometry",raw.seed,raw.style)
				Composer.add_street_house(generated,id,center,width,depth,height,float(-side),ground,palette[(row*2+(1 if side>0 else 0))%6],float(raw.seed%19)/100.0-0.09+float(row)*0.012)
				variants.append(generated.snapshot())
			counts[id]=variants[0].parts.size()
			for collection: String in ["parts","rooms"]:
				if variants[0][collection].size()!=variants[1][collection].size(): return {"reason":"producer_count_changed","house":id}
				for index in range(variants[0][collection].size()):
					var old: Dictionary=variants[0][collection][index]
					var next: Dictionary=variants[1][collection][index]
					var found := -1
					for source_index in range(source[collection].size()):
						if source[collection][source_index].id==old.id: found=source_index; break
					if found<0: return {"reason":"producer_identity_missing","id":old.id}
					var update := _delta(source[collection][found],old,next,collection+"/"+old.id,changed)
					if not update.ready: return update
					source[collection][found]=update.value
	return {"ready":true,"packed":true,"source":source,"houseCounts":counts,"changedPaths":changed,"unchangedFieldsPreserved":true,
		"qualification":"Original-to-packed producer deltas only, checked against captured original values. Retains pre-completion recipe declarations and every unrelated record; not a composer replay."}

func _delta(actual: Variant,old: Variant,next: Variant,path: String,changed: Array) -> Dictionary:
	if var_to_bytes(old)==var_to_bytes(next): return {"ready":true,"value":actual}
	if old is Dictionary and next is Dictionary and actual is Dictionary:
		var value: Dictionary=actual.duplicate(true)
		for key in old:
			if not next.has(key) or not actual.has(key): return {"ready":false,"reason":"unsupported_field_removal","path":path+"/"+str(key)}
			var child := _delta(actual[key],old[key],next[key],path+"/"+str(key),changed)
			if not child.ready: return child
			value[key]=child.value
		for key in next:
			if not old.has(key): return {"ready":false,"reason":"unsupported_field_addition","path":path+"/"+str(key)}
		return {"ready":true,"value":value}
	if var_to_bytes(actual)!=var_to_bytes(old): return {"ready":false,"reason":"captured_original_field_mismatch","path":path,"actual":actual,"original":old}
	changed.append(path)
	return {"ready":true,"value":next}
