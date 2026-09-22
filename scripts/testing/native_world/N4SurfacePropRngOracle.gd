extends SceneTree

# This is an engine-owned compatibility oracle for the first native
# surface-prop source slice.  It deliberately uses only RandomNumberGenerator
# and the inherited legacy FNV scalar hash so the C++ core can be compared
# without starting Main or publishing world content.

func legacy_hash(text: String) -> int:
	var h := 2166136261
	for index in range(text.length()):
		h = int((h ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return h

func raw_sequence(seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var values: Array[int] = []
	var states: Array[int] = []
	for _index in range(8):
		values.append(rng.randi())
		states.append(rng.state)
	return {
		"seed": seed_value,
		"values": values,
		"states": states,
		"stateAfter": rng.state
	}

func range_sequence(seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var ranges: Array[int] = []
	var states: Array[int] = []
	for _index in range(8):
		ranges.append(rng.randi_range(0, 24))
		states.append(rng.state)
	return {
		"seed": seed_value,
		"values": ranges,
		"states": states,
		"stateAfter": rng.state
	}

func signed_range_sequence(seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var values: Array[int] = []
	var states: Array[int] = []
	for _index in range(8):
		values.append(rng.randi_range(-7, 5))
		states.append(rng.state)
	return {"seed": seed_value, "values": values, "states": states, "stateAfter": rng.state}

func float_sequence(seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var values: Array[float] = []
	var float32_bits: Array[int] = []
	var states: Array[int] = []
	for _index in range(8):
		var value := rng.randf()
		values.append(value)
		float32_bits.append(PackedFloat32Array([value]).to_byte_array().decode_u32(0))
		states.append(rng.state)
	return {"seed": seed_value, "values": values, "float32Bits": float32_bits, "states": states, "stateAfter": rng.state}

func prop_coordinate_sequence(seed_text: String, chunk_x: int, chunk_z: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	var seed_value := legacy_hash("%s:props:%d,%d" % [seed_text, chunk_x, chunk_z])
	rng.seed = seed_value
	var attempts: Array[Dictionary] = []
	for attempt in range(28):
		var x := chunk_x * 28 + 2 + rng.randi_range(0, 24)
		var z := chunk_z * 28 + 2 + rng.randi_range(0, 24)
		attempts.append({
			"attempt": attempt,
			"x": x,
			"z": z,
			"id": "%s:%d,%d:%d" % [seed_text, x, z, attempt]
		})
	return {
		"seedText": seed_text,
		"chunk": [chunk_x, chunk_z],
		"seed": seed_value,
		"attempts": attempts,
		"stateAfterCoordinates": rng.state
	}

func removed_root_shift_sequence(seed_text: String, remove_first_root: bool) -> Dictionary:
	# Full 28-attempt source-order witness with deliberately synthetic decisions:
	# attempt zero is otherwise an ordinary rock; later eligible attempts choose
	# no feature. A root tombstone skips the first prop roll and six rock draws.
	var rng := RandomNumberGenerator.new()
	rng.seed = legacy_hash("%s:props:%d,%d" % [seed_text, 0, 0])
	var attempts: Array[Dictionary] = []
	for attempt in range(28):
		var before_coordinates := rng.state
		var x := 2 + rng.randi_range(0, 24)
		var z := 2 + rng.randi_range(0, 24)
		var after_coordinates := rng.state
		if attempt != 0 or not remove_first_root:
			rng.randf() # eligible prop roll
		if attempt == 0 and not remove_first_root:
			for _draw in range(6):
				rng.randf() # ordinary rock recipe
		attempts.append({
			"ordinal": attempt,
			"cell": [x, z],
			"id": "%s:%d,%d:%d" % [seed_text, x, z, attempt],
			"stateBeforeCoordinates": before_coordinates,
			"stateAfterCoordinates": after_coordinates,
			"stateAfterRecipe": rng.state
		})
	return {"removedFirstRoot": remove_first_root, "attempts": attempts, "finalState": rng.state}

func cutoff_precision_boundary() -> Dictionary:
	# This seed's first prop roll after the live attempt-zero coordinate pair is
	# exactly the float32 value immediately below the float64 scalar 0.08.
	var rng := RandomNumberGenerator.new()
	rng.seed = 22929874
	var coordinate_offsets := [rng.randi_range(0, 24), rng.randi_range(0, 24)]
	var roll := rng.randf()
	var cutoff := 0.08
	var narrowed_cutoff := PackedFloat32Array([cutoff])[0]
	return {
		"seed": 22929874,
		"coordinateOffsets": coordinate_offsets,
		"roll": roll,
		"rollFloat32BytesHex": PackedFloat32Array([roll]).to_byte_array().hex_encode(),
		"rollFloat64BytesHex": PackedFloat64Array([roll]).to_byte_array().hex_encode(),
		"cutoff": cutoff,
		"cutoffFloat32BytesHex": PackedFloat32Array([cutoff]).to_byte_array().hex_encode(),
		"cutoffFloat64BytesHex": PackedFloat64Array([cutoff]).to_byte_array().hex_encode(),
		"liveFloat64Decision": roll < cutoff,
		"narrowedFloat32Decision": roll < narrowed_cutoff,
		"stateAfter": rng.state,
	}

func _initialize() -> void:
	var unicode_seed := "世界🌲"
	var prop_key := "%s:props:%d,%d" % [unicode_seed, -3, 5]
	var without_removal := removed_root_shift_sequence("atlas-1492", false)
	var with_removal := removed_root_shift_sequence("atlas-1492", true)
	var cutoff_boundary := cutoff_precision_boundary()
	if without_removal.attempts[0].id != with_removal.attempts[0].id \
			or without_removal.attempts[1].id == with_removal.attempts[1].id \
			or without_removal.attempts.size() != 28 or with_removal.attempts.size() != 28 \
			or without_removal.finalState == with_removal.finalState:
		push_error("Removed-root source-order oracle did not shift the next candidate")
		quit(1)
		return
	if cutoff_boundary.coordinateOffsets != [1, 7] \
			or cutoff_boundary.rollFloat32BytesHex != "0ad7a33d" \
			or cutoff_boundary.rollFloat64BytesHex != "00000040e17ab43f" \
			or cutoff_boundary.cutoffFloat64BytesHex != "7b14ae47e17ab43f" \
			or not cutoff_boundary.liveFloat64Decision \
			or cutoff_boundary.narrowedFloat32Decision:
		push_error("Surface-prop cutoff precision boundary oracle failed")
		quit(1)
		return
	var report := {
		"schema": "n4-surface-prop-rng-oracle/v4",
		"legacyHash": {
			"empty": legacy_hash(""),
			"atlas": legacy_hash("atlas-1492"),
			"unicode": legacy_hash(unicode_seed),
			"propKey": legacy_hash(prop_key)
		},
		"raw": [raw_sequence(0), raw_sequence(1), raw_sequence(4294967295), raw_sequence(legacy_hash(prop_key))],
		"range": [range_sequence(0), range_sequence(1), range_sequence(4294967295), range_sequence(legacy_hash(prop_key))],
		"signedRange": [signed_range_sequence(0), signed_range_sequence(1), signed_range_sequence(4294967295)],
		"floats": [float_sequence(0), float_sequence(1), float_sequence(4294967295), float_sequence(legacy_hash(prop_key))],
		"coordinates": [
			prop_coordinate_sequence("atlas-1492", 0, 0),
			prop_coordinate_sequence(unicode_seed, -3, 5)
		],
		"removedRootShift": [
			without_removal,
			with_removal
		],
		"cutoffPrecisionBoundary": cutoff_boundary,
	}
	var encoded := JSON.stringify(report)
	print(encoded)
	var report_path := OS.get_environment("N4_SURFACE_PROP_RNG_ORACLE_REPORT")
	if report_path != "":
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file == null:
			push_error("Unable to write N4 surface-prop RNG oracle report")
			quit(1)
			return
		file.store_string(JSON.stringify(report, "\t"))
	quit()
