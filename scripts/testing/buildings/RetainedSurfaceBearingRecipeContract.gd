extends SceneTree
const Recipe = preload("res://scripts/buildings/RetainedSurfaceBearingRecipe.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
var checks = {}
func _initialize() -> void: call_deferred("run")
func fixture():
	var b = Blueprint.new("retained",123,"stone")
	b.add_part({"id":"surface","kind":"foundation","position":Vector3(0,0.7,0),"size":Vector3(2,0.2,2)})
	return b
func old_record(id: String = "old") -> Dictionary:
	return {"id":id,"kind":"foundation","position":Vector3(0,0.5,0),"rotation":Vector3.ZERO,"size":Vector3(2,1,2),"collision":true,"recipe":{}}
func rejected(name: String, b, retired: Array, ids: Array, voids: Array) -> void:
	var frozen = var_to_bytes(b.snapshot())
	var inputs = var_to_bytes([retired,ids,voids])
	var result = Recipe.prepare(b,retired,ids,voids)
	checks[name] = not result.ready and not result.has("afterSnapshot") and frozen == var_to_bytes(b.snapshot()) and inputs == var_to_bytes([retired,ids,voids])
func synthetic() -> Dictionary:
	var b = fixture()
	var frozen = var_to_bytes(b.snapshot())
	var r = Recipe.prepare(b,[old_record()],["surface"],[])
	checks.real_support = r.ready and r.get("emitted",[]).size() == 1 and r.get("afterChecks",[]).all(func(c):return c.passed)
	checks.input_unchanged = frozen == var_to_bytes(b.snapshot())
	var overlapping = fixture()
	var second_surface = overlapping.parts[0].snapshot(); second_surface.id = "surface_b"
	overlapping.add_part(second_surface)
	var shared = Recipe.prepare(overlapping,[old_record()],["surface","surface_b"],[])
	checks.overlapping_targets_share_one_bearing = shared.ready and shared.get("emitted",[]).size() == 1 and shared.get("selectedIds",[]).size() == 2 and shared.get("afterChecks",[]).all(func(c):return c.passed)
	var shared_reverse = Recipe.prepare(overlapping,[old_record()],["surface_b","surface"],[])
	checks.shared_targets_reverse_exact = shared.ready and shared_reverse.ready and var_to_bytes(shared.afterSnapshot) == var_to_bytes(shared_reverse.afterSnapshot)
	if r.ready:
		var again = Recipe.prepare(Copy.copy_blueprint(r.afterSnapshot),[old_record()],["surface"],[])
		checks.idempotent = again.ready and again.get("unchanged",false) and var_to_bytes(again.afterSnapshot) == var_to_bytes(r.afterSnapshot)
	var two = [old_record("z_old"),old_record("a_old")]
	var clipped = [AABB(Vector3(-1.0,0,-1),Vector3(0.3,0.6,2)),AABB(Vector3(0.8,0,0.7),Vector3(0.2,0.6,0.3))]
	var first = Recipe.prepare(b,two,["surface"],clipped)
	two.reverse(); clipped.reverse()
	var second = Recipe.prepare(b,two,["surface"],clipped)
	checks.order_independent = first.ready and second.ready and var_to_bytes(first.afterSnapshot) == var_to_bytes(second.afterSnapshot) and var_to_bytes(first.emitted) == var_to_bytes(second.emitted)
	rejected("full_void",b,[old_record()],["surface"],[AABB(Vector3(-2,-1,-2),Vector3(4,3,4))])
	var low = old_record(); low.position.y = 0.15; low.size.y = 0.3
	rejected("old_volume_too_short",b,[low],["surface"],[])
	var tilted = old_record(); tilted.rotation.y = 0.1
	rejected("unsupported_shape",b,[tilted],["surface"],[])
	var rotated = old_record(); rotated.rotation.y = PI*0.5
	var rotated_result = Recipe.prepare(b,[rotated],["surface"],[])
	checks.rotated_retired_solid_proven = rotated_result.ready and rotated_result.emitted.all(func(row):return Recipe.oriented_contains(Recipe.Part.new(rotated),Recipe.Part.new(row.part)))
	var outside = Recipe.Part.new(old_record()); outside.size.x += Recipe.EPS
	checks.strict_oriented_containment_rejects_eps_expansion = not Recipe.oriented_contains(Recipe.Part.new(old_record()),outside)
	rejected("thin_fragment_not_enlarged",b,[old_record()],["surface"],[AABB(Vector3(-1,0,-1),Vector3(1.99,0.6,2))])
	rejected("duplicate_retired",b,[old_record(),old_record()],["surface"],[])
	rejected("duplicate_target",b,[old_record()],["surface","surface"],[])
	rejected("bad_void",b,[old_record()],["surface"],[AABB()])
	rejected("missing_target",b,[old_record()],["absent"],[])
	var collision = fixture(); collision.add_part({"id":"surface_retained_bearing_000","kind":"decoration","collision":false,"position":Vector3(20,20,20)})
	rejected("id_collision",collision,[old_record()],["surface"],[])
	var dup = fixture(); dup.add_part(dup.parts[0].snapshot())
	rejected("duplicate_source",dup,[old_record()],["surface"],[])
	var enormous = fixture(); enormous.parts[0].size = Vector3(10000000,1,10000000)
	rejected("validation_grid_work_bounded",enormous,[old_record()],["surface"],[])
	var below = old_record("surviving_short"); below.position.y = 0.1; below.size.y = 0.2
	var short_source = fixture(); short_source.add_part(below)
	var high = Recipe.prepare(short_source,[old_record()],["surface"],[])
	checks.short_existing_root_does_not_erase_required_bearing = high.ready and high.get("emitted",[]).size() == 1
	var fragmented: Array = []
	for i in range(257): fragmented.append(Rect2(Vector2(i*2,0),Vector2.ONE))
	checks.fragment_work_bounded = not Recipe.subtract(fragmented,Rect2(Vector2(-5,-5),Vector2.ONE)).ready
	return {"first":r.get("reason",""),"orderReason":first.get("reason","")}
func run() -> void:
	var output = OS.get_environment("RETAINED_BEARING_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output):
		quit(2); return
	var started = Time.get_ticks_usec()
	var result = synthetic()
	var passed = checks.size()>0 and checks.values().all(func(v):return v==true)
	var report = {"passed":passed,"checks":checks,"elapsedUsec":Time.get_ticks_usec()-started,"result":result,
		"evidenceLevel":"synthetic source contract; no production composer or live gameplay"}
	var file = FileAccess.open(output,FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.flush()
	var written = file.get_error() == OK
	file.close()
	print("RETAINED BEARING CONTRACT ",passed," ",JSON.stringify(checks))
	quit(0 if passed and written else 1)
