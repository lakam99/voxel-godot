extends SceneTree
## Sparse/dense production terrain/town-query heuristic, NOT site acceptance.
## No Recipe, Site.prepare, queue injection, scene loading, or publication calls.
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Context = preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const World = preload("res://scripts/WorldGenerationSystem.gd")
const Tutorial = preload("res://scripts/TutorialSystem.gd")
const Survey = preload("res://scripts/world/CitadelSiteSurvey.gd")
const ORIGIN := Vector2i(0,-1)
const RADIUS := 2
const GRID := 9
const DEFAULT_SEED := "atlas-30895044"
var deadline := 0
var seed_text := ""
var dense_requested := false
var dense_region := Vector2i.ZERO

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("CITADEL_CANDIDATE_SCOUT_OUTPUT")
	seed_text=OS.get_environment("CITADEL_CANDIDATE_SCOUT_SEED")
	if seed_text.is_empty(): seed_text=DEFAULT_SEED
	if not output.is_absolute_path() or FileAccess.file_exists(output) or seed_text.length()>256: quit(2); return
	var dense_text := OS.get_environment("CITADEL_CANDIDATE_SCOUT_DENSE_REGION")
	if not dense_text.is_empty():
		var pieces := dense_text.split(",",true)
		if pieces.size()!=2 or dense_text.length()>20 or not pieces[0].is_valid_int() or not pieces[1].is_valid_int(): quit(2); return
		dense_region=Vector2i(int(pieces[0]),int(pieces[1]))
		if dense_text!="%d,%d"%[dense_region.x,dense_region.y] or absi(dense_region.x-ORIGIN.x)>RADIUS or absi(dense_region.y-ORIGIN.y)>RADIUS: quit(2); return
		dense_requested=true
	deadline=Time.get_ticks_msec()+40000
	var worker := Thread.new()
	if worker.start(_scout)!=OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary=worker.wait_to_finish()
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.flush()
	var saved := file.get_error()==OK
	file.close()
	print("CANDIDATE SCOUT diagnosticCompleted=",report.get("diagnosticCompleted",false)," candidates=",report.get("candidateCount",0)," replayExact=",report.get("forwardReverseExact",false))
	quit(0 if saved and report.get("diagnosticCompleted",false) else 1)

func _world() -> Dictionary:
	# Match RecipeDiagnostic + Survey: derive the ordinary tutorial town via
	# WGS, apply the owning fence radius, then pin canonical inputs in a fresh
	# context. Other towns are ordinary deterministic generation, not injected.
	var context := Context.new()
	context.seed_text=seed_text; context.seed_hash=context.hash_string(seed_text); context.setup_noise()
	var generator := World.new()
	generator.setup(context); context.set_generator(generator)
	var region: Vector2i=Tutorial.TUTORIAL_TOWN_REGION
	var town: Dictionary=context.town_region(region.x,region.y)
	var pinned := {"regionX":region.x,"regionZ":region.y,"centerX":int(town.centerX),"centerZ":int(town.centerZ),"radius":Tutorial.FENCE_RADIUS_CELLS,"level":float(town.level)}
	var fresh := Context.new()
	fresh.seed_text=seed_text; fresh.seed_hash=fresh.hash_string(seed_text)
	fresh.pinned_town_regions[region]=pinned
	fresh.setup_noise()
	var world := World.new()
	world.setup(fresh); fresh.set_generator(world)
	return {"world":world,"townOverrides":{region:pinned}}

func _pass(reverse: bool) -> Dictionary:
	var setup := _world()
	var world = setup.world
	var indices: Array=[]
	for index in range(25): indices.append(index)
	if reverse: indices.reverse()
	var rows: Array=[]
	rows.resize(25)
	for index: int in indices:
		if Time.get_ticks_msec()>=deadline: return {"ready":false,"reason":"scout_deadline"}
		var region := ORIGIN-Vector2i.ONE*RADIUS+Vector2i(index%5,index/5)
		var candidate := Field.candidate_for_region(seed_text,region)
		if candidate.is_empty(): rows[index]={"region":region,"candidatePresent":false}; continue
		var bounds := Admission.declared_influence(candidate)
		var samples: Array=[]
		samples.resize(GRID*GRID)
		var order: Array=[]
		for sample_index in range(GRID*GRID): order.append(sample_index)
		if reverse: order.reverse()
		for sample_index: int in order:
			if Time.get_ticks_msec()>=deadline: return {"ready":false,"reason":"scout_deadline","region":region}
			var x := bounds.position.x+roundi(float(sample_index%GRID)*float(bounds.size.x-1)/float(GRID-1))
			var z := bounds.position.y+roundi(float(sample_index/GRID)*float(bounds.size.y-1)/float(GRID-1))
			var cell := Vector3i(x,0,z)
			var town: Dictionary=world.town_region_for_surface_cell3(cell).duplicate(true)
			var biome: String=world.surface_biome_for_cell3(cell)
			var biome_allowed := Field.allows_surface_biome(biome)
			samples[sample_index]={"cell":Vector2i(x,z),"biome":biome,"town":town,"townOverlap":not town.is_empty(),
				"biomeAllowed":biome_allowed,"sampleExcluded":not town.is_empty() or not biome_allowed}
		var counts: Dictionary={}
		var excluded := 0
		var town_count := 0
		var biome_excluded := 0
		for sample: Dictionary in samples:
			counts[sample.biome]=int(counts.get(sample.biome,0))+1
			excluded+=int(sample.sampleExcluded); town_count+=int(sample.townOverlap); biome_excluded+=int(not sample.biomeAllowed)
		var center: Dictionary=samples[40] # Odd 9x9 grid includes exact center once.
		if center.cell!=candidate.centerCell: return {"ready":false,"reason":"center_lattice_mismatch"}
		rows[index]={"region":region,"candidatePresent":true,"candidate":candidate,"centerCell":candidate.centerCell,
			"recipeSeed":candidate.recipeSeed,"declaredInfluence":bounds,"sampleCount":samples.size(),"samples":samples,
			"centerSample":center,"centerEligible":not center.sampleExcluded,"sampledExclusionCount":excluded,
			"sampledTownOverlapCount":town_count,"sampledExcludedBiomeCount":biome_excluded,"sampledBiomeCounts":counts,
			"distanceSquaredToOriginRegionCenter":Vector2(candidate.centerCell).distance_squared_to(Vector2(ORIGIN*Field.REGION_CELLS+Vector2i.ONE*(Field.REGION_CELLS/2)))}
	return {"ready":true,"regions":rows,"townOverrides":setup.townOverrides}

func _scout() -> Dictionary:
	var started := Time.get_ticks_usec()
	var paths := [get_script().resource_path,"res://scripts/world/CitadelSiteField.gd","res://scripts/world/CitadelTerrainAdmission.gd",
		"res://scripts/world/CitadelSitePreparation.gd","res://scripts/world/CitadelSiteSurvey.gd","res://scripts/terrain/VoxelWorldGenerationContext.gd",
		"res://scripts/WorldGenerationSystem.gd","res://scripts/TerrainVolumeService.gd","res://scripts/world/BiomeRegionField.gd",
		"res://scripts/world/BuildingTerrainProfile.gd","res://scripts/TutorialSystem.gd"]
	var hashes: Dictionary={}
	for path: String in paths: hashes[path]=FileAccess.get_sha256(path)
	var forward := _pass(false)
	if not forward.ready: return forward
	var reverse := _pass(true)
	if not reverse.ready: return reverse
	var exact := var_to_bytes(forward)==var_to_bytes(reverse)
	var sparse_elapsed := Time.get_ticks_usec()-started
	var dense: Dictionary={"requested":false}
	if dense_requested: dense=_dense(forward.townOverrides)
	var changed: Array=[]
	for path: String in paths:
		if hashes[path].is_empty() or FileAccess.get_sha256(path)!=hashes[path]: changed.append(path)
	var ranked: Array=[]
	for row: Dictionary in forward.regions:
		if row.candidatePresent: ranked.append(row)
	ranked.sort_custom(func(a: Dictionary,b: Dictionary) -> bool:
		if a.centerEligible!=b.centerEligible: return a.centerEligible
		if a.sampledExclusionCount!=b.sampledExclusionCount: return a.sampledExclusionCount<b.sampledExclusionCount
		if a.distanceSquaredToOriginRegionCenter!=b.distanceSquaredToOriginRegionCenter: return a.distanceSquaredToOriginRegionCenter<b.distanceSquaredToOriginRegionCenter
		return String(a.candidate.siteId)<String(b.candidate.siteId))
	var ranking: Array=[]
	for index in range(ranked.size()):
		var row: Dictionary=ranked[index]
		ranking.append({"rank":index+1,"region":row.region,"centerCell":row.centerCell,"recipeSeed":row.recipeSeed,"centerEligible":row.centerEligible,
			"sampledExclusionCount":row.sampledExclusionCount,"sampledTownOverlapCount":row.sampledTownOverlapCount,"sampledBiomeCounts":row.sampledBiomeCounts})
	return {"schema":"citadel-candidate-scout/v1","diagnosticCompleted":exact and changed.is_empty() and (not dense_requested or dense.get("diagnosticCompleted",false)),"passedSite":false,
		"evidenceLevel":"sparse deterministic production-query heuristic only","worldSeed":seed_text,"originRegion":ORIGIN,"regionRadius":RADIUS,
		"regionsExamined":25,"candidateCount":ranked.size(),"latticeWidth":GRID,"samplesPerCandidate":81,"centerIncludedOnce":true,
		"regions":forward.regions,"ranking":ranking,"townOverrides":forward.townOverrides,"forwardReverseExact":exact,
		"replayScope":"Fresh WGS/context each pass; reverse region AND sample order; compare complete typed candidate/sample facts in canonical order.",
		"rankingPolicy":"Eligible center first, then fewer excluded samples, then distance to ORIGIN REGION CENTER (not player), then siteId.",
		"limitations":"81 lattice samples across conservative declared influence, not actual geometry reservation or full survey. Outer ocean/town samples do NOT prove actual site invalid; clean samples do NOT prove acceptance. No Recipe/Source preparation, native terrain, scene load, injection, publication, or live gameplay.",
		"denseSurvey":dense,"sparseElapsedUsec":sparse_elapsed,"internalDeadlineSeconds":40,
		"sourceHashes":hashes,"changedSources":changed,"elapsedUsec":Time.get_ticks_usec()-started}

func _dense(towns: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	var candidate := Field.candidate_for_region(seed_text,dense_region)
	if candidate.is_empty(): return {"requested":true,"diagnosticCompleted":false,"reason":"dense_region_has_no_candidate","region":dense_region}
	var bounds := Rect2i(candidate.centerCell-Vector2i.ONE*128,Vector2i.ONE*257)
	var survey := Survey.new()
	if Time.get_ticks_msec()>=deadline: return {"requested":true,"diagnosticCompleted":false,"reason":"scout_deadline"}
	var begin_started := Time.get_ticks_usec()
	var result := survey.begin(seed_text,dense_region,bounds,towns)
	var begin_usec := Time.get_ticks_usec()-begin_started
	var calls := 0
	var call_usec := 0
	var max_call_usec := 0
	while result.status=="pending_budget" and Time.get_ticks_msec()<deadline:
		var call_started := Time.get_ticks_usec()
		result=survey.advance() # Existing default budget and early-rejection policy.
		var elapsed := Time.get_ticks_usec()-call_started
		calls+=1; call_usec+=elapsed; max_call_usec=maxi(max_call_usec,elapsed)
	var timed_out := Time.get_ticks_msec()>=deadline
	return {"requested":true,"diagnosticCompleted":not timed_out and result.status in ["surveyed","rejected"],"region":dense_region,
		"candidate":candidate,"bounds":bounds,"geometryProvenance":"caller_supplied_unverified","requestedColumns":66049,
		"timedOut":timed_out,"survey":result,"beginCallUsec":begin_usec,"advanceCallCount":calls,
		"totalAdvanceCallUsec":call_usec,"maxAdvanceCallUsec":max_call_usec,"elapsedUsec":Time.get_ticks_usec()-started,
		"timingScope":"Whole begin/advance calls include snapshots; survey.workUsec/maxSliceUsec are the production scan-loop measurements.",
		"limitations":"Full 257x257 centered caller square only; NOT actual source reservation, geometry envelope, site acceptance, durable-edit/other-site coverage, or publication readiness. Rejection is for this square, not proof that actual geometry is invalid. Sparse reverse control does not replay this dense survey."}
