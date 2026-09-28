extends SceneTree

const Oracle := preload("res://scripts/testing/native_world/N3EffectiveTerrainOracle.gd")
const CitadelSiteFieldScript := preload("res://scripts/world/CitadelSiteField.gd")
const ChunkPinScript := preload("res://scripts/world/ActiveEffectiveTerrainChunkPin.gd")

const REPORT_SCHEMA := "n3-effective-terrain-differential-report/v1"
const EVIDENCE_LEVEL := "shadow-only/no-production-cutover"
const DEBUG_DLL_PATH := "res://addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll"
const CELL := 1.35
const PAGE_CELLS := 280
const EXPECTED_COUNTS := {
	"surfaceColumns": 10,
	"cellCenters": 11,
	"latticeNumeric": 11,
	"worldNumeric": 6,
	"surfaceProjectionNumeric": 9,
}
const MATERIALS := ["air", "grass", "dirt", "stone", "sand", "snow", "deepStone", "bedrock", "clay", "gravel", "coalOre", "ironOre", "crystalOre", "copperOre", "mud", "water", "lava"]
const BIOMES := ["plains", "forest", "swamp", "desert", "savanna", "snow", "taiga", "tundra", "ocean", "beach", "town", "underground", "deep_underground", "underground_air", "alpine"]
const FLUIDS := ["", "water", "lava"]

var failures: Array = []
var mismatches: Array = []
var report_path := ""
var native_shadow_only := true
var query_counts := EXPECTED_COUNTS.duplicate(true)
var checks := {
	"sourceParity": false,
	"independentGoldens": false,
	"mutationChecks": false,
	"pinLifetime": false,
	"noProductionMutation": false,
}
var evidence := {}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	report_path = OS.get_environment("N3_EFFECTIVE_TERRAIN_DIFFERENTIAL_REPORT").strip_edges()
	var golden_hash_before := FileAccess.get_sha256(Oracle.GOLDENS_PATH)
	var dll_hash_before := FileAccess.get_sha256(DEBUG_DLL_PATH)
	_require(not report_path.is_empty() and not FileAccess.file_exists(report_path), "fresh_report_path_required")
	_require(_valid_digest(golden_hash_before), "goldens_hash_unavailable")
	_require(_valid_digest(dll_hash_before), "debug_adapter_hash_unavailable")
	if not failures.is_empty():
		_finish(golden_hash_before, dll_hash_before)
		return

	# The oracle is fully constructed and sampled before the native class is
	# instantiated. Its production GDScript path has no native dependency.
	var goldens: Dictionary = Oracle.load_goldens()
	_require(bool(goldens.get("ok", true)), "goldens_load_failed")
	var world_spec: Dictionary = goldens.get("world", {}) if goldens.get("world") is Dictionary else {}
	var profiles: Array = Oracle.site_profiles_from_goldens(goldens)
	_require(profiles.size() == (world_spec.get("siteProfiles", []) as Array).size(), "oracle_site_profile_count_mismatch")
	var oracle_world: Dictionary = Oracle.build_world(
		String(world_spec.get("seed", "")), profiles, Oracle.town_overrides_from_goldens(goldens))
	var oracle_samples: Dictionary = Oracle.sample_all(oracle_world, goldens)
	var oracle_golden_compare: Dictionary = Oracle.compare_to_goldens(oracle_samples, goldens)
	query_counts = _counts(oracle_samples)
	checks.independentGoldens = bool(oracle_world.get("ok", false)) \
		and bool(oracle_samples.get("ok", false)) \
		and not bool(oracle_samples.get("forbiddenNativePathsUsed", true)) \
		and bool(oracle_golden_compare.get("ok", false)) \
		and query_counts == EXPECTED_COUNTS \
		and golden_hash_before == FileAccess.get_sha256(Oracle.GOLDENS_PATH)
	_require(checks.independentGoldens, "independent_oracle_or_goldens_failed")
	if not failures.is_empty():
		evidence["oracleGoldenComparison"] = oracle_golden_compare
		_finish(golden_hash_before, dll_hash_before)
		return

	_require(ClassDB.class_exists("NativeWorldBackend"), "native_backend_class_missing")
	var backend = ClassDB.instantiate("NativeWorldBackend") if ClassDB.class_exists("NativeWorldBackend") else null
	_require(backend != null, "native_backend_instantiation_failed")
	if backend == null:
		_finish(golden_hash_before, dll_hash_before)
		return

	var initialized: Dictionary = backend.initialize(_initialization_request(world_spec))
	_envelope(initialized, "initialize")
	_require(initialized.get("status") == "ready", "native_initialization_failed")
	var groups: Dictionary = _group_queries(goldens)
	_require(not groups.is_empty(), "native_query_groups_empty")
	var pages: Array = groups.keys()
	pages.sort_custom(func(left: Vector2i, right: Vector2i): return left.y < right.y or left.y == right.y and left.x < right.x)

	var shaping := _resolve_shaping(backend, pages, profiles, String(world_spec.get("seed", "")))
	_require(bool(shaping.get("ok", false)), "native_shaping_resolution_failed")
	evidence["shaping"] = shaping
	if not failures.is_empty():
		_finish(golden_hash_before, dll_hash_before)
		return

	var old_pages := _pin_pages(backend, pages, 0)
	_require(bool(old_pages.get("ok", false)), "old_page_pin_failed")
	var old_chunk_pin: Dictionary = {}
	if bool(old_pages.get("ok", false)) and not pages.is_empty():
		old_chunk_pin = ChunkPinScript.capture(backend, String(world_spec.get("seed", "")),
			Vector2i(pages[0].x * 10, pages[0].y * 10))
		_require(bool(old_chunk_pin.get("ok", false)), "old_effective_chunk_pin_capture_failed")
	var mutation := _commit_mutations(backend, world_spec)
	_require(bool(mutation.get("ok", false)), "native_mutation_contract_failed")
	if bool(old_chunk_pin.get("ok", false)):
		_require(not ChunkPinScript.is_current(backend, String(world_spec.get("seed", "")), old_chunk_pin),
			"old_effective_chunk_pin_survived_delta_mutation")
	checks.mutationChecks = bool(mutation.get("ok", false))
	evidence["mutations"] = mutation
	var new_pages := _pin_pages(backend, pages, 1)
	_require(bool(new_pages.get("ok", false)), "new_page_pin_failed")
	if bool(new_pages.get("ok", false)) and not pages.is_empty():
		var test_chunk: Vector2i = Vector2i(pages[0].x * 10, pages[0].y * 10)
		var admitted_chunk: Dictionary = ChunkPinScript.capture(backend, String(world_spec.get("seed", "")), test_chunk)
		_require(bool(admitted_chunk.get("ok", false)) and admitted_chunk.get("primaryPage") == pages[0],
			"effective_chunk_pin_capture_failed")
		_require(ChunkPinScript.is_current(backend, String(world_spec.get("seed", "")), admitted_chunk),
			"effective_chunk_pin_freshness_failed")
		var forged_chunk := admitted_chunk.duplicate(true)
		forged_chunk.pageStatus.terrainDeltaRevision = 0
		_require(not ChunkPinScript.is_current(backend, String(world_spec.get("seed", "")), forged_chunk),
			"effective_chunk_pin_tamper_accepted")
		_require(not ChunkPinScript.is_current(backend, "different-seed", admitted_chunk),
			"effective_chunk_pin_seed_mismatch_accepted")
	if not failures.is_empty():
		_finish(golden_hash_before, dll_hash_before)
		return

	var owner_status: Dictionary = backend.status()
	_envelope(owner_status, "owner_status")
	_require(owner_status.get("sourceSeedText") == String(world_spec.get("seed", "")),
		"native_owner_seed_mismatch")
	var expected_source_identity := _identity_hex(owner_status.get("sourceIdentity"))
	var expected_shaping_identity := _identity_hex(owner_status.get("shapingRegistryIdentity"))
	backend = null
	await process_frame

	var sampled := _sample_after_owner_release(groups, pages, old_pages.pages, new_pages.pages,
		expected_source_identity, expected_shaping_identity)
	evidence["sampling"] = sampled.duplicate(true)
	if evidence.sampling.has("samples"):
		evidence.sampling.erase("samples")
	_require(bool(sampled.get("ok", false)), "native_sampling_after_owner_release_failed")
	checks.pinLifetime = bool(sampled.get("ok", false))
	var native_samples: Dictionary = sampled.get("samples", {})
	var native_golden_compare: Dictionary = Oracle.compare_to_goldens(native_samples, goldens)
	_compare_exact(oracle_samples, native_samples, "samples")
	if not bool(native_golden_compare.get("ok", false)):
		for mismatch in native_golden_compare.get("mismatches", []):
			if mismatches.size() < 128:
				mismatches.append({"comparison": "native_to_goldens", "detail": mismatch})
	checks.sourceParity = bool(sampled.get("ok", false)) \
		and bool(native_golden_compare.get("ok", false)) and mismatches.is_empty()
	_require(checks.sourceParity, "native_oracle_source_parity_failed")
	evidence["pinIdentities"] = sampled.get("identities", [])
	evidence["nativeBatchSchema"] = sampled.get("batchSchema", {})
	evidence["oracleGoldenComparison"] = oracle_golden_compare
	evidence["nativeGoldenComparison"] = native_golden_compare

	var golden_hash_after := FileAccess.get_sha256(Oracle.GOLDENS_PATH)
	var dll_hash_after := FileAccess.get_sha256(DEBUG_DLL_PATH)
	checks.noProductionMutation = native_shadow_only \
		and golden_hash_before == golden_hash_after and dll_hash_before == dll_hash_after
	_require(checks.noProductionMutation, "production_or_authoritative_input_mutated")
	_finish(golden_hash_before, dll_hash_before, golden_hash_after, dll_hash_after,
		expected_source_identity, expected_shaping_identity, String((goldens.get("querySet", {}) as Dictionary).get("id", "")))


func _initialization_request(world_spec: Dictionary) -> Dictionary:
	var towns: Array = []
	for value in world_spec.get("townOverrides", []):
		var region := _cell2(value.get("region", []))
		var row := {"region": region, "hasTown": bool(value.get("hasTown", false))}
		if row.hasTown:
			row["centerX"] = int(value.get("center", [0, 0])[0])
			row["centerZ"] = int(value.get("center", [0, 0])[1])
			row["radiusCells"] = int(value.get("radius", 0))
			row["levelMeters"] = float(value.get("level", 0.0))
		towns.append(row)
	var ordinary: Dictionary = world_spec.get("ordinaryStructurePolicy", {})
	return {
		"schema": "n3-native-world-backend-initialize/v1",
		"seedText": String(world_spec.get("seed", "")),
		"revisions": {"sourceSchema": 2, "terrainGenerator": 1, "biomeRegionField": 2,
			"latticeQuery": 1, "cellCenterQuery": 1, "surfaceColumnQuery": 1},
		"constants": {"cellSizeMeters": CELL, "cellCenterOffsetCells": 0.5,
			"worldBottomCellY": -64, "waterLevelMeters": 11.1,
			"minimumSurfaceMeters": 4.0, "maximumSurfaceMeters": 120.0},
		"sitePolicy": {"sourcePolicyRevision": 1, "surveyGenerationPolicyRevision": 1,
			"ordinaryRegionCells": int(ordinary.get("regionCells", 0)),
			"ordinarySpawnChance": float(ordinary.get("spawnChance", NAN)),
			"townOverrides": towns},
	}


func _resolve_shaping(backend, pages: Array, profiles: Array, seed: String) -> Dictionary:
	var requests_by_region := {}
	for page in pages:
		var readiness: Dictionary = backend.shaping_requests(page)
		_envelope(readiness, "shaping_requests:%s" % page)
		if readiness.get("status") == "failed":
			return {"ok": false, "reason": readiness.get("reason", "")}
		for request in readiness.get("requests", []):
			var region: Vector2i = request.get("region", Vector2i.ZERO)
			var key := _v2_key(region)
			if requests_by_region.has(key) and requests_by_region[key] != request:
				return {"ok": false, "reason": "conflicting_shaping_request", "region": region}
			requests_by_region[key] = request
	var profiles_by_site := {}
	for profile in profiles:
		profiles_by_site[String(profile.get("siteId", ""))] = profile
	var resolutions: Array = []
	var prepared_count := 0
	var request_keys: Array = requests_by_region.keys()
	request_keys.sort()
	for key in request_keys:
		var request: Dictionary = requests_by_region[key]
		var region: Vector2i = request.region
		var candidate: Dictionary = CitadelSiteFieldScript.candidate_for_region(seed, region)
		if candidate.is_empty() or String(candidate.get("siteId", "")) != String(request.get("siteId", "")) \
				or candidate.get("centerCell") != request.get("centerCell") \
				or int(candidate.get("recipeSeed", -1)) != int(request.get("recipeSeed", -2)):
			return {"ok": false, "reason": "shaping_candidate_identity_mismatch", "request": request, "candidate": candidate}
		var site_id := String(candidate.siteId)
		if profiles_by_site.has(site_id):
			var profile: Dictionary = profiles_by_site[site_id]
			var envelope: Rect2i = profile.envelopeCells
			var reservation: Rect2i = profile.reservationCells
			var source_reservation: Rect2i = envelope.grow(1).merge(reservation)
			resolutions.append({
				"region": region, "requestIdentity": request.requestIdentity,
				"workerSourceKey": request.workerSourceKey, "kind": "prepared", "reasonCode": "",
				"candidate": candidate.duplicate(true),
				"manifest": {"ready": true, "sourceSignature": String(profile.sourceSignature)},
				"reservationCells": source_reservation,
				"profile": profile.duplicate(true),
			})
			prepared_count += 1
		else:
			resolutions.append({"region": region, "requestIdentity": request.requestIdentity,
				"workerSourceKey": request.workerSourceKey, "kind": "absent", "reasonCode": "n3_differential_absent"})
	if prepared_count != profiles.size():
		return {"ok": false, "reason": "prepared_profile_not_requested", "prepared": prepared_count, "profiles": profiles.size()}
	var receipts: Array = []
	var replays: Array = []
	for start in range(0, resolutions.size(), 64):
		var batch := resolutions.slice(start, mini(start + 64, resolutions.size()))
		var receipt: Dictionary = backend.apply_shaping_resolutions(batch)
		_envelope(receipt, "apply_shaping_resolutions")
		if receipt.get("status") != "ready" or receipt.get("commitStatus") != "committed":
			return {"ok": false, "reason": "shaping_commit_failed", "receipt": receipt}
		receipts.append(_receipt_fields(receipt))
		var replay: Dictionary = backend.apply_shaping_resolutions(batch)
		_envelope(replay, "replay_shaping_resolutions")
		if replay.get("status") != "ready" or replay.get("commitStatus") != "no_change" \
				or replay.get("shapingRegistryRevision") != receipt.get("shapingRegistryRevision") \
				or replay.get("shapingRegistryIdentity") != receipt.get("shapingRegistryIdentity"):
			return {"ok": false, "reason": "shaping_replay_failed", "replay": replay}
		replays.append(_receipt_fields(replay))
	for page in pages:
		var ready: Dictionary = backend.shaping_requests(page)
		_envelope(ready, "ready_shaping_requests:%s" % page)
		if ready.get("status") != "ready" or not (ready.get("requests", []) as Array).is_empty():
			return {"ok": false, "reason": "shaping_page_not_ready", "page": page, "readiness": ready}
	return {"ok": true, "requestCount": requests_by_region.size(), "preparedCount": prepared_count,
		"absentCount": resolutions.size() - prepared_count, "receipts": receipts, "replays": replays}


func _pin_pages(backend, pages: Array, expected_revision: int) -> Dictionary:
	var result := {}
	for page in pages:
		var pin: Dictionary = backend.pin_effective_page(page)
		_envelope(pin, "pin_effective_page:%s" % page)
		if pin.get("status") != "ready" or pin.get("page") == null:
			return {"ok": false, "page": page, "pin": pin}
		var page_owner = pin.page
		var status: Dictionary = page_owner.status()
		_envelope(status, "page_status:%s" % page)
		if status.get("status") != "ready" or int(status.get("terrainDeltaRevision", -1)) != expected_revision \
				or status.get("primaryPage") != page:
			return {"ok": false, "page": page, "status": status}
		result[page] = page_owner
	return {"ok": true, "pages": result}


func _commit_mutations(backend, world_spec: Dictionary) -> Dictionary:
	var operations: Array = []
	var durable_count := 0
	var overlay_count := 0
	for mutation in world_spec.get("mutations", []):
		var kind := String(mutation.get("kind", ""))
		var name_space := "durable_terrain" if kind == "durable" else "scene_overlay"
		if kind == "durable": durable_count += 1
		elif kind == "sceneOverlay": overlay_count += 1
		else: return {"ok": false, "reason": "unsupported_mutation_kind", "kind": kind}
		var native_state := _native_state(mutation.get("state", {}), String(mutation.get("reason", "")))
		if native_state.is_empty(): return {"ok": false, "reason": "mutation_state_mapping_failed"}
		operations.append({"namespace": name_space, "kind": "set",
			"cell": _cell3(mutation.get("cell", [])), "state": native_state})
	var transaction := {"schema": "n3-native-typed-cell-transaction/v1",
		"transactionId": "n3-effective-terrain-differential:mutations-v1",
		"expectedRevision": 0, "operations": operations}
	var committed: Dictionary = backend.commit_typed_cells(transaction)
	_envelope(committed, "commit_typed_cells")
	var replay: Dictionary = backend.commit_typed_cells(transaction)
	_envelope(replay, "replay_typed_cells")
	var changed := transaction.duplicate(true)
	changed.operations[0].state.density = float(changed.operations[0].state.density) - 0.125
	var changed_replay: Dictionary = backend.commit_typed_cells(changed)
	_envelope(changed_replay, "changed_replay_typed_cells")
	var stale := transaction.duplicate(true)
	stale.transactionId = "n3-effective-terrain-differential:stale-v1"
	var stale_receipt: Dictionary = backend.commit_typed_cells(stale)
	_envelope(stale_receipt, "stale_typed_cells")
	var status: Dictionary = backend.status()
	_envelope(status, "post_mutation_status")
	var ok: bool = durable_count == 3 and overlay_count == 1 \
		and committed.get("status") == "ready" and committed.get("commitStatus") == "committed" and int(committed.get("revision", -1)) == 1 \
		and replay.get("status") == "ready" and replay.get("commitStatus") == "idempotent_replay" and int(replay.get("revision", -1)) == 1 \
		and changed_replay.get("status") == "failed" and String(changed_replay.get("reason", "")).contains("transaction") \
		and stale_receipt.get("status") == "failed" and String(stale_receipt.get("reason", "")).contains("revision") \
		and int(status.get("terrainDeltaRevision", -1)) == 1
	return {"ok": ok, "durableCount": durable_count, "sceneOverlayCount": overlay_count,
		"committed": _receipt_fields(committed), "replay": _receipt_fields(replay),
		"changedReplay": _receipt_fields(changed_replay), "stale": _receipt_fields(stale_receipt),
		"finalRevision": int(status.get("terrainDeltaRevision", -1))}


func _sample_after_owner_release(groups: Dictionary, pages: Array, old_pages: Dictionary,
		new_pages: Dictionary, source_identity: String, shaping_identity: String) -> Dictionary:
	var samples := {"ok": true, "schema": Oracle.SAMPLE_SCHEMA, "oracleSchema": Oracle.SCHEMA,
		"seed": "atlas-1492", "forbiddenNativePathsUsed": false}
	for channel in EXPECTED_COUNTS:
		var rows: Array = []
		rows.resize(int(EXPECTED_COUNTS[channel]))
		samples[channel] = rows
	var identities: Array = []
	var total_old := 0
	var total_new := 0
	var payload_bytes := 0
	var changed_pin_count := 0
	for page in pages:
		var group: Dictionary = groups[page]
		var request: Dictionary = group.request
		var old_result: Dictionary = old_pages[page].sample_batch(request)
		var new_result: Dictionary = new_pages[page].sample_batch(request)
		_envelope(old_result, "old_sample_batch:%s" % page)
		_envelope(new_result, "new_sample_batch:%s" % page)
		if old_result.get("status") != "ready" or new_result.get("status") != "ready":
			return {"ok": false, "reason": "page_batch_failed", "page": page}
		if old_result.get("resultSchema") != "n3-effective-terrain-batch-result/v1" \
				or new_result.get("resultSchema") != "n3-effective-terrain-batch-result/v1" \
				or int(old_result.get("schemaRevision", -1)) != 2 or int(new_result.get("schemaRevision", -1)) != 2:
			return {"ok": false, "reason": "batch_schema_mismatch", "page": page}
		var old_source := _identity_hex(old_result.get("sourceIdentity"))
		var new_source := _identity_hex(new_result.get("sourceIdentity"))
		var old_shaping := _identity_hex(old_result.get("shapingRegistryIdentity"))
		var new_shaping := _identity_hex(new_result.get("shapingRegistryIdentity"))
		var old_pin := _identity_hex(old_result.get("pinIdentity"))
		var new_pin := _identity_hex(new_result.get("pinIdentity"))
		if old_source != source_identity or new_source != source_identity \
				or old_shaping != shaping_identity or new_shaping != shaping_identity \
				or not _valid_digest(old_pin) or not _valid_digest(new_pin) \
				or int(old_result.get("terrainDeltaRevision", -1)) != 0 \
				or int(new_result.get("terrainDeltaRevision", -1)) != 1:
			return {"ok": false, "reason": "page_identity_or_revision_mismatch", "page": page,
				"expectedSource": source_identity, "oldSource": old_source, "newSource": new_source,
				"expectedShaping": shaping_identity, "oldShaping": old_shaping, "newShaping": new_shaping,
				"oldPin": old_pin, "newPin": new_pin,
				"oldRevision": old_result.get("terrainDeltaRevision"), "newRevision": new_result.get("terrainDeltaRevision")}
		if old_pin != new_pin: changed_pin_count += 1
		identities.append({"page": _v2(page), "sourceIdentity": new_source,
			"shapingRegistryIdentity": new_shaping, "oldPinIdentity": old_pin, "newPinIdentity": new_pin,
			"pinContentChanged": old_pin != new_pin,
			"oldTerrainDeltaRevision": 0, "newTerrainDeltaRevision": 1})
		payload_bytes += int(new_result.get("preparedPayloadBytes", -1))
		for channel in EXPECTED_COUNTS:
			var native_rows = new_result.get(channel)
			var old_rows = old_result.get(channel)
			var metadata = group.metadata.get(channel)
			if not native_rows is Array or not old_rows is Array or not metadata is Array \
					or native_rows.size() != metadata.size() or old_rows.size() != metadata.size():
				return {"ok": false, "reason": "page_channel_count_mismatch", "page": page, "channel": channel}
			total_old += old_rows.size()
			total_new += native_rows.size()
			for index in range(native_rows.size()):
				var query: Dictionary = metadata[index]
				var row := _normalize_row(channel, query, native_rows[index])
				if row.is_empty():
					return {"ok": false, "reason": "native_row_normalization_failed", "page": page, "channel": channel, "ordinal": query.ordinal}
				var sample_rows: Array = samples[channel]
				sample_rows[int(query.ordinal)] = row
	for channel in EXPECTED_COUNTS:
		for ordinal in range(int(EXPECTED_COUNTS[channel])):
			var row = samples[channel][ordinal]
			if not row is Dictionary or int(row.get("ordinal", -1)) != ordinal:
				return {"ok": false, "reason": "native_reassembly_incomplete", "channel": channel, "ordinal": ordinal}
	var expected_total := 0
	for count in EXPECTED_COUNTS.values(): expected_total += int(count)
	return {"ok": total_old == expected_total and total_new == expected_total and changed_pin_count > 0,
		"samples": samples, "identities": identities,
		"batchSchema": {"request": "n3-effective-terrain-batch-request/v1",
			"result": "n3-effective-terrain-batch-result/v1", "revision": 2,
			"groupCount": pages.size(), "changedPinCount": changed_pin_count,
			"oldQueryCount": total_old, "newQueryCount": total_new,
			"newPreparedPayloadBytes": payload_bytes}}


func _group_queries(goldens: Dictionary) -> Dictionary:
	var groups := {}
	for channel in EXPECTED_COUNTS:
		for query in goldens.queries.get(channel, []):
			var page := _query_page(channel, query)
			if not groups.has(page):
				groups[page] = {"request": _empty_batch(), "metadata": _empty_channels()}
			var group: Dictionary = groups[page]
			group.request[channel].append(_native_query(channel, query))
			group.metadata[channel].append(query)
	return groups


func _query_page(channel: String, query: Dictionary) -> Vector2i:
	if channel == "worldNumeric":
		var position := _position(query.input.position)
		return _page_for_cell(Vector2i(floori(position.x / CELL), floori(position.z / CELL)))
	var values = query.input.cell
	return _page_for_cell(Vector2i(int(values[0]), int(values[1] if channel == "surfaceColumns" else values[2])))


func _native_query(channel: String, query: Dictionary) -> Dictionary:
	if channel == "surfaceColumns":
		return {"coordinate": _cell2(query.input.cell), "intent": "gameplay"}
	if channel == "cellCenters":
		return {"coordinate": _cell3(query.input.cell), "intent": "gameplay"}
	if channel == "latticeNumeric":
		return {"coordinate": _cell3(query.input.cell), "intent": "terrain_mesh"}
	if channel == "worldNumeric":
		return {"position": _position(query.input.position), "intent": "terrain_mesh", "semanticRevision": 1}
	return {"coordinate": _cell3(query.input.cell), "intent": "terrain_collision", "semanticRevision": 1}


func _normalize_row(channel: String, query: Dictionary, value) -> Dictionary:
	if not value is Dictionary:
		return {}
	var native: Dictionary = value
	var actual: Dictionary
	if channel == "surfaceColumns": actual = _normalize_surface(native)
	elif channel == "cellCenters": actual = _normalize_center(native)
	elif channel == "latticeNumeric":
		var lattice_request: Dictionary = native.get("requested", {})
		if lattice_request.get("intent") != "terrain_mesh" or lattice_request.get("coordinate") != _cell3(query.input.cell): return {}
		actual = _normalize_numeric(native, Vector3(_cell3(query.input.cell)) * CELL)
	elif channel == "worldNumeric":
		if native.get("intent") != "terrain_mesh" or int(native.get("semanticRevision", -1)) != 1 \
				or not native.get("requestedPosition") is Vector3: return {}
		actual = _normalize_numeric(native, native.requestedPosition)
	else:
		var cell := _cell3(query.input.cell)
		var projection_request: Dictionary = native.get("requested", {})
		if projection_request.get("intent") != "terrain_collision" \
				or projection_request.get("coordinate") != cell \
				or int(native.get("semanticRevision", -1)) != 1: return {}
		actual = _normalize_numeric(native, Vector3(float(cell.x) * CELL, float(cell.y) * CELL, float(cell.z) * CELL))
	if actual.is_empty(): return {}
	return {"ordinal": int(query.ordinal), "id": String(query.id), "input": query.input, "actual": actual}


func _normalize_surface(native: Dictionary) -> Dictionary:
	var requested: Dictionary = native.get("requested", {})
	if requested.get("intent") != "gameplay" or not requested.get("coordinate") is Vector2i \
			or not native.get("sourceCell") is Vector2i \
			or not _enum_matches(native, "biomeId", "biome", BIOMES): return {}
	var reference := float(native.get("referenceSurfaceY", NAN))
	var deformed := float(native.get("deformedSurfaceY", NAN))
	var volume := float(native.get("volumeSurfaceY", NAN))
	if not is_finite(reference) or not is_finite(deformed) or not is_finite(volume): return {}
	return {"requestedCell": _v2(requested.coordinate), "sourceCell": _v2(native.sourceCell),
		"referenceSurfaceY": reference, "referenceSurfaceYBits": _f64_bits(reference),
		"deformedSurfaceY": deformed, "deformedSurfaceYBits": _f64_bits(deformed),
		"volumeSurfaceY": volume, "volumeSurfaceYBits": _f64_bits(volume),
		"surfaceBiome": String(native.biome)}


func _normalize_center(native: Dictionary) -> Dictionary:
	var requested: Dictionary = native.get("requested", {})
	if requested.get("intent") != "gameplay" or not requested.get("coordinate") is Vector3i \
			or not native.get("sourceCell") is Vector3i \
			or not _enum_matches(native, "materialId", "material", MATERIALS) \
			or not _enum_matches(native, "biomeId", "biome", BIOMES) \
			or not _enum_matches(native, "fluidId", "fluid", FLUIDS) \
			or not native.get("light") is Vector2i: return {}
	if bool(native.get("edited", false)) == bool(native.get("generated", true)): return {}
	var sparse = native.get("editedSparseState")
	if bool(native.edited) != (sparse is Dictionary): return {}
	var cell: Vector3i = requested.coordinate
	var position := Vector3((float(cell.x) + 0.5) * CELL, (float(cell.y) + 0.5) * CELL, (float(cell.z) + 0.5) * CELL)
	var block_id := String((sparse as Dictionary).get("blockId", "")) if sparse is Dictionary else String(native.material)
	var light: Vector2i = native.light
	var density := float(native.get("density", NAN))
	if not is_finite(density) or block_id.is_empty(): return {}
	return {"requestedCell": _v3i(cell), "sourceCell": _v3i(native.sourceCell),
		"positionBits": _v3_f32_bits(position), "material": String(native.material), "blockId": block_id,
		"biome": String(native.biome), "solid": bool(native.solid), "density": density,
		"densityBits": _f64_bits(density), "fluid": String(native.fluid),
		"light": {"sky": light.x, "block": light.y},
		"generated": bool(native.generated), "edited": bool(native.edited)}


func _normalize_numeric(native: Dictionary, position: Vector3) -> Dictionary:
	if not position.is_finite() or not native.get("requestedCell") is Vector3i or not native.get("sourceCell") is Vector3i \
			or not _enum_matches(native, "materialId", "material", MATERIALS): return {}
	if bool(native.get("edited", false)) == bool(native.get("generated", true)): return {}
	var sparse = native.get("editedSparseState")
	if bool(native.edited) != (sparse is Dictionary): return {}
	# The production GDScript API carries both values through Vector3 before
	# returning them.  Normalize the adapter's double-valued Variant fields at
	# that same float32 boundary before comparing their exact f64 encodings.
	var density := _f32(float(native.get("density", NAN)))
	var surface := _f32(float(native.get("surfaceY", NAN)))
	if not is_finite(density) or not is_finite(surface): return {}
	var underground := bool(native.get("undergroundAirVoid", false))
	return {"positionBits": _v3_f32_bits(position), "requestedCell": _v3i(native.requestedCell),
		"sourceCell": _v3i(native.sourceCell), "density": density, "densityBits": _f64_bits(density),
		"solid": density >= 0.0, "undergroundAirVoid": underground,
		"marker": "underground_air" if underground else "none", "surfaceY": surface,
		"surfaceYBits": _f64_bits(surface), "material": String(native.material),
		"generated": bool(native.generated), "edited": bool(native.edited)}


func _f32(value: float) -> float:
	return float(PackedFloat32Array([value])[0])


func _native_state(state_value, reason: String) -> Dictionary:
	if not state_value is Dictionary: return {}
	var state: Dictionary = state_value
	var material_id := MATERIALS.find(String(state.get("material", "")))
	var biome_id := BIOMES.find(String(state.get("biome", "")))
	var fluid_id := FLUIDS.find(String(state.get("fluid", "")))
	if material_id < 0 or biome_id < 0 or fluid_id < 0 or not state.get("light") is Dictionary: return {}
	var light: Dictionary = state.light
	return {"materialId": material_id, "biomeId": biome_id, "solid": bool(state.get("solid", false)),
		"density": float(state.get("density", NAN)), "fluidId": fluid_id,
		"light": Vector2i(int(light.get("sky", 0)), int(light.get("block", 0))),
		"metadata": (state.get("metadata", {}) as Dictionary).duplicate(true),
		"blockId": String(state.get("blockId", "")), "editReason": reason}


func _compare_exact(left, right, path: String) -> void:
	if mismatches.size() >= 128: return
	if typeof(left) != typeof(right):
		mismatches.append({"comparison": "oracle_to_native", "field": path, "expected": left, "actual": right})
		return
	if left is Dictionary:
		if left.size() != right.size():
			mismatches.append({"comparison": "oracle_to_native", "field": path + ".size", "expected": left.size(), "actual": right.size()})
			return
		for key in left:
			if not right.has(key):
				mismatches.append({"comparison": "oracle_to_native", "field": path + "." + String(key), "expected": left[key], "actual": "<missing>"})
			elif key != "ok": _compare_exact(left[key], right[key], path + "." + String(key))
	elif left is Array:
		if left.size() != right.size():
			mismatches.append({"comparison": "oracle_to_native", "field": path + ".size", "expected": left.size(), "actual": right.size()})
			return
		for index in range(left.size()): _compare_exact(left[index], right[index], "%s[%d]" % [path, index])
	elif left != right:
		mismatches.append({"comparison": "oracle_to_native", "field": path, "expected": left, "actual": right})


func _empty_batch() -> Dictionary:
	return {"schema": "n3-effective-terrain-batch-request/v1", "surfaceColumns": [], "cellCenters": [],
		"latticeNumeric": [], "worldNumeric": [], "surfaceProjectionNumeric": []}


func _empty_channels() -> Dictionary:
	return {"surfaceColumns": [], "cellCenters": [], "latticeNumeric": [], "worldNumeric": [], "surfaceProjectionNumeric": []}


func _counts(samples: Dictionary) -> Dictionary:
	var result := {}
	for channel in EXPECTED_COUNTS:
		var rows = samples.get(channel)
		result[channel] = rows.size() if rows is Array else -1
	return result


func _page_for_cell(cell: Vector2i) -> Vector2i:
	return Vector2i(floori(float(cell.x) / PAGE_CELLS), floori(float(cell.y) / PAGE_CELLS))


func _enum_matches(value: Dictionary, id_field: String, name_field: String, names: Array) -> bool:
	var identity := int(value.get(id_field, -1))
	return identity >= 0 and identity < names.size() and String(value.get(name_field, "")) == String(names[identity])


func _identity_hex(value) -> String:
	if not value is Dictionary or value.get("algorithm") != "sha256": return ""
	var digest := String(value.get("hex", ""))
	return digest if _valid_digest(digest) else ""


func _valid_digest(value: String) -> bool:
	return value.length() == 64 and value == value.to_lower() and value.is_valid_hex_number(false)


func _envelope(value: Dictionary, label: String) -> void:
	if value.get("schema") != "n3-native-world-backend-adapter/v1" \
			or value.get("productionCutover") != false or value.get("shadowOnly") != true:
		native_shadow_only = false
		failures.append(label + ":shadow_envelope_invalid")


func _receipt_fields(value: Dictionary) -> Dictionary:
	return {"status": value.get("status"), "reason": value.get("reason"),
		"commitStatus": value.get("commitStatus"), "revision": value.get("revision"),
		"shapingRegistryRevision": value.get("shapingRegistryRevision"),
		"shapingRegistryIdentity": _identity_hex(value.get("shapingRegistryIdentity"))}


func _require(condition: bool, label: String) -> void:
	if not condition and not failures.has(label): failures.append(label)


func _finish(golden_hash_before: String, dll_hash_before: String,
		golden_hash_after := "", dll_hash_after := "", source_identity := "",
		shaping_identity := "", query_set_id := "") -> void:
	if golden_hash_after.is_empty(): golden_hash_after = FileAccess.get_sha256(Oracle.GOLDENS_PATH)
	if dll_hash_after.is_empty(): dll_hash_after = FileAccess.get_sha256(DEBUG_DLL_PATH)
	var passed := failures.is_empty() and mismatches.is_empty()
	var report := {
		"schema": REPORT_SCHEMA, "status": "passed" if passed else "failed",
		"passed": passed, "finished": true, "evidenceLevel": EVIDENCE_LEVEL,
		"productionCutover": false, "godotVersion": Engine.get_version_info(),
		"querySetId": query_set_id, "queryCounts": query_counts,
		"nativeAdapterIdentity": dll_hash_before, "querySetIdentity": golden_hash_before,
		"checks": checks, "mismatchCount": mismatches.size(), "mismatches": mismatches,
		"failures": failures, "requiredSchemas": {
			"adapter": "n3-native-world-backend-adapter/v1",
			"initialize": "n3-native-world-backend-initialize/v1",
			"typedCellTransaction": "n3-native-typed-cell-transaction/v1",
			"batchRequest": "n3-effective-terrain-batch-request/v1",
			"batchResult": "n3-effective-terrain-batch-result/v1", "batchSchemaRevision": 2,
			"oracle": Oracle.SCHEMA, "oracleSamples": Oracle.SAMPLE_SCHEMA,
			"goldens": Oracle.GOLDENS_SCHEMA},
		"identities": {"sourceIdentity": source_identity,
			"shapingRegistryIdentity": shaping_identity,
			"nativeAdapterSha256": dll_hash_before, "goldensSha256": golden_hash_before},
		"hashes": {"debugAdapterBefore": dll_hash_before, "debugAdapterAfter": dll_hash_after,
			"debugAdapterUnchanged": dll_hash_before == dll_hash_after,
			"goldensBefore": golden_hash_before, "goldensAfter": golden_hash_after,
			"goldensUnchanged": golden_hash_before == golden_hash_after},
		"evidence": evidence,
	}
	if not report_path.is_empty():
		DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
			file.close()
	print(JSON.stringify(report))
	quit(0 if passed else 1)


func _cell2(value) -> Vector2i:
	return Vector2i(int(value[0]), int(value[1]))


func _cell3(value) -> Vector3i:
	return Vector3i(int(value[0]), int(value[1]), int(value[2]))


func _position(value) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _v2(value: Vector2i) -> Array:
	return [value.x, value.y]


func _v3i(value: Vector3i) -> Array:
	return [value.x, value.y, value.z]


func _v2_key(value: Vector2i) -> String:
	return "%d,%d" % [value.x, value.y]


func _f64_bits(value: float) -> String:
	return PackedFloat64Array([value]).to_byte_array().hex_encode()


func _f32_bits(value: float) -> String:
	return PackedFloat32Array([value]).to_byte_array().hex_encode()


func _v3_f32_bits(value: Vector3) -> Array:
	return [_f32_bits(value.x), _f32_bits(value.y), _f32_bits(value.z)]
