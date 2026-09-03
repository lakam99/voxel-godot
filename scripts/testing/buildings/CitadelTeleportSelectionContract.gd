extends SceneTree
## Pure test-harness selection checks; never instantiates Main or a viewport.
const Runner = preload("res://scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
var checks: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var first := Field.candidate_for_region("atlas-30895044",Vector2i(0,-1))
	var second := Field.candidate_for_region("atlas-30895044",Vector2i(-1,0))
	var found: Array[Dictionary]=[{"candidate":first},{"candidate":second}]
	var before := var_to_bytes(found)
	checks.default_is_first=Runner.select_candidate(found,"")==first
	checks.explicit_first=Runner.select_candidate(found,"0,-1")==first
	checks.explicit_second=Runner.select_candidate(found,"-1,0")==second
	checks.nonmember_rejects=Runner.select_candidate(found,"1,1").is_empty()
	checks.empty_rejects=Runner.select_candidate([],"-1,0").is_empty()
	checks.existing_records_unchanged=before==var_to_bytes(found)
	for value: String in ["0",",","0,0,0"," 0,0","0,0 ","+1,0","01,0","-0,0","x,0","0.5,0","1048576,0","-1048577,0","999999999999999,0"]:
		checks["invalid:"+value]=not Runner.valid_region_request(value) and Runner.select_candidate(found,value).is_empty()
	for value: String in ["","0,0","-1,0","1048575,-1048576"]:
		checks["valid:"+value]=Runner.valid_region_request(value)
	var path := OS.get_environment("CITADEL_TELEPORT_SELECTION_OUTPUT")
	if not path.is_absolute_path() or FileAccess.file_exists(path): quit(2); return
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null: quit(2); return
	var passed := not checks.values().has(false)
	file.store_string(JSON.stringify({"passed":passed,"checks":checks,"checkCount":checks.size(),
		"evidenceLevel":"pure fixture selection contract, no Main instance or site eligibility",
		"runnerSha256":FileAccess.get_sha256("res://scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd")},"\t"))
	file.close()
	print("Citadel teleport selection checks=",checks.size()," passed=",passed)
	quit(0 if passed else 1)
