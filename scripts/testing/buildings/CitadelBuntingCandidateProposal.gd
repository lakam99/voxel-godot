extends SceneTree
## Offline archived generated geometry only. Never injected into runtime.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Domain = preload("res://scripts/buildings/CitadelMarketBuntingDomain.gd")
const Anchor = preload("res://scripts/buildings/CitadelBuntingAnchorRecipe.gd")
const Structural = preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const Manifest = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/facade-input-capture-03/input.bin"
const SHA := "1935cc9ecab553c91c453f2a8ac715e90062fc363a244d880b153a5af9d66f2c"
var deadline := 0
var last_stage := ""
var output := ""
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	output = OS.get_environment("CITADEL_BUNTING_CANDIDATE_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.get_sha256(INPUT) != SHA: quit(2); return
	deadline = Time.get_ticks_msec()+90000
	var hashes := _hashes()
	var file := FileAccess.open(INPUT,FileAccess.READ)
	var input: Dictionary = file.get_var(false); file.close()
	var source = Copy.copy_blueprint(input.blueprint)
	var frozen := var_to_bytes(source.snapshot())
	var started := Time.get_ticks_usec()
	# Known producer association for this diagnostic only, not inferred by the
	# recipe helper and not an authored production placement/seed exception.
	var domain: Dictionary = Domain.build(source,"urban_row_02_left","urban_row_02_right","urban_market_plaza")
	var checks := {"domain_ready":domain.get("ready",false)}
	var result := {}
	var preserved := true
	if checks.domain_ready:
		var members: Array = []
		for index in range(13): members.append("urban_bunting_01_%02d"%index)
		var records := [{"ropeId":"urban_bunting_rope_01","pennantIds":members,"placementDomain":domain.domain}]
		var manifest: Dictionary = Manifest.read(source)
		checks.house_manifest_valid = manifest.get("ready",false)
		if checks.house_manifest_valid:
			var protected: Dictionary = Structural._protected_bounds(source,manifest.records,input.policy.protectedObstacles)
			checks.protected_bounds_valid = protected.get("ready",false)
			if checks.protected_bounds_valid:
				protected.bounds.append_array(domain.protectedRooms)
				result = Anchor.prepare(source,records,protected.bounds,_continue)
				checks.proposal_ready = result.get("ready",false)
				if checks.proposal_ready:
					var replacements := {}
					for record: Dictionary in result.changes: replacements[record.id] = record
					for part in source.parts:
						if replacements.has(part.id) and part.id != records[0].ropeId and not members.has(part.id): preserved=false
					checks.only_selected_assembly_changes = preserved
	checks.source_immutable = frozen == var_to_bytes(source.snapshot())
	checks.within_deadline = Time.get_ticks_msec() < deadline
	checks.hashes_valid = hashes.values().all(func(value): return String(value).length()==64)
	checks.source_hashes_unchanged = hashes == _hashes()
	var archive := {"inputPath":INPUT,"inputSha256":SHA,"domain":domain,"proposal":result}
	file = FileAccess.open(output.get_base_dir().path_join("proposal.bin"),FileAccess.WRITE)
	checks.archive_written = file != null
	if file != null:
		file.store_var(archive,false); file.flush(); checks.archive_written=file.get_error()==OK; file.close()
	result.erase("sourceBytes"); result.erase("changes")
	var report := {"passed":checks.values().all(func(value): return value==true),"checks":checks,
		"elapsedUsec":Time.get_ticks_usec()-started,"result":result,"domain":domain,"lastStage":last_stage,"sourceHashes":hashes,
		"scope":"Offline proposal on pinned pre-structural captured candidate. Rooted sockets and clearance only; remaining original structural failures, current-source generation, final physical gate, publication and visual appearance are not accepted."}
	file = FileAccess.open(output,FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report,"\t",true,true));file.flush();var saved:=file.get_error()==OK;file.close()
	quit(0 if saved and report.passed else 1)
func _continue(stage: String) -> bool:
	last_stage=stage
	return Time.get_ticks_msec()<deadline
func _hashes() -> Dictionary:
	var paths: Array[String]=[get_script().resource_path,"res://project.godot","res://tools/run-building-contract.mjs"]
	var hashes: Dictionary={}
	var regex := RegEx.create_from_string('["\'](res://[^"\'\\r\\n]+)["\']')
	while not paths.is_empty():
		var path: String=paths.pop_back()
		if hashes.has(path):continue
		hashes[path]=FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
		if path.get_extension() != "gd":continue
		for matched: RegExMatch in regex.search_all(FileAccess.get_file_as_string(path)):
			var dep: String=matched.get_string(1)
			if dep.get_extension() in ["gd","gdshader"]:paths.append(dep)
	return hashes
