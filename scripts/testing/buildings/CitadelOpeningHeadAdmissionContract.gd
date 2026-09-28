extends "res://scripts/testing/buildings/CitadelOpeningHeadBandContract.gd"

## Synthetic source-box admission plus actual known-failing recipe rejection.
## No rendering, normal integration, support capacity or gameplay acceptance.
const Admission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")

func _run() -> void:
	var path := OS.get_environment("VOXEL_OPENING_HEAD_ADMISSION_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var checks: Dictionary = {}
	var identity := Transform3D.IDENTITY
	var cases: Array = [
		["overlap", identity, identity, true, false],
		["separated", identity, Transform3D(Basis.IDENTITY, Vector3(1.01, 0, 0)), true, true],
		["exact_cardinal_touch", identity, Transform3D(Basis.IDENTITY, Vector3(1, 0, 0)), true, true],
		["represented_small_intrusion", identity, Transform3D(Basis.IDENTITY, Vector3(0.9999999403953552, 0, 0)), true, false],
		["represented_small_gap", identity, Transform3D(Basis.IDENTITY, Vector3(1.0000001192092896, 0, 0)), true, true],
		["rotated_overlap", identity, Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3.ZERO), true, false],
		["rotated_clear", identity, Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3(5, 0, 0)), true, true],
		["sheared_overlap", identity, Transform3D(Basis(Vector3(1, 0, 0), Vector3(0.5, 1, 0), Vector3(0, 0, 1)), Vector3.ZERO), true, false],
		["degenerate_rejected", identity, Transform3D(Basis.from_scale(Vector3(0, 1, 1)), Vector3.ZERO), false, false],
		["nonfinite_rejected", identity, Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0)), false, false]]
	var measurements: Array = []
	for row: Array in cases:
		var result := Admission.measure(row[1], row[2])
		var reverse := Admission.measure(row[2], row[1])
		checks[row[0]] = result.valid == row[3] and result.clear == row[4] and reverse.valid == result.valid and reverse.clear == result.clear
		measurements.append({"name": row[0], "result": result})
	var header: Dictionary = {"id": "synthetic_header", "kind": "beam", "size": Vector3.ONE, "position": Vector3.ZERO}
	for kind: String in ["wall", "foundation", "floor", "beam", "door", "window", "crate", "custom_collision_kind"]:
		var b = Copy.Blueprint.new("synthetic_kind_admission", 0, "timber")
		b.add_part({"id": "unrelated", "kind": kind, "size": Vector3.ONE, "collision": true})
		var frozen := Plan.digest(b.snapshot())
		var result := Band._foreign_solid_admission(b, header, [], [])
		checks["all_kinds:" + kind] = not result.ready and result.reason == "foreign_solid_header_no_fit" and result.blockingPartId == "unrelated" and Plan.digest(b.snapshot()) == frozen
	var clear = Copy.Blueprint.new("synthetic_clear_admission", 0, "timber")
	clear.add_part({"id": "distant", "kind": "foundation", "position": Vector3(4, 0, 0), "size": Vector3.ONE})
	checks["distant_solid_admitted"] = Band._foreign_solid_admission(clear, header, [], []).ready
	var source := _read_source()
	var actual: Dictionary = {}
	checks["bound_actual_source_read"] = not source.is_empty()
	if not source.is_empty():
		var b = Copy.copy_blueprint(source.afterSnapshot)
		var frozen := Plan.digest(b.snapshot())
		var original_parts: Array = b.parts.duplicate()
		var membership: Dictionary = Copy.street_house_memberships(b)
		var houses: Array = membership.get("houses", []).filter(func(h): return h.prefix == "urban_row_03_right")
		checks["known_failing_house_found"] = membership.ready and houses.size() == 1
		if checks.known_failing_house_found:
			actual = Band.prepare_first(b, houses[0].memberIds, {"furnitureParts": source.furnitureSnapshot.parts, "reservedVolumes": source.protectedReservations, "requiredHeadroom": 1.72})
			checks["actual_intrusion_rejected_atomically"] = not actual.ready and actual.reason == "foreign_solid_header_no_fit" and not actual.has("candidateSnapshot") and Plan.digest(b.snapshot()) == frozen and b.parts == original_parts
		checks["source_file_still_bound"] = FileAccess.get_sha256(SOURCE_PATH) == SOURCE_SHA
	var passed: bool = checks.values().all(func(value): return value == true)
	var report := {"passed": passed, "checks": checks, "measurements": measurements, "actualNoFit": actual,
		"seed": 208159, "scale": 1.25, "elapsedMsec": Time.get_ticks_msec() - started,
		"limitations": "Synthetic affine source-box admission and real recipe atomic no-fit only. Does not prove a fitting replacement, published geometry, visuals, normal integration or gate zero."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)
