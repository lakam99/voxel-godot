extends "res://scripts/testing/buildings/CitadelMarketRigidTransformContract.gd"

## Reuse unchanged actual-publisher comparison, but all producer households and
## the current batch recipe. No diagnostic pose input and no geometry acceptance.
const Preparation = preload("res://scripts/testing/buildings/CitadelMarketRecipeVisual.gd")

func _run() -> void:
	_rigid_path = OS.get_environment("VOXEL_MARKET_RIGID_REPORT")
	var report := {"passed": false, "evidenceLevel": "frozen_source_and_actual_cpu_publisher_preservation_contract",
		"doesNotProve": "No GPU image, intersections, support, pedestrian access, physics or gameplay. Position-dependent custom data remains a strict mismatch; no exception is applied."}
	if not _rigid_path.is_absolute_path() or FileAccess.file_exists(_rigid_path):
		_rigid_path = ""
		_rigid_finish(report, "require_fresh_report")
		return
	var baseline := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE")
	var prepared: Dictionary = Preparation._prepare_frozen_recipe(baseline)
	if not prepared.get("ready", false):
		report["preparation"] = prepared
		_rigid_finish(report, "preparation_failed")
		return
	var file := FileAccess.open(baseline, FileAccess.READ)
	var envelope = file.get_var(false)
	file.close()
	var frozen: Dictionary = envelope.output
	var source: Dictionary = frozen.sourceSnapshot
	var before = Blueprint.new(source.id, source.seed, source.style)
	before.recipe = source.recipe.duplicate(true)
	before.rooms = source.rooms.duplicate(true)
	for record in source.parts:
		var part = before.add_part(record)
		before.physical_parts_by_id[part.id] = part
	# Include the exact same terminal recipe on both sides. This contract isolates
	# only the batch rigid movement, not terminal joinery acceptance.
	var terminals: Dictionary = Preparation._prepare_terminal_frames(before, float(int(source.seed) % 19) / 100.0 - 0.09)
	if not terminals.get("ready", false):
		_rigid_finish(report, "terminal_precondition_failed")
		return
	for part in before.parts:
		before.physical_parts_by_id[part.id] = part
	var after = prepared.blueprint
	var before_digest := _stable_digest(before.snapshot())
	var after_digest := _stable_digest(after.snapshot())
	var transforms: Dictionary = {}
	var relative: Array = []
	for plan in prepared.plans:
		for id in plan.memberIds:
			transforms[id] = plan.transform
		relative.append(_relative_geometry(before, after, plan.memberIds, plan.transform))
	var source_rows: Array = []
	var unexpected: Array = []
	for part in after.parts:
		var old = before.find_part(part.id)
		if old == null:
			unexpected.append(part.id)
			continue
		if not transforms.has(part.id):
			if _stable_digest(old.snapshot()) != _stable_digest(part.snapshot()):
				unexpected.append(part.id)
			continue
		var expected: Transform3D = transforms[part.id] * before.part_transform(old)
		var actual: Transform3D = after.part_transform(part)
		var old_fields: Dictionary = old.snapshot()
		var new_fields: Dictionary = part.snapshot()
		for key in ["position", "rotation"]:
			old_fields.erase(key)
			new_fields.erase(key)
		source_rows.append({"partId": part.id, "positionExact": actual.origin == expected.origin,
			"basisError": _basis_error(actual.basis, expected.basis), "nonTransformFieldsExact": _stable_digest(old_fields) == _stable_digest(new_fields)})
	var before_publisher = _configured_publisher(before)
	var after_publisher = _configured_publisher(after)
	var payload: Array = []
	for id in transforms:
		payload.append(_compare_payload(id, _complete_payload(before_publisher, before, before.find_part(id)),
			_complete_payload(after_publisher, after, after.find_part(id)), transforms[id]))
	var old_furniture = FurniturePlanner.build(_copy_blueprint(before), int(frozen.fixture.furnitureSeed))
	var new_furniture = FurniturePlanner.build(_copy_blueprint(after), int(frozen.fixture.furnitureSeed))
	var furniture := _furniture_parity(old_furniture, new_furniture)
	var checks := {"allProducerMembersCovered": source_rows.size() == prepared.memberIds.size() and transforms.size() == prepared.memberIds.size(),
		"sourceTransformsAndOtherFieldsPreserved": source_rows.all(func(row): return row.positionExact and row.basisError <= SOURCE_BASIS_EPS and row.nonTransformFieldsExact),
		"withinHouseholdRelativeGeometryPreserved": relative.all(func(row): return row.passed), "unmovedSourceExact": unexpected.is_empty(),
		"sourceOrderExact": before.parts.map(func(part): return part.id) == after.parts.map(func(part): return part.id),
		"blueprintHeaderExact": _stable_digest(_header(before)) == _stable_digest(_header(after)),
		"publisherGeometryPreserved": payload.all(func(row): return row.geometryPreserved),
		"publisherMaterialCountsPreserved": payload.all(func(row): return row.materialCountsPreserved),
		"publisherCustomDataExact": payload.all(func(row): return row.customDataExact),
		"furnitureUnchanged": furniture.bothReady and int(furniture.beforePartCount) > 0 and furniture.snapshotsEqual and furniture.reservationsEqual,
		"servicesDidNotMutateSource": before_digest == _stable_digest(before.snapshot()) and after_digest == _stable_digest(after.snapshot()),
		"frozenInputUnchanged": FileAccess.get_sha256(baseline) == MARKET_FROZEN_SHA}
	report.merge({"checks": checks, "sourceMembers": source_rows, "publisherMembers": payload, "relativeGeometry": relative,
		"unexpectedOtherSourceIds": unexpected, "furniture": furniture, "plans": prepared.plans, "passed": checks.values().all(func(value): return bool(value))}, true)
	_rigid_finish(report, "contract_complete")
