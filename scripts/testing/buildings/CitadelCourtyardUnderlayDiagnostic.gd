extends SceneTree

## Pinned source/cached-fact diagnosis only; not full recipe or gameplay proof.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Civic = preload("res://scripts/buildings/CivicHouseInfillRecipe.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/facade-input-capture-03/input.bin"
const INPUT_SHA := "1935cc9ecab553c91c453f2a8ac715e90062fc363a244d880b153a5af9d66f2c"
const FAILURE := "res://artifacts/citadel-runtime-integration/candidate-recipe-17/failure.bin"
const FAILURE_SHA := "bec29f97da604a4a5efc4872179d01da84ea39aa2324a60b296b8e40044f5517"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("CITADEL_UNDERLAY_DIAGNOSTIC_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	var checks := {"input_hash":FileAccess.get_sha256(INPUT)==INPUT_SHA,"failure_hash":FileAccess.get_sha256(FAILURE)==FAILURE_SHA}
	if not checks.values().all(func(value):return value): quit(2); return
	var input: Dictionary = _read(INPUT)
	var failure: Dictionary = _read(FAILURE)
	var source = Copy.copy_blueprint(input.blueprint)
	var frozen := var_to_bytes(source.snapshot())
	var working = Copy.copy_blueprint(source.snapshot())
	Copy.clear_caches(working)
	var evidence: Dictionary = failure.civicClearanceFailure
	var envelope: AABB = evidence.bounds
	var footprint := Rect2(Vector2(envelope.position.x,envelope.position.z),Vector2(envelope.size.x,envelope.size.z))
	var rows: Array = []
	var support_rects: Array[Rect2]=[]
	var area := 0.0
	checks.exact_four_recorded_blockers = evidence.blockingEvidence.count==4 and evidence.blockingEvidence.rows.size()==4 and not evidence.blockingEvidence.truncated
	for row: Dictionary in evidence.blockingEvidence.rows:
		var originals: Array = source.parts.filter(func(part):return part.id==row.id)
		var cleaned: Array = working.parts.filter(func(part):return part.id==row.id)
		checks[row.id+"_present"] = originals.size()==1 and cleaned.size()==1
		if originals.size()!=1 or cleaned.size()!=1: continue
		var before = originals[0]
		var after = cleaned[0]
		checks[row.id+"_historical_root_before"] = before.recipe.get("physicalRoot")==true
		checks[row.id+"_root_cache_removed"] = before.recipe.get("physicalRoot")==true and not after.recipe.has("physicalRoot")
		checks[row.id+"_rejected_after"] = not Civic.compatible_underlay(after,0.62)
		checks[row.id+"_matches_terminal_record"] = var_to_bytes(after.snapshot())==var_to_bytes(row.part)
		var bounds: AABB = source.transformed_part_bounds(before)
		checks[row.id+"_geometry_unchanged"] = bounds==working.transformed_part_bounds(after) and bounds==row.bounds
		checks[row.id+"_foundation_height"] = bounds.position.y==0.0 and bounds.end.y==Vector3(0,0.62,0).y
		var overlap := footprint.intersection(Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z)))
		support_rects.append(Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z)))
		checks[row.id+"_positive_xz_support"] = overlap.has_area()
		area += overlap.get_area()
		rows.append({"id":row.id,"overlap":overlap,"before":before.snapshot(),"after":after.snapshot()})
	checks.footprint_area_covered = absf(area-footprint.get_area())<0.001
	var union_coverage := Civic.Support.covers(footprint,support_rects,Callable())
	checks.exact_support_union_covered=union_coverage.get("ready",false)
	checks.source_immutable = frozen==var_to_bytes(source.snapshot())
	var report := {"passed":checks.values().all(func(value):return value==true),"checks":checks,"rows":rows,"house":evidence.house,"envelope":envelope,"overlapAreaSum":area,"footprintArea":footprint.get_area(),"unionCoverage":union_coverage,"scope":"Frozen pre-structural source and actual cache sanitation reproduce recorded terminal foundation records. No remedy, complete recipe, publication, visuals or gameplay acceptance."}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null:quit(2);return
	file.store_string(JSON.stringify(report,"  ",true,true))
	file.flush()
	var saved := file.get_error()==OK
	file.close()
	print("Courtyard underlay diagnostic checks=",checks.size()," passed=",report.passed)
	quit(0 if saved and report.passed else 1)

func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path,FileAccess.READ)
	var result: Dictionary=file.get_var(false)
	file.close()
	return result
