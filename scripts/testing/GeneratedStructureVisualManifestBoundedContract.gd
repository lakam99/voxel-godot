extends SceneTree

const Manifest := preload("res://scripts/world/GeneratedStructureVisualManifest.gd")
const Readiness := preload("res://scripts/world/VisibleWorldReadiness.gd")
const BOUNDS := Rect2i(-6, -6, 12, 12)
const NEAR := Rect2i(-2, -2, 4, 4)

class Publisher extends RefCounted:
	var installed := true

	func visual_receipt_installed(_source_identity: String, _source_revision: String,
			_world_revision: String, _view_revision: int, candidate_id: String,
			metadata: Dictionary, representation_id: String, _tier: String) -> bool:
		return installed and candidate_id == "citadel:site:wall" \
			and String(metadata.get("citadelMemberId", "")) == "wall" \
			and representation_id == "%s:scene:%d" % [candidate_id, get_instance_id()]

class SourceCapture extends RefCounted:
	var source: Object
	var bounds: Rect2i
	var revision: int
	var steps := 0

	func advance(_max_atoms: int = 128, _max_usec: int = 3000) -> Dictionary:
		steps += 1
		if source.revision != revision:
			return {"status": "pending", "reason": "ordinary_visual_capture_source_changed",
				"retryable": true}
		if steps == 1:
			return {"status": "pending", "reason": "ordinary_visual_capture_budget",
				"retryable": true, "stage": "enumeration"}
		return source.region_ordinary_visual_source(bounds)

class Source extends RefCounted:
	var owners: Array[Node3D] = []
	var publisher: Publisher
	var revision := 1

	func region_publication_readiness(_bounds: Rect2i) -> Dictionary:
		return {"status": "ready"}

	func region_dependency_requirements(_bounds: Rect2i) -> Dictionary:
		return {"status": "described"}

	func region_dependency_revision(_bounds: Rect2i) -> String:
		return "dependency:%d" % revision

	func region_dependency_scheduling_revision(_bounds: Rect2i) -> Array:
		return ["dependency", revision]

	func region_citadel_visual_source(_bounds: Rect2i) -> Dictionary:
		return {"status": "described", "descriptionComplete": true,
			"sourceRevision": "citadel:%d:%d" % [revision, publisher.get_instance_id()],
			"candidates": [{"candidateId": "citadel:site:wall", "positionXZ": Vector2(2.5, 0.5),
				"memberId": "wall", "binding": {"siteId": "site", "revision": revision},
				"sourceSignature": "plan:1", "publisher": publisher}]}

	func region_ordinary_visual_source(_bounds: Rect2i) -> Dictionary:
		var rows: Array[Dictionary] = []
		var ids: Array[int] = []
		for i in owners.size():
			var owner := owners[i]
			var representation := owner.get_child(0) as Node3D
			ids.append(owner.get_instance_id())
			ids.append(representation.get_instance_id())
			rows.append({"candidateId": "ordinary:%d" % i,
				"positionXZ": Vector2(float(i) + 0.5, 0.5),
				"cell": Vector3i(i, 0, 0), "owner": owner,
				"representation": representation})
		return {"status": "described", "sourceRevision": "ordinary:%d:%s" % [revision, str(ids)],
			"sourceCount": 1, "candidates": rows}

	func begin_region_ordinary_visual_source_capture(bounds: Rect2i) -> Object:
		var capture := SourceCapture.new()
		capture.source = self
		capture.bounds = bounds
		capture.revision = revision
		return capture

var failures: Array[String] = []
var check_count := 0

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var source := Source.new()
	source.publisher = Publisher.new()
	for i in 3:
		var body := _make_body()
		world.add_child(body)
		source.owners.append(body)
	var direct_readiness := _readiness(30)
	var direct_revision := int(direct_readiness.get("_view_revision"))
	var direct: Dictionary = Manifest.submit(world, source, direct_readiness,
		30, direct_revision, BOUNDS, NEAR, false)
	_check("direct_ready", direct.get("status") == "ready", direct)
	var bounded_readiness := _readiness(31)
	var bounded_revision := int(bounded_readiness.get("_view_revision"))
	var begun: Dictionary = Manifest.begin_bounded(world, source, bounded_readiness,
		31, bounded_revision, BOUNDS, NEAR, false)
	_check("begin_pending_with_weak_job", begun.get("status") == "pending"
		and begun.get("job") is Manifest and int(begun.get("candidateAdmissionUsec", -1)) >= 0,
		begun)
	var job: Manifest = begun.get("job")
	var bounded: Dictionary = _drain(job)
	_check("bounded_matches_direct", bounded.get("status") == "ready"
		and bounded.get("candidateCount") == direct.get("candidateCount")
		and bounded.get("representedCount") == direct.get("representedCount")
		and bounded.get("sourceRevision") == direct.get("sourceRevision"),
		{"direct": direct, "bounded": bounded})
	var final_readiness := _readiness(33)
	var final_revision := int(final_readiness.get("_view_revision"))
	var final_begin: Dictionary = Manifest.begin_bounded(world, source, final_readiness,
		33, final_revision, BOUNDS, NEAR, false)
	var final_job: Manifest = final_begin.get("job")
	var final_slice: Dictionary = {}
	for step in 64:
		final_slice = final_job.advance(1, 10000)
		if final_slice.get("reason") == "ordinary_visual_capture_budget" \
				and String(final_job.get("_bounded").get("stage", "")) == "finish": break
	_check("final_producer_recheck_is_bounded", final_slice.get("status") == "pending"
		and final_slice.get("reason") == "ordinary_visual_capture_budget"
		and String(final_job.get("_bounded").get("stage", "")) == "finish", final_slice)
	source.revision += 1
	var stale_final: Dictionary = final_job.advance(1, 10000)
	_check("final_producer_change_rejects_old_receipts", stale_final.get("status") == "pending"
		and stale_final.get("reason") == "ordinary_visual_capture_source_changed",
		stale_final)
	source.revision -= 1
	var changed_readiness := _readiness(32)
	var changed_revision := int(changed_readiness.get("_view_revision"))
	var changed_begin: Dictionary = Manifest.begin_bounded(world, source, changed_readiness,
		32, changed_revision, BOUNDS, NEAR, false)
	var changed_job: Manifest = changed_begin.get("job")
	var capture_slice: Dictionary = changed_job.advance(1, 10000)
	_check("ordinary_capture_is_retryable", capture_slice.get("status") == "pending"
		and capture_slice.get("reason") == "ordinary_visual_capture_budget", capture_slice)
	var capture_complete: Dictionary = changed_job.advance(1, 10000)
	_check("ordinary_capture_reaches_candidate_stage", capture_complete.get("status") == "pending"
		and capture_complete.get("stage") == "candidates", capture_complete)
	var first_slice: Dictionary = changed_job.advance(1, 10000)
	_check("one_candidate_slice_is_pending", first_slice.get("status") == "pending"
		and first_slice.get("stage") == "candidates", first_slice)
	var replacement := _make_body()
	world.add_child(replacement)
	source.owners[0] = replacement
	var changed: Dictionary = _drain(changed_job)
	_check("owner_replacement_restarts", changed.get("status") == "pending"
		and changed.get("reason") in ["generated_structure_bounded_owner_changed",
			"generated_structure_source_revision_changed"], changed)
	var restart: Dictionary = Manifest.begin_bounded(world, source, changed_readiness,
		32, changed_revision, BOUNDS, NEAR, false)
	var restarted: Dictionary = _drain(restart.get("job"))
	_check("replacement_reaches_new_revision", restarted.get("status") == "ready"
		and restarted.get("sourceRevision") != bounded.get("sourceRevision"), restarted)
	world.queue_free()
	var report := {"schema": "generated-structure-bounded-contract/v1",
		"passed": failures.is_empty(), "failures": failures,
		"checkCount": check_count,
		"candidateCount": bounded.get("candidateCount", -1),
		"sourceDescriptionUsec": bounded.get("sourceDescriptionUsec", -1),
		"candidateAdmissionUsec": bounded.get("candidateAdmissionUsec", -1)}
	var report_path := OS.get_environment("VOXEL_GENERATED_STRUCTURE_BOUNDED_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report))
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func _make_body() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_meta("generated", true)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	body.add_child(mesh)
	return body


func _readiness(request_id: int) -> Object:
	var readiness = Readiness.new()
	var begun: Dictionary = readiness.begin_view(request_id, "seed", "world", BOUNDS,
		NEAR, Vector2.ZERO, 6.0)
	_check("view_started_%d" % request_id, begun.get("status") == "ready", begun)
	return readiness


func _drain(job: Manifest) -> Dictionary:
	if job == null:
		return {"status": "failed", "reason": "job_missing"}
	var latest: Dictionary = {}
	for i in 64:
		latest = job.advance(1, 10000)
		if latest.get("status") != "pending" or latest.get("reason") in [
				"generated_structure_bounded_owner_changed",
				"generated_structure_source_revision_changed"]:
			return latest
	return {"status": "failed", "reason": "bounded_drain_limit", "last": latest}


func _check(name: String, condition: bool, detail: Dictionary) -> void:
	check_count += 1
	if not condition:
		failures.append(name + ": " + JSON.stringify(detail))
