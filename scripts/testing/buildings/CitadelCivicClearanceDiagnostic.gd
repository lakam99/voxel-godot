extends SceneTree
## Offline actual captured source and actual furniture regeneration. No replay
## is injected into the game; this is not terminal-source/spawn acceptance.
const Civic = preload("res://scripts/buildings/CivicHouseInfillRecipe.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/facade-input-capture-03/input.bin"
const INPUT_SHA := "1935cc9ecab553c91c453f2a8ac715e90062fc363a244d880b153a5af9d66f2c"
const FAILURE := "res://artifacts/citadel-runtime-integration/candidate-recipe-16/failure.bin"
const FAILURE_SHA := "d29a3150a9d5f79b022b3ab00a5988d32952b9a1c9f2775cc2d3102d2580d792"
var deadline := 0
var checks: Dictionary = {}
class SnapshotProbe:
	var calls := 0
	func snapshot() -> Dictionary:
		calls+=1
		return {"syntheticSnapshotProbe":true}
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("CITADEL_CIVIC_CLEARANCE_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	deadline=Time.get_ticks_msec()+45000
	checks.pinned_inputs=FileAccess.get_sha256(INPUT)==INPUT_SHA and FileAccess.get_sha256(FAILURE)==FAILURE_SHA
	if not checks.pinned_inputs: quit(2); return
	var hashes := _hashes()
	var input: Dictionary=_read(INPUT)
	var failure: Dictionary=_read(FAILURE)
	var source=Copy.copy_blueprint(input.blueprint)
	var frozen := var_to_bytes(source.snapshot())
	var prepared: Dictionary=Urban.prepare_furnishings(source,541151883)
	checks.actual_furniture_ready=prepared.get("ready",false)
	if not checks.actual_furniture_ready: quit(2); return
	var furniture=prepared.furnishingPlan
	checks.exact_captured_furnishing_parts=var_to_bytes(furniture.snapshot().parts)==var_to_bytes(input.policy.furnitureParts)
	var ground_y: float=source.recipe.get("foundationHeight",0.62)
	var actual: Dictionary=Civic.validate_composed(source,failure.civicInfill,furniture,ground_y,_continue)
	# Run01 disproved the initial reproduction hypothesis. Pin that observed
	# stage boundary explicitly: this archive passes, the later Recipe16 fails.
	checks.prestructural_gate_passes=actual.get("ready",false)
	var memberships: Dictionary=Copy.street_house_memberships(source)
	checks.membership_ready=memberships.get("ready",false)
	var rows: Array=[]
	if checks.membership_ready:
		for spec: Dictionary in failure.civicInfill.specs:
			var house: Dictionary=memberships.houses.filter(func(value):return value.prefix==spec.id)[0]
			var own=Copy.copy_blueprint(source.snapshot())
			own.parts=own.parts.filter(func(part):return house.memberIds.has(part.id))
			own.rooms=own.rooms.filter(func(room):return room.id==house.roomId)
			var shape: Dictionary=Civic._house_geometry(own)
			if not shape.ready: checks.geometry_ready=false;continue
			var envelope: AABB=shape.bounds
			for furnishing in furniture.parts:
				if furnishing.room_id==house.roomId: envelope=envelope.merge(Civic.Frame.furnishing_bounds(furnishing.snapshot()).bounds)
			var blockers: Array=[]
			for part in source.parts:
				if house.memberIds.has(part.id) or Civic.compatible_underlay(part,ground_y):continue
				_add(blockers,envelope,source.transformed_part_bounds(part),"part",part.id)
			for room: Dictionary in source.rooms:
				if room.id==house.roomId:continue
				if room.get("role","")!="courtyard" and room.get("bounds") is AABB:_add(blockers,envelope,room.bounds,"room",room.id)
				for box: AABB in Civic.Interior.circulation_reservations([room]):_add(blockers,envelope,box,"room_access",room.id)
			for index in range(furniture.protected_access_reservations.size()):
				_add(blockers,envelope,furniture.protected_access_reservations[index],"plan_reservation",str(index))
			for furnishing in furniture.parts:
				if furnishing.room_id==house.roomId:continue
				_add(blockers,envelope,Civic.Frame.furnishing_bounds(furnishing.snapshot()).bounds,"furnishing",furnishing.id)
			rows.append({"house":spec.id,"envelope":envelope,"sameReportedBounds":envelope==failure.civicClearanceFailure.get("bounds"),"blockers":blockers,"ownRoom":own.rooms[0]})
	checks.same_failed_house_envelope=rows.any(func(row):return row.house==failure.civicClearanceFailure.house and row.sameReportedBounds)
	checks.no_prestructural_blockers=rows.size()==2 and rows.all(func(row):return row.blockers.is_empty())
	# Explicit mock instrumentation unit only: overflow must not materialize
	# snapshots which will immediately be discarded by the bounded evidence cap.
	var probe := SnapshotProbe.new()
	var bounded := {"rows":[],"count":0,"counts":{},"truncated":false,"limit":32}
	for index in range(40):Civic._append_clearance_evidence(bounded,{"kind":"mock","id":str(index)},probe)
	checks.synthetic_snapshot_allocations_bounded=probe.calls==32 and bounded.count==40 and bounded.rows.size()==32 and bounded.truncated
	var controls: Array=[]
	for count: int in [1,33]:
		var trial=Copy.copy_blueprint(source.snapshot())
		for index in range(count):
			trial.add_part({"id":"synthetic_foreign_blocker_%d"%index,"kind":"decor","collision":false,"position":rows[0].envelope.get_center(),"size":Vector3.ONE})
		var blocked: Dictionary=Civic.validate_composed(trial,failure.civicInfill,furniture,ground_y,_continue)
		var measured: Dictionary=blocked.get("blockingEvidence",{})
		checks["synthetic_"+str(count)+"_rejected"]=not blocked.get("ready",true) and blocked.get("reason")=="composed_civic_clearance_failed"
		checks["synthetic_"+str(count)+"_evidence_exact"]=measured.get("count")==count and measured.get("rows",[]).size()==mini(count,32) and measured.get("truncated")== (count>32)
		checks["synthetic_"+str(count)+"_identified"]=measured.get("rows",[]).all(func(row):return row.kind=="part" and String(row.id).begins_with("synthetic_foreign_blocker_"))
		var house: Dictionary=memberships.houses.filter(func(value):return value.prefix==failure.civicClearanceFailure.house)[0]
		checks["synthetic_"+str(count)+"_evidence_cancellation"]=Civic._clearance_failure_evidence(trial,house,furniture,rows[0].envelope,ground_y,func(_stage:String)->bool:return false)=={"cancelled":true}
		controls.append({"syntheticCount":count,"failure":blocked})
	checks.source_immutable=frozen==var_to_bytes(source.snapshot())
	checks.hashes_unchanged=hashes==_hashes()
	checks.hashes_valid=hashes.values().all(func(value):return String(value).length()==64)
	checks.deadline=Time.get_ticks_msec()<deadline
	var report := {"passed":checks.values().all(func(value):return value==true),"checks":checks,"sourceHashes":hashes,
		"actual":actual,"rows":rows,"syntheticEvidenceControls":controls,"furnishingCount":furniture.parts.size(),"reservationCount":furniture.protected_access_reservations.size(),
		"scope":"Pinned pre-structural source, exact regenerated furniture and measured clearance blockers. Not complete terminal blockers, remedy acceptance, publication or gameplay."}
	var file := FileAccess.open(output.get_basename()+".bin",FileAccess.WRITE)
	if file==null:quit(2);return
	file.store_var(report,false);file.close()
	file=FileAccess.open(output,FileAccess.WRITE)
	if file==null:quit(2);return
	file.store_string(JSON.stringify(report,"\t",true,true));file.close()
	quit(0 if report.passed else 1)
func _add(rows: Array, envelope: AABB, bounds: AABB, kind: String, id: String) -> void:
	if Civic.Placement._axis_overlap(envelope,bounds,0,Civic.CLEARANCE) and Civic.Placement._axis_overlap(envelope,bounds,1,0) and Civic.Placement._axis_overlap(envelope,bounds,2,Civic.CLEARANCE):
		rows.append({"kind":kind,"id":id,"bounds":bounds})
func _continue(_stage: String="") -> bool:return Time.get_ticks_msec()<deadline
func _read(path: String) -> Dictionary:
	var file:=FileAccess.open(path,FileAccess.READ);var value: Dictionary=file.get_var(false);file.close();return value
func _hashes() -> Dictionary:
	var result: Dictionary={};var pending: Array[String]=[get_script().resource_path,"res://tools/run-building-contract.mjs","res://project.godot"]
	var regex:=RegEx.create_from_string('["\'](res://[^"\'\\r\\n]+)["\']')
	while not pending.is_empty():
		var path: String=pending.pop_back()
		if result.has(path):continue
		result[path]=FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
		if path.get_extension()!="gd":continue
		for match_value: RegExMatch in regex.search_all(FileAccess.get_file_as_string(path)):
			var dep: String=match_value.get_string(1)
			if dep.get_extension() in ["gd","gdshader"]:pending.append(dep)
	return result
