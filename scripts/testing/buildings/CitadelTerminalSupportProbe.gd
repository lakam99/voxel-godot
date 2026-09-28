extends SceneTree
## Pinned source-only support eligibility observations, never shop acceptance.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Elevation = preload("res://scripts/buildings/TerminalShopElevationRecipe.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate20-shop-capture-01/input.bin"
const INPUT_SHA := "314b05afeb053e6f57737c83aaff43231c200fa6d37699b874c07b1407280e66"
const FAILURE := "res://artifacts/citadel-runtime-integration/candidate20-shop-capture-01/failure.bin"
const FAILURE_SHA := "685a05891cea5338f2c169564427f2319793c147bd8ee438de57c365c1195b9c"
var output := ""
var deadline := 0

func _initialize() -> void:call_deferred("_run")
func _run() -> void:
	output=OS.get_environment("CITADEL_TERMINAL_SUPPORT_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output):quit(2);return
	deadline=Time.get_ticks_msec()+60000
	var thread := Thread.new()
	if thread.start(_work)!=OK:quit(2);return
	while thread.is_alive():await process_frame
	var report: Dictionary=thread.wait_to_finish()
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null:quit(2);return
	file.store_string(JSON.stringify(report,"  ",true,true));file.flush()
	var saved := file.get_error()==OK
	file.close();quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var checks := {"pinned":FileAccess.get_sha256(INPUT)==INPUT_SHA and FileAccess.get_sha256(FAILURE)==FAILURE_SHA}
	var report := {"passed":false,"checks":checks,"surfaces":[],"missingSupportObservations":[],
		"scope":"Frozen pre-shop source, isolated support closure and full-source physical queries. Neither an alternate valid shop placement nor complete source/runtime acceptance."}
	if not checks.pinned:return report
	var input := _read(INPUT)
	var failure := _read(FAILURE)
	var b=Copy.copy_blueprint(input.blueprint)
	var before := var_to_bytes(b.snapshot())
	var layout: Dictionary=failure.terminals.layout
	var members: Dictionary={}
	for id: String in layout.memberIds:members[id]=true
	var records: Dictionary={}
	for part in b.parts:
		var bounds: AABB=b.transformed_part_bounds(part)
		records[part.id]={"part":part,"bounds":bounds,"footprint":Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z))}
	var selected: Dictionary=Elevation._support_closure(b,records,members,layout.supportId)
	checks.selected_closure_reproduced=selected.get("reason")==failure.terminals.closure.reason
	var footprint: Rect2=layout.footprint
	var minimum_span := minf(footprint.size.x,footprint.size.y)
	for part in b.parts:
		if not _continue(""):return report
		if not Urban.is_primary_tree_paving(part) or not part.collision_enabled or part.rotation!=Vector3.ZERO or minf(part.size.x,part.size.z)<minimum_span:continue
		var start := Time.get_ticks_usec()
		var closure: Dictionary=Elevation._support_closure(b,records,members,part.id)
		report.surfaces.append({"id":part.id,"position":part.position,"size":part.size,"ready":closure.ready,"reason":closure.get("reason",""),"elapsedUsec":Time.get_ticks_usec()-start})
	checks.source_immutable=before==var_to_bytes(b.snapshot())
	var full=Copy.copy_blueprint(input.blueprint)
	checks.full_source_resolution_completed=full.resolve_physical_contracts_cancellable(_continue)
	if not checks.full_source_resolution_completed:return report
	for check: Dictionary in failure.terminals.closure.checks:
		for sample: Dictionary in check.get("supportCoverage",[]):
			if sample.get("supported",false):continue
			var point: Vector3=sample.position
			var part=full.find_part(check.partId)
			var nearby: Array=[]
			for candidate in full.parts:
				if candidate.id==part.id or not candidate.collision_enabled:continue
				var bounds: AABB=full.transformed_part_bounds(candidate)
				if bounds.grow(0.8).has_point(point) and bounds.position.y<=point.y+0.12:
					nearby.append({"record":candidate.snapshot(),"bounds":bounds})
			report.missingSupportObservations.append({"partId":part.id,"sample":sample,"wholeSourceSupport":full.structural_support_at(part,point),"nearby":nearby})
	checks.deadline=Time.get_ticks_msec()<deadline
	report.passed=checks.values().all(func(value):return value==true)
	return report

func _continue(_stage:String) -> bool:return Time.get_ticks_msec()<deadline
func _read(path:String) -> Dictionary:
	var file := FileAccess.open(path,FileAccess.READ)
	var result: Dictionary=file.get_var(false);file.close();return result
