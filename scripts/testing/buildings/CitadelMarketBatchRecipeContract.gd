extends "res://scripts/testing/buildings/CitadelMarketPlacementProbe.gd"

const Batch = preload("res://scripts/buildings/HouseholdLayoutBatchRecipe.gd")
const Terminal = preload("res://scripts/buildings/TerminalShopFrameBuilder.gd")

func _extra_checks(report: Dictionary, b, _boxes: Dictionary, groups: Array, _claimed: Dictionary) -> void:
	var copy = Blueprint.new(b.id, b.seed, b.style)
	copy.recipe = b.recipe.duplicate(true)
	copy.rooms = b.rooms.duplicate(true)
	for part in b.parts:
		copy.add_part(part.snapshot())
	var frames: Array = []
	for index in range(3):
		frames.append(Terminal.add_frame(copy, "urban_terminal_%02d" % index, "urban_market_plaza_retaining"))
	if not frames.all(func(row): return row.get("ready", false)):
		report["batch"] = {"ready": false, "frames": frames}
		return
	var households: Array = []
	for group in groups:
		if group.has("layoutSpec"):
			households.append({"memberIds": group.allIds, "front": Vector3(0, 0, -float(group.layoutSpec.depth))})
	var before := var_to_bytes(copy.snapshot())
	var result := Batch.plan(copy, households, Urban.plan_courtyard_household)
	var exact := before == var_to_bytes(copy.snapshot())
	report["batch"] = _serialize(result)
	report["batchInputExact"] = exact
	report["extraChecksCompleted"] = exact and bool(result.get("ready", false))

func _serialize(value: Variant) -> Variant:
	if value is Transform3D:
		return {"origin": value.origin, "basis": [value.basis.x, value.basis.y, value.basis.z]}
	if value is Dictionary:
		var output: Dictionary = {}
		for key in value:
			output[key] = _serialize(value[key])
		return output
	if value is Array:
		return value.map(func(item): return _serialize(item))
	return value
