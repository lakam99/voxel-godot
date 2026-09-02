extends SceneTree
## Synthetic source-adapter tests. No world publication or gameplay claims.
const C = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const B = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
var checks = {}
func _initialize(): call_deferred("run")
func source():
	var b = B.new("adapter",1,"stone")
	b.add_part({"id":"paving","kind":"foundation","semantic":"castle_courtyard_paving","position":Vector3(0,0.7,0),"size":Vector3(2,0.2,2)})
	return b
func roots() -> Array:
	return [{"id":"old","kind":"foundation","collision":true,"position":Vector3(0,0.5,0),"rotation":Vector3.ZERO,"size":Vector3(2,1,2),"recipe":{}}]
func rejected(name: String,b,obstacles: Array,reason: String):
	var frozen = var_to_bytes(b.snapshot())
	var r = C.prepare_retained_paving(b,roots(),obstacles)
	checks[name] = not r.ready and r.get("reason","") == reason and frozen==var_to_bytes(b.snapshot()) and not r.has("afterSnapshot")
func commit_rejected(name: String,b,snapshot: Dictionary):
	var frozen = var_to_bytes(b.snapshot())
	var r = C._commit_retained_paving(b,snapshot)
	checks[name] = not r.ready and frozen==var_to_bytes(b.snapshot())
func run():
	var output = OS.get_environment("CITADEL_PAVING_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	var b = source(); var frozen = var_to_bytes(b.snapshot()); var original = b.parts[0]
	var r = C.prepare_retained_paving(b,roots(),[])
	checks.valid_recipe = r.ready and r.get("emitted",[]).size()==1 and var_to_bytes(b.snapshot())==frozen
	if r.ready:
		var forged = r.afterSnapshot.duplicate(true); forged.parts[0].position.x += 1
		commit_rejected("forged_prefix_atomic",b,forged)
		forged = r.afterSnapshot.duplicate(true); forged.parts[1].id = forged.parts[0].id
		commit_rejected("duplicate_append_atomic",b,forged)
		forged = r.afterSnapshot.duplicate(true); forged.recipe["fake"] = true
		commit_rejected("changed_recipe_atomic",b,forged)
		forged = r.afterSnapshot.duplicate(true); forged.rooms.append({"id":"fake"})
		commit_rejected("changed_rooms_atomic",b,forged)
		checks.commit_exact = C._commit_retained_paving(b,r.afterSnapshot).ready and var_to_bytes(b.snapshot())==var_to_bytes(r.afterSnapshot) and b.parts[0]==original
		var again = C.prepare_retained_paving(b,roots(),[])
		checks.noop_exact = again.ready and again.unchanged and var_to_bytes(again.afterSnapshot)==var_to_bytes(b.snapshot())
	rejected("malformed_furniture",source(),[{}],"invalid_retained_paving_furnishing")
	rejected("invalid_furniture_bounds",source(),[{"bounds":AABB()}],"invalid_retained_paving_reserved_volume")
	rejected("protected_void_no_support",source(),[{"bounds":AABB(Vector3(-2,-1,-2),Vector3(4,3,4))}],"no_retired_bearing_volume")
	var bad = source(); bad.rooms.append({})
	rejected("missing_room_bounds",bad,[],"invalid_retained_paving_room")
	bad = source(); bad.rooms.append({"bounds":AABB(Vector3(-2,0,-2),Vector3(4,3,4)),"accesses":[{}]})
	rejected("malformed_access",bad,[],"invalid_retained_paving_access")
	bad = source(); bad.rooms.append({"bounds":AABB(Vector3(-2,0,-2),Vector3(4,3,4)),"role":"courtyard","accesses":[{"position":Vector3.ZERO,"size":Vector3.ZERO}]})
	rejected("nonpositive_access",bad,[],"invalid_retained_paving_reserved_volume")
	for presentation in ["door","portcullis"]:
		var with_door = source()
		with_door.add_part({"id":"door","kind":"door","size":Vector3(2,3,0.18),"position":Vector3(10,1.5,0),"recipe":{"doorPresentation":presentation}})
		var dr = C.prepare_retained_paving(with_door,roots(),[])
		checks[presentation+"_sweep_supported"] = dr.ready
	bad = source(); bad.add_part({"id":"bad_door","kind":"door","position":Vector3(10,1,0),"recipe":{"openSwing":"bad"}})
	rejected("invalid_door_angle",bad,[],"invalid_retained_paving_door_angle")
	bad = source(); bad.add_part({"id":"bad_door","kind":"door","position":Vector3(10,1,0),"recipe":{"openSwing":INF}})
	rejected("nonfinite_door_angle",bad,[],"invalid_retained_paving_door")
	var report = {"passed":checks.values().all(func(v):return v==true),"checks":checks,"evidenceLevel":"synthetic source-adapter only"}
	var f = FileAccess.open(output,FileAccess.WRITE)
	if f==null: quit(2); return
	f.store_string(JSON.stringify(report,"\t")); f.flush()
	var written = f.get_error()==OK; f.close()
	print("COMPOSER ADAPTER ",report.passed," ",JSON.stringify(checks))
	quit(0 if written and report.passed else 1)
