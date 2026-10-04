extends SceneTree

## Direct production-method versus value-only replay contract, not gameplay.
const MainScript := preload("res://scripts/Main.gd")
const Structures := preload("res://scripts/StructureSystem.gd")
const Admission := preload("res://scripts/world/CitadelTerrainAdmission.gd")
const EcologyLedger := preload("res://scripts/world/EcologySourceValueLedger.gd")
const CHUNK := Vector2i.ZERO
const EXPECTED_ATTEMPTS := 53

func _init() -> void:
	call_deferred("run")

func bits(value: float) -> int:
	return PackedFloat32Array([value]).to_byte_array().decode_u32(0)

func transform_bits(value: Transform3D) -> Array:
	return [bits(value.basis.x.x), bits(value.basis.x.y), bits(value.basis.x.z),
		bits(value.basis.y.x), bits(value.basis.y.y), bits(value.basis.y.z),
		bits(value.basis.z.x), bits(value.basis.z.y), bits(value.basis.z.z),
		bits(value.origin.x), bits(value.origin.y), bits(value.origin.z)]

func snapshot_policy(profile: BiomeEnvironmentProfile) -> Dictionary:
	var result := {"maxHeight": float(profile.detail_max_height_above_water),
		"types": [], "thresholds": [], "yOffsets": [], "scaleMins": [], "scaleMaxs": []}
	for i in range(profile.detail_types.size()):
		result.types.append(String(profile.detail_types[i]))
		result.thresholds.append(float(profile.detail_thresholds[i]))
		result.yOffsets.append(float(profile.detail_y_offsets[i]))
		result.scaleMins.append(float(profile.detail_scale_mins[i]))
		result.scaleMaxs.append(float(profile.detail_scale_maxs[i]))
	return result

func new_rows(batches: Dictionary, before_counts: Dictionary) -> Dictionary:
	var result := {}
	for key in batches.keys():
		var rows: Array = batches[key]
		var prior := int(before_counts.get(key, 0))
		if prior >= rows.size():
			continue
		var added := []
		for i in range(prior, rows.size()):
			added.append(transform_bits(rows[i]))
		result[String(key)] = added
	return result

func batch_counts(batches: Dictionary) -> Dictionary:
	var result := {}
	for key in batches.keys():
		result[key] = (batches[key] as Array).size()
	return result

func next_cell(rng: RandomNumberGenerator, chunk_key: Vector2i) -> Vector2i:
	var preview := RandomNumberGenerator.new()
	preview.seed = rng.seed
	preview.state = rng.state
	return Vector2i(
		chunk_key.x * MainScript.CHUNK_SIZE + 1 + preview.randi_range(0, MainScript.CHUNK_SIZE - 2),
		chunk_key.y * MainScript.CHUNK_SIZE + 1 + preview.randi_range(0, MainScript.CHUNK_SIZE - 2))

func capture_facts(main: Object, rng: RandomNumberGenerator, chunk_key: Vector2i) -> Dictionary:
	var cell := next_cell(rng, chunk_key)
	var x := cell.x
	var z := cell.y
	var blocked: bool = main.natural_props_blocked_at_cell(x, z)
	var sample: Dictionary = main.surface_volume_spawn_sample_at_cell(x, z) if not blocked else {}
	var found := not sample.is_empty() and bool(sample.get("found", false))
	var height := float(sample.get("height", 0.0))
	var biome := String(sample.get("biome", "plains"))
	var eligible := not blocked and found and height >= MainScript.WATER_LEVEL - 0.1 \
		and height <= 104.0 and biome != "town"
	var heights := []
	var policy := {}
	if eligible:
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				heights.append(float(main.surface_y_at_cell(Vector3i(x + dx, 0, z + dz))))
		policy = snapshot_policy(main.biome_environment_catalog.profile_for_biome(biome))
	return {"cell": [x, z], "blocked": blocked, "found": found,
		"height": height, "biome": biome, "heights": heights, "policy": policy,
		"eligible": eligible}

func native_input_row(facts: Dictionary, ordinal: int) -> Dictionary:
	return {"ordinal": ordinal,
		"cell": Vector2i(int(facts.cell[0]), int(facts.cell[1])),
		"blocked": bool(facts.blocked), "found": bool(facts.found),
		"height": float(facts.height), "biome": String(facts.biome),
		"heights": (facts.heights as Array).duplicate(true),
		"policy": (facts.policy as Dictionary).duplicate(true)}

func compare_native_case(main: Object, chunk_key: Vector2i, facts_rows: Array,
		direct_rows: Array, final_rng_state: String) -> Dictionary:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	if backend == null or not backend.has_method("compose_detail_ordered_plan_shadow"):
		return {"status": "failed", "failures": ["native detail shadow unavailable"]}
	var capture := {"schema": "n4-detail-ordered-plan-shadow/v1",
		"seedText": main.seed_text, "chunk": chunk_key,
		"quality": {"decorativeDensity": float(main.visual_quality.decorativeDensity),
			"decorativeDetailCap": int(main.visual_quality.decorativeDetailCap)},
		"attempts": facts_rows}
	var native: Dictionary = backend.compose_detail_ordered_plan_shadow(capture)
	var failures := []
	if native.get("status") != "ready":
		return {"status": "failed", "failures": ["native rejected input: " + String(native.get("reason", ""))]}
	var attempts: Array = native.get("attempts", [])
	if attempts.size() != direct_rows.size():
		failures.append("native attempt count")
	for i in range(mini(attempts.size(), direct_rows.size())):
		var direct: Dictionary = direct_rows[i]
		var row: Dictionary = attempts[i]
		var cell: Vector2i = row.cell
		if row.ordinal != i or [cell.x, cell.y] != direct.cell:
			failures.append("attempt %d native coordinate" % i)
		if String(row.stateBeforeCoordinates) != String(direct.beforeState) \
				or String(row.stateAfterCoordinates) != String(direct.coordinateState) \
				or String(row.stateAfterAttempt) != String(direct.afterState):
			failures.append("attempt %d native RNG state" % i)
		if String(row.choiceType) != String(direct.choiceType):
			failures.append("attempt %d native choice" % i)
		var native_rows := {}
		for transform in row.transforms:
			var detail_type := String(transform.detailType)
			if not native_rows.has(detail_type):
				native_rows[detail_type] = []
			var scale := Vector3.ONE * float(transform.scale)
			var reconstructed := Transform3D(Basis(Vector3.UP, float(transform.yaw)).scaled(scale),
				transform.origin)
			(native_rows[detail_type] as Array).append(transform_bits(reconstructed))
		if JSON.stringify(native_rows) != JSON.stringify(direct.rows):
			failures.append("attempt %d native transform bits" % i)
	if String(native.get("finalRngState", "")) != final_rng_state:
		failures.append("native final RNG state")
	return {"status": "passed" if failures.is_empty() else "failed",
		"attemptsCompared": mini(attempts.size(), direct_rows.size()),
		"failures": failures.slice(0, 30)}

func append_replay(replayed: Dictionary, detail_type: String, origin: Vector3,
		yaw: float, scale: Vector3) -> void:
	if not replayed.has(detail_type):
		replayed[detail_type] = []
	var transform := Transform3D(Basis(Vector3.UP, yaw).scaled(scale), origin)
	replayed[detail_type].append(transform_bits(transform))

func replay_attempt(facts: Dictionary, rng: RandomNumberGenerator, chunk_key: Vector2i) -> Dictionary:
	var result := {"rows": {}, "choiceType": "", "stateAfterCoordinates": ""}
	var x := int(chunk_key.x * MainScript.CHUNK_SIZE + 1 + rng.randi_range(0, MainScript.CHUNK_SIZE - 2))
	var z := int(chunk_key.y * MainScript.CHUNK_SIZE + 1 + rng.randi_range(0, MainScript.CHUNK_SIZE - 2))
	result["cell"] = [x, z]
	result["stateAfterCoordinates"] = str(rng.state)
	if bool(facts.blocked) or not bool(facts.found):
		return result
	var height := float(facts.height)
	if height < MainScript.WATER_LEVEL - 0.1 or height > 104.0 or String(facts.biome) == "town":
		return result
	var center := float(facts.heights[4])
	var max_delta := 0.0
	for sample in facts.heights:
		max_delta = maxf(max_delta, abs(float(sample) - center))
	if max_delta > MainScript.CELL * 1.35:
		return result
	var local_position := Vector3(
		float(x - chunk_key.x * MainScript.CHUNK_SIZE) * MainScript.CELL + rng.randf_range(-0.42, 0.42),
		height,
		float(z - chunk_key.y * MainScript.CHUNK_SIZE) * MainScript.CELL + rng.randf_range(-0.42, 0.42))
	var roll := rng.randf()
	var policy: Dictionary = facts.policy
	if height > MainScript.WATER_LEVEL + float(policy.maxHeight):
		return result
	var selected := -1
	for i in range(policy.thresholds.size()):
		if roll < float(policy.thresholds[i]):
			selected = i
			break
	if selected < 0:
		return result
	var detail_type := String(policy.types[selected])
	result["choiceType"] = detail_type
	if detail_type == "":
		return result
	var rows: Dictionary = result.rows
	if detail_type == "flower":
		var yaw := rng.randf() * TAU
		var scale := rng.randf_range(0.82, 1.18)
		var offset := Vector3(cos(yaw + PI * 0.5), 0.0, sin(yaw + PI * 0.5)) * 0.08
		append_replay(rows, "flowerStem", local_position + Vector3(0.0, 0.15, 0.0) - offset,
			yaw, Vector3.ONE * scale)
		append_replay(rows, "flowerBloom", local_position + Vector3(0.0, 0.15, 0.0) + offset,
			yaw + PI * 0.62, Vector3.ONE * scale)
	else:
		append_replay(rows, detail_type,
			local_position + Vector3(0.0, float(policy.yOffsets[selected]), 0.0),
			rng.randf() * TAU,
			Vector3.ONE * rng.randf_range(float(policy.scaleMins[selected]),
				float(policy.scaleMaxs[selected])))
	return result

func run_rejected_branch(main: Object, mode: String) -> Dictionary:
	var state: Dictionary = main.begin_chunk_prop_spawn_state(Node3D.new(), CHUNK.x, CHUNK.y)
	var rng: RandomNumberGenerator = state.detailRng
	var replay_rng := RandomNumberGenerator.new()
	replay_rng.seed = rng.seed
	var cell := next_cell(rng, CHUNK)
	var marker := Vector2i(cell.x + 1, cell.y + 1)
	var markers: Dictionary = main.get("volume_edit_markers")
	if mode == "blocked":
		main.structure_system.reserve_natural_prop_exclusion(cell.x, cell.y, 1, 1,
			"detail-parity-blocked")
	else:
		markers[marker] = main.surface_y_at_cell(Vector3i(marker.x, 0, marker.y)) + 20.0
	var before_state := str(rng.state)
	var facts: Dictionary = capture_facts(main, rng, CHUNK)
	var replay: Dictionary = replay_attempt(facts.duplicate(true), replay_rng, CHUNK)
	var batches := {}
	var attempt: Dictionary = main.begin_chunk_detail_attempt(state, rng)
	var coordinate_state := str(rng.state)
	while not main.advance_chunk_detail_attempt(state, attempt, rng, batches):
		pass
	var failures := []
	if replay.cell != facts.cell or [attempt.x, attempt.z] != facts.cell:
		failures.append("coordinates")
	if replay.stateAfterCoordinates != coordinate_state or str(replay_rng.state) != str(rng.state):
		failures.append("conditional RNG state")
	if not replay.rows.is_empty() or not batches.is_empty():
		failures.append("rejected attempt emitted detail")
	if mode == "blocked" and not bool(facts.blocked):
		failures.append("structure exclusion did not block")
	if mode == "variation":
		if not bool(facts.eligible) or float(facts.heights[8]) - float(facts.heights[4]) <= MainScript.CELL * 1.35:
			failures.append("saved-height marker did not trigger variation rejection")
	var native_facts := [native_input_row(facts, 0)]
	var direct_rows := [{"cell": facts.cell, "beforeState": before_state,
		"coordinateState": coordinate_state, "afterState": str(rng.state),
		"choiceType": replay.choiceType, "rows": replay.rows}]
	for ordinal in range(1, EXPECTED_ATTEMPTS):
		before_state = str(rng.state)
		facts = capture_facts(main, rng, CHUNK)
		native_facts.append(native_input_row(facts, ordinal))
		replay = replay_attempt(facts.duplicate(true), replay_rng, CHUNK)
		var before_counts := batch_counts(batches)
		attempt = main.begin_chunk_detail_attempt(state, rng)
		coordinate_state = str(rng.state)
		while not main.advance_chunk_detail_attempt(state, attempt, rng, batches):
			pass
		if replay.cell != facts.cell or [attempt.x, attempt.z] != facts.cell:
			failures.append("attempt %d coordinates" % ordinal)
		if replay.stateAfterCoordinates != coordinate_state or str(replay_rng.state) != str(rng.state):
			failures.append("attempt %d RNG state" % ordinal)
		if JSON.stringify(replay.rows) != JSON.stringify(new_rows(batches, before_counts)):
			failures.append("attempt %d detail type or transform bits" % ordinal)
		direct_rows.append({"cell": facts.cell, "beforeState": before_state,
			"coordinateState": coordinate_state, "afterState": str(rng.state),
			"choiceType": replay.choiceType, "rows": replay.rows})
	var native_result: Dictionary = compare_native_case(main, CHUNK, native_facts,
		direct_rows, str(rng.state))
	for failure in native_result.failures:
		failures.append("native: " + String(failure))
	if mode == "variation":
		markers.erase(marker)
	(state.chunk as Node3D).free()
	return {"mode": mode, "cell": [cell.x, cell.y],
		"attemptsCompared": EXPECTED_ATTEMPTS, "nativeStatus": native_result.status,
		"failures": failures}

func find_flower_chunk(main: Object) -> Vector2i:
	for radius in [24, 48, 96, 192]:
		for sign_x in [-1, 0, 1]:
			for sign_z in [-1, 0, 1]:
				if sign_x == 0 and sign_z == 0:
					continue
				var key := Vector2i(sign_x * radius, sign_z * radius)
				var center := Vector3i(key.x * MainScript.CHUNK_SIZE + 14, 0,
					key.y * MainScript.CHUNK_SIZE + 14)
				if String(main.surface_biome_at_cell(center)) in ["forest", "taiga"]:
					return key
	return Vector2i(2147483647, 2147483647)

func run_flower_case(main: Object, chunk_key: Vector2i) -> Dictionary:
	var chunk := Node3D.new()
	var state: Dictionary = main.begin_chunk_prop_spawn_state(chunk, chunk_key.x, chunk_key.y)
	var rng: RandomNumberGenerator = state.detailRng
	var replay_rng := RandomNumberGenerator.new()
	replay_rng.seed = rng.seed
	var batches := {}
	var failures := []
	var flower_count := 0
	var native_facts := []
	var direct_rows := []
	for ordinal in range(EXPECTED_ATTEMPTS):
		var facts: Dictionary = capture_facts(main, rng, chunk_key)
		native_facts.append(native_input_row(facts, ordinal))
		var before_state := str(rng.state)
		var replay: Dictionary = replay_attempt(facts.duplicate(true), replay_rng, chunk_key)
		var before_counts := batch_counts(batches)
		var attempt: Dictionary = main.begin_chunk_detail_attempt(state, rng)
		var coordinate_state := str(rng.state)
		while not main.advance_chunk_detail_attempt(state, attempt, rng, batches):
			pass
		if replay.cell != facts.cell or [attempt.x, attempt.z] != facts.cell:
			failures.append("attempt %d coordinates" % ordinal)
		if replay.stateAfterCoordinates != coordinate_state or str(replay_rng.state) != str(rng.state):
			failures.append("attempt %d conditional RNG state" % ordinal)
		if JSON.stringify(replay.rows) != JSON.stringify(new_rows(batches, before_counts)):
			failures.append("attempt %d detail type or transform bits" % ordinal)
		direct_rows.append({"cell": facts.cell, "beforeState": before_state,
			"coordinateState": coordinate_state, "afterState": str(rng.state),
			"choiceType": replay.choiceType, "rows": replay.rows})
		if replay.choiceType == "flower":
			flower_count += 1
	var native_result: Dictionary = compare_native_case(main, chunk_key, native_facts,
		direct_rows, str(rng.state))
	for failure in native_result.failures:
		failures.append("native: " + String(failure))
	chunk.free()
	return {"chunk": [chunk_key.x, chunk_key.y], "flowerCount": flower_count,
		"attemptsCompared": EXPECTED_ATTEMPTS, "nativeStatus": native_result.status,
		"failures": failures}

func run() -> void:
	var failures := []
	var main = MainScript.new()
	main.apply_world_seed("atlas-1492", false)
	main.setup_biome_environment_catalog()
	for material_key in ["detailGrass", "detailFlower", "detailReed", "detailPebble",
			"detailSnow", "detailLeaf", "detailScrub"]:
		main.materials[material_key] = StandardMaterial3D.new()
	var structures := Structures.new()
	structures.main = main
	structures.regional_source_generation = 1
	var admission := Admission.new()
	admission.configure(main.seed_text, {}, {"regionCells": 384, "spawnChance": 0.0})
	admission.finalize_town_inputs({})
	structures.citadel_terrain_admission = admission
	main.structure_system = structures
	var chunk := Node3D.new()
	root.add_child(chunk)
	chunk.global_position = Vector3(float(CHUNK.x * MainScript.CHUNK_SIZE) * MainScript.CELL,
		0.0, float(CHUNK.y * MainScript.CHUNK_SIZE) * MainScript.CELL)
	var state: Dictionary = main.begin_chunk_prop_spawn_state(chunk, CHUNK.x, CHUNK.y)
	var quality: Dictionary = main.visual_quality.duplicate(true)
	var density := clampf(float(quality.get("decorativeDensity", 0.74)), 0.0, 1.0)
	var attempts := maxi(8, int(round(float(quality.get("decorativeDetailCap", 72)) * density)))
	if attempts != EXPECTED_ATTEMPTS:
		failures.append("quality did not select 53 attempts")
	var production_rng: RandomNumberGenerator = state.detailRng
	var replay_rng := RandomNumberGenerator.new()
	replay_rng.seed = production_rng.seed
	var production_batches := {}
	var replay_batches := {}
	var native_facts := []
	var direct_rows := []
	var branch_counts := {"blocked": 0, "surfaceRejected": 0, "variationRejected": 0,
		"eligible": 0, "flower": 0}
	var checked := 0
	for ordinal in range(attempts):
		var before_state := str(production_rng.state)
		if before_state != str(replay_rng.state):
			failures.append("attempt %d pre-RNG state" % ordinal)
		var facts: Dictionary = capture_facts(main, production_rng, CHUNK)
		native_facts.append(native_input_row(facts, ordinal))
		var replay: Dictionary = replay_attempt(facts.duplicate(true), replay_rng, CHUNK)
		var before_counts := batch_counts(production_batches)
		var attempt: Dictionary = main.begin_chunk_detail_attempt(state, production_rng)
		var actual_coordinate_state := str(production_rng.state)
		while not main.advance_chunk_detail_attempt(state, attempt, production_rng, production_batches):
			pass
		var produced: Dictionary = new_rows(production_batches, before_counts)
		if replay.cell != facts.cell or [attempt.x, attempt.z] != facts.cell:
			failures.append("attempt %d coordinates" % ordinal)
		if replay.stateAfterCoordinates != actual_coordinate_state:
			failures.append("attempt %d coordinate RNG state" % ordinal)
		if str(replay_rng.state) != str(production_rng.state):
			failures.append("attempt %d final RNG state" % ordinal)
		if JSON.stringify(replay.rows) != JSON.stringify(produced):
			failures.append("attempt %d detail type or transform bits" % ordinal)
		direct_rows.append({"cell": facts.cell, "beforeState": before_state,
			"coordinateState": actual_coordinate_state, "afterState": str(production_rng.state),
			"choiceType": replay.choiceType, "rows": produced})
		for detail_type in replay.rows.keys():
			if not replay_batches.has(detail_type):
				replay_batches[detail_type] = []
			(replay_batches[detail_type] as Array).append_array(replay.rows[detail_type])
		if bool(facts.blocked):
			branch_counts.blocked += 1
		elif not bool(facts.eligible):
			branch_counts.surfaceRejected += 1
		elif replay.rows.is_empty():
			branch_counts.variationRejected += 1
		else:
			branch_counts.eligible += 1
			if replay.choiceType == "flower":
				branch_counts.flower += 1
		checked += 1
	var final_batches := {}
	for key in production_batches.keys():
		var rows := []
		for transform in production_batches[key]:
			rows.append(transform_bits(transform))
		final_batches[String(key)] = rows
	if JSON.stringify(replay_batches) != JSON.stringify(final_batches):
		failures.append("final ordered batch transforms")
	var ledger_state: Dictionary = state
	ledger_state["detailBatches"] = production_batches.duplicate(true)
	ledger_state["detailBatchKeys"] = production_batches.keys()
	ledger_state["detailBatchIndex"] = 0
	if not main.process_chunk_detail_batch_spawn_state(ledger_state, -1.0, 0):
		failures.append("production detail batch capture did not finish")
	var ledger = ledger_state.get("ecologySourceLedger")
	var ecology_snapshot: Dictionary = ledger.call("snapshot") if ledger != null else {}
	var expected_instance_count := 0
	for transforms_value in production_batches.values():
		expected_instance_count += (transforms_value as Array).size()
	var candidates: Array = ecology_snapshot.get("candidates", [])
	if candidates.size() != expected_instance_count:
		failures.append("producer ledger instance count")
	var expected_by_id := {}
	for detail_type_value in production_batches.keys():
		var detail_type := String(detail_type_value)
		var transforms: Array = production_batches[detail_type_value]
		for index in range(transforms.size()):
			var source_id := "%s:detail:%d,%d:%s:%d" % [main.seed_text, CHUNK.x, CHUNK.y, detail_type, index]
			expected_by_id[source_id] = transforms[index]
	for candidate_value in candidates:
		var candidate: Dictionary = candidate_value
		var source_id := String(candidate.get("sourceId", ""))
		if not expected_by_id.has(source_id):
			failures.append("producer ledger emitted unknown detail source ID")
			break
		var expected_transform: Transform3D = expected_by_id[source_id]
		var expected_bounds: AABB = main.detail_mesh(String(candidate.get("detailType", ""))).get_aabb() * expected_transform
		var actual_bounds: AABB = candidate.get("localBounds", AABB())
		if transform_bits(candidate.get("transform", Transform3D())) != transform_bits(expected_transform) \
				or String(candidate.get("contentRevision", "")).is_empty() \
				or not actual_bounds.is_equal_approx(expected_bounds):
			failures.append("producer ledger detail transform/bounds mismatch: %s" % source_id)
			break
	var replay_chunk := Node3D.new()
	var replay_state: Dictionary = main.begin_chunk_prop_spawn_state(replay_chunk, CHUNK.x, CHUNK.y)
	for detail_type_value in production_batches.keys():
		main.record_chunk_detail_source_values(replay_chunk, CHUNK.x, CHUNK.y,
			String(detail_type_value), production_batches[detail_type_value])
	var replay_snapshot: Dictionary = replay_state.ecologySourceLedger.call("snapshot")
	if String(ecology_snapshot.get("contentRevision", "")) != \
			String(replay_snapshot.get("contentRevision", "")):
		failures.append("producer ledger changed across chunk recreation")
	if String(ecology_snapshot.get("scope", "")) != "partial_static_ecology_producer_values" \
			or not (ecology_snapshot.get("limitations", []) as Array).has("surface rocks, ore, forage, wildlife, and underground props are not captured"):
		failures.append("producer ledger omitted its partial-coverage declaration")
	if String(ecology_snapshot.get("lifetime", "")) != \
			"streamed_chunk_owner; regenerated from seed and durable removals after unload":
		failures.append("producer ledger lifetime is not explicit")
	main._finalize_ecology_source_values(ledger_state)
	if not chunk.has_meta("static_ecology_source_value_snapshot") \
			or chunk.has_meta("static_ecology_source_value_ledger"):
		failures.append("snapshot was not transferred to bounded chunk ownership")
	var tombstone_ledger = EcologyLedger.new()
	tombstone_ledger.configure(main.seed_text, CHUNK, "tombstone-contract", 0)
	if not candidates.is_empty():
		var tombstone_candidate: Dictionary = candidates[0].duplicate(true)
		tombstone_candidate["sourceId"] = "harvest-contract-prop"
		tombstone_candidate["propId"] = "harvest-contract-prop"
		tombstone_ledger.record_candidate(tombstone_candidate)
	tombstone_ledger.apply_removed_props({"harvest-contract-prop": true}, 7)
	var tombstone_snapshot: Dictionary = tombstone_ledger.snapshot()
	if tombstone_snapshot.candidates.size() != 0 or tombstone_snapshot.tombstones.size() != 1 \
			or tombstone_snapshot.removedPropsRevision != 7:
		failures.append("durable removal did not become a tombstone")
	var tree_records := []
	for _replay_index in range(2):
		var tree_chunk := Node3D.new()
		root.add_child(tree_chunk)
		var tree_state: Dictionary = main.begin_chunk_prop_spawn_state(tree_chunk, 3, 5)
		var tree_rng := RandomNumberGenerator.new()
		tree_rng.seed = 781223
		main.make_tree(tree_chunk, "%s:16,24:0" % main.seed_text,
			Vector3(2.0, 8.0, 3.0), "forest", tree_rng, Vector2i(16, 24))
		var tree_snapshot: Dictionary = tree_state.ecologySourceLedger.call("snapshot")
		tree_records.append(tree_snapshot)
		var tree_candidates: Array = tree_snapshot.get("candidates", [])
		if tree_candidates.size() != 1:
			failures.append("tree producer did not capture one visual source")
		else:
			var tree_candidate: Dictionary = tree_candidates[0]
			var expected_prop_id := "%s:16,24:0" % main.seed_text
			var tree_bounds: AABB = tree_candidate.get("localBounds", AABB())
			if String(tree_candidate.get("sourceId", "")) != "%s:tree:%s" % [main.seed_text, expected_prop_id] \
					or String(tree_candidate.get("visualId", "")) != "procedural-tree:%s" % expected_prop_id \
					or int(tree_candidate.get("recipeVersion", 0)) != 2 \
					or tree_bounds.size.x <= 0.0 or tree_bounds.size.y <= 0.0 or tree_bounds.size.z <= 0.0 \
					or not tree_candidate.has("runtimeSpec"):
				failures.append("tree visual identity, recipe inputs, or bounds changed")
			if tree_candidate.has("collision") or tree_candidate.has("interaction"):
				failures.append("tree render record duplicates gameplay authority")
		tree_chunk.free()
	if tree_records.size() == 2 and String(tree_records[0].get("contentRevision", "")) != \
			String(tree_records[1].get("contentRevision", "")):
		failures.append("tree producer values changed across chunk recreation")
	replay_chunk.free()
	var native_baseline: Dictionary = compare_native_case(main, CHUNK, native_facts,
		direct_rows, str(production_rng.state))
	for failure in native_baseline.failures:
		failures.append("native baseline: " + String(failure))
	var variation_case: Dictionary = run_rejected_branch(main, "variation")
	var blocked_case: Dictionary = run_rejected_branch(main, "blocked")
	for failure in variation_case.failures:
		failures.append("variation case: " + String(failure))
	for failure in blocked_case.failures:
		failures.append("blocked case: " + String(failure))
	var flower_key := find_flower_chunk(main)
	var flower_case := {"chunk": [], "flowerCount": 0, "attemptsCompared": 0,
		"failures": ["no forest/taiga chunk in bounded search"]}
	if flower_key.x != 2147483647:
		flower_case = run_flower_case(main, flower_key)
	for failure in flower_case.failures:
		failures.append("flower case: " + String(failure))
	if int(flower_case.flowerCount) == 0:
		failures.append("flower case did not exercise flower recipe")
	var report := {"schema": "detail-ordered-pure-data-parity/v1",
		"status": "passed" if failures.is_empty() else "failed",
		"evidenceLevel": "direct production-method/value-only replay; not live gameplay",
		"seed": main.seed_text, "chunk": [CHUNK.x, CHUNK.y],
		"attemptsExpected": EXPECTED_ATTEMPTS, "attemptsCompared": checked,
		"branchCounts": branch_counts, "batchTypes": final_batches.keys(),
		"nativeBaseline": native_baseline,
		"ecologySourceValueLedger": {"candidateCount": candidates.size(),
			"recreationRevisionMatches": String(ecology_snapshot.get("contentRevision", "")) == String(replay_snapshot.get("contentRevision", "")),
			"tombstoneCount": tombstone_snapshot.get("tombstones", []).size(),
			"treeRecreationRevisionMatches": tree_records.size() == 2 and String(tree_records[0].get("contentRevision", "")) == String(tree_records[1].get("contentRevision", "")),
			"snapshotLifetime": ecology_snapshot.get("lifetime", ""),
			"scope": ecology_snapshot.get("scope", ""),
			"contentRevision": ecology_snapshot.get("contentRevision", "")},
		"variationCase": variation_case, "blockedCase": blocked_case, "flowerCase": flower_case,
		"finalRngState": str(production_rng.state), "failures": failures.slice(0, 30)}
	var path := OS.get_environment("DETAIL_ORDERED_PARITY_REPORT")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	chunk.free()
	main.free()
	quit(0 if failures.is_empty() else 1)
