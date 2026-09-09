extends SceneTree
const Recipe = preload("res://scripts/buildings/LowerFacadeBearingRecipe.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var path := "res://artifacts/citadel-runtime-integration/candidate-recipe-27/source.bin"
	if FileAccess.get_sha256(path)!="03c75d895c82bd7a2ba8093b619f1715a02a2d03d7fdd7af5889c81398f19a37": quit(2);return
	var source: Dictionary=FileAccess.open(path,FileAccess.READ).get_var(false)
	var context: Dictionary=Recipe._build_root_context(Copy.copy_blueprint(source.blueprint))
	if not context.ready: quit(2);return
	var roots=Copy.copy_blueprint(context.context.rootSnapshot)
	var candidates: Array=source.blueprint.parts.filter(func(p):return p.semantic=="lower_facade_bearing")
	var checks := {}
	var timings := []
	for i in range(mini(3,candidates.size())):
		var additions: Array=[candidates[i].duplicate(true)]
		var body_id: String=candidates[i].id
		for record: Dictionary in source.blueprint.parts:
			if record.id.begins_with(body_id+"_connection_"): additions.append(record.duplicate(true))
		var panel_id: String=body_id.trim_suffix("_lower_bearing")
		var panel_record: Dictionary=source.blueprint.parts.filter(func(p):return p.id==panel_id)[0]
		var panel=Part.new(panel_record)
		var plain=Copy.copy_blueprint(roots.snapshot())
		for record: Dictionary in additions: plain.add_part(record)
		plain.add_part(panel.snapshot())
		Copy.clear_caches(plain)
		var fast=Recipe._assembly_proof(roots,additions,panel)
		var start:=Time.get_ticks_usec()
		var expected: Dictionary=plain.validate_physical_integrity()
		var old_usec:=Time.get_ticks_usec()-start
		start=Time.get_ticks_usec()
		var actual: Dictionary=fast.validate_once()
		timings.append({"oldUsec":old_usec,"newUsec":Time.get_ticks_usec()-start,"reused":fast.reused_count,"roots":roots.parts.size()})
		checks[str(i)+"_exact_report"]=var_to_bytes(expected)==var_to_bytes(actual)
		checks[str(i)+"_exact_snapshot"]=var_to_bytes(plain.snapshot())==var_to_bytes(fast.snapshot())
		checks[str(i)+"_reused"]=fast.reused_count>0
		checks[str(i)+"_cache_released"]=fast.reusable.is_empty()
		var cancelled=Recipe._assembly_proof(roots,additions,panel)
		var cancellation: Dictionary=cancelled.validate_once(func(_stage):return false)
		checks[str(i)+"_cancelled_and_released"]=cancellation.get("cancelled",false) and cancelled.reusable.is_empty()
		var rotated=Part.new(panel.snapshot())
		rotated.rotation.y=0.2
		checks[str(i)+"_rotated_fallback"]=Recipe._assembly_proof(roots,additions,rotated).reusable.is_empty()
		var target=roots.parts.filter(func(p):return p.physical_intent=="structural_mass" and p.recipe.has("physicalSupportCoverage"))[0]
		var near=Part.new({"id":"near_invalidation","kind":"beam","position":target.recipe.physicalSupportCoverage[0].position,"size":Vector3.ONE})
		var invalidated=Recipe._assembly_proof(roots,[],near)
		checks[str(i)+"_near_member_invalidates"]=not invalidated.reusable.has(invalidated.parts.filter(func(p):return p.id==target.id)[0])
	var file:=FileAccess.open(OS.get_environment("LOWER_REUSE_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed":not checks.is_empty() and not checks.values().has(false),"checks":checks,"timings":timings,"scope":"Full masonry-root differential with three captured assemblies; not gameplay."},"\t"));file.close()
	quit(0 if not checks.is_empty() and not checks.values().has(false) else 1)
