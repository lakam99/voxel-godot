extends SceneTree
## Synthetic production-producer geometry contract; no rendered acceptance.
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Declaration = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
var checks: Dictionary = {}
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("FACADE_PARTITION_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	for index in range(64):
		var offset := float(index - 32) * 0.3719273
		var a = _build(offset)
		var b = _build(offset)
		if not a.recipe.has("facadeApertures") or not b.recipe.has("facadeApertures"):
			checks["producer_ready_%d" % index] = false
			continue
		checks["deterministic_%d" % index] = var_to_bytes(a.snapshot()) == var_to_bytes(b.snapshot())
		var record: Dictionary = a.recipe.facadeApertures.fixture
		var by_id := {}
		for part in a.parts: by_id[part.id] = part
		checks["binding_%d" % index] = Declaration.validate(record, by_id)
		var clear := true
		for part in a.parts:
			var bounds: AABB = a.transformed_part_bounds(part)
			for opening in record.openings:
				var volume: AABB = opening.fullVolume
				var scalar_overlap := true
				for axis in range(3):
					scalar_overlap = scalar_overlap and minf(float(part.position[axis]) + float(part.size[axis]) * 0.5, float(volume.end[axis])) > maxf(float(part.position[axis]) - float(part.size[axis]) * 0.5, float(volume.position[axis]))
				clear = clear and not scalar_overlap and not bounds.intersects(volume)
		checks["every_panel_clear_%d" % index] = clear and a.parts.size() > 0
		# Existing 5x5 ordered cells minus the two openings: 23 panels.
		var identity: bool = a.parts.size() == 23
		for part_index in range(a.parts.size()):
			var part = a.parts[part_index]
			identity = identity and part.id == "fixture_%03d" % part_index and part.recipe.variation == 0.108 + float(posmod(part_index, 5) - 2) * 0.004 and part.material_id == "painted_brick_cream" and part.collision_enabled
		checks["partition_identity_%d" % index] = identity
	for bounds in [Vector2(7.609762382507324, 8.659762382507324), Vector2(-21.99427, -20.83427), Vector2(0, 1), Vector2(-1, 0)]:
		var result := Urban.FacadePartition.interval(bounds.x, bounds.y)
		checks["interval_%d" % checks.size()] = result.ready and result.size > 0 and result.center - result.size * 0.5 >= bounds.x and result.center + result.size * 0.5 <= bounds.y
	for invalid in [Vector2(1, 0), Vector2(1, 1), Vector2(NAN, 1), Vector2(0, INF), Vector2(0, 0.019), Vector2(16777216, 16777218)]:
		checks["invalid_%d" % checks.size()] = not Urban.FacadePartition.interval(invalid.x, invalid.y).ready
	for recessed in [false, true]:
		var target = Blueprint.new("late_rejection", 101)
		target.add_part({"id": "existing", "kind": "wall", "size": Vector3.ONE})
		var before := var_to_bytes(target.snapshot())
		var openings: Array[Dictionary] = [{"centerY": 16777217.0, "height": 1.0, "centerZ": 0.0, "width": 1.16}]
		var result: Dictionary
		if recessed:
			result = Urban.add_recessed_facade_mass(target, "late", 0, 0, 6, 6, 0, 16777220, 1, "stone_foundation", 0, openings, "facade")
		else:
			result = Urban.add_partitioned_street_facade(target, "late", 0, 0, 6, 0, 16777220, 0.3, "stone_foundation", 0, openings, "facade")
		checks["late_rejection_atomic_%s" % recessed] = not result.ready and result.get("panelIndex", 0) > 0 and before == var_to_bytes(target.snapshot())
		if not checks["late_rejection_atomic_%s" % recessed]: print("LATE RESULT ", recessed, " ", result)
	var report := {"passed": checks.values().all(func(value): return value == true), "checks": checks,
		"scope": "Synthetic actual facade producer, strict scalar and AABB aperture exclusion, deterministic repeated output, declaration bindings and invalid intervals."}
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  ", true, true)); file.flush()
	var saved := file.get_error() == OK; file.close(); quit(0 if saved and report.passed else 1)

func _build(offset: float):
	var b = Blueprint.new("partition_contract", 101)
	var openings: Array[Dictionary] = [{"centerY": offset + 5.3, "height": 1.46, "centerZ": offset + 1.8, "width": 1.16},
		{"centerY": offset + 8.35, "height": 1.46, "centerZ": offset - 1.8, "width": 1.16}]
	var result := Urban.add_partitioned_street_facade(b, "fixture", 10.16414, offset, 8.15, offset + 2.04, offset + 11.41, 0.3, "painted_brick_cream", 0.108, openings, "citadel_urban_facade")
	if not result.ready: print("PRODUCER REJECTED offset=", offset, " result=", result)
	return b
