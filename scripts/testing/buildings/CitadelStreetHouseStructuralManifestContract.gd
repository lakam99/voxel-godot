extends SceneTree

const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Composer = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Manifest = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")

func _initialize() -> void:
	for dependency in [Blueprint, Composer, Manifest]:
		if not dependency.can_instantiate():
			push_error("Street-house manifest dependency failed to compile")
			quit(2)
			return
	var path := OS.get_environment("VOXEL_STREET_HOUSE_MANIFEST_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var checks := {}
	var source = Blueprint.new("manifest_contract", 73, "citadel")
	Composer.add_street_house(source, "contract_house", Vector3.ZERO, 8.0, 9.0, 7.0, 1.0, 0.62, "painted_brick_cream", 0.03)
	var frozen_parts := var_to_bytes(source.parts.map(func(part): return part.snapshot()))
	var frozen_rooms := var_to_bytes(source.rooms)
	var first := Manifest.read(source)
	var repeat := Manifest.read(source)
	if not first.ready:
		_finish({"setup_ready": false}, first)
		return
	checks["read_ready_repeat_exact_immutable_geometry"] = first.ready and var_to_bytes(first) == var_to_bytes(repeat) \
		and frozen_parts == var_to_bytes(source.parts.map(func(part): return part.snapshot())) and frozen_rooms == var_to_bytes(source.rooms)
	checks["one_complete_producer_record"] = first.get("records", []).size() == 1 and first.records[0].producerPrefix == "contract_house" \
		and first.records[0].chimney.id == "contract_house_chimney" and first.records[0].chimney.gableIds.size() == 2 \
		and first.records[0].chimney.upstreamIds.size() == 3 and first.records[0].bracketIds.size() == 2 \
		and first.records[0].facadeDeclarationKeys == ["contract_house_upper_facade"]
	checks["threshold_foundation_ownership_declared"] = first.records[0].threshold == {
		"id": "contract_house_door_threshold", "foundationId": "contract_house_foundation"}
	var sign_exists := Manifest.find_part(source, "contract_house_sign_arm") != null
	checks["optional_sign_manifest_matches_recipe_output"] = sign_exists == not first.records[0].signAssembly.is_empty() \
		and (not sign_exists or first.records[0].signAssembly == {"armId": "contract_house_sign_arm", "boardId": "contract_house_hanging_sign"})
	var duplicate_before := var_to_bytes(source.snapshot())
	var duplicate := Manifest.declare(source, first.records[0])
	checks["duplicate_declaration_rejects_atomically"] = not duplicate.ready and duplicate.reason == "invalid_or_duplicate_manifest_collection" \
		and duplicate_before == var_to_bytes(source.snapshot())
	var malformed = Blueprint.new("malformed_manifest", source.seed, source.style)
	malformed.recipe = source.recipe.duplicate(true)
	malformed.rooms = source.rooms.duplicate(true)
	for part in source.parts:
		var copy = malformed.add_part(part.snapshot())
		copy.physical_intent = part.physical_intent
	malformed.recipe[Manifest.KEY]["contract_house"].chimney.gableIds = ["contract_house_upper_shell_side_-1", "foreign_gable"]
	var malformed_before := var_to_bytes(malformed.snapshot())
	var malformed_result := Manifest.read(malformed)
	checks["foreign_member_rejects_without_mutation"] = not malformed_result.ready and malformed_result.reason == "invalid_manifest_chimney_closure" \
		and malformed_before == var_to_bytes(malformed.snapshot())
	var uncovered = Blueprint.new("uncovered_manifest", source.seed, source.style)
	uncovered.recipe = source.recipe.duplicate(true)
	uncovered.rooms = source.rooms.duplicate(true)
	for part in source.parts:
		var copy = uncovered.add_part(part.snapshot())
		copy.physical_intent = part.physical_intent
	uncovered.add_part({"id": "uncovered_door", "kind": "door", "material": "painted_door", "position": Vector3(20, 1, 0), "size": Vector3(0.2, 2, 1), "collision": true, "semantic": "citadel_urban_door"})
	checks["uncovered_generated_door_fails_closed"] = Manifest.read(uncovered).get("reason") == "incomplete_manifest_coverage"
	var closure_controls := {
		"missing_threshold": func(record): record.erase("threshold"),
		"malformed_threshold": func(record): record.threshold = [],
		"foreign_threshold": func(record): record.threshold.id = "foreign_door_threshold",
		"foreign_threshold_foundation": func(record): record.threshold.foundationId = "foreign_foundation",
		"omitted_bracket": func(record): record.bracketIds = [record.bracketIds[0]],
		"substituted_bracket": func(record): record.bracketIds[1] = "contract_house_door_lintel",
		"substituted_gable": func(record): record.chimney.gableIds[1] = "contract_house_stone_shell_side_1",
		"omitted_foundation": func(record): record.chimney.upstreamIds = record.chimney.upstreamIds.slice(1),
		"substituted_negative_shell": func(record): record.chimney.upstreamIds[1] = "contract_house_upper_shell_side_-1",
		"substituted_positive_shell": func(record): record.chimney.upstreamIds[2] = "contract_house_upper_shell_side_1"
	}
	var closure_rejections := true
	for label: String in closure_controls:
		var tampered = _copy_source(source)
		closure_controls[label].call(tampered.recipe[Manifest.KEY]["contract_house"])
		var before := var_to_bytes(tampered.snapshot())
		var result := Manifest.read(tampered)
		closure_rejections = closure_rejections and not result.ready and before == var_to_bytes(tampered.snapshot())
	checks["omitted_and_substituted_closure_roles_reject_atomically"] = closure_rejections
	var door_room = _copy_source(source)
	Manifest.find_part(door_room, "contract_house_door").recipe.roomId = "foreign_interior"
	var door_room_before := var_to_bytes(door_room.snapshot())
	checks["door_room_ownership_rejects_atomically"] = Manifest.read(door_room).get("reason") == "invalid_manifest_door_room" \
		and door_room_before == var_to_bytes(door_room.snapshot())
	for mutation: String in ["duplicate_threshold", "threshold_semantic", "foundation_kind"]:
		var altered = _copy_source(source)
		if mutation == "duplicate_threshold":
			altered.add_part(Manifest.find_part(altered, "contract_house_door_threshold").snapshot())
		elif mutation == "threshold_semantic":
			Manifest.find_part(altered, "contract_house_door_threshold").semantic = "unrelated_finish"
		else:
			Manifest.find_part(altered, "contract_house_foundation").kind = "beam"
		var altered_before := var_to_bytes(altered.snapshot())
		checks[mutation + "_rejects_atomically"] = not Manifest.read(altered).get("ready", true) \
			and altered_before == var_to_bytes(altered.snapshot())
	var stale_aperture = _copy_source(source)
	stale_aperture.recipe.facadeApertures.contract_house_upper_facade.sourceBinding = "0".repeat(64)
	var stale_before := var_to_bytes(stale_aperture.snapshot())
	var stale_result := Manifest.read(stale_aperture)
	checks["stale_facade_source_binding_rejects_atomically"] = not stale_result.ready and stale_result.reason == "stale_manifest_facade_declaration" \
		and stale_before == var_to_bytes(stale_aperture.snapshot())
	var tampered_sign_anchors = _copy_source(source)
	tampered_sign_anchors.recipe[Manifest.KEY]["contract_house"].signAnchorIds = ["contract_house_door_lintel"]
	var tampered_sign_before := var_to_bytes(tampered_sign_anchors.snapshot())
	var tampered_sign_result := Manifest.read(tampered_sign_anchors)
	checks["tampered_sign_anchor_membership_rejects_atomically"] = not tampered_sign_result.ready \
		and tampered_sign_result.reason == "invalid_manifest_sign_anchors" \
		and tampered_sign_before == var_to_bytes(tampered_sign_anchors.snapshot())
	var preexisting = Blueprint.new("preexisting_manifest", 91, "citadel")
	preexisting.recipe[Manifest.KEY] = {"stale_house": first.records[0].duplicate(true)}
	var reset := Composer.reset_street_house_structural_manifest(preexisting)
	checks["composition_boundary_discards_preexisting_manifest"] = reset.ready and preexisting.recipe[Manifest.KEY].is_empty()
	var passed: bool = checks.values().all(func(value): return value == true)
	var report := {"passed": passed, "checks": checks,
		"scope": "Producer-authored structural manifest only; no completion, publication, rendering or gameplay claim."}
	var output := FileAccess.open(OS.get_environment("VOXEL_STREET_HOUSE_MANIFEST_REPORT"), FileAccess.WRITE)
	if output != null: output.store_string(JSON.stringify(report, "\t")); output.close()
	quit(0 if passed else 1)

func _finish(checks: Dictionary, detail: Dictionary) -> void:
	var report := {"passed": false, "checks": checks, "detail": detail,
		"scope": "Producer-authored structural manifest only; no completion, publication, rendering or gameplay claim."}
	var output := FileAccess.open(OS.get_environment("VOXEL_STREET_HOUSE_MANIFEST_REPORT"), FileAccess.WRITE)
	if output != null: output.store_string(JSON.stringify(report, "\t")); output.close()
	quit(1)

func _copy_source(source):
	var copy = Blueprint.new(source.id, source.seed, source.style)
	copy.recipe = source.recipe.duplicate(true)
	copy.rooms = source.rooms.duplicate(true)
	for part in source.parts:
		var added = copy.add_part(part.snapshot())
		added.physical_intent = part.physical_intent
	return copy
