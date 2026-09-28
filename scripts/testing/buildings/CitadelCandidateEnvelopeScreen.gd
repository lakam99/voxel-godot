extends SceneTree

## TEST SELECTION ONLY. A previous candidate's envelope is a proxy, never the
## source of a different candidate and never runtime admission evidence.
const Base = preload("res://scripts/testing/buildings/CitadelCandidateIntegrationContinuation.gd")
var output := ""
var world_seed := ""
var state = Base.Diagnostic.Progress.new()

func _initialize() -> void:call_deferred("_run")

func _run() -> void:
	output=OS.get_environment("CITADEL_CANDIDATE_SCREEN_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output):quit(2);return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	world_seed="atlas-"+str(rng.randi())
	state.started=Time.get_ticks_msec()
	state.begin_phase("proxy_screen",90000)
	var thread := Thread.new()
	if thread.start(_work)!=OK:quit(2);return
	var next_progress := 0
	while thread.is_alive():
		if Time.get_ticks_msec()>=next_progress:
			_write(output.get_base_dir().path_join("progress.json"),state.snapshot())
			next_progress=Time.get_ticks_msec()+1000
		await process_frame
	var report: Dictionary=thread.wait_to_finish()
	state.finish()
	report["progress"]=state.snapshot(true)
	var saved := _write(output,report)
	print("CITADEL PROXY SCREEN selected=",report.get("selected",{})," seed=",world_seed)
	quit(0 if saved and report.get("passed",false) else 1)

func _work() -> Dictionary:
	var result := {"passed":false,"checks":{},"worldSeed":world_seed,"selected":{},"observations":[],
		"proxySourceSha256":Base.SOURCE_SHA,"actualCandidateSourceBuilt":false,
		"scope":"Read-only candidate screening with another recipe's envelope. No actual new-candidate recipe, admission, publication, rendering or gameplay acceptance; any selection requires its own full source and exact integration gates."}
	result.checks.proxy_hash=FileAccess.get_sha256(Base.SOURCE)==Base.SOURCE_SHA
	if not result.checks.proxy_hash:return result
	var file := FileAccess.open(Base.SOURCE,FileAccess.READ)
	if file==null or file.get_length()>67108864:return result
	var source: Dictionary=file.get_var(false)
	file.close()
	var furniture: Dictionary=source.furnishingPlan.duplicate(true)
	furniture["accessReservations"]=source.accessReservations.duplicate(true)
	var restored := Base.Restore.restore(source.blueprint,furniture,state.checkpoint)
	result.checks.exact_proxy_restoration=restored.ready
	if not restored.ready:return result
	var manifest := Base.Manifest.build(restored.blueprint,restored.furnishingPlan,Base.Site.CELL)
	result.checks.proxy_manifest=manifest.ready
	if not manifest.ready:return result
	var context=Base.Diagnostic.Context.new()
	context.seed_text=world_seed;context.seed_hash=context.hash_string(world_seed);context.setup_noise()
	var world=Base.Diagnostic.World.new()
	world.setup(context);context.set_generator(world)
	var town_region: Vector2i=Base.Diagnostic.Tutorial.TUTORIAL_TOWN_REGION
	var town: Dictionary=context.town_region(town_region.x,town_region.y).duplicate(true)
	town.radius=Base.Diagnostic.Tutorial.FENCE_RADIUS_CELLS
	var towns := {town_region:town}
	var policy := {"regionCells":Base.MainPolicy.STRUCTURE_REGION_CELLS,"spawnChance":Base.MainPolicy.STRUCTURE_SPAWN_CHANCE}
	for ring in range(6):
		for z in range(-ring,ring+1):
			for x in range(-ring,ring+1):
				if maxi(absi(x),absi(z))!=ring:continue
				if not state.checkpoint("proxy_candidate") or result.observations.size()>=32:return result
				var region := Vector2i(x,z)
				var candidate := Base.Site.Field.candidate_for_region(world_seed,region)
				if candidate.is_empty():continue
				var survey := Base.Diagnostic.Survey.new()
				var center: Vector2i=candidate.centerCell
				var center_result := survey.begin(world_seed,region,Rect2i(center,Vector2i.ONE),towns)
				while center_result.status=="pending_budget":
					if not state.checkpoint("proxy_center_survey"):return result
					center_result=survey.advance()
				var observation := {"candidate":candidate,"centerSurvey":center_result,"proxyTerrain":{}}
				result.observations.append(observation)
				if center_result.status!="surveyed":continue
				var level := roundf(float(center_result.minimumSurfaceY)/Base.Site.CELL)*Base.Site.CELL
				var terrain := Base.Site.prepare_terrain(manifest,candidate,towns,level,policy,state.checkpoint)
				observation.proxyTerrain={"status":terrain.status,"reason":terrain.get("reason",""),"conflict":terrain.get("conflict",{})}
				if terrain.status!="prepared":continue
				observation.proxyTerrain["reservationCells"]=terrain.reservationCells
				observation.proxyTerrain["apronCells"]=terrain.profile.apronCells
				result.selected=candidate
				result.passed=true
				result.checks.selected_proxy_only=true
				return result
	return result

func _write(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:return false
	file.store_string(JSON.stringify(value,"  ",true,true));file.flush()
	return file.get_error()==OK
