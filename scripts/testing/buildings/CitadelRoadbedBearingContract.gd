extends SceneTree

## Source/service contracts, never visual or live navigation acceptance.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Routes = preload("res://scripts/testing/buildings/CitadelRoadbedRoutePreservationCases.gd")
var checks: Array = []
var cases: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# Godot can enter the main script even when a preloaded helper failed to
	# compile. Exit explicitly instead of leaving a failed coroutine alive.
	for dependency in [Blueprint, Castle, Copy, Routes]:
		if not dependency.can_instantiate():
			push_error("Roadbed contract dependency failed to compile")
			quit(2)
			return
	var path := OS.get_environment("VOXEL_ROADBED_BEARING_REPORT")
	var selected_seed := int(OS.get_environment("VOXEL_ROADBED_BEARING_SEED"))
	if selected_seed not in [208159, 237207443]:
		quit(2)
		return
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	for mode in ["thin", "gap", "partition"]:
		_positive(mode)
	for mutation in ["missing", "disabled", "disabled_mass", "displaced", "ungrounded", "uncovered"]:
		_negative(mutation)
	print("Roadbed synthetic physical cases completed; checks=", checks.size())
	var route_evidence: Dictionary = Routes.run_cases(selected_seed)
	checks.append_array(route_evidence.get("checks", []))
	_check("route_cases_passed", bool(route_evidence.get("passed", false)))
	for seed_case in route_evidence.get("evidence", []):
		_check("seed_%s_route_replays_actually_performed" % seed_case.get("seed", 0), bool(seed_case.get("replays", {}).get("performed", false)))
	var passed := not checks.is_empty() and checks.all(func(row): return bool(row.passed))
	var report := {"passed": passed, "seed": selected_seed, "checks": checks, "physicalCases": cases, "routeEvidence": route_evidence,
		"scope": "Actual recipe-producer and source/service physical/route contracts. No rendered, collision-backed gameplay, or overall Citadel gate acceptance."}
	var bytes := JSON.stringify(report, "\t").to_utf8_buffer()
	if bytes.size() > 1048576:
		quit(2)
		return
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_buffer(bytes)
	output.flush()
	var error := output.get_error()
	output.close()
	if error != OK or FileAccess.get_file_as_bytes(path) != bytes:
		quit(2)
		return
	print("Roadbed bearing source contracts: ", passed, " checks=", checks.size())
	quit(0 if passed else 1)

func _fixture(mode: String):
	var b = Blueprint.new("synthetic_roadbed_bearings", 53, "stone")
	_root(b, "left", Vector3(-1.85, 0.5, 0.0), Vector3(2.3, 1.0, 4.0))
	if mode != "gap": _root(b, "thin", Vector3(-0.6, 0.5, 0.0), Vector3(0.2, 1.0, 4.0))
	_root(b, "right", Vector3(1.75 if mode == "gap" else 1.25, 0.5, 0.0), Vector3(2.5 if mode == "gap" else 3.5, 1.0, 4.0))
	if mode == "partition":
		b.add_part({"id": "existing_step", "kind": "foundation", "position": Vector3(0.0, 1.5, 0.0),
			"size": Vector3(0.8, 1.0, 4.0), "semantic": "castle_processional_step", "collision": true})
	Castle.add_elevated_street_roadbed(b, "synthetic_street", Vector3.ZERO, 4.0, 2.0, 1.0, 0.8, 0.0)
	return b

func _root(b, id: String, position: Vector3, size: Vector3) -> void:
	b.add_part({"id": id, "kind": "foundation", "material": "stone_foundation", "position": position,
		"size": size, "collision": true, "semantic": "castle_courtyard_foundation",
		"recipe": {"physicalIntent": "structural_root", "physicalRoot": true}})

func _positive(mode: String) -> void:
	var b = _fixture(mode)
	var source: Dictionary = b.snapshot()
	var repeated = _fixture(mode)
	_check(mode + "_producer_repeat_exact", var_to_bytes(source) == var_to_bytes(repeated.snapshot()))
	var old = Copy.copy_blueprint(source)
	for part in _roadbeds(old):
		part.recipe.erase("physicalRequiredSeatPartIds")
		part.recipe.erase("physicalAssemblyRole")
	var stripped := source.duplicate(true)
	for record in stripped.parts:
		if record.semantic == "castle_route_terrace_walkway":
			record.recipe.erase("physicalRequiredSeatPartIds")
			record.recipe.erase("physicalAssemblyRole")
	_check(mode + "_only_two_new_recipe_fields", var_to_bytes(stripped) == var_to_bytes(old.snapshot()))
	var count := 0
	for part in _roadbeds(b):
		count += 1
		_check(mode + "_seat_list_exact_" + part.id, part.recipe.physicalRequiredSeatPartIds == part.recipe.physicalRequiredSupportPartIds)
		_check(mode + "_full_coverage_role_" + part.id, part.recipe.physicalAssemblyRole == "walkable_subfloor")
	_check(mode + "_expected_roadbed_count", count == (2 if mode == "partition" else 1))
	if mode == "gap":
		_check("gap_actual_producer_adds_retaining_root", b.parts.any(func(part): return part.id.contains("retaining_foundation")))
	var fresh := _validate(b)
	var repeated_report: Dictionary = b.validate_physical_integrity()
	_check(mode + "_repeat_decisions_exact", var_to_bytes(_decisions(fresh)) == var_to_bytes(_decisions(repeated_report)))
	var cleared := _validate(b)
	_check(mode + "_cleared_decisions_exact", var_to_bytes(_decisions(fresh)) == var_to_bytes(_decisions(cleared)))
	var rows := _roadbed_rows(fresh)
	for row: Dictionary in rows:
		_check(mode + "_passes_" + row.partId, bool(row.passed))
		_check(mode + "_25_rooted_samples_" + row.partId, row.supportCoverage.size() == 25 and bool(row.hasRootedCoverage) and row.supportCoverage.all(func(sample): return bool(sample.supported)))
		_check(mode + "_all_named_seats_" + row.partId, bool(row.hasRootedSeats) and bool(row.reachesGroundRoot))
	var old_rows := _roadbed_rows(_validate(old))
	if mode == "thin":
		_check("thin_old_schema_reproduces_sample_id_failure", old_rows.size() == 1 and not old_rows[0].passed and old_rows[0].reachesGroundRoot and not old_rows[0].supportPartIds.has("thin"))
		_check("thin_new_contract_keeps_unsampled_bearing_mandatory", rows.size() == 1 and rows[0].requiredSeatPartIds.has("thin") and rows[0].requiredSupportPartIds.has("thin") and not rows[0].supportPartIds.has("thin"))
	cases.append({"case": mode, "scope": "Synthetic geometry through actual producer; old schema is a two-field counterfactual, not a historical artifact.",
		"rows": rows, "oldSchemaRows": old_rows})

func _negative(mutation: String) -> void:
	var b = _fixture("thin")
	var roadbed = _roadbeds(b)[0]
	var thin = b.parts.filter(func(part): return part.id == "thin")[0]
	match mutation:
		"missing": b.parts.erase(thin)
		"disabled": thin.collision_enabled = false
		"disabled_mass":
			thin.collision_enabled = false
			thin.physical_intent = "structural_mass"
			thin.recipe.physicalIntent = "structural_mass"
		"displaced": thin.position.x += 20.0
		"ungrounded":
			# Keep the top contact exactly at y=1, but remove its connection to ground.
			# Narrow it away from adjacent foundations beyond the contact tolerance,
			# otherwise the edge samples legitimately find embedded lateral supports.
			thin.size.x = 0.04
			thin.size.y = 0.6
			thin.position.y = 0.7
		"uncovered":
			var right = b.parts.filter(func(part): return part.id == "right")[0]
			right.size.z = 0.8
	var report := _validate(b)
	var row: Dictionary = _roadbed_rows(report)[0]
	_check(mutation + "_roadbed_rejected", not bool(row.passed))
	_check(mutation + "_all_requirements_retained", roadbed.recipe.physicalRequiredSupportPartIds == ["left", "thin", "right"] and roadbed.recipe.physicalRequiredSeatPartIds == ["left", "thin", "right"])
	if mutation == "uncovered":
		_check("uncovered_all_seats_still_contact", bool(row.hasRootedSeats) and bool(row.reachesGroundRoot))
		_check("uncovered_sample_independently_rejected", not bool(row.hasRootedCoverage) and row.supportCoverage.any(func(sample): return not bool(sample.supported)))
	else:
		_check(mutation + "_other_bearings_cover_all_samples", bool(row.hasRootedCoverage) and row.supportCoverage.size() == 25 and row.supportCoverage.all(func(sample): return bool(sample.supported)))
		if mutation == "disabled_mass":
			# A disabled member may retain a geometric support chain; its own failed
			# collision contract must still invalidate the mandatory dependent.
			var bearer_row: Dictionary = report.checks.filter(func(check): return check.partId == "thin")[0]
			_check("disabled_mass_retains_real_rooted_chain", b.has_rooted_support_chain(thin, {}) and bool(bearer_row.reachesGroundRoot) and bool(row.hasRootedSeats))
			_check("disabled_mass_collision_contract_fails", not bool(bearer_row.passed) and not bool(bearer_row.collisionEnabled))
			_check("disabled_mass_mandatory_dependency_rejected", row.get("hasValidRequiredDependencies", true) == false)
		else:
			_check(mutation + "_named_bearing_rejected", not bool(row.hasRootedSeats))
		if mutation == "ungrounded":
			_check("ungrounded_top_contact_preserved", is_equal_approx(thin.position.y + thin.size.y * 0.5, roadbed.position.y - roadbed.size.y * 0.5) and not b.is_grounded_structural_root(thin) and not bool(thin.recipe.get("physicalRoot", false)))
	cases.append({"case": mutation, "row": row, "violations": report.violations})

func _validate(b) -> Dictionary:
	Copy.clear_caches(b)
	return b.validate_physical_integrity()

func _decisions(report: Dictionary) -> Dictionary:
	var copy := report.duplicate(true)
	# First inference records taxonomy; later resolution records the now-explicit
	# recipe. Compare every physical fact, excluding only that expected provenance.
	for row in copy.checks: row.erase("classification")
	return copy

func _roadbeds(b) -> Array:
	return b.parts.filter(func(part): return part.semantic == "castle_route_terrace_walkway")

func _roadbed_rows(report: Dictionary) -> Array:
	return report.checks.filter(func(row): return String(row.partId).begins_with("castle_district_synthetic_street_roadbed_"))

func _check(id: String, passed: bool) -> void:
	checks.append({"id": id, "passed": passed})
	if not passed: push_error("Roadbed bearing contract failed: " + id)
