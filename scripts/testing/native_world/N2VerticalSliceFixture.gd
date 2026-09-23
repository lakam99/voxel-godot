extends Node3D

const OracleScript := preload("res://scripts/testing/native_world/N2LatticeSourceOracle.gd")
const RenderGeneratorScript := preload("res://scripts/testing/native_world/N2PreparedRenderGenerator.gd")
const CollisionOwnerScript := preload("res://scripts/terrain/NativeTerrainCollisionOwner.gd")

const REPORT_SCHEMA := "n2-native-world-vertical-slice-fixture/v1"
const RESULT_SCHEMA := "n2-native-vertical-slice-result/v1"
const PREPARE_METHOD := "n2_prepare_vertical_slice"
const CELL := 1.35
const TERRAIN_LAYER := 2
const MAX_SECONDS := 10.0

var _report_path := ""
var _screenshot_path := ""
var _started_usec := 0
var _body: StaticBody3D
var _terrain: Node3D
var _viewer: Node3D
var _actor: CharacterBody3D
var _installed_shapes: Array[CollisionShape3D] = []
var _acknowledged_physics_frame := -1
var _installed_provenance := {}
var _current_authority := {}
var _resource_lifecycle := {"admittedRequests": 0, "currentInFlightBuilds": 0, "peakInFlightBuilds": 0,
	"currentPreparedResults": 0, "peakPreparedResults": 0, "currentPreparedBytes": 0, "peakPreparedBytes": 0,
	"currentRetiredShapeSetsAwaitingRelease": 0, "peakRetiredShapeSetsAwaitingRelease": 0}


func _ready() -> void:
	_report_path = OS.get_environment("N2_NATIVE_WORLD_REPORT").strip_edges()
	_screenshot_path = OS.get_environment("N2_NATIVE_WORLD_SCREENSHOT").strip_edges()
	_started_usec = Time.get_ticks_usec()
	call_deferred("_run")


func _run() -> void:
	if _report_path.is_empty() or FileAccess.file_exists(_report_path):
		_finish(false, "fresh_report_path_required", {})
		return
	var oracle = OracleScript.new()
	var baseline: Dictionary = oracle.build_snapshot(PackedByteArray(), 1)
	if not bool(baseline.get("ok", false)):
		_finish(false, "baseline_oracle_failed", {"oracleFailure": baseline})
		return
	var delta_serialization: Dictionary = oracle.frozen_edit_serialization()
	var edited: Dictionary = oracle.build_snapshot(delta_serialization.bytes, 2)
	if not bool(edited.get("ok", false)):
		_finish(false, "edited_reload_oracle_failed", {"oracleFailure": edited})
		return
	var common := {
		"oracle": {
			"schema": baseline.schema, "sampleCount": baseline.sampleCount,
			"baselineSha256": baseline.samplesSha256, "editedSha256": edited.samplesSha256,
			"ordering": baseline.ordering, "bounds": baseline.bounds,
			"anchors": baseline.anchors, "noiseFloatBits": baseline.noiseFloatBits,
			"typedDeltas": edited.deltas, "forbiddenOraclePathsUsed": baseline.forbiddenOraclePathsUsed
		},
		"expectedNativeApi": _expected_native_api(),
		"authority": _authority_inventory()
	}
	if not ClassDB.class_exists("TerrainMeshingBackend"):
		_finish(false, "missing_native_class:TerrainMeshingBackend", common)
		return
	var backend = ClassDB.instantiate("TerrainMeshingBackend")
	if backend == null or not backend.has_method(PREPARE_METHOD):
		common["availableNativeMethods"] = backend.get_method_list().map(func(row): return String(row.name)) if backend != null else []
		_finish(false, "missing_native_method:%s" % PREPARE_METHOD, common)
		return
	var baseline_request := oracle.native_request(PackedByteArray())
	baseline_request["requestIdentity"] = {"ownerGeneration": 1, "sourceRevision": 1, "cancellationEpoch": 1}
	var same_shape_request := oracle.native_request(PackedByteArray())
	same_shape_request["requestIdentity"] = {"ownerGeneration": 1, "sourceRevision": 1, "cancellationEpoch": 2}
	var edited_request := oracle.native_request(delta_serialization.bytes)
	edited_request["requestIdentity"] = {"ownerGeneration": 1, "sourceRevision": 2, "cancellationEpoch": 2}
	var native_baseline: Variant = _prepare_native(backend, baseline_request)
	var baseline_check := _validate_native_result(oracle, baseline, native_baseline, baseline_request)
	if not baseline_check.ok:
		common["nativeBaseline"] = baseline_check
		_finish(false, String(baseline_check.reason), common)
		return
	if baseline.samplesSha256 == edited.samplesSha256:
		_finish(false, "cross_seam_edits_did_not_change_snapshot", common)
		return
	var setup := _setup_fixture_nodes(native_baseline)
	if not setup.ok:
		_finish(false, String(setup.reason), common.merged({"setup": setup}, true))
		return
	var invalid_identity: Dictionary = baseline_request.requestIdentity.duplicate(true)
	invalid_identity["sourceRevision"] = -1
	var no_probe := func(_owner: StaticBody3D, _identity: Dictionary) -> Dictionary:
		return {"ok": false}
	var invalid_identity_result: Dictionary = await (_body as Node).call("replace", native_baseline, invalid_identity, no_probe)
	var invalid_source: Dictionary = native_baseline.duplicate(true)
	invalid_source.source["snapshotDigest"] = ""
	var invalid_source_result: Dictionary = await (_body as Node).call("replace", invalid_source, baseline_request.requestIdentity, no_probe)
	var invalid_artifact: Dictionary = native_baseline.duplicate(true)
	invalid_artifact.collision["artifactKey"] = 17
	var invalid_artifact_result: Dictionary = await (_body as Node).call("replace", invalid_artifact, baseline_request.requestIdentity, no_probe)
	if invalid_identity_result.get("reason") != "collision_identity_invalid" \
			or invalid_source_result.get("reason") != "collision_provenance_invalid" \
			or invalid_artifact_result.get("reason") != "collision_provenance_invalid" \
			or _body.get_child_count() != 0:
		_finish(false, "collision_owner_invalid_input_rejection_failed", common.merged({
			"invalidIdentity": invalid_identity_result, "invalidSource": invalid_source_result,
			"invalidArtifact": invalid_artifact_result}, true))
		return
	_current_authority = baseline_request.requestIdentity.duplicate(true)
	_current_authority["sourceRevision"] = int(_current_authority.sourceRevision) + 1000
	var shape_count_before_stale_install := _body.get_child_count()
	var stale_before_install := await _replace_collision(native_baseline, baseline_request.requestIdentity)
	if bool(stale_before_install.get("ok", false)) or stale_before_install.get("reason") != "stale_before_install" \
			or _body.get_child_count() != shape_count_before_stale_install or not _installed_shapes.is_empty():
		_finish(false, "stale_before_install_rejection_not_proven", common.merged({"staleBeforeInstall": stale_before_install}, true))
		return
	_current_authority = baseline_request.requestIdentity.duplicate(true)
	var stale_before_ack := await _replace_collision(native_baseline, baseline_request.requestIdentity, true)
	if bool(stale_before_ack.get("ok", false)) or stale_before_ack.get("reason") != "stale_before_acknowledgement":
		_finish(false, "stale_before_ack_rejection_not_proven", common.merged({"staleBeforeAck": stale_before_ack}, true))
		return
	_current_authority = baseline_request.requestIdentity.duplicate(true)
	var baseline_install := await _replace_collision(native_baseline, baseline_request.requestIdentity)
	if not baseline_install.ok:
		_finish(false, String(baseline_install.reason), common.merged({"baselineInstall": baseline_install}, true))
		return
	var baseline_seam := await _seam_physics("baseline")
	_release_prepared(native_baseline)
	native_baseline = null
	var native_same_shape: Variant = _prepare_native(backend, same_shape_request)
	var same_shape_check := _validate_native_result(oracle, baseline, native_same_shape, same_shape_request)
	if not same_shape_check.ok or same_shape_check.tileGeometrySha256 != baseline_check.tileGeometrySha256 \
			or same_shape_check.terrainTriangleCount != baseline_check.terrainTriangleCount \
			or same_shape_check.blockerTriangleCount != baseline_check.blockerTriangleCount \
			or same_shape_check.collisionArtifactKey == baseline_check.collisionArtifactKey:
		_finish(false, "same_shape_new_revision_artifact_invalid", common.merged({
			"sameShapeCheck":same_shape_check,"baselineCheck":baseline_check}, true))
		return
	_current_authority = same_shape_request.requestIdentity.duplicate(true)
	(_body as Node).call("set_authority", _current_authority)
	var occupied_guard := func(_owner: StaticBody3D, _identity: Dictionary) -> bool:
		return false
	var blocked_replacement: Dictionary = await (_body as Node).call("replace", native_same_shape,
		same_shape_request.requestIdentity, no_probe, Callable(), occupied_guard)
	if blocked_replacement.get("reason") != "replacement_occupied_before_install" \
			or (_body as Node).call("physical_receipt", same_shape_request.requestIdentity).get("ready", false):
		_finish(false, "occupied_replacement_not_rejected", common.merged({
			"blockedReplacement": blocked_replacement}, true))
		return
	var same_shape_install := await _replace_collision(native_same_shape, same_shape_request.requestIdentity)
	if not same_shape_install.ok or same_shape_install.acknowledgement.provenance.get("requestIdentity") != same_shape_request.requestIdentity:
		_finish(false, "same_shape_new_owner_not_physically_acknowledged", common.merged({
			"sameShapeInstall":same_shape_install}, true))
		return
	var same_shape_seam := await _seam_physics("same_shape_new_epoch")
	var same_shape_same_hits: bool = baseline_seam.results.map(func(row): return [row.id,row.hit]) \
		== same_shape_seam.results.map(func(row): return [row.id,row.hit])
	_release_prepared(native_same_shape)
	native_same_shape = null
	var native_edited: Variant = _prepare_native(backend, edited_request)
	var edited_check := _validate_native_result(oracle, edited, native_edited, edited_request)
	if not edited_check.ok:
		common["nativeEdited"] = edited_check
		_finish(false, String(edited_check.reason), common)
		return
	for tile_key in ["-3,-1", "-2,-1"]:
		if baseline_check.tileGeometrySha256.get(tile_key) == edited_check.tileGeometrySha256.get(tile_key):
			_finish(false, "seam_edit_did_not_change_both_tile_artifacts", common.merged({
				"nativeBaseline": baseline_check, "nativeEdited": edited_check, "unchangedTile": tile_key}, true))
			return
	_current_authority = edited_request.requestIdentity.duplicate(true)
	var edited_install := await _replace_collision(native_edited, edited_request.requestIdentity)
	if not edited_install.ok:
		_finish(false, String(edited_install.reason), common.merged({"editedInstall": edited_install}, true))
		return
	var edited_seam := await _seam_physics("edited")
	var seam_hit_changed := false
	for index in range(baseline_seam.results.size()):
		if bool(baseline_seam.results[index].hit) != bool(edited_seam.results[index].hit):
			seam_hit_changed = true
	var cross_seam := {"baseline": baseline_seam, "edited": edited_seam,
		"changed": seam_hit_changed,
		"allHitsOwnedBySoleBody": baseline_seam.results.all(func(row): return row.soleBody) \
			and edited_seam.results.all(func(row): return row.soleBody)}
	var render_result := await _install_render(native_edited)
	if not render_result.ok:
		_finish(false, String(render_result.reason), common.merged({"render": render_result}, true))
		return
	var native_edited_timings: Dictionary = native_edited.timings.duplicate(true)
	_release_prepared(native_edited)
	native_edited = null
	var physics := await _physics_evidence()
	var required_render_gap := String(_terrain.generator.required_gap())
	if not required_render_gap.is_empty():
		physics["ok"] = false
		render_result["requiredSnapshotGap"] = required_render_gap
	else:
		render_result["requiredSnapshotGap"] = ""
	var authority := _authority_inventory()
	var timing := _timing_record(native_edited_timings, edited_install, render_result)
	var lifecycle_ok := int(_resource_lifecycle.admittedRequests) == 3 \
		and int(_resource_lifecycle.currentInFlightBuilds) == 0 and int(_resource_lifecycle.peakInFlightBuilds) == 1 \
		and int(_resource_lifecycle.currentPreparedResults) == 0 and int(_resource_lifecycle.peakPreparedResults) == 1 \
		and int(_resource_lifecycle.currentPreparedBytes) == 0 and int(_resource_lifecycle.peakPreparedBytes) <= 4194304 \
		and int(_resource_lifecycle.currentRetiredShapeSetsAwaitingRelease) == 0 \
		and int(_resource_lifecycle.peakRetiredShapeSetsAwaitingRelease) <= 1
	var passed: bool = bool(physics.ok) and bool(cross_seam.changed) and bool(cross_seam.allHitsOwnedBySoleBody) \
		and same_shape_same_hits and same_shape_seam.results.all(func(row): return row.soleBody) \
		and same_shape_seam.results.any(func(row): return row.id == "solid_down" and row.hit \
			and row.provenance.get("requestIdentity") == same_shape_request.requestIdentity) \
		and authority.staticBodyCount == 1 and authority.projectOwnedTerrainBodies == 1 \
		and authority.voxelTerrainCollisionEnabled == false and _installed_shapes.size() == 3 \
		and _acknowledged_physics_frame >= 0 and float(timing.totalMilliseconds) <= MAX_SECONDS * 1000.0 and lifecycle_ok
	common["nativeBaseline"] = baseline_check
	common["sameShapeCheck"] = same_shape_check
	common["nativeEdited"] = edited_check
	common["baselineInstall"] = baseline_install
	common["sameShapeInstall"] = same_shape_install
	common["blockedReplacement"] = blocked_replacement
	common["sameShapePhysics"] = same_shape_seam
	common["sameShapeSameHits"] = same_shape_same_hits
	common["editedInstall"] = edited_install
	common["staleBeforeInstall"] = stale_before_install
	common["staleBeforeAck"] = stale_before_ack
	common["crossSeamPhysics"] = cross_seam
	common["render"] = render_result
	common["physics"] = physics
	common["authority"] = authority
	common["timing"] = timing
	common["resourceLifecycle"] = _resource_lifecycle.duplicate(true)
	common["installedProvenance"] = _installed_provenance
	common["acknowledgedPhysicsFrame"] = _acknowledged_physics_frame
	await _capture()
	await (_body as Node).call("stop_and_drain")
	var stop_drain := {"remainingShapes": (_body as Node).get("installed_shapes").size(),
		"remainingChildren": _body.get_child_count(),
		"installedProvenance": (_body as Node).get("installed_provenance"),
		"acknowledgedPhysicsFrame": (_body as Node).get("acknowledged_physics_frame")}
	common["stopDrain"] = stop_drain
	passed = passed and stop_drain.remainingShapes == 0 and stop_drain.remainingChildren == 0 \
		and stop_drain.installedProvenance.is_empty() and stop_drain.acknowledgedPhysicsFrame == -1
	_finish(passed, "passed" if passed else "one_authority_or_physics_evidence_failed", common)


func _prepare_native(backend, request: Dictionary):
	if int(_resource_lifecycle.admittedRequests) >= 4 or int(_resource_lifecycle.currentInFlightBuilds) >= 1 \
			or int(_resource_lifecycle.currentPreparedResults) >= 1:
		return {"schema": RESULT_SCHEMA, "ok": false, "reason": "fixture_native_admission_cap_exceeded"}
	_resource_lifecycle["admittedRequests"] = int(_resource_lifecycle.admittedRequests) + 1
	_resource_lifecycle["currentInFlightBuilds"] = int(_resource_lifecycle.currentInFlightBuilds) + 1
	_resource_lifecycle["peakInFlightBuilds"] = max(int(_resource_lifecycle.peakInFlightBuilds), int(_resource_lifecycle.currentInFlightBuilds))
	var result = backend.call(PREPARE_METHOD, request)
	_resource_lifecycle["currentInFlightBuilds"] = int(_resource_lifecycle.currentInFlightBuilds) - 1
	if result is Dictionary and bool(result.get("ok", false)):
		var bytes := int(result.get("preparedPayloadBytes", -1))
		_resource_lifecycle["currentPreparedResults"] = int(_resource_lifecycle.currentPreparedResults) + 1
		_resource_lifecycle["currentPreparedBytes"] = int(_resource_lifecycle.currentPreparedBytes) + bytes
		_resource_lifecycle["peakPreparedResults"] = max(int(_resource_lifecycle.peakPreparedResults), int(_resource_lifecycle.currentPreparedResults))
		_resource_lifecycle["peakPreparedBytes"] = max(int(_resource_lifecycle.peakPreparedBytes), int(_resource_lifecycle.currentPreparedBytes))
	return result


func _release_prepared(result) -> void:
	if not result is Dictionary or not bool(result.get("ok", false)):
		return
	_resource_lifecycle["currentPreparedResults"] = int(_resource_lifecycle.currentPreparedResults) - 1
	_resource_lifecycle["currentPreparedBytes"] = int(_resource_lifecycle.currentPreparedBytes) - int(result.get("preparedPayloadBytes", 0))


func _validate_native_result(oracle, expected: Dictionary, value, request: Dictionary) -> Dictionary:
	if not value is Dictionary:
		return {"ok": false, "reason": "native_result_not_dictionary"}
	if value.get("schema") != RESULT_SCHEMA or not bool(value.get("ok", false)):
		return {"ok": false, "reason": "native_result_schema_or_status_invalid", "actual": value}
	for required in ["requestIdentity", "source", "collision", "render", "timings", "resourceUsage", "preparedPayloadAccounting"]:
		if not value.has(required) or not value[required] is Dictionary:
			return {"ok": false, "reason": "native_result_field_missing:%s" % required}
	if value.requestIdentity != request.requestIdentity:
		return {"ok": false, "reason": "native_request_identity_mismatch"}
	# The frozen N2 source domain has no lava sample. Later native schema work
	# appended lava at material ID 16 and fluid ID 2; require exactly that
	# extension, then compare every original N2 column against its unchanged
	# independent 16/2-name oracle. Any lava ID in this frozen vector still
	# fails the oracle's per-cell range/value checks below.
	var source_tables: Dictionary = value.source.get("nameTables", {})
	var native_material_names = source_tables.get("materialNames")
	var native_fluid_names = source_tables.get("fluidNames")
	if not native_material_names is PackedStringArray or not native_fluid_names is PackedStringArray:
		return {"ok":false, "reason":"native_extended_name_tables_untyped"}
	if native_material_names.size() != OracleScript.MATERIAL_NAMES.size() + 1 \
			or native_fluid_names.size() != OracleScript.FLUID_NAMES.size() + 1:
		return {"ok":false, "reason":"native_lava_extension_count_mismatch"}
	for i in range(OracleScript.MATERIAL_NAMES.size()):
		if native_material_names[i] != OracleScript.MATERIAL_NAMES[i]:
			return {"ok":false, "reason":"native_lava_extension_material_prefix_mismatch", "index":i}
	for i in range(OracleScript.FLUID_NAMES.size()):
		if native_fluid_names[i] != OracleScript.FLUID_NAMES[i]:
			return {"ok":false, "reason":"native_lava_extension_fluid_prefix_mismatch", "index":i}
	if native_material_names[-1] != "lava" or native_fluid_names[-1] != "lava":
		return {"ok":false, "reason":"native_lava_extension_value_mismatch"}
	var frozen_source: Dictionary = value.source.duplicate(true)
	frozen_source.nameTables.materialNames = PackedStringArray(OracleScript.MATERIAL_NAMES)
	frozen_source.nameTables.fluidNames = PackedStringArray(OracleScript.FLUID_NAMES)
	var parity: Dictionary = oracle.compare_packed_columns(expected.samples, frozen_source)
	if not parity.ok:
		return {"ok": false, "reason": parity.reason, "parity": parity}
	if value.source.get("sampleCount") != 33915 or value.source.get("ordering") != "x_fastest_then_z_then_y":
		return {"ok": false, "reason": "native_source_bounds_or_ordering_invalid"}
	if value.source.get("noiseFloatBits") != expected.noiseFloatBits:
		return {"ok": false, "reason": "native_raw_noise_bits_mismatch"}
	if not value.collision.get("tileTriangles") is Array or value.collision.tileTriangles.size() != 2:
		return {"ok": false, "reason": "native_collision_tile_partition_missing"}
	var tile_keys := {}
	var tile_geometry_hashes := {}
	for tile in value.collision.tileTriangles:
		if not tile is Dictionary or tile.get("coordinateFrame") != "world" or bool(tile.get("includesDeclaredBlockers", true)):
			return {"ok": false, "reason": "native_collision_tile_frame_or_blocker_partition_invalid"}
		var key = tile.get("tileKey")
		if not key is Array or key.size() != 2:
			return {"ok": false, "reason": "native_collision_tile_key_invalid"}
		var key_text := "%d,%d" % [int(key[0]), int(key[1])]
		var geometry_hash := String(tile.get("geometrySha256", ""))
		if geometry_hash.length() != 64 or not geometry_hash.is_valid_hex_number(false):
			return {"ok": false, "reason": "native_collision_tile_geometry_hash_invalid", "tileKey": key}
		tile_keys[key_text] = true
		tile_geometry_hashes[key_text] = geometry_hash
	if tile_keys.size() != 2 or not tile_keys.has("-3,-1") or not tile_keys.has("-2,-1"):
		return {"ok": false, "reason": "native_collision_tile_keys_mismatch"}
	if not value.collision.get("blockers") is Array or value.collision.blockers.size() != 1:
		return {"ok": false, "reason": "native_collision_blocker_missing"}
	var blocker: Dictionary = value.collision.blockers[0]
	if blocker.get("id") != "n2:blocker:tile-b:-24,-10" or blocker.get("semanticClass") != "fixture_obstacle" \
			or blocker.get("physicalIntent") != "blocker" or not blocker.get("center") is Array or not blocker.get("size") is Array:
		return {"ok": false, "reason": "native_collision_blocker_identity_invalid"}
	if blocker.center != [-32.4, 16.497000000000003, -13.5] or blocker.size != [1.35, 2.7, 1.35]:
		return {"ok": false, "reason": "native_collision_blocker_geometry_mismatch"}
	if not value.render.get("sdfValues") is PackedFloat32Array or not value.render.get("indices") is PackedByteArray \
			or not value.render.get("data5") is PackedByteArray or value.render.sdfValues.size() != 33915 \
			or value.render.indices.size() != 33915 or value.render.data5.size() != 33915:
		return {"ok": false, "reason": "native_packed_render_payload_invalid"}
	var expected_samples: Array = expected.samples
	var expected_sdf := PackedFloat32Array()
	expected_sdf.resize(expected_samples.size())
	for index in range(expected_samples.size()):
		expected_sdf[index] = -float(expected_samples[index].density) / CELL
		if value.render.sdfValues[index] != expected_sdf[index] \
				or int(value.render.indices[index]) != int(expected_samples[index].materialId) \
				or int(value.render.data5[index]) != int(expected_samples[index].materialId):
			return {"ok": false, "reason": "native_render_channel_parity_mismatch", "ordinal": index,
				"expectedSdfFloat32": expected_sdf[index], "actualSdfFloat32": value.render.sdfValues[index],
				"expectedMaterial": expected_samples[index].materialId, "actualIndices": value.render.indices[index],
				"actualData5": value.render.data5[index]}
	var prepared_bytes := int(value.get("preparedPayloadBytes", -1))
	if prepared_bytes <= 0 or prepared_bytes > 4194304:
		return {"ok": false, "reason": "native_prepared_payload_cap_invalid", "preparedPayloadBytes": prepared_bytes}
	var accounting_check := _validate_payload_accounting(value, prepared_bytes)
	if not accounting_check.ok:
		return accounting_check
	if value.collision.get("snapshotDigest") != value.source.get("snapshotDigest") or value.render.get("snapshotDigest") != value.source.get("snapshotDigest"):
		return {"ok": false, "reason": "artifact_snapshot_identity_mismatch"}
	var usage: Dictionary = value.resourceUsage
	for field in ["admittedRequests", "peakInFlightBuilds", "preparedResults", "preparedBytes", "installedBodiesExpected",
			"installedShapesExpected", "collisionTriangles", "retiredShapeSetsAwaitingRelease"]:
		if typeof(usage.get(field)) != TYPE_INT or int(usage[field]) < 0:
			return {"ok": false, "reason": "native_resource_usage_counter_invalid", "field": field, "usage": usage}
	if int(usage.admittedRequests) != 1 or int(usage.peakInFlightBuilds) != 1 \
			or int(usage.preparedResults) != 1 or int(usage.preparedBytes) != prepared_bytes \
			or int(usage.installedBodiesExpected) != 1 or int(usage.installedShapesExpected) != 3 \
			or int(usage.collisionTriangles) > 200000 or int(usage.retiredShapeSetsAwaitingRelease) != 0:
		return {"ok": false, "reason": "native_resource_usage_cap_invalid", "usage": usage}
	return {"ok": true, "reason": "", "sampleCount": int(value.source.sampleCount), "snapshotDigest": value.source.snapshotDigest,
		"preparedPayloadBytes": prepared_bytes, "collisionArtifactKey": value.collision.get("artifactKey"), "renderArtifactKey": value.render.get("artifactKey"),
		"terrainTriangleCount": int(value.collision.get("terrainTriangleCount", -1)),
		"blockerTriangleCount": int(value.collision.get("blockerTriangleCount", -1)),
		"tileVertexCounts": value.collision.tileTriangles.map(func(tile): return tile.vertices.size()),
		"tileGeometrySha256": tile_geometry_hashes, "resourceUsage": usage,
		"preparedPayloadAccounting": accounting_check.accounting}


func _validate_payload_accounting(value: Dictionary, prepared_bytes: int) -> Dictionary:
	var source: Dictionary = value.source
	var columns: Dictionary = source.columns
	var collision: Dictionary = value.collision
	var render: Dictionary = value.render
	var reported: Dictionary = value.preparedPayloadAccounting
	var source_bytes: int = columns.density.size() * 8 + columns.surfaceY.size() * 8 \
		+ columns.sourceRevisions.size() * 4
	for field in ["surfaceYValid", "solid", "materialIds", "surfaceBiomeIds", "resolvedBiomeIds", "fluidIds", "sourceKinds"]:
		source_bytes += columns[field].size()
	var render_bytes: int = render.sdfValues.size() * 4 + render.indices.size() + render.data5.size()
	var collision_bytes: int = 0
	var string_bytes: int = String(source.generatedSourceId).to_utf8_buffer().size()
	string_bytes += String(source.snapshotDigest).to_utf8_buffer().size()
	string_bytes += String(collision.snapshotDigest).to_utf8_buffer().size()
	string_bytes += String(render.snapshotDigest).to_utf8_buffer().size()
	string_bytes += String(collision.artifactKey).to_utf8_buffer().size()
	string_bytes += String(render.artifactKey).to_utf8_buffer().size()
	for tile in collision.tileTriangles:
		collision_bytes += tile.vertices.size() * 3 * 4
		string_bytes += String(tile.geometrySha256).to_utf8_buffer().size()
	for table_name in ["materialNames", "biomeNames", "fluidNames", "sourceKindNames"]:
		for item in source.nameTables[table_name]:
			string_bytes += String(item).to_utf8_buffer().size()
	for sparse in source.sparseSources:
		string_bytes += String(sparse.id).to_utf8_buffer().size()
	for blocker in collision.blockers:
		string_bytes += String(blocker.id).to_utf8_buffer().size()
		string_bytes += String(blocker.semanticClass).to_utf8_buffer().size()
		string_bytes += String(blocker.physicalIntent).to_utf8_buffer().size()
	var sparse_bytes: int = source.sparseSources.size() * 2 * 8
	var blocker_bytes: int = collision.blockers.size() * 6 * 8
	var noise_bytes: int = source.noiseFloatBits.size() * (3 * 4 + 3 * 8)
	var expected_scope := "native variable payload; excludes Variant container overhead and fixed object headers"
	var recomputed := {
		"sourcePackedColumnsBytes": source_bytes,
		"renderPackedBytes": render_bytes,
		"collisionPackedBytes": collision_bytes,
		"stringBytes": string_bytes,
		"sparseMetadataBytes": sparse_bytes,
		"blockerGeometryBytes": blocker_bytes,
		"noiseFixtureBytes": noise_bytes,
		"scope": expected_scope,
	}
	var recomputed_total: int = source_bytes + render_bytes + collision_bytes + string_bytes \
		+ sparse_bytes + blocker_bytes + noise_bytes
	recomputed["total"] = recomputed_total
	for field in recomputed:
		if reported.get(field) != recomputed[field]:
			return {"ok": false, "reason": "native_prepared_payload_accounting_mismatch", "field": field,
				"expected": recomputed[field], "actual": reported.get(field), "recomputed": recomputed, "reported": reported}
	if recomputed_total != prepared_bytes:
		return {"ok": false, "reason": "native_prepared_payload_total_mismatch",
			"expected": recomputed_total, "actual": prepared_bytes, "recomputed": recomputed, "reported": reported}
	return {"ok": true, "reason": "", "accounting": recomputed}


func _setup_fixture_nodes(native_result: Dictionary) -> Dictionary:
	_body = CollisionOwnerScript.new()
	_body.name = "N2SoleTerrainCollisionAuthority"
	_body.collision_layer = TERRAIN_LAYER
	_body.collision_mask = 0
	_body.set_meta("n2ProjectOwnedTerrainBody", true)
	add_child(_body)
	_terrain = VoxelTerrain.new()
	_terrain.name = "N2FixtureVoxelRenderConsumer"
	_terrain.generate_collisions = false
	_terrain.collision_layer = 0
	_terrain.collision_mask = 0
	_terrain.scale = Vector3.ONE * CELL
	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	_terrain.set_format(format)
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	mesher.transitions_enabled = false
	_terrain.mesher = mesher
	add_child(_terrain)
	_viewer = VoxelViewer.new()
	_viewer.name = "N2FixtureRenderViewer"
	_viewer.view_distance = 64
	_viewer.requires_visuals = true
	_viewer.requires_collisions = false
	_viewer.position = Vector3(-32.0, 18.0, -8.0) * CELL
	add_child(_viewer)
	var camera := Camera3D.new()
	camera.current = true
	camera.position = Vector3(-22.0, 26.0, 10.0) * CELL
	add_child(camera)
	camera.look_at(Vector3(-32.0, 12.0, -8.0) * CELL, Vector3.UP)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -25.0, 0.0)
	light.shadow_enabled = true
	add_child(light)
	return {"ok": true, "nativeSnapshotDigest": native_result.source.get("snapshotDigest")}


func _replace_collision(native_result: Dictionary, request_identity: Dictionary, mutate_before_ack := false) -> Dictionary:
	(_body as Node).call("set_authority", _current_authority)
	var before_ack := func():
		if mutate_before_ack:
			_current_authority = request_identity.duplicate(true)
			_current_authority["sourceRevision"] = int(_current_authority.sourceRevision) + 1000
			(_body as Node).call("set_authority", _current_authority)
	var probe := func(body: StaticBody3D, identity: Dictionary) -> Dictionary:
		var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
			Vector3(-32.4, 16.497, -16.0), Vector3(-32.4, 16.497, -12.0), TERRAIN_LAYER))
		var provenance := _hit_provenance(int(hit.get("shape", -1)))
		return {"ok": not hit.is_empty() and hit.get("collider") == body
			and provenance.get("snapshotDigest") == native_result.source.snapshotDigest
			and provenance.get("artifactKey") == native_result.collision.artifactKey
			and provenance.get("requestIdentity") == identity
			and provenance.get("featureId") == "n2:blocker:tile-b:-24,-10",
			"provenance": provenance}
	var clear_guard := func(_owner: StaticBody3D, _identity: Dictionary) -> bool:
		return true
	var outcome: Dictionary = await (_body as Node).call("replace", native_result, request_identity, probe, before_ack, clear_guard)
	var physical_receipt: Dictionary = (_body as Node).call("physical_receipt", request_identity)
	if bool(outcome.get("ok", false)) != bool(physical_receipt.get("ready", false)):
		return {"ok": false, "reason": "physical_receipt_disagrees_with_replacement",
			"replacement": outcome, "physicalReceipt": physical_receipt}
	if bool(physical_receipt.get("ready", false)) and physical_receipt.get("provenance", {}).get("requestIdentity") != request_identity:
		return {"ok": false, "reason": "physical_receipt_wrong_revision"}
	_installed_shapes = (_body as Node).get("installed_shapes")
	_installed_provenance = (_body as Node).get("installed_provenance")
	_acknowledged_physics_frame = (_body as Node).get("acknowledged_physics_frame")
	_resource_lifecycle["currentRetiredShapeSetsAwaitingRelease"] = (_body as Node).get("retired_shape_sets")
	_resource_lifecycle["peakRetiredShapeSetsAwaitingRelease"] = (_body as Node).get("peak_retired_shape_sets")
	return outcome


func _install_render(native_result: Dictionary) -> Dictionary:
	var hydration_started_usec := Time.get_ticks_usec()
	var generator = RenderGeneratorScript.new()
	var setup: Dictionary = generator.setup(native_result.render)
	if not setup.ok:
		return setup
	_terrain.generator = generator
	_terrain.automatic_loading_enabled = true
	var hydration_finished_usec := Time.get_ticks_usec()
	var stats := generator.consumption_stats()
	for _frame in range(180):
		if int(stats.generatedBlockCount) > 0 and int(stats.requiredSampleWriteCount) > 0:
			break
		await get_tree().process_frame
		stats = generator.consumption_stats()
	if int(stats.generatedBlockCount) <= 0 or int(stats.requiredSampleWriteCount) <= 0:
		return {"ok": false, "reason": "voxel_tools_did_not_consume_required_native_samples", "consumption": stats}
	return {"ok": true, "consumer": "VoxelTerrain/VoxelBuffer/VoxelMesherTransvoxel", "collisionDisabled": not _terrain.generate_collisions,
		"sampleCount": setup.sampleCount, "consumption": stats,
		"hydrationMilliseconds": float(hydration_finished_usec - hydration_started_usec) / 1000.0,
		"consumptionWaitMilliseconds": float(Time.get_ticks_usec() - hydration_finished_usec) / 1000.0}


func _seam_physics(label: String) -> Dictionary:
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	var results: Array = []
	for row in [
		["solid_down", Vector3(-19.75, 35, -1.75) * CELL, Vector3(-19.75, -10, -1.75) * CELL],
		["tile_a_edit_pair", Vector3(-32.5, 12.1, -4.5) * CELL, Vector3(-34.0, 12.1, -4.5) * CELL],
		["tile_b_edit_pair", Vector3(-31.95, 12.1, -4.5) * CELL, Vector3(-31.0, 12.1, -4.5) * CELL],
		["cross_seam", Vector3(-32.5, 12.1, -4.5) * CELL, Vector3(-31.0, 12.1, -4.5) * CELL]
	]:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(row[1], row[2], TERRAIN_LAYER))
		results.append({"id": row[0], "hit": not hit.is_empty(), "soleBody": hit.is_empty() or hit.get("collider") == _body,
			"shape": int(hit.get("shape", -1)), "provenance": _hit_provenance(int(hit.get("shape", -1)))})
	return {"label": label, "results": results,
		"hitSignature": results.map(func(row): return {"id": row.id, "hit": row.hit, "shape": row.shape})}


func _physics_evidence() -> Dictionary:
	await get_tree().physics_frame
	var world := get_world_3d().direct_space_state
	var rays := []
	for row in [
		["solid_down", Vector3(-19.75, 35, -1.75) * CELL, Vector3(-19.75, -10, -1.75) * CELL, true],
		["cave_clearance", Vector3(-33, -2, -5) * CELL, Vector3(-32, -2, -5) * CELL, false],
		["cave_wall", Vector3(-35.25, -1.75, -4.75) * CELL, Vector3(-29.75, -1.75, -4.75) * CELL, true],
		["blocker_hit", Vector3(-32.4, 16.497, -16.0), Vector3(-32.4, 16.497, -12.0), true],
		["blocker_miss", Vector3(-30.0, 16.497, -16.0), Vector3(-30.0, 16.497, -12.0), false]
	]:
		var query := PhysicsRayQueryParameters3D.create(row[1], row[2], TERRAIN_LAYER)
		var hit := world.intersect_ray(query)
		var provenance := _hit_provenance(int(hit.get("shape", -1)))
		rays.append({"id": row[0], "expectedHit": row[3], "hit": not hit.is_empty(), "soleBody": hit.is_empty() or hit.get("collider") == _body,
			"shape": int(hit.get("shape", -1)), "provenance": provenance})
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	var shape_query := PhysicsShapeQueryParameters3D.new()
	shape_query.shape = capsule
	shape_query.transform = Transform3D(Basis.IDENTITY, Vector3(-30.0, 21.0, -5.0))
	shape_query.motion = Vector3(0.0, -12.0, 0.0)
	shape_query.collision_mask = TERRAIN_LAYER
	var sweep = world.cast_motion(shape_query)
	_actor = CharacterBody3D.new()
	_actor.name = "N2GenericTraversalActor"
	_actor.collision_layer = 0
	_actor.collision_mask = TERRAIN_LAYER
	_actor.position = Vector3(-30.0, 25.0, -5.0)
	var actor_shape := CollisionShape3D.new()
	actor_shape.shape = capsule
	_actor.add_child(actor_shape)
	add_child(_actor)
	var start := _actor.position
	var touched_floor := false
	for _frame in range(120):
		_actor.velocity = Vector3(1.0, _actor.velocity.y - 9.8 / 60.0, 0.25)
		_actor.move_and_slide()
		touched_floor = touched_floor or _actor.is_on_floor()
		await get_tree().physics_frame
	var slope_end := _actor.position
	_actor.position = Vector3(-32.4, 16.497, -16.0)
	_actor.velocity = Vector3.ZERO
	await get_tree().physics_frame
	var touched_blocker := false
	for _frame in range(90):
		_actor.velocity = Vector3(0.0, 0.0, 4.0)
		_actor.move_and_slide()
		touched_blocker = touched_blocker or _actor.is_on_wall()
		await get_tree().physics_frame
	var blocker_end := _actor.position
	var expected_snapshot := String(_installed_provenance.get("snapshotDigest", ""))
	var expected_artifact := String(_installed_provenance.get("collisionArtifactKey", ""))
	var rays_ok := rays.all(func(row):
		if row.hit != row.expectedHit or not row.soleBody: return false
		if not row.hit: return true
		return row.provenance.get("snapshotDigest") == expected_snapshot \
			and row.provenance.get("artifactKey") == expected_artifact)
	var sweep_hit := sweep.size() == 2 and float(sweep[0]) >= 0.0 and float(sweep[0]) < 1.0 \
		and float(sweep[1]) >= float(sweep[0]) and float(sweep[1]) <= 1.0
	var traversal_ok := touched_floor and slope_end != start and touched_blocker and blocker_end.z < -14.0
	return {"ok": rays_ok and sweep_hit and traversal_ok, "rays": rays,
		"capsuleSweep": {"safeFraction": sweep[0] if sweep.size() > 0 else null, "unsafeFraction": sweep[1] if sweep.size() > 1 else null},
		"characterBody": {"start": _v3(start), "slopeEnd": _v3(slope_end), "touchedFloor": touched_floor,
			"blockerStart": [-32.4, 16.497, -16.0], "blockerEnd": _v3(blocker_end), "touchedBlocker": touched_blocker}}


func _hit_provenance(shape_index: int) -> Dictionary:
	if shape_index < 0 or _body == null:
		return {}
	var owner_id := _body.shape_find_owner(shape_index)
	var owner = _body.shape_owner_get_owner(owner_id) if owner_id >= 0 else null
	return owner.get_meta("provenance", {}) if owner != null else {}


func _authority_inventory() -> Dictionary:
	var bodies := get_tree().get_nodes_in_group("n2_never_used")
	bodies.clear()
	for node in _walk(self):
		if node is StaticBody3D: bodies.append(node)
	var project_owned := bodies.filter(func(node): return bool(node.get_meta("n2ProjectOwnedTerrainBody", false)))
	return {"staticBodyCount": bodies.size(), "projectOwnedTerrainBodies": project_owned.size(),
		"voxelTerrainCollisionEnabled": bool(_terrain.generate_collisions) if _terrain != null else false,
		"installedShapeCount": _installed_shapes.size()}


func _walk(node: Node) -> Array:
	var result: Array = [node]
	for child in node.get_children(): result.append_array(_walk(child))
	return result


func _timing_record(native_timings: Dictionary, install: Dictionary, render_result: Dictionary) -> Dictionary:
	return {"requestValidationMilliseconds": native_timings.get("requestValidationMilliseconds"),
		"deltaResolutionMilliseconds": native_timings.get("deltaResolutionMilliseconds"),
		"sourceMilliseconds": native_timings.get("sourceMilliseconds"),
		"collisionMilliseconds": native_timings.get("collisionMilliseconds"),
		"renderPackMilliseconds": native_timings.get("renderPackMilliseconds"),
		"hydrationMilliseconds": render_result.get("hydrationMilliseconds"),
		"renderConsumptionWaitMilliseconds": render_result.get("consumptionWaitMilliseconds"),
		"installMilliseconds": install.get("installMilliseconds"),
		"acknowledgementMilliseconds": install.get("acknowledgementMilliseconds"),
		"totalMilliseconds": float(Time.get_ticks_usec() - _started_usec) / 1000.0}


func _expected_native_api() -> Dictionary:
	return {"class": "TerrainMeshingBackend", "method": PREPARE_METHOD,
		"requestSchema": "n2-native-vertical-slice-request/v1", "resultSchema": RESULT_SCHEMA,
		"preparedPayloadCapBytes": 4194304,
		"resultFields": ["requestIdentity", "preparedPayloadBytes", "source.columns(Packed*)", "source.nameTables(PackedStringArray)", "source.generatedSourceId", "source.sparseSources", "source.noiseFloatBits", "source.snapshotDigest",
			"collision.artifactKey", "collision.snapshotDigest", "collision.tileTriangles[2]{coordinateFrame=world,includesDeclaredBlockers=false,vertices}",
			"collision.blockers[1]{id,center,size,semanticClass,physicalIntent}",
			"render.artifactKey", "render.snapshotDigest", "render.sdfValues(PackedFloat32Array,bounded SDF channel values)", "render.indices/data5(PackedByteArray,exact channel values)", "timings"]}


func _capture() -> void:
	if _screenshot_path.is_empty(): return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_screenshot_path.get_base_dir())
	get_viewport().get_texture().get_image().save_png(_screenshot_path)


func _finish(passed: bool, reason: String, evidence: Dictionary) -> void:
	var report := {"schema": REPORT_SCHEMA, "passed": passed, "reason": reason,
		"evidenceLevel": "headed N2-only lattice parity and one-authority physics fixture; no production cutover or gameplay claim",
		"finished": true, "elapsedMilliseconds": float(Time.get_ticks_usec() - _started_usec) / 1000.0,
		"evidence": evidence, "godotVersion": Engine.get_version_info()}
	if not _report_path.is_empty():
		DirAccess.make_dir_recursive_absolute(_report_path.get_base_dir())
		var file := FileAccess.open(_report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
			file.close()
	get_tree().quit(0 if passed else 1)


func _v3(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
