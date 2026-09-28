extends SceneTree
## Diagnostic interception of the exact source+policy before structural staging.
## Frozen Composer differs only by class_name removal and one dependency redirect.
const Builder = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const SOURCE := "res://scripts/buildings/CitadelUrbanPocComposer.gd"
const MIRROR := "res://artifacts/citadel-runtime-integration/facade-input-capture-source-03/Composer.gd"
const STUB := "res://artifacts/citadel-runtime-integration/facade-input-capture-source/StructuralInputCapture.gd"
const SEED := 541151883
const CONTEXT := {"biome":"forest","siteKey":"citadel-site-v1:14:atlas-30895044:-1,0","citadelScale":1.25}
var output := ""
var deadline := 0
var stage := ""
var stopped := false
var callbacks := 0
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	output=OS.get_environment("FACADE_STRUCTURAL_INPUT_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	deadline=Time.get_ticks_msec()+100000
	var checks: Dictionary={}
	var original := FileAccess.get_file_as_string(SOURCE).replace("\r\n","\n")
	var expected := original.replace("class_name CitadelUrbanPocComposer\n","").replace(
		'preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")','preload("'+STUB+'")')
	checks.exact_offline_transform=expected.strip_edges()==FileAccess.get_file_as_string(MIRROR).replace("\r\n","\n").strip_edges()
	var hashes := _hashes()
	var started := Time.get_ticks_usec()
	var built := Builder.build_with_diagnostics(SEED,CONTEXT,_continue)
	checks.builder_ready=built.get("blueprint")!=null
	var result: Dictionary={}
	if checks.builder_ready and checks.exact_offline_transform:
		var mirror = load(MIRROR)
		result=mirror.compose_prepared(built.blueprint,SEED,_continue)
	var path := output.get_base_dir().path_join("input.bin")
	checks.capture_exists=FileAccess.file_exists(path)
	checks.deliberately_not_ready=result.get("ready")==false and result.get("reason")=="cancelled"
	checks.reached_ordinary_structural_entry=stage=="structural_completion_prepare_started"
	checks.source_deadline=not stopped and Time.get_ticks_msec()<deadline
	var counts := {}
	if checks.capture_exists:
		var file := FileAccess.open(path,FileAccess.READ)
		var value: Dictionary=file.get_var(false); file.close()
		checks.source_and_policy_captured=value.get("blueprint") is Dictionary and value.get("policy") is Dictionary
		counts={"parts":value.blueprint.parts.size(),"furniture":value.policy.furnitureParts.size(),"reservedVolumes":value.policy.reservedVolumes.size(),"protectedObstacles":value.policy.protectedObstacles.size()}
	var after := _hashes()
	checks.source_hashes_valid=hashes.values().all(func(value): return String(value).length()==64)
	checks.sources_unchanged=hashes==after
	var report := {"passed":checks.values().all(func(v): return v==true),"checks":checks,"seed":SEED,"context":CONTEXT,
		"counts":counts,"elapsedUsec":Time.get_ticks_usec()-started,"callbacks":callbacks,"sourceHashesBefore":hashes,"sourceHashesAfter":after,
		"inputSha256":FileAccess.get_sha256(path) if checks.capture_exists else "",
		"scope":"Offline entry interception capture only. Real preceding recipe and furniture policy, no structural preparation, ready source, admission, terrain, publication or gameplay acceptance."}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t",true,true)); file.flush()
	var saved := file.get_error()==OK; file.close()
	quit(0 if saved and report.passed else 1)
func _continue(label: String) -> bool:
	stage=label; callbacks+=1
	stopped=stopped or Time.get_ticks_msec()>=deadline
	return not stopped
func _hashes() -> Dictionary:
	var result: Dictionary={}
	var pending: Array[String]=[get_script().resource_path,SOURCE,STUB]
	var regex := RegEx.create_from_string("[\"'](res://[^\"'\\r\\n]+)[\"']")
	while not pending.is_empty():
		var path: String=pending.pop_back()
		if result.has(path): continue
		result[path]=FileAccess.get_sha256(path)
		for match_value: RegExMatch in regex.search_all(FileAccess.get_file_as_string(path)):
			var dependency := match_value.get_string(1)
			if dependency.get_extension() in ["gd","gdshader"]: pending.append(dependency)
	return result
