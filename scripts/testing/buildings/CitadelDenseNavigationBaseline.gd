extends SceneTree
## Offline baseline acquisition from the pinned completed recipe snapshot.
## The owned preparation worker is the production CPU path; no scene publisher,
## NavigationServer registration, live collision or gameplay acceptance runs.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate-recipe-source-profile-32/source.bin"
const INPUT_SHA := "42f3c7b2ff1dee451f98dbd286c1a2d346c9e0033326f578ec8a6fea75418067"
const ORIGIN_REPORT := "res://artifacts/citadel-runtime-integration/candidate-teleport-navigation-filter-12/report.json"
const SITE_ID := "citadel-site-v1:16:atlas-3376622889:-2,-2"
const WORLD_ORIGIN := Vector3(-4500.9, 41.85, -3800.25)
const ORIGIN_TEXT := "(-4500.9, 41.85, -3800.25)"
const TILE_FIELDS := ["surfaces", "crossingLinks", "requiredCrossingIds", "unresolvedCrossings", "collisionRecords", "doors"]
const ARTIFACT := "navigation-tiles.bin"

class Deadline extends RefCounted:
	var started := Time.get_ticks_msec()
	var callbacks := 0
	var cancelled := false
	var last_stage := ""
	func checkpoint(stage: String) -> bool:
		callbacks += 1
		last_stage = stage
		if callbacks % 128 == 0: cancelled = cancelled or Time.get_ticks_msec() - started > 120000
		return not cancelled

var output := ""

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	output = OS.get_environment("CITADEL_DENSE_NAVIGATION_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	var worker := Thread.new()
	if worker.start(_prepare) != OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	report.checks.owned_worker = report.workerThreadId != OS.get_thread_caller_id()
	report.passed = report.complete and report.checks.values().all(func(value): return value == true)
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "  ", true, true)); file.flush()
	var saved := file.get_error() == OK
	file.close()
	print("DENSE NAVIGATION BASELINE ", JSON.stringify({"passed": report.passed, "counts": report.get("counts", {})}))
	quit(0 if saved and report.passed else 1)

func _prepare() -> Dictionary:
	var checks := {"source_pinned": FileAccess.get_sha256(INPUT) == INPUT_SHA}
	var report := {"schema": "citadel-dense-navigation-baseline/v1", "passed": false, "complete": false,
		"checks": checks, "workerThreadId": OS.get_thread_caller_id(), "sourcePath": INPUT, "sourceSha256": INPUT_SHA,
		"originReport": ORIGIN_REPORT, "worldOrigin": WORLD_ORIGIN,
		"evidenceLevel": "offline_pinned_source_preparation_baseline",
		"doesNotProve": "No recipe regeneration, scene publication, NavigationServer registration, runtime readiness, live collision, movement, performance acceptance or gameplay acceptance.",
		"comparison": {"artifact": ARTIFACT, "format": "FileAccess.store_var(value, false); full raw navigation_tiles Dictionary",
			"excludedPaths": ["preparationUsec"], "ordered": true,
			"semanticSha256Encoding": "Godot Variant encoding into a zero-filled buffer; only the root preparationUsec field is removed. All other values, types, dictionary insertion order and array order are retained."}}
	if not checks.source_pinned: return report
	var origin_hash := FileAccess.get_sha256(ORIGIN_REPORT)
	var origin: Variant = JSON.parse_string(FileAccess.get_file_as_string(ORIGIN_REPORT))
	checks.headed_origin_report = origin is Dictionary and origin.get("passed") == true \
		and origin.get("seed") == "atlas-3376622889" and origin.get("candidate", {}).get("siteId") == SITE_ID \
		and origin.get("candidate", {}).get("recipeSeed") == 1393179273 \
		and origin.get("evidence", {}).get("sceneAudit", {}).get("sourceOrigin") == ORIGIN_TEXT \
		and origin.get("evidence", {}).get("sceneAudit", {}).get("rootPosition") == ORIGIN_TEXT \
		and origin.get("evidence", {}).get("sceneAudit", {}).get("rootMatchesProfile") == true \
		and origin.get("evidence", {}).get("sceneAudit", {}).get("sourceStillMatches") == true
	if not checks.headed_origin_report: return report
	var recorded_binding: Dictionary = origin.get("evidence", {}).get("acceptedIdentity", {}).get("binding", {})
	# JSON numbers decode as floats. Reconstitute the documented binding's int
	# generation explicitly; this is an offline identity, never a live receipt.
	var binding := {"siteId": recorded_binding.get("siteId", ""), "sourceKey": recorded_binding.get("sourceKey", ""),
		"generation": int(recorded_binding.get("generation", 0))}
	checks.source_binding = Preparation.valid_binding(binding) and binding.siteId == SITE_ID \
		and recorded_binding.get("generation") == binding.generation
	if not checks.source_binding: return report
	report.binding = binding
	report.originReportSha256 = origin_hash
	var file := FileAccess.open(INPUT, FileAccess.READ)
	if file == null: checks.source_read = false; return report
	var decoded: Variant = file.get_var(false)
	checks.source_read = file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	checks.source_envelope = decoded is Dictionary and decoded.get("ready") == true \
		and decoded.get("blueprint") is Dictionary and decoded.get("furnishingPlan") is Dictionary \
		and decoded.get("accessReservations") is Array
	if not checks.source_read or not checks.source_envelope: return report
	var source: Dictionary = decoded
	var source_before := _typed_sha(source)
	checks.source_typed_digest = source_before.length() == 64
	if not checks.source_typed_digest: return report
	# source32 saved these reservations beside the furnishing snapshot. Restore
	# the detached input shape expected by BuildingPublicationSource exactly.
	var furniture: Dictionary = source.furnishingPlan.duplicate(true)
	checks.detached_reservations_consistent = not furniture.has("accessReservations") \
		or _typed_sha(furniture.accessReservations) == _typed_sha(source.accessReservations)
	if not checks.detached_reservations_consistent: return report
	furniture["accessReservations"] = source.accessReservations.duplicate(true)
	var furniture_before := _typed_sha(furniture)
	checks.furniture_typed_digest = furniture_before.length() == 64
	if not checks.furniture_typed_digest: return report
	var started := Time.get_ticks_usec()
	var deadline := Deadline.new()
	print("DENSE NAVIGATION BASELINE worker_preparation")
	var prepared := Preparation.prepare_source(source.blueprint, furniture, binding, deadline.checkpoint, WORLD_ORIGIN)
	report.preparationElapsedUsec = Time.get_ticks_usec() - started
	report.preparationProgress = {"callbacks": deadline.callbacks, "lastStage": deadline.last_stage, "cancelled": deadline.cancelled}
	checks.prepared = prepared.get("ready") == true
	if not checks.prepared: report.failure = prepared.get("reason", "preparation_failed"); return report
	# Inspect only in this offline fixture, and retire the entire holder on this
	# worker. No production consumer is given a second navigation authority.
	var payload: Dictionary = prepared.prepared._payload
	var spatial = payload.spatialDependencies
	var navigation: Dictionary = spatial.navigation_tiles
	checks.preparation_worker = payload.workerThreadId == OS.get_thread_caller_id()
	checks.spatial_binding_origin = spatial.binding == binding and spatial.origin == WORLD_ORIGIN
	checks.source_input_unchanged = source_before == _typed_sha(source) and furniture_before == _typed_sha(furniture)
	checks.reservations_restored_exact = _typed_sha(payload.furnishingPlan.access_reservations_snapshot()) == _typed_sha(source.accessReservations)
	var expected_furniture: Dictionary = furniture.duplicate(false)
	expected_furniture.erase("accessReservations")
	checks.furniture_snapshot_exact = _typed_sha(payload.furnishingPlan.snapshot()) == _typed_sha(expected_furniture)
	checks.all_source_parts_owned = spatial.parts.size() == payload.blueprint.parts.size() + payload.furnishingPlan.parts.size()
	checks.navigation_ready = navigation.get("ready") == true and navigation.get("tiles") is Dictionary \
		and navigation.get("preparationUsec") is int
	if not checks.values().all(func(value): return value == true): return report
	var counts := {"tiles": navigation.tiles.size(), "sampleCount": navigation.sampleCount, "surfaceCount": navigation.surfaceCount,
		"blockedSampleCount": navigation.blockedSampleCount, "rejectedFootprintCount": navigation.rejectedFootprintCount,
		"unresolvedCrossingIds": navigation.unresolvedCrossingIds.size(), "buildingParts": payload.blueprint.parts.size(),
		"furnitureParts": payload.furnishingPlan.parts.size(), "accessReservations": source.accessReservations.size()}
	var totals := {}
	for field: String in TILE_FIELDS: totals[field] = 0
	var tile_rows: Array[Dictionary] = []
	checks.complete_tile_fields = true
	# Keep the producer's dictionary insertion order and every array occurrence.
	# Counts and per-tile hashes are indexes, not replacements for the full oracle.
	for key in navigation.tiles:
		var tile: Dictionary = navigation.tiles[key]
		if not key is String or tile.keys() != TILE_FIELDS:
			checks.complete_tile_fields = false
			return report
		var row := {"tileKey": key, "typedSha256": _typed_sha(tile), "counts": {}}
		if row.typedSha256.length() != 64: checks.complete_tile_fields = false; return report
		for field: String in TILE_FIELDS:
			if not tile[field] is Array: checks.complete_tile_fields = false; return report
			row.counts[field] = tile[field].size()
			totals[field] += tile[field].size()
		tile_rows.append(row)
	checks.surface_total_exact = totals.surfaces == navigation.surfaceCount
	checks.nonempty_baseline = counts.tiles > 0 and counts.sampleCount > 0 and counts.surfaceCount > 0
	var semantic: Dictionary = navigation.duplicate(false)
	semantic.erase("preparationUsec")
	report.semanticSha256 = _typed_sha(semantic)
	report.rawTypedSha256 = _typed_sha(navigation)
	checks.complete_navigation_digests = report.semanticSha256.length() == 64 and report.rawTypedSha256.length() == 64
	report.navigationPreparationUsec = navigation.preparationUsec
	report.counts = counts
	report.tileFieldTotals = totals
	report.tilesInProducerOrder = tile_rows
	report.navigationFieldOrder = navigation.keys()
	var artifact_path := output.get_base_dir().path_join(ARTIFACT)
	checks.artifact_saved_typed_exact = _save_exact(artifact_path, navigation, report.rawTypedSha256)
	checks.source_files_unchanged = FileAccess.get_sha256(INPUT) == INPUT_SHA and FileAccess.get_sha256(ORIGIN_REPORT) == origin_hash
	report.artifactSha256 = {ARTIFACT: FileAccess.get_sha256(artifact_path)}
	report.artifactBytes = 0
	if checks.artifact_saved_typed_exact:
		file = FileAccess.open(artifact_path, FileAccess.READ)
		if file != null:
			report.artifactBytes = file.get_length()
			file.close()
	checks.complete_artifact_size = report.artifactBytes > 0
	report.complete = checks.values().all(func(value): return value == true)
	return report

static func _typed_sha(value: Variant) -> String:
	var bytes := var_to_bytes(value)
	# Deterministic padding retains every encoded Variant value and type.
	bytes.fill(0)
	if bytes.encode_var(0, value, false) != bytes.size(): return ""
	var hash := HashingContext.new()
	if hash.start(HashingContext.HASH_SHA256) != OK or hash.update(bytes) != OK: return ""
	return hash.finish().hex_encode()

static func _save_exact(path: String, value: Dictionary, expected_sha: String) -> bool:
	if FileAccess.file_exists(path) or expected_sha.length() != 64: return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_var(value, false); file.flush()
	var saved := file.get_error() == OK
	file.close()
	if not saved: return false
	file = FileAccess.open(path, FileAccess.READ)
	if file == null: return false
	var decoded: Variant = file.get_var(false)
	var read_exact := file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	return read_exact and decoded is Dictionary and _typed_sha(decoded) == expected_sha
