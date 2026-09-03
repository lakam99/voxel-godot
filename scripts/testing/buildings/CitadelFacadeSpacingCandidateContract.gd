extends SceneTree
## Regenerated candidate with real pre-structural furniture/access policy.
## Source-only; no complete structural, terrain, publication or gameplay claim.
const Facades = preload("res://scripts/buildings/CitadelFacadeCompletionRecipe.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/facade-input-capture-03/input.bin"
const ACTUAL_SHA := "1935cc9ecab553c91c453f2a8ac715e90062fc363a244d880b153a5af9d66f2c"
const BEFORE := "res://artifacts/citadel-runtime-integration/facade-input-capture-01/input.bin"
const BEFORE_SHA := "796a2375d8d6209d3a779f73d18ad638e0efee1b40e1d7407074ba0a20ac81e7"
const FAILED := "res://artifacts/citadel-runtime-integration/candidate-recipe-13/failure.bin"
const FAILED_SHA := "0fa8293b8743a6bfcf2ac51ce6d6b7888c57135ace50bb27c7170659af17c04f"
var deadline := 0
var stages: Array = []
var last_stage := ""
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("CITADEL_FACADE_SPACING_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	var checks := {"input_pins":FileAccess.get_sha256(INPUT)==ACTUAL_SHA and FileAccess.get_sha256(BEFORE)==BEFORE_SHA and FileAccess.get_sha256(FAILED)==FAILED_SHA}
	if not checks.input_pins: quit(2); return
	var hashes := _hashes()
	var input: Dictionary=_read(INPUT)
	var before: Dictionary=_read(BEFORE)
	var failure: Dictionary=_read(FAILED)
	# Window-mounted plants/candles must follow their moved windows. Exact
	# relational preservation belongs to CitadelWindowSpacingPreservationContract;
	# this stage uses the entire regenerated policy without omitting obstacles.
	checks.furniture_and_obstacle_counts_retained=input.policy.furnitureParts.size()==before.policy.furnitureParts.size() and input.policy.protectedObstacles.size()==before.policy.protectedObstacles.size()
	checks.house_rooms_and_access_unchanged=var_to_bytes(input.blueprint.rooms)==var_to_bytes(before.blueprint.rooms)
	checks.source_part_count_preserved=input.blueprint.parts.size()==before.blueprint.parts.size()
	var bytes := var_to_bytes(input)
	var started := Time.get_ticks_usec()
	deadline=Time.get_ticks_msec()+180000
	var result := Facades.prepare(Copy.copy_blueprint(input.blueprint),input.policy,_continue)
	checks.facade_stage_ready=result.get("ready",false)
	var final_report := {}
	var targeted: Array=[]
	if checks.facade_stage_ready:
		var after = Copy.copy_blueprint(result.afterSnapshot)
		final_report=after.validate_physical_integrity_cancellable(_continue)
		checks.final_proof_completed=not final_report.get("cancelled",false)
		for row: Dictionary in final_report.get("checks",[]):
			if failure.structuralCompletionFailure.failedIds.has(row.partId): targeted.append(row)
		var facade_checks: Array=targeted.filter(func(row):return String(row.partId).contains("_upper_facade_"))
		checks.all_24_previous_failed_facades_present=facade_checks.size()==24
		checks.all_24_previous_failed_facades_pass=facade_checks.size()==24 and facade_checks.all(func(row):return row.passed)
		var archive := {"snapshot":result.afterSnapshot,"policy":input.policy,"result":result,"finalProof":final_report}
		var file := FileAccess.open(output.get_base_dir().path_join("prepared.bin"),FileAccess.WRITE)
		checks.archive_written=file!=null
		if file!=null:
			file.store_var(archive,false); file.flush(); checks.archive_written=file.get_error()==OK; file.close()
	checks.inputs_unchanged=bytes==var_to_bytes(input)
	checks.deadline=Time.get_ticks_msec()<deadline
	checks.sources_unchanged=hashes==_hashes()
	checks.hashes_valid=hashes.values().all(func(value):return String(value).length()==64)
	result.erase("afterSnapshot")
	var report := {"passed":checks.values().all(func(value):return value==true),"checks":checks,"elapsedUsec":Time.get_ticks_usec()-started,"result":result,"targetedChecks":targeted,"failedIds":Copy.failed_ids(final_report) if final_report.has("checks") else [],"stages":stages,"lastStage":last_stage,"sourceHashes":hashes,"scope":"Actual regenerated candidate facade stage with ordinary policy and independent full physical proof. Later structural stages, bunting, publication and gameplay unproven."}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t",true,true)); file.flush()
	var saved := file.get_error()==OK; file.close()
	quit(0 if saved and report.passed else 1)
func _continue(stage: String) -> bool:
	last_stage=stage
	if not stage.begins_with("physical_") and (stages.is_empty() or stages[-1].stage!=stage):
		stages.append({"stage":stage,"msec":Time.get_ticks_msec()})
		if stages.size()>512: stages.pop_front()
	return Time.get_ticks_msec()<deadline
func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path,FileAccess.READ)
	var result: Dictionary=file.get_var(false); file.close(); return result
func _hashes() -> Dictionary:
	var result := {}
	var pending: Array[String]=[get_script().resource_path,INPUT,BEFORE,FAILED]
	var regex := RegEx.create_from_string("[\"'](res://[^\"'\\r\\n]+)[\"']")
	while not pending.is_empty():
		var path: String=pending.pop_back()
		if result.has(path): continue
		result[path]=FileAccess.get_sha256(path)
		if path.get_extension()!="gd": continue
		for match_value: RegExMatch in regex.search_all(FileAccess.get_file_as_string(path)):
			var next := match_value.get_string(1)
			if next.get_extension() in ["gd","gdshader"]: pending.append(next)
	return result
