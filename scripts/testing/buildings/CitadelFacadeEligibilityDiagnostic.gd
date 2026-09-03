extends SceneTree
## Actual captured pre-structural source; diagnostics only, never publication.
const Heads = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const Lower = preload("res://scripts/buildings/LowerFacadeBearingRecipe.gd")
const Facades = preload("res://scripts/buildings/CitadelFacadeCompletionRecipe.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/facade-input-capture-03/input.bin"
const INPUT_SHA := "1935cc9ecab553c91c453f2a8ac715e90062fc363a244d880b153a5af9d66f2c"
const FAILURES := "res://artifacts/citadel-runtime-integration/candidate-recipe-13/failure.bin"
const FAILURE_SHA := "0fa8293b8743a6bfcf2ac51ce6d6b7888c57135ace50bb27c7170659af17c04f"
var deadline := 0
var output := ""
var checks: Dictionary={}
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	output=OS.get_environment("FACADE_ELIGIBILITY_REPORT")
	if not output.is_absolute_path(): quit(2); return
	deadline=Time.get_ticks_msec()+90000
	var hashes := _hashes()
	checks.input_pinned=FileAccess.get_sha256(INPUT)==INPUT_SHA
	checks.failures_pinned=FileAccess.get_sha256(FAILURES)==FAILURE_SHA
	if not checks.input_pinned or not checks.failures_pinned: _finish({},hashes); return
	var file := FileAccess.open(INPUT,FileAccess.READ)
	var input: Dictionary=file.get_var(false); file.close()
	file=FileAccess.open(FAILURES,FileAccess.READ)
	var failure: Dictionary=file.get_var(false); file.close()
	var policy: Dictionary=input.policy.duplicate(true)
	policy.requiredHeadroom=Facades.REQUIRED_HEADROOM
	var started := Time.get_ticks_usec()
	var opening := Heads.prepare_all_first_rows(Lower.Copy.copy_blueprint(input.blueprint),policy,_continue)
	checks.opening_ready=opening.get("ready",false)
	if not checks.opening_ready: _finish({"opening":opening},hashes); return
	var snapshot: Dictionary=opening.candidateSnapshot
	var initial := Lower._current_unsupported_bottom_panels(snapshot,_continue)
	checks.initial_ready=initial.get("ready",false)
	if not checks.initial_ready: _finish({"initial":initial},hashes); return
	var source = Lower.Copy.copy_blueprint(snapshot)
	var rows: Array=[]
	for id: String in failure.structuralCompletionFailure.failedIds:
		var panel = source.find_part(id)
		if panel==null or panel.semantic!="citadel_urban_facade": continue
		if not _continue("panel"): checks.deadline=false; break
		var declaration_key := ""
		for key: String in source.recipe.facadeApertures:
			if source.recipe.facadeApertures[key].partIds.has(id): declaration_key=key; break
		var declaration: Dictionary=source.recipe.facadeApertures[declaration_key]
		var bottoms: Array=[]
		var minimum := INF
		for sibling_id: String in declaration.partIds:
			var bottom: float=Lower.Connection._bounds(source.find_part(sibling_id))[1]
			minimum=minf(minimum,bottom)
			bottoms.append({"id":sibling_id,"bottom":bottom})
		var bottom: float=Lower.Connection._bounds(panel)[1]
		var read := Lower._read(snapshot,id,policy)
		rows.append({"id":id,"eligible":initial.eligible.has(id),"initialRooted":initial.rooted.has(id),
			"bottom":bottom,"minimum":minimum,"difference":bottom-minimum,"declarationBottom":declaration.wallDomain.position.y,
			"directReadReady":read.ready,"directReadReason":read.get("reason",""),"bottoms":bottoms})
	checks.all_failed_facades_inspected=rows.size()==24
	checks.deadline=Time.get_ticks_msec()<deadline
	file=FileAccess.open(output.get_base_dir().path_join("prepared.bin"),FileAccess.WRITE)
	checks.prepared_written=file!=null
	if file!=null:
		file.store_var({"snapshot":snapshot,"policy":policy,"initial":initial,"rows":rows,"opening":opening},false); file.flush()
		checks.prepared_written=file.get_error()==OK; file.close()
	_finish({"rows":rows,"eligibleIds":initial.eligible,"elapsedUsec":Time.get_ticks_usec()-started},hashes)
func _continue(_stage: String) -> bool: return Time.get_ticks_msec()<deadline
func _hashes() -> Dictionary:
	var result: Dictionary={}
	var pending: Array[String]=[get_script().resource_path]
	var regex := RegEx.create_from_string("[\"'](res://[^\"'\\r\\n]+)[\"']")
	while not pending.is_empty():
		var path: String=pending.pop_back()
		if result.has(path): continue
		result[path]=FileAccess.get_sha256(path)
		if path.get_extension()!="gd": continue
		for value: RegExMatch in regex.search_all(FileAccess.get_file_as_string(path)):
			var next := value.get_string(1)
			if next.get_extension() in ["gd","gdshader"]: pending.append(next)
	return result
func _finish(evidence: Dictionary, hashes: Dictionary) -> void:
	checks.sources_unchanged=hashes==_hashes()
	checks.hashes_valid=hashes.values().all(func(value): return String(value).length()==64)
	checks.input_unchanged=FileAccess.get_sha256(INPUT)==INPUT_SHA and FileAccess.get_sha256(FAILURES)==FAILURE_SHA
	var report := {"passed":checks.values().all(func(value): return value==true),"checks":checks,"evidence":evidence,
		"sourceHashes":hashes,"scope":"Captured-source opening preparation and lower-facade eligibility diagnosis only. Not a structural repair or gameplay pass."}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t",true,true)); file.flush()
	var saved := file.get_error()==OK; file.close()
	quit(0 if saved and report.passed else 1)
