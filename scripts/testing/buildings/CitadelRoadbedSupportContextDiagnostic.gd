extends SceneTree

## Read-only source diagnostic. Completion is NOT physical/gameplay acceptance.
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const PRIOR := "res://artifacts/citadel-visual-reset/roadbed-bearing-contract-02/report.json"
const PRIOR_SHA := "e8af372ab89d19f95593b77fd10ec3f575cbc09b3f7d00eb186b184bfc40688f"
const SEED := 237207443
const MAX_BYTES := 1048576

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for dependency in [Castle, Copy]:
		if not dependency.can_instantiate():
			quit(2)
			return
	var path := OS.get_environment("VOXEL_ROADBED_CONTEXT_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()) or FileAccess.get_sha256(PRIOR) != PRIOR_SHA:
		quit(2)
		return
	var prior: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PRIOR))
	var prior_failures: Array = []
	for seed_case in prior.routeEvidence.evidence:
		if int(seed_case.seed) != SEED: continue
		for pool in seed_case.actualRoadbedPhysicalPools.results:
			if not bool(pool.passed): prior_failures.append(pool)
	if prior_failures.is_empty():
		quit(2)
		return
	var source_hashes := _source_hashes()
	print("Support context: building seed ", SEED)
	var started := Time.get_ticks_msec()
	var source = Castle.build(SEED, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25, "settlementTier": "city", "style": "masonry"})
	if source == null:
		quit(2)
		return
	var build_msec := Time.get_ticks_msec() - started
	print("Support context: build complete in ", build_msec, " ms; beginning single full-source validation")
	Copy.clear_caches(source)
	var validation_started := Time.get_ticks_msec()
	var physical: Dictionary = source.validate_physical_integrity()
	var validation_msec := Time.get_ticks_msec() - validation_started
	print("Support context: validation complete in ", validation_msec, " ms")
	var roadbed_ids: Dictionary = {}
	for part in source.parts:
		if part.semantic == "castle_route_terrace_walkway": roadbed_ids[part.id] = true
	var roadbed_rows: Array = physical.checks.filter(func(row): return roadbed_ids.has(row.partId))
	var failures: Array = physical.checks.filter(func(row): return not bool(row.passed)).map(func(row): return row.partId)
	var contexts: Array = []
	var incomplete: Array = []
	for pool in prior_failures:
		var matching: Array = roadbed_rows.filter(func(row): return row.partId == pool.partId)
		if matching.size() != 1:
			incomplete.append("missing_or_duplicate_current_roadbed:" + String(pool.partId))
			continue
		var current: Dictionary = matching[0]
		for old_sample in pool.failedTargetCheck.supportCoverage:
			if bool(old_sample.supported): continue
			var samples: Array = current.supportCoverage.filter(func(sample): return sample.sample == old_sample.sample)
			if samples.size() != 1:
				incomplete.append("missing_or_duplicate_current_sample")
				continue
			var sample: Dictionary = samples[0]
			var owner = source.find_part(String(sample.supportPartId))
			var nearby: Array = []
			for part in source.structural_candidates_near(sample.position):
				if part.kind != "foundation": continue
				var bounds: AABB = source.transformed_part_bounds(part).grow(0.05)
				var point: Vector3 = sample.position
				if point.x >= bounds.position.x and point.x <= bounds.end.x and point.z >= bounds.position.z and point.z <= bounds.end.z:
					nearby.append(_geometry(part))
			nearby.sort_custom(func(a, b): return String(a.id) < String(b.id))
			if nearby.size() > 64: incomplete.append("nearby_foundation_context_limit")
			contexts.append({"partId": pool.partId, "roadbed": _geometry(source.find_part(String(pool.partId))),
				"priorPoolSample": old_sample, "fullSourceSample": sample,
				"selectedSupport": _geometry(owner), "selectedSupportRooted": owner != null and source.has_rooted_support_chain(owner, {}),
				"nearbyFoundationTotal": nearby.size(), "nearbyFoundations": nearby.slice(0, 64)})
	if roadbed_rows.size() != roadbed_ids.size() or roadbed_rows.is_empty(): incomplete.append("roadbed_check_cardinality")
	if contexts.is_empty(): incomplete.append("missing_sample_context")
	if source_hashes != _source_hashes() or FileAccess.get_sha256(PRIOR) != PRIOR_SHA: incomplete.append("source_or_prior_changed")
	var report := {"schema": "citadel_roadbed_support_context/v1", "completed": incomplete.is_empty(),
		"seed": SEED, "priorReport": PRIOR, "priorReportSha256": PRIOR_SHA, "sourceHashes": source_hashes,
		"buildCount": 1, "validationCount": 1, "buildMsec": build_msec, "validationMsec": validation_msec,
		"fullSourceValidation": {"passed": physical.passed, "failedCheckCount": failures.size(), "failedIds": failures,
			"scope": "Uncomposed Castle source, not completed Citadel or gameplay acceptance."},
		"actualRoadbedCount": roadbed_ids.size(), "roadbedChecks": roadbed_rows, "sampleContexts": contexts,
		"incompleteReasons": incomplete,
		"scope": "Read-only diagnostic of isolated versus full-source support ownership. Exit zero means evidence collection completed, never physical gate acceptance."}
	var bytes := JSON.stringify(report, "\t").to_utf8_buffer()
	if bytes.size() > MAX_BYTES:
		report.completed = false
		report.incompleteReasons.append("report_byte_limit")
		report.roadbedChecks = []
		report.sampleContexts = []
		report.fullSourceValidation.failedIds = []
		bytes = JSON.stringify(report, "\t").to_utf8_buffer()
	if bytes.size() > MAX_BYTES:
		quit(2)
		return
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_buffer(bytes)
	output.flush()
	var error := output.get_error()
	output.close()
	if error != OK or FileAccess.get_file_as_bytes(path) != bytes:
		quit(2)
		return
	print("Support context diagnostic completed=", report.completed, "; full-source failed checks=", failures.size())
	quit(0 if report.completed else 1)

func _geometry(part) -> Dictionary:
	if part == null: return {"missing": true}
	return {"id": part.id, "kind": part.kind, "semantic": part.semantic, "position": part.position,
		"rotation": part.rotation, "size": part.size, "collision": part.collision_enabled,
		"physicalIntent": part.physical_intent, "physicalRoot": part.recipe.get("physicalRoot", false),
		"requiredSupports": part.recipe.get("physicalRequiredSupportPartIds", []),
		"requiredSeats": part.recipe.get("physicalRequiredSeatPartIds", [])}

func _source_hashes() -> Dictionary:
	var result: Dictionary = {}
	for path in ["res://scripts/testing/buildings/CitadelRoadbedSupportContextDiagnostic.gd",
		"res://scripts/buildings/CastleCompoundBlueprintBuilder.gd", "res://scripts/buildings/BuildingBlueprint.gd",
		"res://scripts/buildings/MandatoryPhysicalDependencyValidator.gd", "res://scripts/buildings/FacadeOpeningBearingRecipe.gd"]:
		result[path] = FileAccess.get_sha256(path)
	return result
