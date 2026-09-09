extends SceneTree

## Intentional pre-shop cancellation and direct-component diagnosis. Captured
## input is not a successful public Recipe or a runtime-injectable source.
const Diagnostic = preload("res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd")
const Shop = preload("res://scripts/buildings/CitadelShopRecipe.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate-recipe-20/input.bin"
const INPUT_SHA := "f73675b03661f5637095a906f99c0c9dea10ef5274a02a07a141ce2be0518c5c"
var state = Diagnostic.Progress.new()
var output := ""
var captured := false
var after_false := 0

func _initialize() -> void:call_deferred("_run")

func _run() -> void:
	output=OS.get_environment("CITADEL_SHOP_CAPTURE_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output):quit(2);return
	state.started=Time.get_ticks_msec();state.begin_phase("pre_shop_capture",60000)
	var thread := Thread.new()
	if thread.start(_work)!=OK:quit(2);return
	var next_progress := 0
	while thread.is_alive():
		if Time.get_ticks_msec()>=next_progress:
			_write_json(output.get_base_dir().path_join("progress.json"),state.snapshot())
			next_progress=Time.get_ticks_msec()+1000
		await process_frame
	var report: Dictionary=thread.wait_to_finish()
	state.finish();report["progress"]=state.snapshot(true)
	var saved := _write_json(output,report)
	print("SHOP FAILURE CAPTURE passed=",report.get("passed",false)," failure=",report.get("shopFailure",{}).get("reason",""))
	quit(0 if saved and report.get("passed",false) else 1)

func _work() -> Dictionary:
	var checks := {"pinned_input":FileAccess.get_sha256(INPUT)==INPUT_SHA}
	var report := {"passed":false,"checks":checks,"shopFailure":{},"inputSha256":INPUT_SHA,
		"scope":"Actual Builder/Composer stopped before shops; regenerated deterministic furnishings and direct Shop.prepare failure. No complete Recipe, physical, site, publication or gameplay acceptance."}
	if not checks.pinned_input:return report
	var file := FileAccess.open(INPUT,FileAccess.READ)
	var input: Dictionary=file.get_var(false);file.close()
	var original := var_to_bytes(input)
	var seed: int=input.candidate.recipeSeed
	var built: Dictionary=Diagnostic.Builder.build_with_diagnostics(seed,input.context.duplicate(true),_gate)
	if built.get("blueprint")==null:
		report["buildFailure"]=built.get("diagnostics",{});return report
	var blueprint=built.blueprint
	var composed: Dictionary=Diagnostic.Urban.compose_prepared(blueprint,seed,_gate)
	checks.exact_pre_shop_boundary=captured and after_false==0 and not composed.get("ready",true)
	if not checks.exact_pre_shop_boundary:return report
	var snapshot: Dictionary=blueprint.snapshot()
	var snapshot_bytes := var_to_bytes(snapshot)
	checks.capture_written=_write_typed(output.get_base_dir().path_join("input.bin"),{"blueprint":snapshot,"candidate":input.candidate,"context":input.context,"civicInfill":composed.get("civicInfill",{})})
	if not checks.capture_written:return report
	if not state.begin_phase("shop_component_diagnostic",30000):return report
	var furnishings: Dictionary=Diagnostic.Urban.prepare_furnishings(blueprint,seed)
	checks.furnishings_regenerated=furnishings.get("ready",false)
	if not checks.furnishings_regenerated:return report
	var plan=furnishings.furnishingPlan
	var frozen_plan := var_to_bytes([plan.snapshot(),plan.protected_access_reservations])
	var obstacles := Shop.furnishing_obstacles(plan.snapshot(),plan.protected_access_reservations)
	checks.furnishing_obstacles_valid=obstacles.ready
	if not checks.furnishing_obstacles_valid:return report
	var shops := Shop.prepare(blueprint,obstacles.obstacles,Diagnostic.Urban.add_market_stall_household,Diagnostic.Urban.add_terminal_shop_row,Diagnostic.Urban.plan_courtyard_household,Diagnostic.Urban.plan_terminal_shop_household)
	checks.expected_shop_failure=shops.get("ready")==false and shops.get("reason")=="terminal_recipe_failed"
	checks.source_immutable=snapshot_bytes==var_to_bytes(blueprint.snapshot()) and original==var_to_bytes(input)
	checks.furniture_immutable=frozen_plan==var_to_bytes([plan.snapshot(),plan.protected_access_reservations])
	if not state.begin_phase("report_export",10000):return report
	report.shopFailure=shops
	report["furnishingCount"]=plan.parts.size()
	report["capturedPartCount"]=blueprint.parts.size()
	checks.failure_written=_write_typed(output.get_base_dir().path_join("failure.bin"),shops)
	checks.artifact_unchanged=FileAccess.get_sha256(INPUT)==INPUT_SHA
	report["captureSha256"]=FileAccess.get_sha256(output.get_base_dir().path_join("input.bin"))
	report["failureSha256"]=FileAccess.get_sha256(output.get_base_dir().path_join("failure.bin"))
	report.passed=checks.values().all(func(value):return value==true)
	return report

func _gate(stage: String) -> bool:
	if captured:after_false+=1;return false
	if not state.checkpoint(stage):return false
	if stage=="shop_recipe_prepare_started":captured=true;return false
	return true

func _write_typed(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:return false
	file.store_var(value,false);file.flush()
	return file.get_error()==OK

func _write_json(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:return false
	file.store_string(JSON.stringify(value,"  ",true,true));file.flush()
	return file.get_error()==OK
