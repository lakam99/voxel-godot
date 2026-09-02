extends SceneTree

## Synthetic collection contract; not visual or live gameplay acceptance.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")

func _initialize() -> void:
	call_deferred("_run")

func _house():
	var b = Blueprint.new("collection_contract", 208159, "timber")
	Urban.add_street_house(b, "house", Vector3.ZERO, 8.65, 9.45, 6.2, 1.0, 0.62, "plaster_cream", 0.05)
	return b

func _run() -> void:
	var rows: Array = []
	var b = _house()
	var before_count: int = b.parts.size()
	var assembled: Dictionary = Urban.add_roof_frames(b)
	rows.append({"id": "one_complete_house", "passed": bool(assembled.get("ready", false)) and b.parts.size() == before_count + 12, "result": assembled})
	var first_snapshot: Dictionary = b.snapshot()
	var second: Dictionary = Urban.add_roof_frames(b)
	rows.append({"id": "duplicate_install_rejected_without_mutation", "passed": not bool(second.get("ready", false)) and b.snapshot() == first_snapshot, "result": second})
	for missing in ["house_roof_left", "house_roof_right", "house_upper_shell_side_-1"]:
		b = _house()
		b.parts = b.parts.filter(func(part): return part.id != missing)
		var snapshot: Dictionary = b.snapshot()
		var outcome: Dictionary = Urban.add_roof_frames(b)
		rows.append({"id": "missing_" + missing, "passed": not bool(outcome.get("ready", false)) and not String(outcome.get("reason", "")).is_empty() and b.snapshot() == snapshot, "result": outcome})
	b = _house()
	for part in b.parts:
		if part.id == "house_roof_left":
			b.add_part(part.snapshot())
			break
	var duplicate_snapshot: Dictionary = b.snapshot()
	var duplicate: Dictionary = Urban.add_roof_frames(b)
	rows.append({"id": "duplicate_roof_id_rejected", "passed": not bool(duplicate.get("ready", false)) and b.snapshot() == duplicate_snapshot, "result": duplicate})
	b = _house()
	for part in b.parts:
		if part.id == "house_roof_right":
			part.id = "house_unrecognized_roof_side"
	var unrecognized_snapshot: Dictionary = b.snapshot()
	var unrecognized: Dictionary = Urban.add_roof_frames(b)
	rows.append({"id": "unrecognized_roof_pair_rejected", "passed": not bool(unrecognized.get("ready", false)) and b.snapshot() == unrecognized_snapshot, "result": unrecognized})
	var empty: Dictionary = Urban.add_roof_frames(Blueprint.new())
	rows.append({"id": "missing_roof_collection_rejected", "passed": not bool(empty.get("ready", false)), "result": empty})
	var report := {"evidenceLevel": "synthetic_collection_contract", "passed": rows.all(func(row): return bool(row.passed)), "checks": rows,
		"doesNotProve": "No rendered image, contact precision, engineering safety, NPC/gameplay behavior or arbitrary seed acceptance."}
	var path := OS.get_environment("VOXEL_ROOF_COMPOSITION_REPORT")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	print("Roof composition synthetic contract: ", report.passed, " cases=", rows.size())
	quit(0 if report.passed else 1)
