extends SceneTree

const Manifest := preload("res://scripts/world/ChunkPropVisualManifest.gd")
const DetailPublisher := preload("res://scripts/world/DetailBatchVisualReceiptPublisher.gd")
const PhysicalCache := preload("res://scripts/world/PhysicalChunkPropManifestCache.gd")
const KEY := Vector2i(2, -1)
const SEED := "bounded-props"
const REVISION := "scan:42"

class MainFixture extends Node3D:
	var chunks: Dictionary = {}
	var removed_props_revision := 0

var failures: Array[String] = []
var check_count := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := MainFixture.new()
	root.add_child(main)
	var chunk := _chunk()
	main.add_child(chunk)
	main.chunks[KEY] = chunk
	for index in 24:
		chunk.add_child(_prop(index))
	var batch := _detail_batch(chunk, 32)
	var direct: Dictionary = Manifest.capture(chunk, KEY, SEED, REVISION, true, 1.0)
	_check("direct_completed", direct.get("status") == "ready"
		and direct.get("candidateCount") == 56, direct)
	var begun: Dictionary = Manifest.begin_capture(main, chunk, KEY, SEED, REVISION, true, 1.0)
	_check("begin_retryable_job", begun.get("status") == "pending"
		and begun.get("retryable") == true and begun.get("job") is Manifest, begun)
	var job: Manifest = begun.get("job")
	var bounded: Dictionary = _drain(job)
	_check("bounded_exact_static_parity", bounded.get("status") == "ready"
		and bounded.get("sourceRevision") == direct.get("sourceRevision")
		and bounded.get("candidateCount") == direct.get("candidateCount")
		and bounded.get("byKind") == direct.get("byKind")
		and _candidate_facts(bounded) == _candidate_facts(direct),
		{"bounded": _manifest_summary(bounded), "direct": _manifest_summary(direct)})
	var surface_direct: Dictionary = Manifest.capture(chunk, KEY, SEED,
		REVISION, true, 1.0, true)
	var surface_bounded: Dictionary = _drain(Manifest.begin_capture(main, chunk,
		KEY, SEED, REVISION, true, 1.0, true).get("job"))
	_check("bounded_surface_exact_static_parity",
		surface_bounded.get("status") == surface_direct.get("status")
		and surface_bounded.get("sourceRevision") == surface_direct.get("sourceRevision")
		and surface_bounded.get("byKind") == surface_direct.get("byKind")
		and _candidate_facts(surface_bounded) == _candidate_facts(surface_direct),
		{"bounded": _manifest_summary(surface_bounded),
			"direct": _manifest_summary(surface_direct)})
	var cache := PhysicalCache.new()
	cache.remember(main, chunk, KEY, SEED, REVISION, false, 1.0, bounded)
	var reused: Dictionary = cache.recall(main, chunk, KEY, SEED,
		REVISION, false, 1.0)
	_check("unchanged_physical_source_reused", bool(reused.get("candidateSnapshotCacheHit", false))
		and reused.get("sourceRevision") == bounded.get("sourceRevision")
		and _candidate_facts(reused) == _candidate_facts(bounded),
		_manifest_summary(reused))
	var moving_prop := chunk.get_child(0) as Node3D
	var original_prop_position := moving_prop.global_position
	moving_prop.global_position += Vector3(30.0, 0.0, 0.0)
	var moved_prop_cache: Dictionary = cache.recall(main, chunk, KEY, SEED,
		REVISION, false, 1.0)
	_check("changed_ordinary_prop_position_invalidates_cache",
		moved_prop_cache.is_empty(), moved_prop_cache)
	var moved_prop_source: Dictionary = Manifest.capture(chunk, KEY, SEED,
		REVISION, true, 1.0)
	_check("changed_ordinary_prop_position_recaptures_visual_source",
		moved_prop_source.get("status") == "ready"
		and moved_prop_source.get("sourceRevision") != bounded.get("sourceRevision")
		and _candidate_position(moved_prop_source, "%s:prop:0" % SEED)
			== Vector2(original_prop_position.x + 30.0, original_prop_position.z),
		_manifest_summary(moved_prop_source))
	moving_prop.global_position = original_prop_position
	batch.global_position = Vector3(90.0, 0.0, 0.0)
	var moved_detail: Dictionary = cache.recall(main, chunk, KEY, SEED,
		REVISION, false, 1.0)
	_check("changed_detail_position_invalidates_cache", moved_detail.is_empty(), moved_detail)
	batch.global_position = Vector3.ZERO
	cache.remember(main, chunk, KEY, SEED, REVISION, false, 1.0, bounded)
	main.removed_props_revision += 1
	var removed_revision: Dictionary = cache.recall(main, chunk, KEY, SEED,
		REVISION, false, 1.0)
	_check("durable_edit_invalidates_cache", removed_revision.is_empty(), removed_revision)
	main.removed_props_revision -= 1
	moving_prop.set_meta("wildlife_variant", "deer")
	moving_prop.set_meta("wildlife_home", original_prop_position)
	var wildlife_source: Dictionary = Manifest.capture(chunk, KEY, SEED,
		REVISION, true, 1.0)
	cache.remember(main, chunk, KEY, SEED, REVISION, false, 1.0, wildlife_source)
	moving_prop.global_position += Vector3(30.0, 0.0, 0.0)
	var moved_wildlife: Dictionary = cache.recall(main, chunk, KEY, SEED,
		REVISION, false, 1.0)
	_check("wildlife_movement_keeps_stable_home_source",
		bool(moved_wildlife.get("candidateSnapshotCacheHit", false))
		and moved_wildlife.get("sourceRevision") == wildlife_source.get("sourceRevision")
		and _candidate_facts(moved_wildlife) == _candidate_facts(wildlife_source),
		_manifest_summary(moved_wildlife))
	moving_prop.global_position = original_prop_position
	moving_prop.remove_meta("wildlife_variant")
	moving_prop.remove_meta("wildlife_home")
	var changed_job: Manifest = Manifest.begin_capture(main, chunk, KEY, SEED,
		REVISION, true, 1.0).get("job")
	changed_job.advance(1, 10000)
	var old_prop := chunk.get_child(0)
	chunk.remove_child(old_prop)
	old_prop.queue_free()
	chunk.add_child(_prop(0))
	var changed: Dictionary = _drain(changed_job)
	_check("same_count_owner_replacement_retries", _source_changed(changed), changed)
	var edited_job: Manifest = Manifest.begin_capture(main, chunk, KEY, SEED,
		REVISION, true, 1.0).get("job")
	main.removed_props_revision += 1
	var edited: Dictionary = edited_job.advance(1, 10000)
	_check("durable_edit_revision_retries", _source_changed(edited), edited)
	var batch_job: Manifest = Manifest.begin_capture(main, chunk, KEY, SEED,
		REVISION, true, 1.0).get("job")
	var prep: Dictionary = {}
	for i in 160:
		prep = batch_job.advance(1, 10000)
		if prep.get("stage") == "materialize": break
	_check("batch_job_reached_materialize", prep.get("stage") == "materialize", prep)
	batch.global_position = Vector3(999, 0, 0)
	var mutated: Dictionary = _drain(batch_job)
	_check("same_frame_batch_transform_retries", _source_changed(mutated),
		_manifest_summary(mutated))
	var empty_chunk := _chunk()
	main.add_child(empty_chunk)
	main.chunks[KEY] = empty_chunk
	var empty: Dictionary = _drain(Manifest.begin_capture(main, empty_chunk, KEY,
		SEED, REVISION, true, 1.0).get("job"))
	_check("completed_empty_is_explicit", empty.get("status") == "ready"
		and empty.get("candidateCount") == 0 and empty.get("scanComplete") == true,
		empty)
	empty_chunk.set_meta("chunk_prop_candidate_scan_complete", false)
	var incomplete: Dictionary = Manifest.begin_capture(main, empty_chunk, KEY,
		SEED, REVISION, false, 1.0)
	_check("incomplete_is_not_empty", incomplete.get("status") == "pending"
		and incomplete.get("retryable") == true and not incomplete.has("job"), incomplete)
	var incomplete_without_revision: Dictionary = Manifest.begin_capture(main,
		empty_chunk, KEY, SEED, "", false, 1.0)
	_check("incomplete_without_revision_retries",
		incomplete_without_revision.get("status") == "pending"
		and incomplete_without_revision.get("reason") == "chunk_prop_candidate_scan_incomplete"
		and incomplete_without_revision.get("retryable") == true,
		incomplete_without_revision)
	var report := {"schema": "chunk-prop-bounded-capture-contract/v1",
		"passed": failures.is_empty(), "failures": failures,
		"checkCount": check_count,
		"candidateCount": bounded.get("candidateCount", -1),
		"sourceRevision": bounded.get("sourceRevision", "")}
	var report_path := OS.get_environment("VOXEL_CHUNK_PROP_BOUNDED_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report))
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func _chunk() -> Node3D:
	var chunk := Node3D.new()
	chunk.set_meta("chunk_prop_candidate_scan_complete", true)
	chunk.set_meta("chunk_prop_candidate_source_revision", REVISION)
	chunk.set_meta("chunk_surface_candidate_scan_complete", true)
	chunk.set_meta("chunk_surface_candidate_source_revision", REVISION)
	return chunk


func _prop(index: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_meta("prop_id", "%s:prop:%d" % [SEED, index])
	body.position = Vector3(index + 0.5, 0.0, 0.5)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	body.add_child(mesh)
	return body


func _detail_batch(chunk: Node3D, count: int) -> MultiMeshInstance3D:
	var decor := Node3D.new()
	decor.set_meta("kind", "decor")
	chunk.add_child(decor)
	var batch := MultiMeshInstance3D.new()
	batch.set_meta("detail_type", "grass")
	batch.visibility_range_end = 100.0
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = BoxMesh.new()
	multimesh.instance_count = count
	for index in count:
		multimesh.set_instance_transform(index,
			Transform3D(Basis.IDENTITY, Vector3(index + 0.25, 0.0, 1.25)))
	batch.multimesh = multimesh
	decor.add_child(batch)
	var publisher := DetailPublisher.new()
	publisher.configure(batch, "grass")
	batch.set_meta(Manifest.DETAIL_RECEIPT_PUBLISHER_META, publisher)
	chunk.set_meta("visual_detail_expected_batches", [{"detailType": "grass",
		"batchInstanceId": batch.get_instance_id(), "instanceCount": count}])
	return batch


func _drain(job: Manifest) -> Dictionary:
	if job == null: return {"status": "failed", "reason": "job_missing"}
	var latest: Dictionary = {}
	for i in 512:
		latest = job.advance(1, 10000)
		if latest.get("status") != "pending" \
				or latest.get("reason") != "chunk_prop_bounded_capture_budget":
			return latest
	return {"status": "failed", "reason": "bounded_drain_limit", "last": latest}


func _source_changed(result: Dictionary) -> bool:
	return result.get("status") == "pending" and result.get("retryable") == true \
		and result.get("reason") == "chunk_prop_bounded_source_changed"


func _candidate_facts(manifest: Dictionary) -> Array:
	var facts: Array = []
	for candidate in manifest.get("candidates", []):
		facts.append([candidate.get("candidateId"), candidate.get("kind"),
			candidate.get("positionXZ"), candidate.get("renderable"),
			candidate.get("detailInstanceTransform"),
			candidate.get("detailInstanceColor"),
			candidate.get("detailInstanceCustomData"),
			candidate.get("detailVisibilityEnd"),
			(candidate.get("owner") as Object).get_instance_id()])
	return facts


func _candidate_position(manifest: Dictionary, candidate_id: String) -> Vector2:
	for candidate in manifest.get("candidates", []):
		if String(candidate.get("candidateId", "")) == candidate_id:
			return candidate.get("positionXZ", Vector2.INF)
	return Vector2.INF


func _manifest_summary(manifest: Dictionary) -> Dictionary:
	return {"status": manifest.get("status"), "reason": manifest.get("reason"),
		"count": manifest.get("candidateCount"),
		"revision": manifest.get("sourceRevision")}


func _check(name: String, condition: bool, detail: Dictionary) -> void:
	check_count += 1
	if not condition:
		failures.append(name + ": " + JSON.stringify(detail))
