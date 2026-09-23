extends Node3D

const OwnerScript = preload("res://scripts/terrain/NativeResidentCollisionOwner.gd")
const BarrierScript = preload("res://scripts/terrain/NativeCollisionAdmissionBarrier.gd")

class FakeSource:
	extends RefCounted
	var current := {}
	var rows := {}
	func collision_source_snapshot() -> Dictionary:
		return current.duplicate(true)
	func collision_artifact_row(block: Vector3i, identity: Dictionary) -> Dictionary:
		if current.get("identity") != identity or not rows.has(block):
			return {"status": "pending"}
		return {"status": "ready", "row": (rows[block] as Dictionary).duplicate(true)}

var _source := FakeSource.new()
var _owner: Node3D
var _actor: CharacterBody3D
var _started_usec := 0


func _ready() -> void:
	_started_usec = Time.get_ticks_usec()
	call_deferred("_run")


func _run() -> void:
	_owner = OwnerScript.new()
	add_child(_owner)
	if not _owner.bind_source(_source):
		_finish(false, {"reason": "source_bind_failed"})
		return
	_actor = CharacterBody3D.new()
	_actor.position = Vector3(100, 0, 0)
	_actor.collision_mask = 2
	var actor_shape := CollisionShape3D.new()
	actor_shape.shape = BoxShape3D.new()
	_actor.add_child(actor_shape)
	add_child(_actor)
	var blocks: Array[Vector3i] = [Vector3i.ZERO, Vector3i(1, 0, 0)]
	var first := _identity(1)
	_source.current = _snapshot(first, blocks, "a1", "b1")
	var initial_rows := [_row(blocks[0], "a1", 0.5, first),
		_row(blocks[1], "b1", 0.5, first)]
	_source.rows = {blocks[0]: initial_rows[0], blocks[1]: initial_rows[1]}
	var startup_barrier = BarrierScript.new()
	var started: Dictionary = startup_barrier.begin(self, _owner, first,
		initial_rows[0].bounds.merge(initial_rows[1].bounds))
	while started.get("status") == "pending":
		await get_tree().process_frame
		started = startup_barrier.census_progress(first)
	var startup: Dictionary = await _owner.publish(_request(first, blocks, blocks,
		initial_rows), startup_barrier)
	var startup_ready: Dictionary = _owner.startup_readiness(first)
	var startup_released: bool = startup_barrier.release(first)
	_actor.position = Vector3(0.35, 2, 0.5)
	await get_tree().physics_frame
	var actor_contact: KinematicCollision3D = _actor.move_and_collide(Vector3(0, -4, 0))
	var actor_contact_detail := {"collision": actor_contact != null,
		"colliderIsStatic": actor_contact != null and actor_contact.get_collider() is StaticBody3D,
		"finalY": _actor.position.y}
	var actor_landed: bool = actor_contact != null and actor_contact.get_collider() is StaticBody3D \
		and _actor.position.y >= 0.45
	var second := _identity(2)
	var changed: Array[Vector3i] = [blocks[0]]
	_source.current = _snapshot(second, blocks, "a2", "b1")
	var second_row: Dictionary = _row(blocks[0], "a2", 1.0, second)
	_source.rows[blocks[0]] = second_row
	var edit_barrier = BarrierScript.new()
	var edit_started: Dictionary = edit_barrier.begin(self, _owner, second,
		second_row.bounds)
	while edit_started.get("status") == "pending":
		await get_tree().process_frame
		edit_started = edit_barrier.census_progress(second)
	var altered_row: Dictionary = second_row.duplicate(true)
	var altered_vertices: PackedVector3Array = altered_row.vertices
	altered_vertices[0] += Vector3(0.01, 0, 0)
	altered_row.vertices = altered_vertices
	var altered_candidate: Dictionary = await _owner.publish(_request(second, blocks,
		changed, [altered_row]), edit_barrier)
	var occupied_edit: Dictionary = await _owner.publish(_request(second, blocks,
		changed, [second_row]), edit_barrier)
	_actor.position = Vector3(100, 0, 0)
	await get_tree().physics_frame
	var edit: Dictionary = await _owner.publish(_request(second, blocks,
		changed, [second_row]), edit_barrier)
	var edit_window: Dictionary = _owner.affected_window_readiness(second,
		changed)
	var edit_released: bool = edit_barrier.release(second)
	var third := _identity(3)
	_source.current = _snapshot(third, blocks, "a3", "b1")
	var failure_row: Dictionary = _row(blocks[0], "a3", 2.0, third)
	_source.rows[blocks[0]] = failure_row
	failure_row.probeFrom = Vector3(1.5, 2.8, 0.5)
	failure_row.probeTo = Vector3(1.5, 0.2, 0.5)
	_source.rows[blocks[0]] = failure_row
	var rollback_barrier = BarrierScript.new()
	var rollback_started: Dictionary = rollback_barrier.begin(self, _owner, third,
		failure_row.bounds)
	while rollback_started.get("status") == "pending":
		await get_tree().process_frame
		rollback_started = rollback_barrier.census_progress(third)
	var rejected: Dictionary = await _owner.publish(_request(third, blocks,
		changed, [failure_row]), rollback_barrier)
	var stale_ready: Dictionary = _owner.startup_readiness(second)
	var premature_release: bool = rollback_barrier.release(third)
	var corrected_row: Dictionary = _row(blocks[0], "a3", 2.0, third)
	_source.rows[blocks[0]] = corrected_row
	var retried: Dictionary = await _owner.publish(_request(third, blocks,
		changed, [corrected_row]), rollback_barrier)
	var final_ready: Dictionary = _owner.startup_readiness(third)
	var final_released: bool = rollback_barrier.release(third)
	var staged_source := FakeSource.new()
	var staged_owner = OwnerScript.new()
	add_child(staged_owner)
	staged_owner.bind_source(staged_source)
	var staged_identity := _identity(1)
	var staged_blocks: Array[Vector3i] = []
	var staged_artifacts := {}
	var staged_rows: Array[Dictionary] = []
	for index in range(65):
		var block := Vector3i(1000 + index, 0, 0)
		staged_blocks.append(block)
		staged_artifacts[block] = "empty-%d" % index
		var x := float(block.x) * 3.0
		var empty_row := {"block": block, "artifactKey": staged_artifacts[block],
			"vertices": PackedVector3Array(), "bounds": AABB(Vector3(x, 0, 0),
				Vector3(3, 3, 3)), "probeFrom": Vector3(x + 0.35, 2.8, 0.5),
			"probeTo": Vector3(x + 0.35, 0.2, 0.5), "expectedHit": false}
		staged_rows.append(_source_fields(empty_row, staged_identity,
			{"hex": "65-empty-blocks"}))
		staged_source.rows[block] = staged_rows[-1]
	staged_source.current = {"status": "ready", "identity": staged_identity,
		"sourceIdentity": {"hex": "65-empty-blocks"},
		"sourceEpoch": staged_identity.sourceEpoch,
		"nativeRevision": staged_identity.sourceRevision,
		"ownerGeneration": staged_identity.ownerGeneration,
		"cancellationEpoch": staged_identity.cancellationEpoch,
		"requiredResidentBlocks": staged_blocks.duplicate(),
		"residentBlocks": staged_blocks.duplicate(),
		"membershipProvenance": {"authority": "pinned_demand", "demandRevision": 1,
			"closureToken": "65-block-closure"}, "artifacts": staged_artifacts}
	var missing_snapshot: Dictionary = staged_source.current.duplicate(true)
	missing_snapshot.residentBlocks = staged_blocks.slice(0, 64)
	staged_source.current = missing_snapshot
	var missing_artifact: Dictionary = await staged_owner.publish(_request(staged_identity,
		staged_blocks, [staged_blocks[0]], [staged_rows[0]]))
	staged_source.current.residentBlocks = staged_blocks.duplicate()
	var staged_barrier = BarrierScript.new()
	var stage_begin: Dictionary = staged_barrier.begin(self, staged_owner,
		staged_identity, staged_rows[0].bounds.merge(staged_rows[64].bounds))
	while stage_begin.get("status") == "pending":
		await get_tree().process_frame
		stage_begin = staged_barrier.census_progress(staged_identity)
	var first_batch: Array[Vector3i] = []
	var first_rows: Array[Dictionary] = []
	for index in range(64):
		first_batch.append(staged_blocks[index])
		first_rows.append(staged_rows[index])
	var staged_first: Dictionary = await staged_owner.publish(_request(staged_identity,
		staged_blocks, first_batch, first_rows), staged_barrier)
	var staged_early_ready: Dictionary = staged_owner.startup_readiness(staged_identity)
	var staged_early_release: bool = staged_barrier.release(staged_identity)
	var last_batch: Array[Vector3i] = [staged_blocks[64]]
	var staged_last: Dictionary = await staged_owner.publish(_request(staged_identity,
		staged_blocks, last_batch, [staged_rows[64]]), staged_barrier)
	var staged_final_ready: Dictionary = staged_owner.startup_readiness(staged_identity)
	var staged_final_release: bool = staged_barrier.release(staged_identity)
	var main_drain: Dictionary = await _owner.stop_and_drain()
	var staged_drain: Dictionary = await staged_owner.stop_and_drain()
	var stop_during_prepare: Dictionary = await _shutdown_case(false)
	var stop_during_ack: Dictionary = await _shutdown_case(true)
	var same_revision_drift: Dictionary = await _source_drift_case()
	var passed: bool = startup.get("status") == "ready" \
		and startup_ready.get("status") == "ready" and startup_released \
		and actor_landed and altered_candidate.get("status") == "failed" \
		and altered_candidate.get("reason") == "candidate_source_row_mismatch" \
		and occupied_edit.get("status") == "pending" \
		and occupied_edit.get("reason") == "actor_clearance_pending" \
		and edit.get("status") == "ready" and edit_window.get("status") == "ready" \
		and edit_released and rejected.get("status") == "pending" \
		and bool(rejected.get("oldPhysicalRestored", false)) \
		and int(rejected.get("oldPhysicsFrame", -1)) >= 0 \
		and stale_ready.get("status") == "pending" and not premature_release \
		and retried.get("status") == "ready" \
		and final_ready.get("status") == "ready" and final_released \
		and staged_first.get("status") == "pending" \
		and missing_artifact.get("status") == "pending" \
		and missing_artifact.get("reason") == "required_resident_artifacts_incomplete" \
		and staged_early_ready.get("status") == "pending" and not staged_early_release \
		and staged_last.get("status") == "ready" \
		and staged_final_ready.get("status") == "ready" and staged_final_release \
		and main_drain.get("status") == "ready" and int(main_drain.get("remainingBodies", -1)) == 0 \
		and staged_drain.get("status") == "ready" and int(staged_drain.get("remainingBodies", -1)) == 0 \
		and bool(stop_during_prepare.get("passed", false)) \
		and bool(stop_during_ack.get("passed", false)) \
		and bool(same_revision_drift.get("passed", false))
	_finish(passed, {"startup": startup, "startupReady": startup_ready,
		"actorLanded": actor_landed, "actorContact": actor_contact_detail,
		"alteredCandidate": altered_candidate, "occupiedEdit": occupied_edit,
		"edit": edit, "editWindow": edit_window, "rejected": rejected,
		"oldReadinessAfterSourceChange": stale_ready,
		"prematureRelease": premature_release, "retry": retried,
		"finalReady": final_ready, "finalReleased": final_released,
		"staged65": {"missingArtifact": missing_artifact,
			"first": staged_first, "earlyReady": staged_early_ready,
			"earlyRelease": staged_early_release, "last": staged_last,
			"finalReady": staged_final_ready, "finalRelease": staged_final_release},
		"drain": {"main": main_drain, "staged": staged_drain,
			"duringPrepare": stop_during_prepare, "duringAck": stop_during_ack},
		"sameRevisionDrift": same_revision_drift})


func _source_drift_case() -> Dictionary:
	var source := FakeSource.new()
	var owner = OwnerScript.new()
	add_child(owner)
	owner.bind_source(source)
	var identity := _identity(1)
	var blocks: Array[Vector3i] = [Vector3i(600, 0, 0)]
	var row: Dictionary = _row(blocks[0], "drift-artifact", 0.5,
		identity, {"hex": "drift-source"})
	source.rows[blocks[0]] = row
	source.current = {"status": "ready", "identity": identity,
		"sourceIdentity": {"hex": "drift-source"},
		"sourceEpoch": identity.sourceEpoch,
		"nativeRevision": identity.sourceRevision,
		"ownerGeneration": identity.ownerGeneration,
		"cancellationEpoch": identity.cancellationEpoch,
		"requiredResidentBlocks": blocks.duplicate(),
		"residentBlocks": blocks.duplicate(),
		"membershipProvenance": {"authority": "pinned_demand", "demandRevision": 1,
			"closureToken": "first-closure"},
		"artifacts": {blocks[0]: "drift-artifact"}}
	var barrier = BarrierScript.new()
	var begun: Dictionary = barrier.begin(self, owner, identity, row.bounds)
	while begun.get("status") == "pending":
		await get_tree().process_frame
		begun = barrier.census_progress(identity)
	var change_closure := func():
		source.current.membershipProvenance.closureToken = "changed-same-revision"
	get_tree().process_frame.connect(change_closure, CONNECT_ONE_SHOT)
	var outcome: Dictionary = await owner.publish(_request(identity, blocks,
		blocks, [row]), barrier)
	var readiness: Dictionary = owner.startup_readiness(identity)
	var release: bool = barrier.release(identity)
	var drained: Dictionary = await owner.stop_and_drain()
	return {"passed": outcome.get("status") != "ready" \
		and not bool(outcome.get("sourceCurrent", true)) \
		and readiness.get("status") == "pending" and not release \
		and drained.get("status") == "ready" \
		and int(drained.get("remainingBodies", -1)) == 0,
		"outcome": outcome, "readiness": readiness, "release": release,
		"drained": drained}


func _shutdown_case(during_ack: bool) -> Dictionary:
	var source := FakeSource.new()
	var owner = OwnerScript.new()
	add_child(owner)
	owner.bind_source(source)
	var identity := _identity(1)
	var blocks: Array[Vector3i] = [Vector3i(500 if during_ack else 400, 0, 0)]
	var row: Dictionary = _row(blocks[0], "shutdown-artifact", 0.5,
		identity, {"hex": "shutdown-source"})
	source.rows[blocks[0]] = row
	source.current = {"status": "ready", "identity": identity,
		"sourceIdentity": {"hex": "shutdown-source"},
		"sourceEpoch": identity.sourceEpoch,
		"nativeRevision": identity.sourceRevision,
		"ownerGeneration": identity.ownerGeneration,
		"cancellationEpoch": identity.cancellationEpoch,
		"requiredResidentBlocks": blocks.duplicate(),
		"residentBlocks": blocks.duplicate(),
		"membershipProvenance": {"authority": "pinned_demand", "demandRevision": 1,
			"closureToken": "shutdown-closure"},
		"artifacts": {blocks[0]: "shutdown-artifact"}}
	var barrier = BarrierScript.new()
	var begun: Dictionary = barrier.begin(self, owner, identity, row.bounds)
	while begun.get("status") == "pending":
		await get_tree().process_frame
		begun = barrier.census_progress(identity)
	var stopper := func(): owner.stop_and_drain()
	if during_ack:
		get_tree().physics_frame.connect(stopper, CONNECT_ONE_SHOT)
	else:
		get_tree().process_frame.connect(stopper, CONNECT_ONE_SHOT)
	var outcome: Dictionary = await owner.publish(_request(identity, blocks, blocks,
		[row]), barrier)
	var drained: Dictionary = await owner.stop_and_drain()
	var later: Dictionary = await owner.publish(_request(identity, blocks, blocks, [row]), barrier)
	return {"passed": outcome.get("status") == "failed" \
		and outcome.get("reason") == "resident_owner_stopping" \
		and drained.get("status") == "ready" \
		and int(drained.get("remainingBodies", -1)) == 0 \
		and later.get("status") == "failed" \
		and not barrier.admit_motion(_actor, Vector3.ZERO),
		"outcome": outcome, "drained": drained, "later": later,
		"terminalHold": not barrier.admit_motion(_actor, Vector3.ZERO)}


func _identity(revision: int) -> Dictionary:
	return {"ownerGeneration": 1, "sourceRevision": revision,
		"cancellationEpoch": revision, "sourceEpoch": "fixture-epoch"}


func _snapshot(identity: Dictionary, blocks: Array[Vector3i],
		first_key: String, second_key: String) -> Dictionary:
	return {"status": "ready", "identity": identity.duplicate(true),
		"sourceIdentity": {"hex": "fixture-source-%d" % int(identity.sourceRevision)},
		"sourceEpoch": identity.sourceEpoch, "nativeRevision": identity.sourceRevision,
		"ownerGeneration": identity.ownerGeneration,
		"cancellationEpoch": identity.cancellationEpoch,
		"requiredResidentBlocks": blocks.duplicate(),
		"membershipProvenance": {"authority": "pinned_demand", "demandRevision": 1,
			"closureToken": "fixture-demand-closure"},
		"residentBlocks": blocks.duplicate(),
		"artifacts": {blocks[0]: first_key, blocks[1]: second_key}}


func _row(block: Vector3i, artifact_key: String, height: float,
		identity: Dictionary, source_identity: Dictionary = {}) -> Dictionary:
	var start_x := float(block.x * 3)
	var vertices := PackedVector3Array([
		Vector3(start_x, height, 0), Vector3(start_x + 1, height, 0),
		Vector3(start_x + 1, height, 1),
		Vector3(start_x, height, 0), Vector3(start_x + 1, height, 1),
		Vector3(start_x, height, 1)])
	var row := {"block": block, "artifactKey": artifact_key,
		"vertices": vertices, "bounds": AABB(Vector3(start_x, 0, 0),
			Vector3(3, 3, 3)), "probeFrom": Vector3(start_x + 0.35, 2.8, 0.5),
		"probeTo": Vector3(start_x + 0.35, 0.2, 0.5), "expectedHit": true}
	if source_identity.is_empty():
		source_identity = {"hex": "fixture-source-%d" % int(identity.sourceRevision)}
	return _source_fields(row, identity, source_identity)


func _source_fields(row: Dictionary, identity: Dictionary,
		source_identity: Dictionary) -> Dictionary:
	row["sourceIdentity"] = source_identity.duplicate(true)
	row["pinIdentity"] = {"hex": "fixture-pin-%s" % str(row.block)}
	row["blockContentIdentity"] = {"hex": "fixture-content-%s" % row.artifactKey}
	row["nativeRevision"] = identity.sourceRevision
	row["shapingRegistryRevision"] = 1
	row["sourceEpoch"] = identity.sourceEpoch
	row["ownerGeneration"] = identity.ownerGeneration
	row["cancellationEpoch"] = identity.cancellationEpoch
	row["coordinateFrame"] = "world"
	row["empty"] = (row.vertices as PackedVector3Array).is_empty()
	return row


func _request(identity: Dictionary, resident: Array[Vector3i],
		affected: Array[Vector3i], rows: Array) -> Dictionary:
	return {"schema": "n5-resident-collision-publication/v1",
		"identity": identity, "residentBlocks": resident,
		"affectedBlocks": affected, "rows": rows}


func _finish(passed: bool, evidence: Dictionary) -> void:
	var report := {"schema": "n5-resident-collision-owner-fixture/v1",
		"passed": passed, "evidenceLevel": "real Godot physics mechanism fixture",
		"productionCutover": false, "sourceRowsFixture": true,
		"elapsedMilliseconds": float(Time.get_ticks_usec() - _started_usec) / 1000.0,
		"godotVersion": Engine.get_version_info(), "evidence": evidence}
	var path := OS.get_environment("N5_RESIDENT_COLLISION_REPORT")
	if not path.is_empty():
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
			file.close()
	get_tree().quit(0 if passed else 1)
