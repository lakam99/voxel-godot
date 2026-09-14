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
	var demand_order := OS.get_environment("CITADEL_DENSE_NAVIGATION_ORDER")
	if demand_order.is_empty(): demand_order = "canonical"
	checks.valid_demand_order = demand_order in ["canonical","rotating"]
	var report := {"schema": "citadel-dense-navigation-baseline/v1", "passed": false, "complete": false,
		"demandOrder":demand_order,
		"checks": checks, "workerThreadId": OS.get_thread_caller_id(), "sourcePath": INPUT, "sourceSha256": INPUT_SHA,
		"originReport": ORIGIN_REPORT, "worldOrigin": WORLD_ORIGIN,
		"evidenceLevel": "offline_pinned_source_preparation_baseline",
		"doesNotProve": "No recipe regeneration, scene publication, NavigationServer registration, runtime readiness, live collision, movement, performance acceptance or gameplay acceptance.",
		"comparison": {"artifact": ARTIFACT, "format": "FileAccess.store_var(value, false); full raw navigation_tiles Dictionary",
			"excludedPaths": ["preparationUsec"], "ordered": true,
			"semanticSha256Encoding": "Godot Variant encoding into a zero-filled buffer; only the root preparationUsec field is removed. All other values, types, dictionary insertion order and array order are retained."}}
	if not checks.source_pinned or not checks.valid_demand_order: return report
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
	var prepared := Preparation.prepare_source(source.blueprint, furniture, binding, deadline.checkpoint, WORLD_ORIGIN, Callable(), demand_order=="rotating")
	report.preparationElapsedUsec = Time.get_ticks_usec() - started
	report.preparationProgress = {"callbacks": deadline.callbacks, "lastStage": deadline.last_stage, "cancelled": deadline.cancelled}
	checks.prepared = prepared.get("ready") == true
	if not checks.prepared: report.failure = prepared.get("reason", "preparation_failed"); return report
	# Inspect only in this offline fixture, and retire the entire holder on this
	# worker. No production consumer is given a second navigation authority.
	var payload: Dictionary = prepared.prepared._payload
	var spatial = payload.spatialDependencies
	var navigation: Dictionary = spatial.navigation_tiles
	if demand_order=="rotating":
		var demand_started := Time.get_ticks_usec()
		var drained := _drain_rotating_navigation(prepared.get("navigationSource",{}),binding,deadline)
		report.demandElapsedUsec = Time.get_ticks_usec()-demand_started
		report.demandProgress = {"callbacks":deadline.callbacks,"lastStage":deadline.last_stage,"cancelled":deadline.cancelled}
		report.demandSchedule = drained.get("schedule",{})
		checks.rotating_demand_complete = drained.get("ready",false)
		if not checks.rotating_demand_complete:
			report.failure = drained.get("reason","rotating_navigation_failed")
			return report
		navigation = drained.navigation
	report.sourcePreparationPlusDemandUsec = report.preparationElapsedUsec+int(report.get("demandElapsedUsec",0))
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

func _drain_rotating_navigation(source: Dictionary, binding: Dictionary, deadline: Deadline) -> Dictionary:
	# Offline diagnostic only: start with a full waiting queue, repeatedly change
	# its selected order, and retain the same production producer throughout.
	# Call-local eligibility must keep active work and completions within each
	# declared batch. No scene, route or live-readiness result is fabricated here.
	if not source.is_read_only() or not source.has("producer") or not source.get("domain") is Dictionary \
		or not source.get("binding") is Dictionary or not source.binding.is_read_only() or source.binding!=binding:
		return {"ready":false,"reason":"missing_demanded_producer"}
	var producer = source.producer
	var inventory: Dictionary = source.domain
	if not inventory.is_read_only() or inventory.size()!=4 or inventory.get("status")!="complete" \
		or inventory.get("scope")!="source_navigation_output":
		return {"ready":false,"reason":"invalid_demanded_domain"}
	var domain_members := {}
	for field: String in ["tileKeys","producerTileKeys"]:
		var values: Variant = inventory.get(field)
		if not values is Array or not values.is_read_only() or values.is_empty() or values.size()>16900:
			return {"ready":false,"reason":"invalid_demanded_domain"}
		var seen := {}
		for value in values:
			if not value is String or value.length()>23 or seen.has(value):
				return {"ready":false,"reason":"invalid_demanded_domain_key"}
			var coordinates: PackedStringArray = value.split(",",true)
			if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int():
				return {"ready":false,"reason":"invalid_demanded_domain_key"}
			var x: int = int(coordinates[0])
			var z: int = int(coordinates[1])
			if x < -2147483648 or x > 2147483647 or z < -2147483648 or z > 2147483647 or value!="%d,%d" % [x,z]:
				return {"ready":false,"reason":"invalid_demanded_domain_key"}
			seen[value] = true
			if field=="producerTileKeys" and not domain_members.has(value):
				return {"ready":false,"reason":"producer_outside_demanded_domain"}
		var sorted: Array = values.duplicate()
		sorted.sort()
		if sorted!=values: return {"ready":false,"reason":"unordered_demanded_domain"}
		if field=="tileKeys": domain_members = seen
	var inventory_sha := _typed_sha(inventory)
	if inventory_sha.length()!=64: return {"ready":false,"reason":"invalid_domain_digest"}
	var domain: Array[String] = []
	for key: String in inventory.tileKeys: domain.append(key)
	domain.reverse()
	var requested: Dictionary = producer.request_all()
	if requested.get("status")!="ready": return {"ready":false,"reason":"demanded_request_failed"}
	var schedule := {"domainCount":domain.size(),"turns":0,"permutedTurns":0,"changedSelections":0,
		"maxSelected":0,"activeCoverage":true,"completionCoverage":true,"firstTurns":[],"domainUnchanged":false,
		"domainInventory":inventory,"domainTypedSha256":inventory_sha}
	var previous_selection: Array[String] = []
	for turn in range(20000):
		if not deadline.checkpoint("offline_rotating_navigation"):
			return {"ready":false,"reason":"rotating_navigation_deadline","schedule":schedule}
		var remaining: Array[String] = []
		for key: String in domain:
			if producer.take(key).get("status")!="ready": remaining.append(key)
		if remaining.is_empty():
			var navigation: Dictionary = producer.full_result()
			schedule.domainUnchanged = is_same(inventory,source.domain) and _typed_sha(source.domain)==inventory_sha
			var complete: bool = navigation.get("ready",false) and schedule.turns>1 \
				and schedule.permutedTurns>0 and schedule.changedSelections>0 and schedule.domainUnchanged
			return {"ready":complete,"reason":"" if complete else "rotating_schedule_unproven",
				"navigation":navigation,"schedule":schedule}
		var before: Dictionary = producer.status()
		var active := String(before.get("activeTileKey",""))
		if before.get("status")!="ready" or not active.is_empty() and not remaining.has(active):
			return {"ready":false,"reason":"invalid_rotating_active_source","schedule":schedule}
		var order: Array[String] = []
		if not active.is_empty(): order.append(active)
		var offset: int = (turn*17)%remaining.size()
		for index in range(remaining.size()):
			var key: String = remaining[(offset+index)%remaining.size()]
			if not order.has(key): order.append(key)
			if order.size()==8: break
		var selected: Array[String] = order.duplicate()
		selected.sort()
		var promoted: Dictionary = producer.prioritize_waiting(order)
		if promoted.get("status")!="ready":
			return {"ready":false,"reason":"rotating_priority_rejected","schedule":schedule}
		var after: Dictionary = producer.advance(8000,deadline.checkpoint,selected)
		schedule.turns += 1
		schedule.maxSelected = maxi(schedule.maxSelected,selected.size())
		if order!=selected: schedule.permutedTurns += 1
		if not previous_selection.is_empty() and previous_selection!=selected: schedule.changedSelections += 1
		previous_selection = selected
		var after_active := String(after.get("activeTileKey",""))
		schedule.activeCoverage = schedule.activeCoverage and (after_active.is_empty() or selected.has(after_active))
		for key: String in remaining:
			if producer.take(key).get("status")=="ready" and not selected.has(key): schedule.completionCoverage = false
		if schedule.firstTurns.size()<8:
			schedule.firstTurns.append({"selected":selected,"order":order,"activeBefore":active,"activeAfter":after_active,
				"completedBefore":before.get("completedTileCount",0),"completedAfter":after.get("completedTileCount",0)})
		if after.get("status")!="ready" or not schedule.activeCoverage or not schedule.completionCoverage:
			return {"ready":false,"reason":"rotating_batch_coverage_failed","schedule":schedule}
	return {"ready":false,"reason":"rotating_navigation_turn_limit","schedule":schedule}

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
