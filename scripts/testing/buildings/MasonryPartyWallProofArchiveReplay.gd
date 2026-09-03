extends SceneTree

## Historical typed source/plan replay. Never injects a fixture into runtime.
const Recipe = preload("res://scripts/buildings/MasonryPartyWallBearingRecipe.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const INPUT := "res://artifacts/citadel-visual-reset/household-sign-current-candidate-19/candidate.bin"
const INPUT_SHA := "7e9dae37309cdc1e7637c0769df20da9b96a6c6e66c9a7a3731617dc266e0afe"
const EXPECTED := "res://artifacts/citadel-visual-reset/masonry-party-wall-current-candidate-10/candidate.bin"
const EXPECTED_SHA := "c5c1cb9fffe3016e4d5a27b6d0ab8683db61e4b2066d4cda34906e293d3b43dc"
var deadline := 0
var checks: Dictionary={}
var evidence: Dictionary={}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("PARTY_WALL_ARCHIVE_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	deadline=Time.get_ticks_msec()+30000
	var thread := Thread.new()
	if thread.start(_work)!=OK: quit(2); return
	while thread.is_alive(): await process_frame
	var report: Dictionary=thread.wait_to_finish()
	var file := FileAccess.open(output.get_basename()+".bin",FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_var(report,false); file.flush(); file.close()
	file=FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.flush()
	var saved := file.get_error()==OK
	file.close()
	print("Party wall historical replay passed=",report.passed," checks=",checks.size())
	quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var start := Time.get_ticks_usec()
	var hash_before := FileAccess.get_sha256("res://scripts/buildings/MasonryPartyWallBearingRecipe.gd")
	_exercise()
	checks["recipe_unchanged"]=hash_before==FileAccess.get_sha256("res://scripts/buildings/MasonryPartyWallBearingRecipe.gd")
	checks["deadline"]=Time.get_ticks_msec()<deadline
	return {"passed":checks.values().all(func(v):return v==true),"checks":checks,"evidence":evidence,
		"elapsedUsec":Time.get_ticks_usec()-start,"recipeSha256":hash_before,"inputSha256":INPUT_SHA,"expectedSha256":EXPECTED_SHA,
		"scope":"Historical source-only exact plan and resulting blueprint comparison; not final physical, runtime, rendering or gameplay acceptance."}

func _exercise() -> void:
	checks["archive_hashes"]=FileAccess.get_sha256(INPUT)==INPUT_SHA and FileAccess.get_sha256(EXPECTED)==EXPECTED_SHA
	if not checks.archive_hashes: return
	var raw: Dictionary=bytes_to_var(FileAccess.get_file_as_bytes(INPUT))
	var expected: Dictionary=bytes_to_var(FileAccess.get_file_as_bytes(EXPECTED))
	var history: Dictionary=expected.candidateHistory.back()
	var source = Copy.copy_blueprint(raw.afterSnapshot)
	var seats: Dictionary={}
	for change: Dictionary in history.changes: seats[change.seatId]=true
	checks["one_archived_seat"]=seats.size()==1
	for id: String in seats:
		checks["same_declared_seat_capability"]=Recipe.declare_party_wall_seat(source.find_part(id),true)
	var frozen := var_to_bytes(source.snapshot())
	var prepared := Recipe.prepare_context(source,_continue)
	evidence["preparedReady"]=prepared.ready
	checks["context_ready"]=prepared.ready
	if not prepared.ready: evidence.failure=prepared; return
	var plan := Recipe.plan(source,history.declarationKey,prepared.context,_continue)
	evidence["plan"]=plan
	checks["plan_ready"]=plan.ready
	if not plan.ready: return
	checks["historical_changes_byte_exact"]=var_to_bytes(plan.changes)==var_to_bytes(history.changes)
	checks["historical_target_ids_byte_exact"]=var_to_bytes(plan.targetIds)==var_to_bytes(history.targetIds)
	checks["source_immutable_during_plan"]=frozen==var_to_bytes(source.snapshot())
	checks["independent_proof_retained"]=prepared.context.independent_validations==1
	var applied := Recipe.apply_plan(source,plan)
	checks["applied"]=applied.ready
	checks["historical_resulting_blueprint_byte_exact"]=var_to_bytes(source.snapshot())==var_to_bytes(expected.afterSnapshot)
	checks["old_context_stale_after_apply"]=Recipe._context_valid(source,prepared.context).get("reason")=="stale_party_wall_source_proof"
	checks["archives_unchanged"]=FileAccess.get_sha256(INPUT)==INPUT_SHA and FileAccess.get_sha256(EXPECTED)==EXPECTED_SHA

func _continue(_stage: String) -> bool: return Time.get_ticks_msec()<deadline
