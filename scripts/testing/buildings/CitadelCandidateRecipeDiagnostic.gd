extends SceneTree
## Reproduce a rejected real candidate on one owned worker. Never an acceptance pass.
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Survey = preload("res://scripts/world/CitadelSiteSurvey.gd")
const Site = preload("res://scripts/world/CitadelSitePreparation.gd")
const Recipe = preload("res://scripts/buildings/CitadelRecipePreparation.gd")
const Builder = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Context = preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const World = preload("res://scripts/WorldGenerationSystem.gd")
const Tutorial = preload("res://scripts/TutorialSystem.gd")
const SEED := "atlas-30895044"
const REGION := Vector2i(0,-1)
const EXPECTED_RECIPE := 1747969299

class Progress extends RefCounted:
	const MAX_AGGREGATES := 256
	var mutex := Mutex.new()
	var stage := "starting"
	var callbacks := 0
	var stopped := false
	var deadline := 0
	var started := 0
	var max_gap_usec := 0
	var last_usec := 0
	var phase := "source_preparation"
	var phase_started_usec := 0
	var phase_elapsed: Dictionary = {}
	var aggregates: Dictionary = {}
	var last_key := ""
	var overflow_callbacks := 0
	var timed_out_phase := ""
	var deadline_active := true
	func _charge_gap(now: int) -> void:
		if last_usec<=0 or last_key.is_empty(): return
		var gap := now-last_usec
		max_gap_usec=maxi(max_gap_usec,gap)
		var row: Dictionary=aggregates[last_key]
		row.intervalUsec+=gap
		row.maxIntervalUsec=maxi(int(row.maxIntervalUsec),gap)
	func _check_deadline() -> void:
		if deadline_active and Time.get_ticks_msec()>=deadline:
			stopped=true
			if timed_out_phase.is_empty(): timed_out_phase=phase
	func begin_phase(name: String, budget_msec: int = 0) -> bool:
		mutex.lock()
		var now := Time.get_ticks_usec()
		_charge_gap(now)
		if phase_started_usec>0:
			phase_elapsed[phase]=int(phase_elapsed.get(phase,0))+now-phase_started_usec
			_check_deadline() # A late return cannot acquire a fresh deadline.
		phase=name; phase_started_usec=now; last_usec=0; last_key=""
		if budget_msec>0 and not stopped: deadline=Time.get_ticks_msec()+budget_msec
		deadline_active=budget_msec>=0
		var allowed := not stopped
		mutex.unlock()
		return allowed
	func finish() -> void:
		mutex.lock()
		var now := Time.get_ticks_usec()
		_charge_gap(now)
		if phase_started_usec>0: phase_elapsed[phase]=int(phase_elapsed.get(phase,0))+now-phase_started_usec
		phase_started_usec=0; last_usec=0; last_key=""
		mutex.unlock()
	func checkpoint(label: String) -> bool:
		mutex.lock()
		var now := Time.get_ticks_usec()
		_charge_gap(now)
		var key := phase+"/"+label.get_slice(":",0)
		if not aggregates.has(key) and aggregates.size()>=MAX_AGGREGATES:
			key="overflow"; overflow_callbacks+=1
		if not aggregates.has(key): aggregates[key]={"count":0,"intervalUsec":0,"maxIntervalUsec":0,"firstUsec":now,"lastUsec":now,"rejectedCount":0}
		var row: Dictionary=aggregates[key]
		row.count+=1; row.lastUsec=now
		last_key=key
		last_usec=now; stage=label; callbacks+=1
		_check_deadline()
		var allowed := not stopped
		if not allowed: row.rejectedCount+=1
		mutex.unlock()
		return allowed
	func snapshot(include_aggregates: bool = false) -> Dictionary:
		mutex.lock()
		var value := {"phase":phase,"stage":stage,"callbacks":callbacks,"cancelled":stopped,"maxCallbackGapUsec":max_gap_usec,"elapsedMsec":Time.get_ticks_msec()-started,"timedOutPhase":timed_out_phase}
		if include_aggregates:
			value["phaseElapsedUsec"]=phase_elapsed.duplicate()
			value["stageAggregates"]=aggregates.duplicate(true)
			value["overflowCallbacks"]=overflow_callbacks
			value["timingSemantics"]="Wall intervals attributed to preceding callback family, suffix after ':' coalesced; not exclusive CPU cost or nested call-stack attribution. Source and independent validator are separate namespaces. At most 256 keys plus overflow."
		mutex.unlock()
		return value

var output := ""
var state := Progress.new()
var expect_ready := false

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	output=OS.get_environment("CITADEL_CANDIDATE_RECIPE_OUTPUT")
	if output.is_empty() or not output.is_absolute_path(): push_error("Missing diagnostic output"); quit(2); return
	expect_ready=OS.get_environment("CITADEL_CANDIDATE_EXPECT_READY")=="1"
	if expect_ready and OS.get_environment("CITADEL_CANDIDATE_CAPTURE_BLUEPRINT")=="1": push_error("ExpectReady requires public Recipe entry"); quit(2); return
	state.started=Time.get_ticks_msec(); state.deadline=state.started+(450000 if expect_ready else 150000)
	state.begin_phase("source_preparation")
	var worker := Thread.new()
	if worker.start(_work)!=OK: push_error("Diagnostic worker start failed"); quit(2); return
	var next_report := 0
	while worker.is_alive():
		if Time.get_ticks_msec()>=next_report:
			_write_json("progress.json",state.snapshot())
			next_report=Time.get_ticks_msec()+500
		await process_frame
	var receipt: Dictionary=worker.wait_to_finish()
	state.finish()
	var timing := state.snapshot(true)
	_write_json("timings.json",timing)
	var expected: bool=receipt.get("reason")=="citadel_structural_completion_failed" and receipt.get("structuralReason")=="facade_completion_failed" and receipt.get("artifactsWritten",false)
	var recipe_passed: bool=receipt.get("recipePassed",false)
	var verified: bool=(recipe_passed and receipt.get("physicalPassed",false) and receipt.get("artifactsWritten",false) and receipt.get("contextUnchanged",false) and not timing.cancelled) if expect_ready else expected
	var report := {"schema":"citadel-candidate-recipe-diagnostic/v1","passed":false,"diagnosticCompleted":true,"expectedFailureReproduced":expected,
		"worldSeed":SEED,"region":REGION,"recipeSeed":EXPECTED_RECIPE,"receipt":receipt,"progress":state.snapshot(),
		"evidenceLevel":"source-only failing real candidate replay; no site acceptance, terrain publication, rendering or gameplay",
		"expectedEngineError":"ERROR: Citadel structural completion failed: facade_completion_failed",
		"artifactFormat":"input.bin and failure.bin are FileAccess.store_var(..., false); full failure.json is human-readable, binary preserves types"}
	report["phaseElapsedUsec"]=timing.phaseElapsedUsec
	if expect_ready:
		report.merge({"passed":verified,"recipePassed":recipe_passed,"expectReady":true,
			"evidenceLevel":"public Recipe source-only replay plus full physical-integrity validation; no site, live physics, furniture-validation, rendering or gameplay acceptance",
			"expectedEngineError":"","artifactFormat":"source.bin: full result dictionary with blueprint/furnishingPlan replaced by their snapshots; accessReservations additionally preserves plan-owned protected access. FileAccess.store_var(..., false)."},true)
	_write_json("report.json",report)
	print("CANDIDATE RECIPE DIAGNOSTIC expectedFailureReproduced=",expected," recipePassed=",recipe_passed," reasonChain=",receipt.get("reasonChain",[]))
	quit(0 if verified else 1) # Failure reproduction exit zero is NOT a recipe pass.

func _work() -> Dictionary:
	var candidate := Field.candidate_for_region(SEED,REGION)
	if candidate.is_empty() or candidate.recipeSeed!=EXPECTED_RECIPE: return {"reason":"candidate_identity_mismatch"}
	state.checkpoint("center_biome_survey")
	# Reconstruct the ordinary deterministic tutorial override from its owning
	# constants and WGS, not an artifact seed/biome guess or a Main scene boot.
	var context := Context.new()
	context.seed_text=SEED; context.seed_hash=context.hash_string(SEED); context.setup_noise()
	var world := World.new()
	world.setup(context); context.set_generator(world)
	var tutorial_region: Vector2i=Tutorial.TUTORIAL_TOWN_REGION
	var town: Dictionary=context.town_region(tutorial_region.x,tutorial_region.y).duplicate(true)
	town.radius=Tutorial.FENCE_RADIUS_CELLS
	var towns := {tutorial_region:town}
	var survey := Survey.new()
	var center: Vector2i=candidate.centerCell
	var surveyed := survey.begin(SEED,REGION,Rect2i(center,Vector2i.ONE),towns)
	while surveyed.status=="pending_budget":
		if not state.checkpoint("center_biome_survey"): return {"reason":"cancelled"}
		surveyed=survey.advance()
	if surveyed.status!="surveyed" or surveyed.biomeCounts.size()!=1: return {"reason":"center_survey_not_eligible","survey":surveyed}
	var recipe_context := {"biome":String(surveyed.biomeCounts.keys()[0]),"siteKey":candidate.siteId,"citadelScale":Site.SCALE}
	var input := {"worldSeed":SEED,"candidate":candidate,"context":recipe_context,"centerSurvey":surveyed,"townOverrides":towns,
		"scope":"exact recipe input from ordinary center survey; no full-envelope survey or runtime source injection"}
	if not _write_typed("input.bin",input): return {"reason":"input_write_failed"}
	_write_json("input.json",input)
	var before := var_to_bytes(recipe_context)
	var recipe_started_usec := Time.get_ticks_usec()
	var result: Dictionary
	var captured := true
	var capture_blueprint := OS.get_environment("CITADEL_CANDIDATE_CAPTURE_BLUEPRINT")=="1"
	if capture_blueprint:
		# Diagnostic old-equivalent sequence, NOT the public Recipe boundary or
		# a successful source. Keep the caller object after failed composition.
		state.checkpoint("compound_started")
		var build_result: Dictionary=Builder.build_with_diagnostics(candidate.recipeSeed,recipe_context.duplicate(true),state.checkpoint)
		var built = build_result.get("blueprint")
		if built==null: return {"reason":"blueprint_build_failed","buildDiagnostics":build_result.get("diagnostics",{})}
		state.checkpoint("compound_completed")
		result=Urban.compose_prepared(built,candidate.recipeSeed,state.checkpoint)
		state.checkpoint("diagnostic_failed_caller_snapshot")
		var snapshot: Dictionary=built.snapshot()
		captured=_write_typed("caller-blueprint.bin",snapshot)
		var selected: Array=[]
		for part in built.parts:
			if part.id.begins_with("urban_row_03_left_") or part.id.begins_with("urban_row_02_left_"):
				var bounds: AABB=built.transformed_part_bounds(part)
				selected.append({"snapshot":part.snapshot(),"boundsMin":bounds.position,"boundsMax":bounds.end,"boundsSize":bounds.size,"transform":built.part_transform(part)})
		var geometry := {"evidenceLevel":"diagnostic old-equivalent Builder -> Urban.compose_prepared sequence; failed caller blueprint, not public Recipe output or success",
			"partCount":built.parts.size(),"selectedParts":selected,"policyCaptured":false,"furnishingsRerun":false,
			"note":"Composer owns its one furnishing/policy pass; no reconstruction of policy. Structural completion uses private staging; this is caller state after its failure."}
		captured=_write_typed("geometry.bin",geometry) and captured
		captured=_write_json("geometry.json",geometry) and captured
		result.erase("blueprint"); result.erase("furnishingPlan"); result.erase("interiorProgram")
	else:
		result=Recipe.prepare(candidate.recipeSeed,recipe_context,state.checkpoint)
	var recipe_elapsed_usec := Time.get_ticks_usec()-recipe_started_usec
	var source_within_deadline := true
	if expect_ready: source_within_deadline=state.begin_phase("source_export",-1)
	if expect_ready and result.get("ready",false)==true:
		var source: Dictionary=result.duplicate(false)
		var blueprint = result.get("blueprint")
		var furniture = result.get("furnishingPlan")
		if blueprint==null or furniture==null:
			return {"recipePassed":true,"reason":"ready_source_missing_objects","artifactsWritten":false}
		source["blueprint"]=blueprint.snapshot()
		source["furnishingPlan"]=furniture.snapshot()
		source["accessReservations"]=furniture.access_reservations_snapshot()
		var saved := _write_typed("source.bin",source)
		# Save exact public output BEFORE validator-derived facts. The worker
		# exclusively owns this object and discards it after proof, including on
		# cancellation. No planner rerun or modified object is published.
		# Export time does not spend the independent proof's 60-second budget.
		# Preserve the source deadline decision made at Recipe return.
		var proof_allowed := state.begin_phase("independent_physical_validation",60000)
		var physical_started_usec := Time.get_ticks_usec()
		var physical: Dictionary={"passed":false,"cancelled":true,"checkedPartCount":0,"checks":[],"violations":["source_preparation_deadline_exceeded"]}
		if proof_allowed and source_within_deadline:
			physical=blueprint.validate_physical_integrity_cancellable(state.checkpoint)
		var physical_elapsed_usec := Time.get_ticks_usec()-physical_started_usec
		var proof_within_deadline := state.begin_phase("report_export",-1)
		saved=_write_typed("physical.bin",physical) and saved
		saved=_write_json("physical.json",physical) and saved
		var physical_passed: bool=proof_within_deadline and physical.get("passed",false)==true and not physical.get("cancelled",false) and physical.get("violations",[]).is_empty() and physical.get("checkedPartCount",0)==blueprint.parts.size()
		return {"recipePassed":result.ready==true,"reason":result.get("reason",""),"artifactsWritten":saved,
			"recipeElapsedUsec":recipe_elapsed_usec,"physicalValidationElapsedUsec":physical_elapsed_usec,"sourceWithinDeadline":source_within_deadline,
			"contextUnchanged":before==var_to_bytes(recipe_context),"context":recipe_context,
			"partCount":blueprint.parts.size(),"furniturePartCount":furniture.parts.size(),"accessReservationCount":source.accessReservations.size(),
			"sourceKeys":source.keys(),"physicalValidationPerformed":true,"physicalPassed":physical_passed,
			"physicalViolationCount":physical.get("violations",[]).size(),"physicalCheckedPartCount":physical.get("checkedPartCount",0),
			"furnitureValidationPerformed":false,"sourceSnapshotBeforeDiagnosticPhysicalValidation":true,
			"inputSha256":FileAccess.get_sha256(output.path_join("input.bin")),"sourceSha256":FileAccess.get_sha256(output.path_join("source.bin"))}
	# Persist all nested detail before worker returns/disposes it. No main-thread
	# handoff of large snapshots, and no pruning of failures or physical records.
	var written := _write_typed("failure.bin",result) and captured
	written=_write_json("failure.json",result) and written
	var structural: Dictionary=result.get("structuralCompletionFailure",{})
	var chain: Array=[]
	_collect_reasons(result,"result",chain,0)
	return {"recipePassed":result.get("ready",false)==true,"reason":result.get("reason",""),"structuralReason":structural.get("reason",""),"reasonChain":chain,
		"recipeElapsedUsec":recipe_elapsed_usec,"sourceWithinDeadline":source_within_deadline,
		"contextUnchanged":before==var_to_bytes(recipe_context),"context":recipe_context,"artifactsWritten":written,"callerBlueprintCaptured":capture_blueprint,
		"inputSha256":FileAccess.get_sha256(output.path_join("input.bin")),"failureSha256":FileAccess.get_sha256(output.path_join("failure.bin"))}

func _collect_reasons(value: Variant,path: String,rows: Array,depth: int) -> void:
	if depth>24 or rows.size()>=64: return
	if value is Dictionary:
		for key: String in ["reason","failedHouse","candidateId","panelId","partId","blockingPartId"]:
			if value.has(key): rows.append({"path":path+"."+key,"value":value[key]})
		for key: String in ["structuralCompletionFailure","detail","failureEvidence"]:
			if value.has(key): _collect_reasons(value[key],path+"."+key,rows,depth+1)

func _write_typed(name: String,value: Dictionary) -> bool:
	var file := FileAccess.open(output.path_join(name),FileAccess.WRITE)
	if file==null: push_error("Diagnostic artifact open failed: "+name); return false
	file.store_var(value,false); file.flush()
	var ok := file.get_error()==OK
	file.close()
	if not ok: push_error("Diagnostic artifact write failed: "+name)
	return ok

func _write_json(name: String,value: Dictionary) -> bool:
	var file := FileAccess.open(output.path_join(name),FileAccess.WRITE)
	if file==null: push_error("Diagnostic JSON open failed: "+name); return false
	file.store_string(JSON.stringify(value,"\t")); file.flush()
	var ok := file.get_error()==OK
	file.close()
	if not ok: push_error("Diagnostic JSON write failed: "+name)
	return ok
