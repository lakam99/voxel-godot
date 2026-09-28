extends SceneTree

## Independent frozen-old-sequence SOURCE CONTRACT, never gameplay acceptance.
## Caller invokes static run(), or launches this script HEADLESS via the existing
## watchdog with VOXEL_STANDALONE_REPORT and VOXEL_STANDALONE_SEED. Empty seed
## requests fresh entropy; pass the reported seed to reproduce. No geometry is
## published. The external caller owns process cleanup and the time limit.
const Candidate := preload("res://scripts/world/StandaloneStructureCandidate.gd")


func _initialize() -> void:
	call_deferred("_run_cli")


func _run_cli() -> void:
	var report_path := OS.get_environment("VOXEL_STANDALONE_REPORT")
	if report_path.is_empty() or FileAccess.file_exists(report_path):
		push_error("VOXEL_STANDALONE_REPORT must name a fresh report file.")
		quit(2)
		return
	var source_paths := [
		"res://scripts/world/StandaloneStructureCandidate.gd",
		"res://scripts/testing/buildings/StandaloneStructureCandidateContract.gd",
	]
	var source_hashes := {}
	for path in source_paths:
		source_hashes[path] = FileAccess.get_sha256(path)
	var started := Time.get_ticks_usec()
	var report := run(OS.get_environment("VOXEL_STANDALONE_SEED"))
	report["elapsedUsec"] = Time.get_ticks_usec() - started
	report["engine"] = Engine.get_version_info()
	report["sourceSha256"] = source_hashes
	for path in source_paths:
		if source_hashes[path] != FileAccess.get_sha256(path):
			report.passed = false
			report.checks["source_unchanged_during_execution"] = false
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write standalone source contract report: " + report_path)
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("Standalone source contract passed=", report.passed, " elapsedUsec=", report.elapsedUsec, " report=", report_path)
	quit(0 if report.passed else 1)


static func run(random_seed: String = "") -> Dictionary:
	if random_seed.is_empty():
		random_seed = "standalone-contract-" + Crypto.new().generate_random_bytes(16).hex_encode()
	var checks := {}
	var failures: Array = []
	var samples: Array = []
	var seeds := ["atlas-1492", "", "0", "seed:structure:-1,2", "世界🌲", random_seed]
	for world_seed in seeds:
		print("Standalone candidate parity seed=", world_seed)
		samples.append(_many_regions(String(world_seed), 140, 0.26, 50, checks, failures))
	# Additional region sizes exercise the location draws rather than embedding
	# today's tuning in the API. Forced presence covers every dimension branch.
	for region_cells in [34, 64, 280]:
		samples.append(_many_regions(random_seed, region_cells, 1.0, 12, checks, failures))
	_boundary_contract(checks)
	_helper_contract(checks)
	_bounds_contract(checks)
	seed(763421)
	var expected_global := randi()
	seed(763421)
	Candidate.candidate_for_region(random_seed, Vector2i(-19, 71), 140, 1.0)
	checks["does_not_consume_global_rng"] = randi() == expected_global
	var passed := true
	for value in checks.values():
		passed = passed and bool(value)
	return {
		"complete": true,
		"passed": passed,
		"evidenceLevel": "independent_old_sequence_source_contract",
		"randomSeed": random_seed,
		"checks": checks,
		"samples": samples,
		"firstFailures": failures,
		"limitations": [
			"No Godot scene, terrain admission, downstream geometry, deferred publication or gameplay acceptance.",
			"Exact candidate and continuation RNG parity implies unchanged input to builders, not a rendered-world comparison.",
			"Bounds checks exercise source-audited XZ column extents, not runtime geometry instrumentation or lighting/mesh halos.",
		],
	}


static func _many_regions(world_seed: String, region_cells: int, chance: float, radius: int, checks: Dictionary, failures: Array) -> Dictionary:
	var label := "%s:%d:%s" % [world_seed, region_cells, str(chance)]
	var candidates_equal := true
	var rng_equal := true
	var reverse_equal := true
	var bounds_preserve_rng := true
	var present := 0
	var absent := 0
	var types := {}
	# Keep snapshots so the reverse pass compares independently of query order.
	var snapshots := {}
	for rz in range(-radius, radius):
		for rx in range(-radius, radius):
			var region := Vector2i(rx, rz)
			var old := _old_sequence(world_seed, region, region_cells, chance)
			var expected: Dictionary = old.candidate
			var actual := Candidate.candidate_for_region(world_seed, region, region_cells, chance)
			snapshots[region] = actual.duplicate(true)
			if actual != expected:
				candidates_equal = false
				if failures.size() < 32:
					failures.append({"sample": label, "region": region, "expected": expected, "actual": actual})
			if actual.is_empty():
				absent += 1
				continue
			present += 1
			types[actual.structureType] = int(types.get(actual.structureType, 0)) + 1
			var before := actual.duplicate(true)
			Candidate.terrain_influence_for_candidate(actual)
			bounds_preserve_rng = bounds_preserve_rng and actual == before
			if expected.is_empty():
				rng_equal = false
				continue
			var old_rng: RandomNumberGenerator = old.rng
			var new_rng := Candidate.continuation_rng(actual)
			# Verify both restored fields BEFORE drawing. Seed matters to later
			# consumers even where the next samples happen to match by state.
			rng_equal = rng_equal and old_rng.seed == new_rng.seed and old_rng.state == new_rng.state
			for draw in range(24):
				var same := false
				match draw % 3:
					0: same = old_rng.randi() == new_rng.randi()
					1: same = old_rng.randf() == new_rng.randf()
					2: same = old_rng.randi_range(-117, 257) == new_rng.randi_range(-117, 257)
				rng_equal = rng_equal and same and old_rng.state == new_rng.state
	for rz in range(radius - 1, -radius - 1, -1):
		for rx in range(radius - 1, -radius - 1, -1):
			var region := Vector2i(rx, rz)
			var replay := Candidate.candidate_for_region(world_seed, region, region_cells, chance)
			reverse_equal = reverse_equal and replay == snapshots[region]
	checks[label + ".candidate_parity"] = candidates_equal
	checks[label + ".rng_seed_state_and_24_mixed_draws"] = rng_equal
	checks[label + ".reverse_replay"] = reverse_equal
	checks[label + ".bounds_do_not_mutate_candidate"] = bounds_preserve_rng
	checks[label + ".all_five_types_exercised"] = types.size() == 5
	checks[label + ".presence_and_absence_exercised"] = present > 0 and (absent > 0 if chance < 1.0 else absent == 0)
	return {"worldSeed": world_seed, "regionCells": region_cells, "spawnChance": chance, "regions": radius * radius * 4, "present": present, "absent": absent, "types": types}


static func _boundary_contract(checks: Dictionary) -> void:
	var seed_text := "presence-boundary"
	var region := Vector2i(-1, 0)
	var roll := _old_hash01(seed_text, "structure:%d,%d" % [region.x, region.y])
	checks["presence_equality_is_inclusive"] = not Candidate.candidate_for_region(seed_text, region, 140, roll).is_empty()
	checks["presence_above_chance_rejects"] = Candidate.candidate_for_region(seed_text, region, 140, roll - 0.000001).is_empty()
	checks["presence_below_chance_accepts"] = not Candidate.candidate_for_region(seed_text, region, 140, roll + 0.000001).is_empty()
	checks["negative_chance_absent"] = Candidate.candidate_for_region(seed_text, region, 140, -1.0).is_empty()
	# Regions near the supported citadel survey edge, plus negative seams.
	var equal := true
	for cell in [Vector2i(-7142, -7142), Vector2i(7141, 7141), Vector2i(-1, -1), Vector2i.ZERO, Vector2i(0, -1)]:
		equal = equal and Candidate.candidate_for_region(seed_text, cell, 140, 1.0) == _old_sequence(seed_text, cell, 140, 1.0).candidate
	checks["large_coordinates_and_negative_seams"] = equal


static func _helper_contract(checks: Dictionary) -> void:
	var type_equal := true
	var dimensions_equal := true
	var shrine_no_draws := true
	for rng_seed in range(1000):
		var old_rng := RandomNumberGenerator.new()
		var new_rng := RandomNumberGenerator.new()
		old_rng.seed = rng_seed
		new_rng.seed = rng_seed
		type_equal = type_equal and _old_type(old_rng) == Candidate.standalone_structure_type(new_rng) and old_rng.state == new_rng.state
		for kind in ["shrine", "mine", "ruin", "camp", "cabin", "unknown_legacy_fallback"]:
			old_rng.seed = rng_seed
			new_rng.seed = rng_seed
			var before := new_rng.state
			var expected := _old_dimensions(kind, old_rng)
			var actual := Candidate.structure_dimensions_for_type(kind, new_rng)
			dimensions_equal = dimensions_equal and expected == actual and old_rng.state == new_rng.state
			if kind == "shrine":
				shrine_no_draws = shrine_no_draws and before == new_rng.state
	checks["legacy_type_helper_and_rng_parity"] = type_equal
	checks["legacy_dimensions_helper_and_rng_parity_including_fallback"] = dimensions_equal
	checks["shrine_consumes_no_dimension_draws"] = shrine_no_draws


static func _bounds_contract(checks: Dictionary) -> void:
	var base := Vector2i(-143, 227)
	for kind in ["cabin", "ruin", "shrine", "camp", "mine"]:
		var contained := true
		var exact_rectangle := true
		var honest := true
		for width in range(7, 14):
			for depth in range(7, 15):
				var source := {"baseCell": base, "structureType": kind, "dimensions": Vector2i(width, depth)}
				var result := Candidate.terrain_influence_for_candidate(source)
				var rect: Rect2i = result.influenceCells
				var min_z := -5 if kind in ["camp", "mine"] else -1
				var expected := Rect2i(base + Vector2i(-1, min_z), Vector2i(width + 2, depth - min_z + 1))
				exact_rectangle = exact_rectangle and rect == expected
				honest = honest and result.bounded and not result.publicationReady and not result.terrainAdmissionTested
				# Independently enumerate the inclusive foundation edit cells.
				for x in range(-1, width + 1):
					for z in range(-1, depth + 1):
						contained = contained and rect.has_point(base + Vector2i(x, z))
				if kind in ["camp", "mine"]:
					for z in range(-5, 0):
						for lane in range(-1, 2):
							contained = contained and rect.has_point(base + Vector2i(int(width / 2) + lane, z))
					# The outermost path column must reject an intersecting
					# citadel; a dimensions-only footprint would miss it.
					contained = contained and rect.intersects(Rect2i(base + Vector2i(int(width / 2), -5), Vector2i.ONE))
				contained = contained and not rect.has_point(rect.end)
		checks[kind + ".source_columns_contained"] = contained
		checks[kind + ".half_open_conservative_rectangle"] = exact_rectangle
		checks[kind + ".bounds_not_admission"] = honest
	checks["absent_has_no_bounds_claim"] = not Candidate.terrain_influence_for_candidate({}).bounded
	checks["unknown_source_is_not_assumed_bounded"] = not Candidate.terrain_influence_for_candidate({"baseCell": base, "structureType": "tunnel", "dimensions": Vector2i(9, 9)}).bounded


# FROZEN REFERENCE: former Main.hash01/hash_string and the exact layout portion
# of StructureSystem.update_standalone_structures. Do NOT call Candidate helpers
# here or update this oracle in lockstep with a future generation-policy change.
static func _old_sequence(seed_text: String, region: Vector2i, region_cells: int, spawn_chance: float) -> Dictionary:
	var rx := region.x
	var rz := region.y
	var roll: float = _old_hash01(seed_text, "structure:%d,%d" % [rx, rz])
	if roll > spawn_chance:
		return {"candidate": {}}
	var rng := RandomNumberGenerator.new()
	rng.seed = _old_hash_string("%s:structure:%d,%d" % [seed_text, rx, rz])
	var base_x: int = rx * region_cells + rng.randi_range(16, region_cells - 18)
	var base_z: int = rz * region_cells + rng.randi_range(16, region_cells - 18)
	var structure_type := _old_type(rng)
	var dimensions := _old_dimensions(structure_type, rng)
	return {"candidate": {
		"region": region, "baseCell": Vector2i(base_x, base_z),
		"structureType": structure_type, "dimensions": dimensions,
		"presenceRoll": roll, "rngSeed": rng.seed, "rngState": rng.state,
	}, "rng": rng}


static func _old_type(rng: RandomNumberGenerator) -> String:
	var roll := rng.randf()
	if roll < 0.12:
		return "shrine"
	if roll < 0.32:
		return "mine"
	if roll < 0.58:
		return "ruin"
	if roll < 0.74:
		return "camp"
	return "cabin"


static func _old_dimensions(structure_type: String, rng: RandomNumberGenerator) -> Vector2i:
	if structure_type == "shrine":
		return Vector2i(9, 9)
	if structure_type == "mine":
		return Vector2i(rng.randi_range(10, 12), rng.randi_range(12, 14))
	if structure_type == "camp":
		return Vector2i(rng.randi_range(11, 13), rng.randi_range(10, 12))
	return Vector2i(rng.randi_range(7, 10), rng.randi_range(7, 10))


static func _old_hash01(seed_text: String, text: String) -> float:
	return float(abs(_old_hash_string("%s:%s" % [seed_text, text])) % 100000) / 100000.0


static func _old_hash_string(text: String) -> int:
	var h := 2166136261
	for i in range(text.length()):
		h = int((h ^ text.unicode_at(i)) * 16777619) & 0xffffffff
	return h
