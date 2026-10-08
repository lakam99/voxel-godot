extends SceneTree
## Headed microbenchmark: actual publisher glass, native packet frame ACK, and
## separately labelled RenderingServer operations. Not gameplay acceptance.
const Publisher := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Part := preload("res://scripts/buildings/BuildingPart.gd")
const Preparation := preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Glass := preload("res://scripts/world/StaticTranslucentMeshPreparation.gd")
const Fingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const PacketOwner := preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const SAMPLE_COUNT := 12

class RenderWork extends RefCounted:
	var mutex := Mutex.new()
	var arrays: Array = []
	var material := RID()
	var scenario := RID()
	var mesh := RID()
	var instance := RID()
	var indices := PackedByteArray()
	var placement := Transform3D.IDENTITY
	var operation := "cold"
	var cancelled := false
	var done := false
	var result: Dictionary = {}

	func execute() -> void:
		var started := Time.get_ticks_usec()
		mutex.lock()
		var was_cancelled := cancelled
		mutex.unlock()
		if operation == "free":
			if instance.is_valid(): RenderingServer.free_rid(instance)
			if mesh.is_valid(): RenderingServer.free_rid(mesh)
			instance = RID()
			mesh = RID()
		elif not was_cancelled:
			if operation == "cold":
				mesh = RenderingServer.mesh_create()
				RenderingServer.mesh_add_surface_from_arrays(mesh,RenderingServer.PRIMITIVE_TRIANGLES,arrays)
				instance = RenderingServer.instance_create()
				RenderingServer.instance_set_base(instance,mesh)
				RenderingServer.instance_set_scenario(instance,scenario)
				RenderingServer.instance_set_transform(instance,placement)
				RenderingServer.instance_geometry_set_material_override(instance,material)
			elif operation == "update":
				RenderingServer.mesh_surface_update_index_region(mesh,0,0,indices)
			elif operation == "read_indices":
				var surface := RenderingServer.mesh_get_surface(mesh,0)
				indices = surface.get("index_data",PackedByteArray())
		mutex.lock()
		result = {"operation":operation,"renderCallbackUsec":Time.get_ticks_usec()-started,
			"renderThreadId":OS.get_thread_caller_id(),"cancelled":was_cancelled}
		done = true
		mutex.unlock()

	func snapshot() -> Dictionary:
		mutex.lock()
		var value := result.duplicate()
		value["done"] = done
		mutex.unlock()
		return value

var checks: Array[Dictionary] = []
var measurements: Array[Dictionary] = []
var frames: Dictionary = {}
var phase := "setup"
var last_frame_usec := 0
var frame_callback_seen := false

func _initialize() -> void:
	process_frame.connect(_frame_sample)
	call_deferred("run")

func _frame_sample() -> void:
	var now := Time.get_ticks_usec()
	if last_frame_usec != 0:
		if not frames.has(phase): frames[phase] = []
		frames[phase].append(now-last_frame_usec)
	last_frame_usec = now

func _drawn() -> void:
	frame_callback_seen = true

func check(name: String, passed: bool, detail: Dictionary = {}) -> void:
	checks.append({"name":name,"passed":passed,"detail":detail})
	if not passed: push_error("Surface upload benchmark: "+name+" "+str(detail))

func dispatch(work: RenderWork) -> Dictionary:
	var submitted := Time.get_ticks_usec()
	RenderingServer.call_on_render_thread(work.execute)
	var submission_usec := Time.get_ticks_usec()-submitted
	# The owned process watchdog bounds a hung callback. Never reuse/free a work
	# object while its render callback may still own its arrays or RID fields.
	while true:
		var state := work.snapshot()
		if state.done:
			state["mainSubmissionUsec"] = submission_usec
			state["completionLatencyUsec"] = Time.get_ticks_usec()-submitted
			state["mainThreadId"] = OS.get_main_thread_id()
			return state
		await process_frame
	return {}

func draw_boundary() -> int:
	var started := Time.get_ticks_usec()
	frame_callback_seen = false
	RenderingServer.request_frame_drawn_callback(_drawn)
	for turn in range(180):
		await process_frame
		if frame_callback_seen: return Time.get_ticks_usec()-started
	return -1

func release_work(work: RenderWork) -> bool:
	work.operation = "free"
	work.done = false
	var result := await dispatch(work)
	return result.get("done",false) and not work.mesh.is_valid() and not work.instance.is_valid()

func run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.position = Vector3(0,0,5)
	camera.look_at(Vector3.ZERO)
	camera.current = true
	var light := DirectionalLight3D.new()
	scene.add_child(light)
	light.rotation_degrees = Vector3(-35,20,0)
	var source_root := Node3D.new()
	scene.add_child(source_root)
	var publisher := Publisher.new()
	publisher.unit_box = BoxMesh.new()
	publisher.source_blueprint_id = "surface-benchmark"
	publisher.publication_site_id = "surface-benchmark"
	publisher._scene_parent = weakref(source_root)
	var part := Part.new({"id":"window","kind":"window","material":"window_glass",
		"position":Vector3.ZERO,"size":Vector3(1.8,2.2,0.18),"collision":true,"recipe":{"visual":true}})
	publisher.publish_static_part(part,source_root)
	publisher._record_completed_source_part(part)
	publisher._begin_static_flush(source_root,false)
	for turn in range(1024):
		if not publisher.has_pending_static_flush(): break
		publisher.advance_static_flush(source_root,1000)
	var captured := publisher.capture_committed_static_visual_source(part.id,Preparation.static_record_binding(part.snapshot()))
	check("real_window_source_admitted",captured.get("status")=="ready",{"status":captured.get("status"),"reason":captured.get("reason")})
	var glass_group: Dictionary = {}
	for group: Dictionary in captured.get("groups",[]):
		if group.get("renderLayer")=="translucent": glass_group = group
	check("actual_translucent_surface_found",not glass_group.is_empty())
	if glass_group.is_empty(): finish(scene); return
	var prepared := Glass.prepare(glass_group,{"status":"ready","cameraPosition":camera.global_position,"revision":14})
	check("actual_glass_sorted_payload_prepared",prepared.get("status")=="ready")
	if prepared.get("status")!="ready": finish(scene); return
	var payload: Dictionary = prepared.groups[0]
	var arrays: Array = payload.mesh.surface_get_arrays(0)
	var material: Material = glass_group.resourceBindings.material
	var bytes := 0
	for lane: Variant in arrays: bytes += maxi(0,Fingerprint._packed_array_bytes(lane))
	source_root.visible = false
	phase = "baseline"
	for frame in range(16): await process_frame
	var owner := Node3D.new()
	owner.name = "Chunk_0_0"
	scene.add_child(owner)
	var attached := PacketOwner.attach_to_chunk(owner)
	check("native_packet_backend_ready",attached.get("status")=="ready",attached)
	if attached.get("status")!="ready": finish(scene); return
	var backend: Node = attached.backend
	for sample in range(SAMPLE_COUNT):
		phase = "arraymesh_native"
		await process_frame
		var started := Time.get_ticks_usec()
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		var create_usec := Time.get_ticks_usec()-started
		started = Time.get_ticks_usec()
		mesh.surface_set_material(0,material)
		var material_usec := Time.get_ticks_usec()-started
		var identity := Fingerprint.inspect(mesh)
		var source := "upload-benchmark-"+str(sample)
		var begun: Dictionary = backend.call("begin_packet_with_layers",source,Vector2i.ZERO,1,"source-revision",String(identity.contentDigest),payload.sourceToWorld,1,1,
			[{"layer":"translucent","expectedBatchCount":1,"expectedInstanceCount":1}])
		started = Time.get_ticks_usec()
		var appended: Dictionary = backend.call("append_batch_in_layer",source,1,"glass",mesh,String(identity.contentDigest),material,
			PackedFloat32Array(payload.buffer),mesh.get_aabb(),"structural",false,0.0,0.0,"translucent")
		var append_usec := Time.get_ticks_usec()-started
		started = Time.get_ticks_usec()
		var uploaded: Dictionary = backend.call("advance_packet",source,1,1)
		var upload_usec := Time.get_ticks_usec()-started
		var committed: Dictionary = backend.call("commit_packet",source,1,true)
		var draw_usec := await draw_boundary()
		var token := String(committed.get("presentationToken",committed.get("token","")))
		var ack: Dictionary = backend.call("finalize_presentation",source,1,token)
		check("native_sample_"+str(sample),begun.get("status")=="ready_to_append" and appended.get("status")=="accepted"
			and uploaded.get("status")=="ready_to_commit" and draw_usec>=0 and ack.get("status")=="ready",
			{"begin":begun,"append":appended.get("status"),"upload":uploaded.get("status"),"commit":committed.get("status"),"ack":ack})
		measurements.append({"mode":phase,"sample":sample,"arrayMeshCreateUsec":create_usec,"materialAssignUsec":material_usec,
			"nativeAppendDuplicateUsec":append_usec,"nativeUploadUsec":upload_usec,"uploadToDrawUsec":draw_usec,"bytes":bytes})
		backend.call("release_packet",source,1)
		await process_frame
	for sample in range(SAMPLE_COUNT):
		phase = "server_cold"
		await process_frame
		var work := RenderWork.new()
		work.arrays = arrays
		work.placement = payload.sourceToWorld
		work.material = material.get_rid()
		work.scenario = scene.get_world_3d().scenario
		var cold := await dispatch(work)
		cold["mode"] = phase
		cold["sample"] = sample
		cold["bytes"] = bytes
		cold["uploadToDrawUsec"] = await draw_boundary()
		measurements.append(cold)
		check("server_cold_sample_"+str(sample),cold.get("done",false) and work.mesh.is_valid() and int(cold.uploadToDrawUsec)>=0)
		phase = "server_readback_setup"
		work.operation = "read_indices"
		work.done = false
		var readback := await dispatch(work)
		check("index_readback_"+str(sample),readback.get("done",false) and not work.indices.is_empty(),readback)
		phase = "server_slot_index_update"
		# Reverse whole quad groups: actual index bytes, same allocation and winding.
		var stride: int = work.indices.size()/36
		check("index_payload_shape_"+str(sample),work.indices.size()==36*stride and stride in [2,4],{"bytes":work.indices.size(),"stride":stride})
		if stride not in [2,4] or work.indices.size()!=36*stride:
			await release_work(work)
			finish(scene)
			return
		var updated := PackedByteArray()
		for face in range(5,-1,-1): updated.append_array(work.indices.slice(face*6*stride,(face+1)*6*stride))
		work.indices = updated
		work.operation = "update"
		work.done = false
		var update := await dispatch(work)
		update["mode"] = phase
		update["sample"] = sample
		update["bytes"] = updated.size()
		update["uploadToDrawUsec"] = await draw_boundary()
		measurements.append(update)
		check("server_update_sample_"+str(sample),update.get("done",false) and int(update.uploadToDrawUsec)>=0)
		check("server_release_"+str(sample),await release_work(work))
	phase = "cancellation"
	var cancelled := RenderWork.new()
	cancelled.arrays = arrays
	cancelled.cancelled = true
	var cancel_result := await dispatch(cancelled)
	check("cancelled_render_work_creates_no_resource",cancel_result.get("cancelled",false) and not cancelled.mesh.is_valid(),cancel_result)
	var lifetime_owner := Node3D.new()
	scene.add_child(lifetime_owner)
	var lifetime_ref: WeakRef = weakref(lifetime_owner)
	var orphan := RenderWork.new()
	orphan.arrays = arrays
	orphan.material = material.get_rid()
	orphan.scenario = scene.get_world_3d().scenario
	RenderingServer.call_on_render_thread(orphan.execute)
	lifetime_owner.free()
	while true:
		if orphan.snapshot().get("done",false): break
		await process_frame
	var rejected: bool = not is_instance_valid(lifetime_ref.get_ref()) and bool(orphan.snapshot().get("done",false))
	check("destroyed_owner_result_not_adopted",rejected)
	check("destroyed_owner_resource_released",await release_work(orphan))
	phase = "cleanup"
	owner.free()
	await process_frame
	await draw_boundary()
	finish(scene)

func finish(scene: Node3D) -> void:
	var summaries: Dictionary = {}
	for name: String in frames:
		var samples: Array = frames[name].duplicate()
		samples.sort()
		if not samples.is_empty(): summaries[name] = {"count":samples.size(),"p95Usec":samples[mini(samples.size()-1,ceili(samples.size()*0.95)-1)],"maxUsec":samples[-1],"samplesUsec":samples}
	var passed := true
	for row: Dictionary in checks: passed = passed and bool(row.passed)
	var report := {"schema":"native-surface-upload-benchmark/v1","complete":true,"passed":passed,"checkCount":checks.size(),
		"checks":checks,"measurements":measurements,"frameTiming":summaries,"sampleCountPerMode":SAMPLE_COUNT,
		"renderThreadModel":ProjectSettings.get_setting("rendering/driver/threads/thread_model"),
		"evidenceLevel":"real_glass_payload_native_packet_and_separate_server_operation_microbenchmark",
		"limitations":["Direct server modes do not install through production packet receipts.","Frame intervals measure CPU-visible frame progression, not GPU timestamps.","Cold means new resource allocation after fixture setup; not process-cold shader compilation.","No gameplay/performance improvement claim without comparing whole-frame distributions."]}
	var path := OS.get_environment("VOXEL_SURFACE_UPLOAD_REPORT")
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	scene.free()
	quit(0 if passed else 1)
