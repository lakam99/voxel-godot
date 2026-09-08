extends "res://scripts/testing/buildings/CitadelBuntingStageDiagnostic.gd"
## Hybrid offline contract. Only exact geometry-matching current producer
## receipts are transferred into the pinned late structural source.
const Domain = preload("res://scripts/buildings/CitadelExteriorBuntingDomain.gd")
const Structural = preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const CURRENT := "res://artifacts/citadel-runtime-integration/exterior-bunting-producer-capture-02/input.bin"
const CURRENT_SHA := "c9054b1aac1bbd08f77a41fd6f70480650dc7a82f2d73aa083eeffc483192e83"
const OLD := "res://artifacts/citadel-runtime-integration/candidate21-policy-capture-01/input.bin"
const OLD_SHA := "d6df2eeff4044d85d41cd46e1dc9b200740a01b3abd36455b6536ceb3514a903"
func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var result: Dictionary = file.get_var(false); file.close(); return result
func _work() -> Dictionary:
	state.begin_phase("exterior_bunting_integration", 90000)
	var paths := {_input_path(): _input_sha(), CURRENT: CURRENT_SHA, OLD: OLD_SHA}
	var checks := {"pinned": paths.keys().all(func(p): return FileAccess.get_sha256(p) == paths[p])}
	var report := {"passed": false, "checks": checks, "scope": "Hybrid offline production bunting integration on frozen late geometry with exact matching current producer metadata. No current whole-candidate, publication, rendering or gameplay acceptance."}
	if not checks.pinned: return report
	var input := _read(_input_path()); var current := _read(CURRENT); var old := _read(OLD)
	if input.is_empty() or current.is_empty() or old.is_empty(): return report
	var stripped: Dictionary = current.duplicate(true)
	var expected_fields := {"castle_keep_forecourt_pavilion_-1": [Domain.MOUNT], "castle_keep_forecourt_pavilion_1": [Domain.MOUNT],
		"urban_civic_tower": [Domain.MOUNT], "urban_bunting_rope_02": [Domain.OWNERS]}
	var found_fields := {}; var markers: Array = []
	for record: Dictionary in stripped.blueprint.parts:
		var fields: Array = []
		for key: String in [Domain.MOUNT, Domain.OWNERS]:
			if record.recipe.has(key): fields.append(key)
		if not fields.is_empty(): found_fields[record.id] = fields
		record.recipe.erase(Domain.MOUNT); record.recipe.erase(Domain.OWNERS)
	for assembly: Dictionary in stripped.blueprint.recipe.citadelBuntingAssemblies:
		if assembly.has("mounting"):
			markers.append({"ropeId": assembly.ropeId, "mounting": assembly.mounting})
		assembly.erase("mounting")
	checks.exact_producer_metadata_set = found_fields == expected_fields and markers == [{"ropeId": "urban_bunting_rope_02", "mounting": "exterior"}]
	if not checks.exact_producer_metadata_set: return report
	checks.only_declared_metadata_changed_in_production = var_to_bytes(stripped.blueprint) == var_to_bytes(old.blueprint) and var_to_bytes(current.policy) == var_to_bytes(old.policy)
	if not checks.only_declared_metadata_changed_in_production: return report
	var source = Heads.Copy.copy_blueprint(input.blueprint)
	var transferred: Array = []
	for record: Dictionary in current.blueprint.parts:
		if not record.recipe.has(Domain.MOUNT) and not record.recipe.has(Domain.OWNERS): continue
		var part = source.find_part(record.id)
		if part == null: return report
		for key: String in ["id", "kind", "semantic", "position", "size", "rotation", "collision"]:
			if part.snapshot()[key] != record[key]: return report
		for key: String in [Domain.MOUNT, Domain.OWNERS]:
			if record.recipe.has(key):
				part.recipe[key] = record.recipe[key].duplicate(true)
				transferred.append({"partId": part.id, "field": key})
	for assembly: Dictionary in current.blueprint.recipe.citadelBuntingAssemblies:
		if not assembly.has("mounting"): continue
		var matches := 0
		for target: Dictionary in source.recipe.citadelBuntingAssemblies:
			if target.ropeId != assembly.ropeId: continue
			if target.pennantIds != assembly.pennantIds: return report
			target["mounting"] = assembly.mounting; matches += 1
		if matches != 1: return report
	checks.transferred_exact_owner_fields = transferred.size() == 4
	report["transferredMetadata"] = transferred
	var before := var_to_bytes(source.snapshot()); var protected_before := var_to_bytes(input.protected)
	var result := Structural._complete_bunting(source, input.protected, state.checkpoint)
	checks.completion_ready = result.get("ready", false)
	checks.input_immutable = before == var_to_bytes(source.snapshot()) and protected_before == var_to_bytes(input.protected)
	if not checks.completion_ready:
		report["failure"] = result; return report
	var completed = Heads.Copy.copy_blueprint(result.afterSnapshot)
	var selected := {}
	for assembly: Dictionary in result.assemblies:
		selected[assembly.ropeId] = true
		for id: String in assembly.pennantIds: selected[id] = true
	checks.nonselected_records_unchanged = true
	for part in source.parts:
		if not selected.has(part.id): checks.nonselected_records_unchanged = checks.nonselected_records_unchanged and var_to_bytes(part.snapshot()) == var_to_bytes(completed.find_part(part.id).snapshot())
	checks.protected_volumes_retained = input.protected.all(func(v): return result.protectedBounds.has(v))
	var physical: Dictionary = completed.validate_physical_integrity_cancellable(state.checkpoint)
	var passed := {}
	for row: Dictionary in physical.get("checks", []):
		if row.get("passed", false): passed[row.partId] = true
	checks.selected_members_physically_pass = not physical.get("cancelled", false) and selected.size() == 14 and selected.keys().all(func(id): return passed.has(id))
	checks.stored_clearance_pass = Structural._verify_final_bunting(completed, result, state.checkpoint).get("ready", false)
	var ready_source = Heads.Copy.copy_blueprint(result.afterSnapshot)
	var ready_before := var_to_bytes(ready_source.snapshot())
	var repeated := Structural._complete_bunting(ready_source, input.protected, state.checkpoint)
	checks.passing_geometry_preserved = repeated.get("ready", false) and var_to_bytes(repeated.get("afterSnapshot", {})) == ready_before
	checks.repeat_caller_immutable = ready_before == var_to_bytes(ready_source.snapshot())
	ready_source.find_part("urban_bunting_rope_02").recipe.erase(Domain.OWNERS)
	checks.missing_owners_on_passing_assembly_reject = Structural._bunting_manifest(ready_source).get("reason") == "missing_or_undeclared_exterior_bunting_owners"
	checks.source_files_immutable = paths.keys().all(func(p): return FileAccess.get_sha256(p) == paths[p])
	checks.deadline = state.checkpoint("exterior_bunting_integration_completed")
	report["details"] = result.details
	report.passed = checks.values().all(func(value): return value == true)
	return report
