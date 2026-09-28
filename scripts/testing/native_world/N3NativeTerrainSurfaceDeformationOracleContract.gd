extends SceneTree

const CELL := 1.0
const EXPECTED_OBSERVATIONS_SHA256 := "0c8d7cce1fffe881edb003f122deb55e2c27366db46fb6486de45463f25a3653"


func _init() -> void:
	call_deferred("_run")


func _double_bits(value: float) -> String:
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_double(0, value)
	return bytes.hex_encode()


func _sha256_text(value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(value.to_utf8_buffer())
	return context.finish().hex_encode()


func _plan(center: Vector3, radius: float, drop_depth: float, x: int, z: int, surface_y: float) -> Dictionary:
	var safe_radius := maxf(radius, CELL * 0.75)
	var safe_drop := maxf(drop_depth, CELL * 0.35)
	var column_center := Vector2((float(x) + 0.5) * CELL, (float(z) + 0.5) * CELL)
	var horizontal_distance := column_center.distance_to(Vector2(center.x, center.z))
	var t := clampf(horizontal_distance / safe_radius, 0.0, 1.0)
	var falloff := 1.0 - t * t * (3.0 - 2.0 * t)
	var surface_target_y := surface_y - safe_drop * falloff
	var impact_strength := clampf(falloff * 1.35, 0.0, 1.0)
	var impact_target_y: float = lerp(surface_y, center.y - safe_drop * 0.72, impact_strength)
	var target_y := minf(surface_target_y, impact_target_y)
	var high_y := ceili((surface_y + CELL * 0.60) / CELL)
	var low_y := floori((target_y - CELL * 0.85) / CELL)
	return {
		"columnCenterX": _double_bits(column_center.x),
		"columnCenterZ": _double_bits(column_center.y),
		"horizontalDistance": _double_bits(horizontal_distance),
		"safeRadius": _double_bits(safe_radius),
		"safeDrop": _double_bits(safe_drop),
		"falloff": _double_bits(falloff),
		"falloffAccepted": falloff > 0.001,
		"surfaceTarget": _double_bits(surface_target_y),
		"impactStrength": _double_bits(impact_strength),
		"impactTarget": _double_bits(impact_target_y),
		"target": _double_bits(target_y),
		"targetAccepted": target_y < surface_y - CELL * 0.08,
		"highY": high_y,
		"lowY": low_y,
		"directY2Density": _double_bits(clampf(target_y - 2.5, -CELL * 2.0, -CELL * 0.05)),
		"directY1Density": _double_bits(clampf(target_y - 1.5, -CELL * 2.0, -CELL * 0.05)),
		"boundaryY0Density": _double_bits(clampf(target_y - 0.5, CELL * 0.05, CELL * 1.35)),
	}


func _run() -> void:
	var observations := {
		"impactWins": _plan(Vector3(0.5, 1.5, 0.5), 0.75, 0.35, 0, 0, 2.0),
		"surfaceDropWins": _plan(Vector3(0.5, 1.5, 0.5), 0.75, 1.0, 0, 0, 1.5),
		"negativeClamp": _plan(Vector3(-0.5, 1.75, -0.5), -50.0, -20.0, -1, -1, 2.25),
		"falloffRejected": _plan(Vector3(0.5, 1.5, 0.5), 1.01, 0.35, 1, 0, 2.0),
		"shallowTargetRejected": _plan(Vector3(0.5, 100.0, 0.5), 1.1, 0.35, 1, 0, 2.0),
		"float32Large": _plan(Vector3(16777216.5, 1.5, -16777216.5), 0.75, 0.35, 16777216, -16777216, 2.0),
	}
	var observations_sha256 := _sha256_text(JSON.stringify(observations))
	var semantic_checks := {
		"falloffThresholdRejected": not observations.falloffRejected.falloffAccepted,
		"shallowTargetThresholdRejected": not observations.shallowTargetRejected.targetAccepted,
		"float32LargeCoordinateRoundedToColumnCenter": observations.float32Large.horizontalDistance == _double_bits(0.0),
	}
	var semantic_passed := semantic_checks.values().all(func(value: Variant) -> bool: return value == true)
	var report := {
		"schema": "n3-native-terrain-surface-deformation-oracle/v1",
		"passed": observations_sha256 == EXPECTED_OBSERVATIONS_SHA256 and semantic_passed,
		"observations": observations,
		"observationsSha256": observations_sha256,
		"expectedObservationsSha256": EXPECTED_OBSERVATIONS_SHA256,
		"semanticChecks": semantic_checks,
		"forbiddenNativePathUsed": false,
		"doesNotProve": "Pure Godot 4.6 arithmetic oracle only; no native adapter, production activation, physics publication, or gameplay acceptance.",
	}
	var path := OS.get_environment("N3_SURFACE_DEFORMATION_ORACLE_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  ") + "\n")
	print(JSON.stringify(report))
	quit(0)
