extends SceneTree
## Synthetic direct-publication contracts; no live gameplay or GPU acceptance.
const Roof = preload("res://scripts/buildings/BuildingRoofPublication.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const History = preload("res://scripts/buildings/SurfaceHistoryField.gd")
const Descriptor = preload("res://scripts/buildings/MasonryDescriptorGeometry.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const BASELINE_COMMIT := "8ba83443bb9e5483c097907df24c7c54db1daa56"
const BASELINE_BLOB := "4ace02cdd674f9b35324f5d2cd3b11a571eca0e2"

class SyntheticHistory extends History:
	var exposure := 1.0
	func history_for(_part, _position: Vector3, _height: float, _stable: float) -> float:
		return exposure

class Collector extends RefCounted:
	var source_blueprint_id := "roof-contract-source"
	var surface_history = SyntheticHistory.new()
	var _prepared_history = null
	var static_visual_collecting := false
	var static_visual_part_transform := Transform3D.IDENTITY
	var unit_box := BoxMesh.new()
	var published_nodes: Array = []
	var visual_batch_count := 0
	var records: Array = []
	var materials: Dictionary = {}
	var stages: Dictionary = {}
	var failure := false
	var custom_calls := 0
	var batch_calls := 0
	var light_calls := 0
	var target: WeakRef
	var cancel_hook := ""
	var reject_hook := ""
	var after_cancel := 0
	var cancelled := false
	var history_binding: PackedByteArray
	func _init() -> void:
		surface_history.configure({"routeCorridors":[{"center":Vector3.ZERO,"span":Vector2(8,3)}]})
		history_binding=var_to_bytes(surface_history.route_corridors)
	func _publication_failed() -> bool: return failure
	func prepare_paving_history_snapshot(): return surface_history # Explicit synthetic history.
	func validate_paving_history_source() -> bool:
		return history_binding==var_to_bytes(surface_history.route_corridors)
	func _record_publication_stage(phase: String, _usec: int) -> void:
		stages[phase]=int(stages.get(phase,0))+1
	func hook(name: String) -> void:
		if cancelled: after_cancel+=1
		if reject_hook==name: failure=true
		if cancel_hook==name and target!=null:
			cancelled=true
			target.get_ref().cancel()
	func variation_for(part) -> float: return float(part.recipe.get("variation",0.0))
	func material_for(part) -> Material: return material_for_id(part.material_id,variation_for(part))
	func material_for_id(id: String, variation: float) -> Material:
		var key := str([id,variation])
		if not materials.has(key):
			var material := StandardMaterial3D.new()
			material.set_meta("contract_key",[id,variation])
			materials[key]=material
		return materials[key]
	func history_custom_data(position: Vector3) -> Color:
		return Descriptor.history_custom_data(position,surface_history)
	func append_instance(transform: Transform3D, material: Material, custom: Color) -> void:
		records.append(["instance",transform,material.get_meta("contract_key"),custom])
	func add_box_batch(_parent: Node3D, transforms: Array, material: Material, _name: String, custom: Array = []):
		batch_calls+=1
		for index in transforms.size():
			append_instance(static_visual_part_transform*transforms[index] if static_visual_collecting else transforms[index],material,custom[index])
		hook("batch")
		return null
	func collect_static_visual_transform(transform: Transform3D, material: Material, custom: Color) -> void:
		append_instance(transform,material,custom)
		hook("collect")
	func add_box_visual(_parent: Node3D, size: Vector3, position: Vector3, material: Material, name: String) -> void:
		records.append(["cap",name,size,position,material.get_meta("contract_key"),static_visual_part_transform])
		hook("eave" if name=="RoofEaveCourse" else "ridge")
	func create_mesh_batch() -> MultiMesh:
		return MultiMesh.new()
	func submit_mesh_batch_instance(mesh: MultiMesh, index: int, transform: Transform3D, custom: Color) -> void:
		# Real native submission; exact evidence comes from the submitted values,
		# not headless dummy MultiMesh buffer reads.
		mesh.set_instance_transform(index,transform)
		mesh.set_instance_custom_data(index,custom)
		var job = target.get_ref() if target!=null else null
		append_instance(transform,job._material,custom)
		hook("submit")
	func publish_practical_light(_part, _parent: Node3D) -> void:
		light_calls+=1
		hook("light")

# Frozen baseline functions below are copied verbatim (one extra indent) from
# the recorded Git blob. The contract checks them against Git before execution.
class FrozenOracle extends Collector:
	func publish_roof_shingles(part, parent: Node3D) -> void:
		var size: Vector3 = part.size
		var is_monumental := String(part.id).begins_with("castle_") or String(part.semantic).contains("civic")
		var course_run := 0.46 if is_monumental else 0.54
		var tile_span := 0.56 if is_monumental else 0.68
		var course_count := maxi(1, ceili(size.x / course_run))
		var tile_count := maxi(1, ceili(size.z / tile_span))
		var roof_phase := float(posmod((source_blueprint_id + ":roof:" + String(part.id)).hash(), 4093)) / 4093.0
		var left_slope := String(part.id).ends_with("_left") or String(part.id).contains("roof_left")
		var eave_sign := -1.0 if left_slope else 1.0
		var eave_x := eave_sign * size.x * 0.5
		var ridge_x := -eave_x
		var transforms: Array[Transform3D] = []
		var weathered_transforms: Array[Transform3D] = []
		for course_index in range(course_count):
			var course_t := (float(course_index) + 0.5) / float(course_count)
			var course_width := size.x / float(course_count)
			var row_offset := tile_span * 0.5 if course_index % 2 == 1 else 0.0
			row_offset += (fposmod(sin(float(course_index + 1) * 19.193 + roof_phase * 71.713) * 15731.743, 1.0) - 0.5) * tile_span * 0.18
			for tile_index in range(tile_count + 2):
				var slot_width := size.z / float(tile_count)
				var z := -size.z * 0.5 + slot_width * (float(tile_index) + 0.5) - row_offset
				var tile_start := maxf(-size.z * 0.5, z - slot_width * 0.5)
				var tile_end := minf(size.z * 0.5, z + slot_width * 0.5)
				if tile_end - tile_start < 0.08:
					continue
				z = (tile_start + tile_end) * 0.5
				var piece_noise := fposmod(sin(float(course_index + 1) * 41.17 + float(tile_index + 1) * 13.71 + roof_phase * 29.17) * 31991.37, 1.0)
				var secondary_noise := fposmod(sin(float(course_index + 1) * 11.73 + float(tile_index + 1) * 57.19 + roof_phase * 83.11) * 23171.31, 1.0)
				var x := lerpf(eave_x, ridge_x, course_t)
				var tile_size := Vector3(maxf(0.08, course_width * lerpf(1.04, 1.18, piece_noise)), size.y * lerpf(0.92, 1.16, secondary_noise), maxf(0.08, (tile_end - tile_start - 0.026) * lerpf(0.84, 1.0, piece_noise)))
				var tile_lift := (1.0 - course_t) * size.y * 0.52 + (piece_noise - 0.5) * 0.018
				var transform := Transform3D(Basis(Vector3.FORWARD, (secondary_noise - 0.5) * deg_to_rad(1.7)).scaled(tile_size), Vector3(x, tile_lift, z))
				var exposure := surface_history.history_for(part, part.position + transform.origin, course_t, piece_noise)
				if exposure > 0.58 and piece_noise > 0.78:
					weathered_transforms.append(transform)
				else:
					transforms.append(transform)
		var roof_material := material_for(part)
		add_box_batch(parent, transforms, roof_material, "RoofCourses", build_facade_custom_data(transforms, part))
		if not weathered_transforms.is_empty():
			add_box_batch(parent, weathered_transforms, material_for_id("roof_slate_weathered", variation_for(part) - 0.025), "RoofReplacementCourses", build_facade_custom_data(weathered_transforms, part))
		var cap_material := material_for_id("roof_slate_cap", variation_for(part) - 0.015)
		add_box_visual(parent, Vector3(0.18, maxf(0.10, size.y * 0.72), size.z + 0.14), Vector3(eave_x, size.y * 0.18, 0.0), cap_material, "RoofEaveCourse")
		add_box_visual(parent, Vector3(0.24, maxf(0.11, size.y * 0.82), size.z + 0.18), Vector3(ridge_x, size.y * 0.44, 0.0), cap_material, "RoofRidgeCap")

	func build_facade_custom_data(transforms: Array[Transform3D], part) -> Array[Color]:
		var result: Array[Color] = []
		var min_y := INF
		var max_y := -INF
		for transform in transforms:
			min_y = minf(min_y, transform.origin.y)
			max_y = maxf(max_y, transform.origin.y)
		var height_range := maxf(0.001, max_y - min_y)
		var seed_phase := float(posmod(String(part.id).hash(), 4093)) / 4093.0
		for index in range(transforms.size()):
			var origin := transforms[index].origin
			var height := clampf((origin.y - min_y) / height_range, 0.0, 1.0)
			var stable := fposmod(sin(origin.x * 17.13 + origin.y * 43.77 + origin.z * 11.91 + seed_phase * 97.0) * 31757.13, 1.0)
			result.append(history_custom_data(part.position + origin))
		return result

class Publisher extends FrozenOracle:
	func build_facade_custom_data(transforms: Array[Transform3D], part) -> Array[Color]:
		custom_calls+=1
		return super.build_facade_custom_data(transforms,part)

var checks: Dictionary = {}

func check(label: String, value: bool) -> void:
	checks[label]=value
	if not value: print("ROOF CONTRACT FAILURE ",label)

static func encoded(value: Variant) -> PackedByteArray:
	var bytes := var_to_bytes(value)
	bytes.fill(0); bytes.encode_var(0,value)
	return bytes

static func extract(source: String, name: String, nested: bool) -> String:
	var marker := ("\n\tfunc " if nested else "\nfunc ")+name+"("
	var start := source.find(marker)
	if start<0: return ""
	start+=1
	var finish := source.find("\n\tfunc " if nested else "\nfunc ",start+1)
	if nested:
		var class_end := source.find("\nclass Publisher",start)
		if finish<0 or (class_end>=0 and class_end<finish): finish=class_end
	if finish<0: finish=source.length()
	var lines := source.substr(start,finish-start).strip_edges(false,true).split("\n")
	if nested:
		for index in lines.size(): lines[index]=lines[index].trim_prefix("\t")
	return "\n".join(lines).strip_edges(false,true)

func verify_oracle() -> bool:
	var output: Array = []
	var project := ProjectSettings.globalize_path("res://")
	var code := OS.execute("git",["-C",project,"show",BASELINE_COMMIT+":scripts/buildings/BuildingPartPublisher.gd"],output)
	check("git_baseline_read",code==0 and not output.is_empty())
	if code!=0 or output.is_empty(): return false
	var original: String=String(output[0]).replace("\r","")
	var own := FileAccess.get_file_as_string("res://scripts/testing/buildings/BuildingRoofPublicationContract.gd").replace("\r","")
	for name in ["publish_roof_shingles","build_facade_custom_data"]:
		check(name+"_frozen_exact",extract(original,name,false)==extract(own,name,true))
	output.clear()
	code=OS.execute("git",["-C",project,"rev-parse",BASELINE_COMMIT+":scripts/buildings/BuildingPartPublisher.gd"],output)
	check("git_blob_bound",code==0 and String(output[0]).strip_edges()==BASELINE_BLOB)
	return not checks.values().has(false)

func parity_case(values: Dictionary, collecting: bool, compatibility: bool, budget: int) -> void:
	var label := "%s_%s_%s_%d"%[values.id,str(collecting),str(compatibility),budget]
	checks[label+"_completed"]=false
	var part = Part.new(values)
	if values.has("exactSize"): part.size=values.exactSize
	var before := encoded(part.snapshot())
	var parent := Node3D.new()
	var old := Publisher.new()
	var current := Publisher.new()
	old.surface_history.exposure=float(values.get("exposure",1.0))
	current.surface_history.exposure=old.surface_history.exposure
	var frame := Transform3D(Basis.from_euler(Vector3(0,0.37,0)),Vector3(4,1,-2))
	old.static_visual_collecting=collecting
	old.static_visual_part_transform=frame
	old.publish_roof_shingles(part,parent)
	var job := Roof.new(part,parent,frame,collecting,current.source_blueprint_id,compatibility)
	current.target=weakref(job)
	var turns := 0
	while job.state not in ["ready","failed"] and turns<50000:
		job.advance(current,budget); turns+=1
	check(label+"_ready",job.state=="ready")
	check(label+"_records_exact",encoded(old.records)==encoded(current.records))
	check(label+"_source_unchanged",before==encoded(part.snapshot()) and job._copy.size==part.size)
	check(label+"_publisher_state_restored",not current.static_visual_collecting and current.static_visual_part_transform==Transform3D.IDENTITY)
	if compatibility:
		check(label+"_hooks_exact",old.batch_calls==current.batch_calls and old.custom_calls==current.custom_calls)
	else:
		check(label+"_no_bulk_hooks",current.batch_calls==0 and current.custom_calls==0)
	check(label+"_caps_exact",current.records.size()>=2 and current.records[-2][1]=="RoofEaveCourse" and current.records[-1][1]=="RoofRidgeCap")
	check(label+"_completed",true)
	parent.free()

func cancellation_case(phase: String, collecting: bool) -> void:
	var parent := Node3D.new()
	var publisher := Publisher.new()
	var part = Part.new({"id":"cancel_roof_left","kind":"roof","material":"roof_slate","size":Vector3(8,0.2,7)})
	var job := Roof.new(part,parent,Transform3D.IDENTITY,collecting,publisher.source_blueprint_id)
	publisher.target=weakref(job)
	for index in 50000:
		if job.state==phase: break
		job.advance(publisher,1)
		if job.state in ["failed","ready"]: break
	check(phase+"_cancel_reached",job.state==phase)
	var before := encoded(publisher.records)
	job.cancel()
	for index in 3: job.advance(publisher,4000)
	check(phase+"_cancel_terminal",job.state=="failed" and job.reason=="cancelled")
	check(phase+"_cancel_no_submissions",before==encoded(publisher.records))
	check(phase+"_cancel_retains_payload",job.source_part()==part and job._copy!=null)
	parent.free()

func guard_case(mode: String) -> void:
	var parent := Node3D.new()
	var publisher := Publisher.new()
	var part = Part.new({"id":"guard","kind":"roof","material":"roof_slate","size":Vector3(3,0.2,3)})
	var job := Roof.new(part,parent,Transform3D.IDENTITY,true,publisher.source_blueprint_id)
	publisher.target=weakref(job)
	job.advance(publisher,1)
	match mode:
		"source": publisher.source_blueprint_id="wrong"
		"part": part.size.x+=0.1
		"recipe": part.recipe["changed"]=true
		"history": publisher.surface_history.route_corridors.append({})
		"history_replace": publisher.surface_history=SyntheticHistory.new()
		"publisher": publisher.failure=true
		"parent": parent.free()
	var before := encoded(publisher.records)
	job.advance(publisher,4000)
	check(mode+"_guard_failed",job.state=="failed")
	check(mode+"_guard_no_submissions",before==encoded(publisher.records))
	if is_instance_valid(parent): parent.free()

func hook_case(hook: String, reject: bool) -> void:
	var parent := Node3D.new()
	var publisher := Publisher.new()
	var part = Part.new({"id":"hook","kind":"roof","material":"roof_slate","size":Vector3(3,0.2,3)})
	var job := Roof.new(part,parent,Transform3D.IDENTITY,hook!="submit",publisher.source_blueprint_id,hook=="batch")
	job.defer_practical_light=true
	publisher.target=weakref(job)
	if reject: publisher.reject_hook=hook
	else: publisher.cancel_hook=hook
	for index in 2000:
		if job.state in ["ready","failed"]: break
		job.advance(publisher,4000)
	var label:=hook+("_reject" if reject else "_cancel")
	check(label+"_failed",job.state=="failed")
	var before := encoded(publisher.records)
	job.advance(publisher,4000)
	check(label+"_terminal",before==encoded(publisher.records) and publisher.after_cancel==0)
	parent.free()

func retirement_fixture() -> Dictionary:
	var parent := Node3D.new()
	var publisher := Publisher.new()
	var part = Part.new({"id":"retire","kind":"roof","material":"roof_slate","size":Vector3(3,0.2,3)})
	var job := Roof.new(part,parent,Transform3D.IDENTITY,false,publisher.source_blueprint_id)
	publisher.target=weakref(job)
	for index in 50000:
		if job._upload!=null and job._upload._multi!=null: break
		job.advance(publisher,1)
	var refs := {"job":weakref(job),"publisher":weakref(publisher),"part":weakref(part),"mesh":weakref(publisher.unit_box)}
	if job._upload!=null and job._upload._multi!=null: refs["multi"]=weakref(job._upload._multi)
	check("retirement_native_upload_allocated",refs.has("multi"))
	job.cancel(); parent.free()
	return {"payload":{"job":job,"publisher":publisher},"refs":refs}

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := OS.get_environment("BUILDING_ROOF_PUBLICATION_OUTPUT")
	if output.is_empty(): quit(2); return
	var started := Time.get_ticks_msec()
	if verify_oracle():
		for values: Dictionary in [
			{"id":"ordinary_left","kind":"roof","material":"roof_slate","size":Vector3(4,0.2,3)},
			{"id":"ordinary_right","kind":"roof","material":"roof_slate","size":Vector3(3,0.2,4),"exposure":0.0},
			{"id":"castle_keep_civic_core_roof_left","kind":"roof","material":"roof_slate","size":Vector3(18,0.2,14),"semantic":"civic"},
			{"id":"civic_right","kind":"roof","material":"roof_slate","size":Vector3(4,0.15,5),"semantic":"civic"},
			{"id":"narrow","kind":"roof","material":"roof_slate","size":Vector3(0.1,0.1,0.03)},
			{"id":"thin_rotated","kind":"roof","material":"roof_slate","size":Vector3.ONE,"exactSize":Vector3(2,0.005,3),"position":Vector3(-4,2,7),"rotation":Vector3(0.1,0.4,0.3)}
		]:
			parity_case(values,true,true,4000)
			parity_case(values,true,false,1)
			parity_case(values,true,false,2500)
			parity_case(values,false,false,4000)
		for phase: String in ["setup","tiles","extrema","custom","collect","upload","eave","ridge","finish"]:
			cancellation_case(phase,phase!="upload")
		for mode: String in ["source","part","recipe","history","history_replace","publisher","parent"]: guard_case(mode)
		for hook: String in ["collect","submit","batch","eave","ridge","light"]:
			hook_case(hook,false); hook_case(hook,true)
		var parent := Node3D.new()
		var publisher := Publisher.new()
		var part = Part.new({"id":"budgets","kind":"roof"})
		var job := Roof.new(part,parent,Transform3D.IDENTITY,true,publisher.source_blueprint_id)
		check("budget_zero_rejected",job.advance(publisher,0).reason=="invalid_slice_budget" and job.state=="setup")
		check("budget_4001_rejected",job.advance(publisher,4001).reason=="invalid_slice_budget" and job.state=="setup")
		parent.free()
		var retirement := retirement_fixture() # All borrow frames ended before await.
		var state := Worker.RetirementState.new()
		state.payload=retirement.payload; retirement.payload={}
		var worker := Thread.new()
		check("retirement_worker_started",worker.start(state.release_payload)==OK)
		state.transferred.post()
		while worker.is_alive(): await process_frame
		worker.wait_to_finish()
		for key in retirement.refs: check("retired_"+key,retirement.refs[key].get_ref()==null)
		check("retired_off_main",state.released_on_thread!=OS.get_thread_caller_id())
	var passed := 0
	for value in checks.values():
		if value: passed+=1
	var report := {"passed":passed==checks.size(),"passedCount":passed,"checkCount":checks.size(),"checks":checks,
		"elapsedMsec":Time.get_ticks_msec()-started,"evidenceLevel":"synthetic direct publication/native submissions; not GPU/live acceptance",
		"baselineCommit":BASELINE_COMMIT,"baselineBlob":BASELINE_BLOB,
		"roofSha256":FileAccess.get_sha256("res://scripts/buildings/BuildingRoofPublication.gd"),
		"contractSha256":FileAccess.get_sha256("res://scripts/testing/buildings/BuildingRoofPublicationContract.gd")}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("ROOF CONTRACT ",passed,"/",checks.size())
	quit(0 if report.passed else 1)

