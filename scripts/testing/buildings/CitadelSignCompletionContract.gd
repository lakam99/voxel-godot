extends SceneTree
## Direct source-stage contracts; no live publication or gameplay proof.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Complete = preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const Manifest = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
var checks := {}
func _initialize(): call_deferred("run")
func read_bound(key: String) -> Dictionary:
	var path := OS.get_environment(key)
	if not path.is_absolute_path() or FileAccess.get_sha256(path) != OS.get_environment(key+"_SHA"): return {}
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null or file.get_length() > 32*1024*1024: return {}
	var value: Variant = file.get_var(false)
	file.close()
	return value if value is Dictionary else {}
func run():
	var output := OS.get_environment("SIGN_COMPLETION_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	var reference := read_bound("SIGN_COMPLETION_REFERENCE")
	var final := read_bound("SIGN_COMPLETION_FINAL")
	if reference.is_empty() or not final.get("ready",false): quit(2); return
	var started := Time.get_ticks_usec()
	var phase := OS.get_environment("SIGN_COMPLETION_PHASE")
	if phase not in ["final_old","final_new","initial","blocked"]: quit(2); return
	var source = Copy.copy_blueprint(final.afterSnapshot if phase=="final_new" else reference.handoff.blueprint)
	var records := Manifest.read(source)
	if not records.ready: quit(2); return
	var obstacle := AABB(Vector3.ONE*-10000,Vector3.ONE*20000)
	var evidence := {}
	print("SIGN COMPLETION begin ",phase)
	if phase.begins_with("final_"):
		var physical := Complete._physical(source)
		if not physical.ready: quit(2); return
		checks.generic_physical_report_clear = physical.failedIds.is_empty()
		print("SIGN COMPLETION physical finished ",Time.get_ticks_usec()-started)
		var frozen := var_to_bytes(physical.proof.snapshot())
		var verified := Complete._verify_final_signs(physical.proof,records.records,[])
		checks.expected_final_verdict = verified.ready if phase=="final_new" else not verified.ready and verified.reason=="final_sign_source_invalid"
		checks.verification_never_commits = frozen==var_to_bytes(physical.proof.snapshot())
		evidence["verdict"] = verified.get("reason","ready")
		if phase=="final_new":
			var obstruction := Complete._verify_final_signs(physical.proof,records.records,[obstacle])
			checks.final_guard_rejects_new_protected_obstruction = not obstruction.ready and obstruction.reason=="final_sign_source_invalid" and frozen==var_to_bytes(physical.proof.snapshot())
	else:
		var frozen := var_to_bytes(source.snapshot())
		var stage := Complete._complete_signs(source,records.records,[obstacle] if phase=="blocked" else [])
		evidence = stage
		if phase=="initial":
			checks.every_sign_checked_including_generic_passes = stage.ready and stage.attempts==14 and stage.acceptedIds.size()==1 and stage.preservedIds.size()==13
		else:
			checks.unresolved_sign_is_explicit_failure = not stage.ready and stage.reason=="sign_initial_placement_unresolved" and not stage.pending.is_empty()
			checks.no_commit_when_every_sign_blocked = frozen==var_to_bytes(source.snapshot())
	checks.inputs_remain_hash_bound = not read_bound("SIGN_COMPLETION_REFERENCE").is_empty() and not read_bound("SIGN_COMPLETION_FINAL").is_empty()
	var report := {"passed":checks.values().all(func(value):return value==true),"phase":phase,"checks":checks,"evidence":evidence,"elapsedUsec":Time.get_ticks_usec()-started,"scope":"Direct source orchestration phase only; all four phases required. No fresh complete recipe, rendering, physics, runtime publication or gameplay acceptance."}
	var file := FileAccess.open(output,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("SIGN COMPLETION ",report.passed," ",checks)
	quit(0 if report.passed else 1)
