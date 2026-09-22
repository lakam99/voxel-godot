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
	# Narrow source-order witness: attempt zero is otherwise an ordinary rock,
	# whose make_rock path consumes six compatibility draws. A tombstone skips
	# those draws and the prop roll before the next pair of coordinates.
	var rng := RandomNumberGenerator.new()
	rng.seed = legacy_hash("%s:props:%d,%d" % [seed_text, 0, 0])
	var attempts: Array[Dictionary] = []
	for attempt in range(2):
		var before_coordinates := rng.state
		var x := 2 + rng.randi_range(0, 24)
		var z := 2 + rng.randi_range(0, 24)
		var after_coordinates := rng.state
		if attempt == 0 and not remove_first_root:
			rng.randf() # prop roll
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

func _initialize() -> void:
	var unicode_seed := "世界🌲"
	var prop_key := "%s:props:%d,%d" % [unicode_seed, -3, 5]
	var without_removal := removed_root_shift_sequence("atlas-1492", false)
	var with_removal := removed_root_shift_sequence("atlas-1492", true)
	if without_removal.attempts[0].id != with_removal.attempts[0].id \
			or without_removal.attempts[1].id == with_removal.attempts[1].id:
		push_error("Removed-root source-order oracle did not shift the next candidate")
		quit(1)
		return
	var report := {
		"schema": "n4-surface-prop-rng-oracle/v2",
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
		]
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
