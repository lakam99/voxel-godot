extends SceneTree
const Current = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var old_script = load("res://artifacts/citadel-runtime-integration/support-query-baseline/BuildingBlueprint.gd")
	var input := "res://artifacts/citadel-runtime-integration/candidate-recipe-26/source.bin"
	if FileAccess.get_sha256(input) != "7c2047c45b51f05dbd99c4747c9bde63c8184eb50140c5b46af2bb67179ca70e": quit(2); return
	var source: Dictionary = FileAccess.open(input,FileAccess.READ).get_var(false)
	var results := []
	for script in [old_script, Current]:
		var b = script.new(source.blueprint.id, source.blueprint.seed, source.blueprint.style)
		b.recipe = source.blueprint.recipe.duplicate(true)
		b.rooms = source.blueprint.rooms.duplicate(true)
		var copied = Copy.copy_blueprint(source.blueprint)
		b.parts = copied.parts
		var started := Time.get_ticks_usec()
		var report: Dictionary = b.validate_physical_integrity()
		results.append({"usec":Time.get_ticks_usec()-started,"report":report,"snapshot":b.snapshot()})
	var checks := {"report_exact":var_to_bytes(results[0].report)==var_to_bytes(results[1].report),"snapshot_exact":var_to_bytes(results[0].snapshot)==var_to_bytes(results[1].snapshot),"physical_passed":results[1].report.passed}
	var file := FileAccess.open(OS.get_environment("SUPPORT_QUERY_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed":not checks.values().has(false),"checks":checks,"baselineUsec":results[0].usec,"candidateUsec":results[1].usec,"scope":"Pinned full-source physical differential; not gameplay acceptance."},"\t")); file.close()
	quit(0 if not checks.values().has(false) else 1)

