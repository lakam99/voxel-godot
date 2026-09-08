extends "res://scripts/testing/buildings/CitadelBuntingStageCapture.gd"
const Anchor = preload("res://scripts/buildings/CitadelBuntingAnchorRecipe.gd")
func _input_path() -> String: return "res://artifacts/citadel-runtime-integration/candidate22-bunting-stage-01/input.bin"
func _input_sha() -> String: return "58885c0e75414db4c4c3e16c764c6b7a522e1c9bd46618dd171101bccc8f9bbd"
func _work() -> Dictionary:
	state.begin_phase("bunting_replay", 90000)
	var checks := {"pinned": FileAccess.get_sha256(_input_path()) == _input_sha()}
	var report := {"passed": false, "checks": checks, "scope": "Exact whole-selection offline bunting failure replay and raw geometry inventory. No successful placement, rendering or gameplay acceptance."}
	if not checks.pinned: return report
	var file := FileAccess.open(_input_path(), FileAccess.READ)
	if file == null: return report
	var input: Dictionary = file.get_var(false); file.close()
	var source = Heads.Copy.copy_blueprint(input.blueprint)
	var frozen := var_to_bytes(source.snapshot()); var policy := var_to_bytes([input.assemblies, input.protected])
	var result := Anchor.prepare(source, input.assemblies, input.protected, state.checkpoint)
	checks.exact_failure = not result.get("ready", true) and result.get("reason") == "no_rooted_bunting_endpoint_pair" and result.get("detail", {}).get("ropeId") == "urban_bunting_rope_02"
	report["result"] = result
	var parts: Array = []
	for part in source.parts:
		if not state.checkpoint("bunting_inventory"): return report
		var bounds: AABB = source.transformed_part_bounds(part)
		parts.append({"id": part.id, "kind": part.kind, "semantic": part.semantic, "collision": part.collision_enabled,
			"position": _xyz(part.position), "size": _xyz(part.size), "rotation": _xyz(part.rotation),
			"minimum": _xyz(bounds.position), "maximum": _xyz(bounds.end), "recipe": part.recipe})
	var rooms: Array = []
	for room: Dictionary in source.rooms:
		if room.get("bounds") is AABB: rooms.append({"id": room.get("id", ""), "minimum": _xyz(room.bounds.position), "maximum": _xyz(room.bounds.end)})
	var protected: Array = []
	for volume in input.protected:
		var bounds: AABB = volume.get("bounds") if volume is Dictionary else volume
		protected.append({"minimum": _xyz(bounds.position), "maximum": _xyz(bounds.end)})
	var inventory := {"inputSha256": _input_sha(), "parts": parts, "rooms": rooms, "protected": protected, "recipe": source.recipe}
	var output := OS.get_environment("CITADEL_ORDERED_OPENING_REPORT").get_base_dir().path_join("geometry.json")
	var encoded := JSON.stringify(inventory)
	if not state.checkpoint("bunting_inventory_encoded"): return report
	file = FileAccess.open(output, FileAccess.WRITE)
	if file == null: return report
	file.store_string(encoded); file.flush(); checks.inventory_written = file.get_error() == OK; file.close()
	checks.source_immutable = frozen == var_to_bytes(source.snapshot()) and policy == var_to_bytes([input.assemblies, input.protected]) and FileAccess.get_sha256(_input_path()) == _input_sha()
	checks.deadline = state.checkpoint("bunting_replay_completed")
	report.passed = checks.values().all(func(value): return value == true)
	return report
func _xyz(value: Vector3) -> Array: return [value.x, value.y, value.z]
