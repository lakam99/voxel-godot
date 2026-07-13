extends SceneTree

const TutorialSystemScript := preload("res://scripts/TutorialSystem.gd")
const TutorialSceneBuilderScript := preload("res://scripts/TutorialSceneBuilder.gd")
const TownRuntimeManifestScript := preload("res://scripts/world/TownRuntimeManifest.gd")
const NpcSystemScript := preload("res://scripts/NpcSystem.gd")

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_TUTORIAL_ACTOR_REGISTRATION_CONTRACT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/tutorial-town/tutorial-actor-registration-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var tutorial = TutorialSystemScript.new()
	var builder = TutorialSceneBuilderScript.new()
	var scenarios: Array = tutorial.tutorial_actor_scenarios()
	var manifest := fixture_manifest()
	test_scenario_contract(tutorial, scenarios)
	test_manifest_resolution(builder, scenarios, manifest)
	test_missing_home_fails_before_spawn(builder, scenarios, manifest)
	test_shared_homes_are_declared(scenarios)
	await test_generated_town_spawn_still_uses_generic_registration(manifest)
	await test_tutorial_identity_has_ordinary_simulation(builder, scenarios, manifest)
	test_source_audit()
	tutorial.free()
	finish()

func test_scenario_contract(tutorial, scenarios: Array) -> void:
	var requirements: Dictionary = tutorial.tutorial_scenario_requirements()
	var assignments: Dictionary = requirements.get("actorHomeAssignments", {})
	var presentation_split := true
	var simulation_split := true
	for scenario_value in scenarios:
		var scenario: Dictionary = scenario_value if scenario_value is Dictionary else {}
		presentation_split = presentation_split and scenario.get("presentation") is Dictionary
		simulation_split = simulation_split and scenario.get("simulation") is Dictionary
	add_result(
		"tutorial_actor_scenario_separates_identity_simulation_and_home_assignment",
		scenarios.size() == 6 \
			and bool(requirements.get("ok", false)) \
			and requirements.get("requiredHomeKeys", []) == [0, 1, 2, 3] \
			and assignments.size() == 7 \
			and presentation_split \
			and simulation_split,
		{"requirements": requirements, "scenarioCount": scenarios.size()}
	)

func test_manifest_resolution(builder, scenarios: Array, manifest: Dictionary) -> void:
	var town := {"radius": 25, "level": 16.0}
	var resolution: Dictionary = builder.resolve_tutorial_actor_specs(manifest, scenarios, town)
	var exact := bool(resolution.get("ok", false)) and (resolution.get("specs", []) as Array).size() == scenarios.size()
	var homes: Dictionary = manifest.get("homesByKey", {})
	var profiles := {}
	for spec_value in resolution.get("specs", []):
		var spec: Dictionary = spec_value if spec_value is Dictionary else {}
		var profile: Dictionary = spec.get("profile", {}) if spec.get("profile", {}) is Dictionary else {}
		var home_key := int(spec.get("homeKey", -1))
		var home: Dictionary = homes.get(str(home_key), {})
		profiles[String(spec.get("id", ""))] = profile
		exact = exact \
			and int(profile.get("homeKey", -1)) == home_key \
			and String(profile.get("homeStableId", "")) == String(home.get("stableId", "")) \
			and String(profile.get("doorPortalId", "")) == String(home.get("doorPortalId", "")) \
			and profile.get("homeCell") == home.get("homeCell") \
			and profile.get("porchCell") == home.get("porchCell") \
			and profile.get("doorCell") == home.get("doorCell") \
			and profile.get("interiorLandingCell") == home.get("interiorLandingCell") \
			and profile.get("interiorMinCell") == home.get("interiorMinCell") \
			and profile.get("interiorMaxCell") == home.get("interiorMaxCell") \
			and profile.get("homeRouteCells", []) == home.get("homeRouteCells", []) \
			and not profile.has("requiredVisibleScripted")
	add_result(
		"all_tutorial_actor_profiles_resolve_exactly_from_manifest_before_spawn",
		exact \
			and String((profiles.get("mira", {}) as Dictionary).get("role", "")) == "Civilian" \
			and String((profiles.get("rowan", {}) as Dictionary).get("role", "")) == "Carpenter" \
			and String((profiles.get("niko", {}) as Dictionary).get("role", "")) == "Forager" \
			and String((profiles.get("sera", {}) as Dictionary).get("role", "")) == "Guard",
		resolution
	)

func test_missing_home_fails_before_spawn(builder, scenarios: Array, manifest: Dictionary) -> void:
	var missing := manifest.duplicate(true)
	(missing.get("homesByKey") as Dictionary).erase("3")
	var resolution: Dictionary = builder.resolve_tutorial_actor_specs(missing, scenarios, {"radius": 25, "level": 16.0})
	var problems: Array = resolution.get("problems", [])
	add_result(
		"missing_manifest_assignment_fails_resolution_before_body_creation",
		not bool(resolution.get("ok", true)) \
			and (resolution.get("specs", []) as Array).size() == 5 \
			and problems.any(func(problem): return String(problem).contains("mira cannot resolve homeKey 3")),
		resolution
	)

func test_shared_homes_are_declared(scenarios: Array) -> void:
	var actors_by_home := {}
	for scenario_value in scenarios:
		var scenario: Dictionary = scenario_value
		var key := int(scenario.get("homeKey", -1))
		if not actors_by_home.has(key):
			actors_by_home[key] = []
		(actors_by_home[key] as Array).append(String(scenario.get("id", "")))
	add_result(
		"shared_tutorial_homes_exist_only_as_scenario_assignments",
		actors_by_home.get(1, []) == ["rowan", "sera", "toma"] \
			and actors_by_home.get(2, []) == ["niko", "lyra"] \
			and actors_by_home.get(3, []) == ["mira"],
		actors_by_home
	)

func test_generated_town_spawn_still_uses_generic_registration(manifest: Dictionary) -> void:
	var system := NpcSystemScript.new()
	root.add_child(system)
	system.setup(null, null)
	var record: Dictionary = ((manifest.get("homesByKey") as Dictionary).get("1") as Dictionary).duplicate(true)
	record["id"] = "generated-town-contract"
	var body = system.spawn_town_npc(record, 0)
	var entry: Dictionary = system.npc_entry_for_actor(body) if body != null else {}
	add_result(
		"generic_generated_town_spawn_still_registers_complete_ordinary_profile",
		body != null \
			and not entry.is_empty() \
			and int(entry.get("homeKey", -1)) == 1 \
			and String(entry.get("homeStableId", "")) == String(record.get("stableId", "")) \
			and String(entry.get("doorPortalId", "")) == String(record.get("doorPortalId", "")) \
			and entry.get("homeCell") == record.get("homeCell") \
			and entry.get("homeRouteCells", []) == record.get("homeRouteCells", []) \
			and not bool(entry.get("tutorial", true)) \
			and not bool(entry.get("requiredVisibleScripted", true)),
		entry
	)
	system.free()
	await process_frame

func test_tutorial_identity_has_ordinary_simulation(builder, scenarios: Array, manifest: Dictionary) -> void:
	var resolution: Dictionary = builder.resolve_tutorial_actor_specs(manifest, scenarios, {"radius": 25, "level": 16.0})
	var base_profile: Dictionary = {}
	for spec_value in resolution.get("specs", []):
		if spec_value is Dictionary and String((spec_value as Dictionary).get("id", "")) == "rowan":
			base_profile = ((spec_value as Dictionary).get("profile", {}) as Dictionary).duplicate(true)
			break
	var system := NpcSystemScript.new()
	root.add_child(system)
	system.setup(null, null)
	var tutorial_body := CharacterBody3D.new()
	var ordinary_body := CharacterBody3D.new()
	system.add_child(tutorial_body)
	system.add_child(ordinary_body)
	var tutorial_profile := base_profile.duplicate(true)
	tutorial_profile["id"] = "tutorial-contract"
	tutorial_profile["tutorial"] = true
	var ordinary_profile := base_profile.duplicate(true)
	ordinary_profile["id"] = "ordinary-contract"
	ordinary_profile["tutorial"] = false
	var tutorial_entry: Dictionary = system.register_npc(tutorial_body, tutorial_profile)
	var ordinary_entry: Dictionary = system.register_npc(ordinary_body, ordinary_profile)
	var tutorial_context = tutorial_entry.get("agentContext")
	var ordinary_context = ordinary_entry.get("agentContext")
	var schedule_service = system.autonomy_system.get("schedule_service")
	var tutorial_schedule: Dictionary = schedule_service.role_profile_for(tutorial_context, tutorial_entry)
	var ordinary_schedule: Dictionary = schedule_service.role_profile_for(ordinary_context, ordinary_entry)
	var tutorial_motor = tutorial_entry.get("motorProfile")
	var ordinary_motor = ordinary_entry.get("motorProfile")
	var motor_equal: bool = tutorial_motor != null and ordinary_motor != null \
		and tutorial_motor.to_summary() == ordinary_motor.to_summary()
	add_result(
		"tutorial_identity_does_not_change_collision_motor_schedule_or_lod_pin",
		not tutorial_entry.is_empty() \
			and not ordinary_entry.is_empty() \
			and tutorial_body.collision_layer == ordinary_body.collision_layer \
			and tutorial_body.collision_mask == ordinary_body.collision_mask \
			and motor_equal \
			and tutorial_schedule == ordinary_schedule \
			and String(tutorial_schedule.get("roleId", "")) == "carpenter" \
			and not bool(tutorial_entry.get("requiredVisibleScripted", true)) \
			and not bool(ordinary_entry.get("requiredVisibleScripted", true)),
		{
			"tutorialSchedule": tutorial_schedule,
			"ordinarySchedule": ordinary_schedule,
			"tutorialLayer": tutorial_body.collision_layer,
			"ordinaryLayer": ordinary_body.collision_layer,
			"tutorialRequiredVisible": tutorial_entry.get("requiredVisibleScripted"),
			"ordinaryRequiredVisible": ordinary_entry.get("requiredVisibleScripted")
		}
	)
	system.free()
	await process_frame

func test_source_audit() -> void:
	var tutorial_source := FileAccess.get_file_as_string("res://scripts/TutorialSystem.gd")
	var builder_source := FileAccess.get_file_as_string("res://scripts/TutorialSceneBuilder.gd")
	var npc_source := FileAccess.get_file_as_string("res://scripts/NpcSystem.gd")
	var schedule_source := FileAccess.get_file_as_string("res://scripts/npc_ai/behavior/NpcScheduleService.gd")
	var clean := tutorial_source.find("func refresh_tutorial_npc_home_records") < 0 \
		and tutorial_source.find("func tutorial_home_record(") < 0 \
		and tutorial_source.find("ensure_tutorial_town_home_records") < 0 \
		and builder_source.find("\"requiredVisibleScripted\": true") < 0 \
		and npc_source.find("profile.get(\"requiredVisibleScripted\", profile.get(\"tutorial\"") < 0 \
		and schedule_source.find("entry.get(\"tutorial\", false)") < 0
	add_result(
		"source_has_no_home_refresh_coordinate_fallback_or_tutorial_simulation_privilege",
		clean,
		{"clean": clean}
	)

func fixture_manifest() -> Dictionary:
	var records: Array = []
	var portals: Array = []
	for home_key in range(4):
		var base_x := 280 + home_key * 10
		var porch := Vector2i(base_x, 12)
		var door := Vector2i(base_x, 11)
		var landing := Vector2i(base_x, 10)
		var home := Vector2i(base_x + 1, 9)
		var portal_id := "door:280,0:%d" % home_key
		portals.append(portal_id)
		records.append({
			"homeKey": home_key,
			"buildingIndex": home_key,
			"stableId": "town:280,0:home:%d" % home_key,
			"townKey": "280,0",
			"townCenter": Vector2i(280, 0),
			"townRadius": 25,
			"level": 16.0,
			"homeCell": home,
			"porchCell": porch,
			"doorCell": door,
			"doorPortalId": portal_id,
			"interiorLandingCell": landing,
			"homeRouteCells": [porch, door, landing, home],
			"interiorMinCell": Vector2i(base_x, 8),
			"interiorMaxCell": Vector2i(base_x + 3, 10),
			"guardCell": porch
		})
	return TownRuntimeManifestScript.build("atlas-phase4", "280,0", Vector2i(280, 0), 1, [0, 1, 2, 3], records, portals, 0)

func add_result(name: String, passed: bool, details) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func finish() -> void:
	var failures := results.filter(func(result): return not bool(result.get("passed", false)))
	var report := {
		"schemaVersion": 1,
		"runnerId": "tutorial_actor_registration_contract",
		"testId": "vox_74_tutorial_actor_registration_contract",
		"finished": true,
		"passed": failures.is_empty(),
		"evidenceLevel": "contract",
		"scope": "Manifest-derived tutorial actor profile resolution, registration parity, and source ownership. No live gameplay behavior is exercised.",
		"resultCount": results.size(),
		"failureCount": failures.size(),
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify({"runnerId": report.runnerId, "passed": report.passed, "resultCount": report.resultCount, "failureCount": report.failureCount}, "  "))
	quit(0 if bool(report.passed) else 1)
