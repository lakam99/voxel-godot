extends RefCounted

## Source/service contract only. Called by the physical contract; no runner,
## report file, urban composition, furnishing build or live navigation claim.
## "Before" is a counterfactual schema replay, NOT a historical binary baseline.
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Codec = preload("res://scripts/testing/buildings/CitadelStructuralComposerCheckpointCodec.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const SEEDS := [208159, 237207443]
const CONTEXT := {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25, "settlementTier": "city", "style": "masonry"}
const KNOWN_SOURCE_SNAPSHOT_SHA256 := "6caefa897a3cdd38492c899684535c8e1ed02153a8974d4e2c715102ffa307c0"
const KNOWN_SOURCE_RECIPE_SHA256 := "0fabe5afcb479851848a00c17b44faa789a6e0757bb41141605c4de2ce122ff3"
const HISTORICAL_REPORT := "res://artifacts/citadel-visual-reset/district-placement-repair-contract-04/report.json"
const HISTORICAL_REPORT_SHA256 := "0d7bf8c31992ceea739c839f4dc9a14eff25cedc176a6bef6dfa2775b4381a91"
const ISOLATED_REPORT := "res://artifacts/citadel-visual-reset/roadbed-bearing-contract-02/report.json"
const ISOLATED_SHA := "e8af372ab89d19f95593b77fd10ec3f575cbc09b3f7d00eb186b184bfc40688f"
const CONTEXT_REPORT := "res://artifacts/citadel-visual-reset/roadbed-support-context-fresh-01/report.json"
const CONTEXT_SHA := "af5377b780eb8bac4bd203cf8432602cddc1f9db868c3d6d6df27a3b90bec18b"
const ROADBED := "castle_route_terrace_walkway"
const NEW_FIELDS := ["physicalRequiredSeatPartIds", "physicalAssemblyRole"]
# Source invariants distinguish resolution caches from unchanged geometry.
const CACHE_KEYS := ["physicalSupportPartIds", "physicalSupportCoverage", "physicalAnchorPartIds", "physicalIntentResolution"]
const MAX_PARTS := 20000
const MAX_STREETS := 256
const MAX_ROADBEDS := 512
const SOURCE_PATHS := [
	"res://scripts/testing/buildings/CitadelRoadbedRoutePreservationCases.gd",
	"res://scripts/buildings/CastleCompoundBlueprintBuilder.gd",
	"res://scripts/buildings/LandmarkBuildingRecipeSampler.gd",
	"res://scripts/buildings/BuildingBlueprint.gd",
	"res://scripts/buildings/BuildingPart.gd",
	"res://scripts/testing/buildings/CastleCourtyardDistrictPlacementPlannerContract.gd",
	"res://scripts/testing/buildings/CitadelStructuralComposerCheckpointCodec.gd",
	"res://scripts/buildings/FacadeOpeningBearingRecipe.gd",
	"res://scripts/buildings/FacadeBearingFrameBuilder.gd",
	"res://scripts/buildings/MandatoryPhysicalDependencyValidator.gd",
]


static func run_cases(selected_seed: int) -> Dictionary:
	var started := Time.get_ticks_msec()
	var checks: Array = []
	var evidence: Array = []
	var provenance := _provenance()
	_check(checks, "selected_seed_is_in_approved_matrix", SEEDS.has(selected_seed))
	if SEEDS.has(selected_seed): evidence.append(_seed_case(selected_seed, checks))
	_check(checks, "isolated_diagnostic_preserved", FileAccess.get_sha256(ISOLATED_REPORT) == ISOLATED_SHA)
	_check(checks, "corrective_context_diagnostic_preserved", FileAccess.get_sha256(CONTEXT_REPORT) == CONTEXT_SHA)
	_check(checks, "selected_source_files_unchanged_during_contract", var_to_bytes(provenance) == var_to_bytes(_provenance()))
	return {
		"passed": checks.all(func(row: Dictionary) -> bool: return bool(row.passed)),
		"checks": checks, "evidence": evidence,
		"evidenceLevel": "actual_producer_source_service_counterfactual_schema_replay",
		"baselineKind": "Lossless clone of current Castle.build output; ONLY the two new recipe fields removed on castle_route_terrace_walkway. Not a historical binary baseline.",
		"scope": "Exactly one ordinary Castle.build per seed; no Urban.compose, frozen review candidate, physical negative cases, or additional full builds.",
		"passedMeans": "Schema delta, known historical source oracle, source preservation, every actual roadbed passing full-source physical validation, initial old/new route parity and mandatory new-schema repeat/cache replay. Other source failures remain unresolved.",
		"doesNotProve": "Old-schema repeat/cache stability, historical route execution, fresh-seed historical source parity, full Citadel physical integrity, published mesh/collision, native navigation, NPC movement or headed gameplay acceptance.",
		"isolatedPoolCorrection": {"priorReport": ISOLATED_REPORT, "priorSha256": ISOLATED_SHA, "correctiveReport": CONTEXT_REPORT, "correctiveSha256": CONTEXT_SHA,
			"reason": "The direct-foundation pool omitted rooted paving selected by full-source support resolution. It is retained as diagnostic evidence, not used as the production acceptance authority."},
		"sourceProvenance": provenance,
		"sourceProvenanceScope": "Selected contract/producer/consumer files only, not the complete transitive dependency closure or a clean Git revision.",
		"engine": Engine.get_version_info(), "elapsedMsec": Time.get_ticks_msec() - started,
		"repeatPolicy": {"mandatoryNewSchemaReplays": 2, "extraBuilds": 0,
			"cacheClearScope": "Copy.clear_caches plus lookup/grid indexes: rootedness and supports recomputed from source geometry; required support/seat declarations and physical intent preserved."},
	}


static func _seed_case(seed_value: int, checks: Array) -> Dictionary:
	var label := "seed_%d:" % seed_value
	print(label, " building actual source")
	var build_started := Time.get_ticks_msec()
	var after = Castle.build(seed_value, CONTEXT.duplicate(true))
	var evidence := {"seed": seed_value, "context": CONTEXT.duplicate(true), "buildCount": 1,
		"buildMsec": Time.get_ticks_msec() - build_started}
	print(label, " source build completed in ", evidence.buildMsec, " ms")
	_check(checks, label + "actual_producer_exists", after != null)
	if after == null:
		return evidence
	var streets: Array = after.recipe.get("castleGrammar", {}).get("courtyardGrid", {}).get("streetRecords", [])
	var bounded: bool = not after.parts.is_empty() and after.parts.size() <= MAX_PARTS and not streets.is_empty() and streets.size() <= MAX_STREETS
	_check(checks, label + "nonempty_bounded_source", bounded)
	if not bounded:
		evidence["reason"] = "empty_or_oversized_source"
		return evidence
	var before = _clone(after)
	var clone_comparison := _compare_sources(before, after, false)
	_check(checks, label + "clone_lossless_all_records_byte_exact", clone_comparison.passed)
	evidence["cloneComparison"] = clone_comparison
	if not clone_comparison.passed:
		return evidence
	var roadbed_ids: Array = []
	var invalid_schema_ids: Array = []
	for part in before.parts:
		if part.semantic != ROADBED:
			continue
		roadbed_ids.append(part.id)
		var supports: Variant = part.recipe.get("physicalRequiredSupportPartIds")
		if not supports is Array or supports.is_empty() or not part.recipe.has(NEW_FIELDS[0]) or var_to_bytes(supports) != var_to_bytes(part.recipe.get(NEW_FIELDS[0])) or part.recipe.get(NEW_FIELDS[1]) != "walkable_subfloor":
			invalid_schema_ids.append(part.id)
		for key in NEW_FIELDS:
			part.recipe.erase(key)
	_check(checks, label + "all_actual_roadbeds_have_exact_ordered_seats_and_role", not roadbed_ids.is_empty() and invalid_schema_ids.is_empty())
	var delta := _compare_sources(before, after, true)
	_check(checks, label + "only_two_roadbed_fields_differ_byte_exact", delta.passed)
	evidence["roadbedIdsInProducerOrder"] = roadbed_ids
	evidence["invalidSchemaPartIds"] = invalid_schema_ids
	evidence["schemaComparison"] = delta
	# Independent historical oracle, BEFORE any consumer infers intent or caches.
	# The prior contract uses build_with_diagnostics with this exact context;
	# Castle.build is its blueprint-returning wrapper. Reuse its exact codec,
	# not our length-prefixed streaming hashes and not a canonicalized JSON form.
	if seed_value == 208159:
		evidence["historicalSourceOracle"] = _historical_oracle(before, checks, label)
	else:
		evidence["historicalSourceOracle"] = {"applicable": false, "reason": "No independent historical source hash supplied for fresh seed 237207443."}
	var before_facts := _fingerprints(before)
	var after_facts := _fingerprints(after)
	_check(checks, label + "geometry_material_collision_and_part_order_exact", before_facts.geometryMaterialCollisionOrder == after_facts.geometryMaterialCollisionOrder)
	_check(checks, label + "required_support_lists_and_order_exact", before_facts.requiredSupportListsInPartOrder == after_facts.requiredSupportListsInPartOrder)
	evidence["beforeSourceHashes"] = before_facts
	evidence["afterSourceHashes"] = after_facts
	evidence["actualRoadbedPhysicalValidation"] = _full_physical(after, checks, label)
	print(label, " full-source roadbed validation completed")
	_check(checks, label + "physical_validation_preserves_source_invariants", _invariants_equal(after_facts, _fingerprints(after)))
	# The existing coverage consumer resolves physical contracts and calls the real
	# surface/root owner, boundary, junction and handoff consumers. Compare its
	# ENTIRE output bytes, not just passed, counts, or a replacement predicate.
	var pair_started := Time.get_ticks_msec()
	var before_route: Dictionary = Castle.validate_raised_route_coverage(before)
	var after_route: Dictionary = Castle.validate_raised_route_coverage(after)
	var pair_msec := Time.get_ticks_msec() - pair_started
	print(label, " first route comparison completed in ", pair_msec, " ms")
	_check(checks, label + "route_consumer_exercised_actual_streets", not (before_route.get("records", []) as Array).is_empty() and not (after_route.get("records", []) as Array).is_empty())
	_check(checks, label + "entire_route_owner_coverage_results_byte_exact", var_to_bytes(before_route) == var_to_bytes(after_route))
	_check(checks, label + "existing_route_failures_retained_exactly", var_to_bytes(before_route.get("violations", [])) == var_to_bytes(after_route.get("violations", [])))
	evidence["firstRoutePairMsec"] = pair_msec
	evidence["beforeRoute"] = _route_evidence(before_route)
	evidence["afterRoute"] = _route_evidence(after_route)
	var repeats: Array = []
	for phase in ["repeat", "derivedCacheCleared"]:
		if phase == "derivedCacheCleared": _clear_derived_cache(after)
		var phase_started := Time.get_ticks_msec()
		var new_replay: Dictionary = Castle.validate_raised_route_coverage(after)
		_check(checks, label + phase + ":new_result_byte_exact", var_to_bytes(new_replay) == var_to_bytes(after_route))
		var elapsed := Time.get_ticks_msec() - phase_started
		print(label, " ", phase, " completed in ", elapsed, " ms")
		repeats.append({"phase": phase, "elapsedMsec": elapsed, "after": _route_evidence(new_replay)})
	evidence["replays"] = {"performed": repeats.size() == 2, "results": repeats, "scope": "New schema only; no old-schema repeat/cache stability claim."}
	var before_final := _fingerprints(before)
	var after_final := _fingerprints(after)
	_check(checks, label + "before_consumers_preserve_source_invariants", _invariants_equal(before_facts, before_final))
	_check(checks, label + "after_consumers_preserve_source_invariants", _invariants_equal(after_facts, after_final))
	evidence["beforePostConsumerHashes"] = before_final
	evidence["afterPostConsumerHashes"] = after_final
	return evidence


static func _clone(source):
	# Same snapshot-copy convention as CitadelShopRecipe.copy_source; the immediate
	# all-record byte comparison above rejects any constructor normalization loss.
	var result = Blueprint.new(source.id, source.seed, source.style)
	result.recipe = source.recipe.duplicate(true)
	result.rooms = source.rooms.duplicate(true)
	for original in source.parts:
		var part = result.add_part(original.snapshot())
		part.physical_intent = original.physical_intent
		result.physical_parts_by_id[part.id] = part
	return result


static func _historical_oracle(before, checks: Array, label: String) -> Dictionary:
	var report_sha := FileAccess.get_sha256(HISTORICAL_REPORT)
	# sample_compound normalizes context into this fixed key order. Raw build
	# options above match the historical caller, not the normalized key order.
	var expected_context := {"settlementTier": "city", "biome": "forest", "siteKey": "river-citadel", "style": "masonry", "citadelScale": 1.25}
	var context_matches := var_to_bytes(before.recipe.get("context", {})) == var_to_bytes(expected_context)
	_check(checks, label + "historical_report_identity", report_sha == HISTORICAL_REPORT_SHA256)
	_check(checks, label + "historical_build_context_byte_exact", context_matches)
	# One transient binary snapshot is needed for the established hash method.
	# It is never transported in the report; no full-blueprint JSON is produced.
	var snapshot_sha := Codec.hash_variant(before.snapshot())
	var recipe_sha := Codec.hash_variant(before.recipe)
	_check(checks, label + "historical_source_snapshot_recovered", snapshot_sha == KNOWN_SOURCE_SNAPSHOT_SHA256)
	_check(checks, label + "historical_source_recipe_recovered", recipe_sha == KNOWN_SOURCE_RECIPE_SHA256)
	return {"applicable": true, "reportPath": HISTORICAL_REPORT, "reportSha256": report_sha,
		"expectedReportSha256": HISTORICAL_REPORT_SHA256, "contextMatches": context_matches,
		"sourceSnapshotSha256": snapshot_sha, "expectedSourceSnapshotSha256": KNOWN_SOURCE_SNAPSHOT_SHA256,
		"sourceRecipeSha256": recipe_sha, "expectedSourceRecipeSha256": KNOWN_SOURCE_RECIPE_SHA256,
		"method": "CitadelStructuralComposerCheckpointCodec.hash_variant = SHA256(var_to_bytes(value)); evaluated before route resolution, after removing ONLY the two roadbed fields.",
		"scope": "Independent knownAcceptedSeed source-preservation oracle. Route results still compare counterfactual schemas with current consumers, not a historical binary."}


static func _full_physical(source, checks: Array, label: String) -> Dictionary:
	var started := Time.get_ticks_msec()
	var roadbeds: Dictionary = {}
	for part in source.parts:
		if part.semantic == ROADBED: roadbeds[part.id] = part
	var bounded: bool = not roadbeds.is_empty() and roadbeds.size() <= MAX_ROADBEDS
	_check(checks, label + "physical_source_roadbeds_bounded", bounded)
	if not bounded: return {"passed": false, "validationCount": 0}
	Copy.clear_caches(source)
	var report: Dictionary = source.validate_physical_integrity()
	var selected: Array = report.checks.filter(func(row): return roadbeds.has(row.partId))
	var seen: Dictionary = {}
	for row: Dictionary in selected:
		var part = roadbeds[row.partId]
		var required: Array = part.recipe.get("physicalRequiredSupportPartIds", [])
		var valid: bool = not seen.has(row.partId) and bool(row.passed) and bool(row.get("hasRootedCoverage", false)) and bool(row.get("hasRootedSeats", false)) and bool(row.get("reachesGroundRoot", false))
		valid = valid and row.supportCoverage.size() == 25 and row.supportCoverage.all(func(sample): return bool(sample.supported))
		valid = valid and var_to_bytes(row.get("requiredSeatPartIds")) == var_to_bytes(required) and var_to_bytes(row.get("requiredSupportPartIds")) == var_to_bytes(required)
		valid = valid and part.recipe.get("physicalAssemblyRole") == "walkable_subfloor"
		_check(checks, label + "actual_roadbed_full_source_proof:" + String(row.partId), valid)
		seen[row.partId] = true
	_check(checks, label + "all_actual_roadbeds_checked_once", selected.size() == roadbeds.size() and seen.size() == roadbeds.size())
	var failed_ids: Array = report.checks.filter(func(row): return not bool(row.passed)).map(func(row): return row.partId)
	return {"validationCount": 1, "actualRoadbedCount": roadbeds.size(), "roadbedChecks": selected,
		"globalSourceResult": {"passed": report.passed, "failedCheckCount": failed_ids.size(), "failedIds": failed_ids,
			"scope": "Uncomposed Castle source only; non-roadbed failures remain unresolved. Not full Citadel or gameplay acceptance."},
		"elapsedMsec": Time.get_ticks_msec() - started}


static func _header(b) -> Array:
	return [b.id, b.seed, b.style, b.recipe, b.rooms]


static func _compare_sources(before, after, strip_new_fields: bool) -> Dictionary:
	var mismatches: Array = []
	var same_header := var_to_bytes(_header(before)) == var_to_bytes(_header(after))
	var same_count: bool = before.parts.size() == after.parts.size()
	for index in range(mini(before.parts.size(), after.parts.size())):
		var old_record: Dictionary = before.parts[index].snapshot()
		var new_record: Dictionary = after.parts[index].snapshot()
		if strip_new_fields and after.parts[index].semantic == ROADBED:
			for key in NEW_FIELDS:
				new_record.recipe.erase(key)
		if var_to_bytes(old_record) != var_to_bytes(new_record):
			mismatches.append({"index": index, "beforeId": old_record.id, "afterId": new_record.id})
	return {"passed": same_header and same_count and mismatches.is_empty(), "headerByteExact": same_header,
		"partCount": after.parts.size(), "partCountEqual": same_count, "mismatches": mismatches}


static func _fingerprints(b) -> Dictionary:
	# Stream length-prefixed Variant records; never serialize a full blueprint to
	# JSON or retain a giant blueprint byte buffer. Array and dictionary order,
	# Variant types, materials, vectors and float precision remain unnormalized.
	var contexts: Dictionary = {}
	for key in ["source", "immutable", "geometryMaterialCollisionOrder", "requiredSupportListsInPartOrder"]:
		var context := HashingContext.new()
		context.start(HashingContext.HASH_SHA256)
		contexts[key] = context
	_feed(contexts.source, _header(b))
	_feed(contexts.immutable, _header(b))
	for part in b.parts:
		var record: Dictionary = part.snapshot()
		_feed(contexts.source, record)
		_feed(contexts.requiredSupportListsInPartOrder, [part.id, part.recipe.has("physicalRequiredSupportPartIds"), part.recipe.get("physicalRequiredSupportPartIds")])
		record.erase("physicalIntent")
		for key in CACHE_KEYS + ["physicalIntent", "physicalRoot"]:
			record.recipe.erase(key)
		_feed(contexts.immutable, record)
		record.erase("recipe")
		_feed(contexts.geometryMaterialCollisionOrder, record)
	var result: Dictionary = {}
	for key in contexts:
		result[key] = (contexts[key] as HashingContext).finish().hex_encode()
	return result


static func _invariants_equal(initial: Dictionary, final: Dictionary) -> bool:
	return initial.immutable == final.immutable and initial.geometryMaterialCollisionOrder == final.geometryMaterialCollisionOrder and initial.requiredSupportListsInPartOrder == final.requiredSupportListsInPartOrder


static func _feed(context: HashingContext, value: Variant) -> void:
	var bytes := var_to_bytes(value)
	var length := PackedByteArray()
	length.resize(8)
	length.encode_u64(0, bytes.size())
	context.update(length)
	context.update(bytes)


static func _hash(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	_feed(context, value)
	return context.finish().hex_encode()


static func _route_evidence(route: Dictionary) -> Dictionary:
	var records: Array = []
	for row in route.get("records", []):
		var failed_samples: Array = []
		for sample in row.get("samples", []):
			if not bool(sample.get("passed", false)):
				failed_samples.append({"id": sample.get("id", ""), "ownerId": sample.get("ownerId", ""),
					"rootSupportId": sample.get("rootSupportId", ""), "sha256": _hash(sample)})
		records.append({"streetId": row.get("streetId", ""), "passed": row.get("passed", false),
			"sha256": _hash(row), "sampleCount": row.get("samples", []).size(),
			"violations": row.get("violations", []).duplicate(true), "failedSamples": failed_samples})
	return {"passed": route.get("passed", false), "sha256": _hash(route), "recordCount": records.size(),
		"records": records, "violations": route.get("violations", []).duplicate(true),
		"collisionPartition": route.get("collisionPartition", {}).duplicate(true)}


static func _clear_derived_cache(b) -> void:
	b.physical_parts_by_id.clear()
	b.structural_support_grid.clear()
	b.invalid_gable_part_ids.clear()
	Copy.clear_caches(b)


static func _provenance() -> Array:
	var records: Array = []
	for path in SOURCE_PATHS:
		records.append({"path": path, "sha256": FileAccess.get_sha256(path)})
	return records


static func _check(checks: Array, id: String, passed: bool) -> void:
	checks.append({"id": id, "passed": passed})
