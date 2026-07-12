extends SceneTree

const TownRuntimeManifestScript := preload("res://scripts/world/TownRuntimeManifest.gd")
const StartupReadinessResultScript := preload("res://scripts/world/StartupReadinessResult.gd")
const NpcOrderAcceptanceScript := preload("res://scripts/npc_ai/contracts/NpcOrderAcceptance.gd")

const TOWN_KEY := "280,0"
const SEED := "atlas-contract"

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_TOWN_MANIFEST_CONTRACT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/tutorial-town/town-runtime-manifest-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	test_requirements_derive_semantic_home_keys()
	test_complete_manifest()
	test_missing_required_key()
	test_duplicate_key()
	test_duplicate_stable_identity()
	test_wrong_town_key()
	test_missing_door_and_strict_interior()
	test_deterministic_serialization()
	test_structured_startup_results()
	test_order_acceptance_is_separate_from_route_readiness()
	test_live_nodes_are_rejected()
	finish()

func test_requirements_derive_semantic_home_keys() -> void:
	var requirements: Dictionary = TownRuntimeManifestScript.requirements_from_actor_specs([
		{"id": "mira", "homeKey": 3},
		{"id": "niko", "homeKey": 1},
		{"id": "rowan", "homeKey": 2},
		{"id": "visitor", "requiresHome": false}
	])
	add_result(
		"requirements_derive_semantic_home_keys",
		bool(requirements.get("ok", false)) \
			and requirements.get("requiredHomeKeys", []) == [1, 2, 3] \
			and int((requirements.get("actorHomeAssignments", {}) as Dictionary).get("mira", -1)) == 3,
		requirements
	)

func test_complete_manifest() -> void:
	var manifest := complete_manifest([1, 2, 3])
	var validation: Dictionary = TownRuntimeManifestScript.validate(manifest)
	add_result(
		"complete_manifest_is_ready",
		bool(manifest.get("ready", false)) and bool(validation.get("ok", false)) and (validation.get("problems", []) as Array).is_empty(),
		{"manifest": manifest, "validation": validation}
	)

func test_missing_required_key() -> void:
	var manifest := build_manifest([1, 2, 3], [home_record(1), home_record(3)])
	var validation: Dictionary = TownRuntimeManifestScript.validate(manifest)
	add_result(
		"missing_required_key_reports_semantic_key",
		not bool(validation.get("ok", true)) and validation.get("missingRequiredHomeKeys", []) == [2] and problems_contain(validation, "missing required homeKey 2"),
		validation
	)

func test_duplicate_key() -> void:
	var duplicate := home_record(1)
	duplicate["stableId"] = "town:%s:home:duplicate" % TOWN_KEY
	var manifest := build_manifest([1], [home_record(1), duplicate])
	var validation: Dictionary = TownRuntimeManifestScript.validate(manifest)
	add_result(
		"duplicate_key_is_not_overwritten_silently",
		not bool(validation.get("ok", true)) and validation.get("duplicateHomeKeys", []) == [1] and problems_contain(validation, "duplicate homeKey 1"),
		validation
	)

func test_duplicate_stable_identity() -> void:
	var first := home_record(1)
	var second := home_record(2)
	second["stableId"] = first.get("stableId")
	second["doorPortalId"] = first.get("doorPortalId")
	var validation: Dictionary = TownRuntimeManifestScript.validate(build_manifest([1, 2], [first, second], [portal_id(1)]))
	add_result(
		"duplicate_stable_home_and_portal_identity_is_rejected",
		not bool(validation.get("ok", true)) \
			and problems_contain(validation, "duplicate stableId") \
			and problems_contain(validation, "duplicate doorPortalId"),
		validation
	)

func test_wrong_town_key() -> void:
	var wrong := home_record(1)
	wrong["townKey"] = "999,999"
	var validation: Dictionary = TownRuntimeManifestScript.validate(build_manifest([1], [wrong]))
	add_result(
		"wrong_town_key_is_rejected",
		not bool(validation.get("ok", true)) and problems_contain(validation, "belongs to wrong townKey"),
		validation
	)

func test_missing_door_and_strict_interior() -> void:
	var incomplete := home_record(1)
	incomplete.erase("doorPortalId")
	incomplete.erase("interiorLandingCell")
	incomplete.erase("interiorMinCell")
	incomplete.erase("interiorMaxCell")
	var validation: Dictionary = TownRuntimeManifestScript.validate(build_manifest([1], [incomplete]))
	var problems: Array = validation.get("problems", [])
	add_result(
		"missing_door_and_strict_interior_report_all_problems",
		not bool(validation.get("ok", true)) \
			and problems.size() >= 4 \
			and problems_contain(validation, "missing doorPortalId") \
			and problems_contain(validation, "interiorLandingCell must be Vector2i") \
			and problems_contain(validation, "interiorMinCell must be Vector2i") \
			and problems_contain(validation, "interiorMaxCell must be Vector2i"),
		validation
	)

func test_deterministic_serialization() -> void:
	var first := build_manifest([3, 1, 2], [home_record(3), home_record(1), home_record(2)], [portal_id(3), portal_id(1), portal_id(2)])
	var second := build_manifest([2, 3, 1], [home_record(2), home_record(3), home_record(1)], [portal_id(2), portal_id(3), portal_id(1)])
	var first_json: String = TownRuntimeManifestScript.stable_json(first)
	var second_json: String = TownRuntimeManifestScript.stable_json(second)
	add_result(
		"manifest_serialization_is_deterministic",
		first_json == second_json and first_json != "",
		{"first": first_json, "second": second_json}
	)

func test_structured_startup_results() -> void:
	var manifest := complete_manifest([1])
	var ready: Dictionary = StartupReadinessResultScript.ready(manifest, {"elapsedMs": 12})
	var pending: Dictionary = StartupReadinessResultScript.pending(
		"waiting_for_required_publication",
		manifest,
		["door_portals", "navigation_tiles"],
		{"remaining": 2}
	)
	var failed: Dictionary = StartupReadinessResultScript.failed(
		"manifest_invalid",
		manifest,
		[],
		{"problemCount": 1}
	)
	var valid := bool(StartupReadinessResultScript.validate(ready).get("ok", false)) \
		and bool(StartupReadinessResultScript.validate(pending).get("ok", false)) \
		and bool(StartupReadinessResultScript.validate(failed).get("ok", false))
	add_result(
		"startup_results_distinguish_ready_pending_and_failed",
		valid \
			and bool(ready.get("ok", false)) \
			and not bool(pending.get("ok", true)) \
			and String(pending.get("status", "")) == "pending" \
			and not bool(failed.get("ok", true)) \
			and String(failed.get("status", "")) == "failed",
		{"ready": ready, "pending": pending, "failed": failed}
	)

func test_order_acceptance_is_separate_from_route_readiness() -> void:
	var acceptance: Dictionary = NpcOrderAcceptanceScript.from_scripted_order({
		"id": "mira:go_home:1",
		"kind": "go_home",
		"state": "PENDING",
		"reason": "tutorial_knock_complete",
		"routeState": "pending_budget"
	})
	var rejected: Dictionary = NpcOrderAcceptanceScript.rejected("go_home", "missing_actor", "actor_not_registered")
	var validation: Dictionary = NpcOrderAcceptanceScript.validate(acceptance)
	var rejected_validation: Dictionary = NpcOrderAcceptanceScript.validate(rejected)
	add_result(
		"order_acceptance_retains_intent_without_claiming_route_readiness",
		bool(validation.get("ok", false)) \
			and bool(rejected_validation.get("ok", false)) \
			and bool(acceptance.get("accepted", false)) \
			and String(acceptance.get("status", "")) == "accepted" \
			and not acceptance.has("routeState") \
			and not acceptance.has("routeReady"),
		{"acceptance": acceptance, "rejected": rejected}
	)

func test_live_nodes_are_rejected() -> void:
	var manifest := complete_manifest([1])
	manifest["runtimeDoor"] = Node.new()
	var validation: Dictionary = TownRuntimeManifestScript.validate(manifest)
	add_result(
		"manifest_rejects_live_node_references",
		not bool(validation.get("ok", true)) and problems_contain(validation, "live Object references"),
		validation
	)
	(manifest.get("runtimeDoor") as Node).free()

func complete_manifest(required_keys: Array) -> Dictionary:
	var records: Array = []
	var portals: Array = []
	for key_value in required_keys:
		var key := int(key_value)
		records.append(home_record(key))
		portals.append(portal_id(key))
	return build_manifest(required_keys, records, portals)

func build_manifest(required_keys: Array, records: Array, portals := []) -> Dictionary:
	var resolved_portals: Array = portals if portals is Array and not portals.is_empty() else []
	if resolved_portals.is_empty():
		for record_value in records:
			if record_value is Dictionary:
				var value := String((record_value as Dictionary).get("doorPortalId", ""))
				if value != "":
					resolved_portals.append(value)
	return TownRuntimeManifestScript.build(SEED, TOWN_KEY, Vector2i(280, 0), 7, required_keys, records, resolved_portals, 0)

func home_record(home_key: int) -> Dictionary:
	var offset := home_key * 20
	var home := Vector2i(offset + 13, 12)
	var porch := Vector2i(offset + 11, 16)
	var door := Vector2i(offset + 11, 15)
	var landing := Vector2i(offset + 11, 14)
	return {
		"homeKey": home_key,
		"stableId": "town:%s:home:%d" % [TOWN_KEY, home_key],
		"townKey": TOWN_KEY,
		"homeCell": home,
		"porchCell": porch,
		"doorCell": door,
		"interiorLandingCell": landing,
		"interiorMinCell": Vector2i(offset + 10, 10),
		"interiorMaxCell": Vector2i(offset + 14, 14),
		"homeRouteCells": [porch, door, landing, home],
		"doorPortalId": portal_id(home_key)
	}

func portal_id(home_key: int) -> String:
	return "door:%s:%d" % [TOWN_KEY, home_key]

func problems_contain(validation: Dictionary, needle: String) -> bool:
	for problem in validation.get("problems", []):
		if String(problem).contains(needle):
			return true
	return false

func add_result(name: String, passed: bool, details) -> void:
	results.append({"name": name, "passed": passed, "details": json_safe(details)})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func json_safe(value):
	if value is Object:
		return "<live-object>"
	return TownRuntimeManifestScript.canonical_data(value)

func finish() -> void:
	var failure_count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failure_count += 1
	var report := {
		"schemaVersion": 1,
		"runnerId": "town_runtime_manifest_contract",
		"testId": "vox_71_town_runtime_manifest_contract",
		"finished": true,
		"passed": failure_count == 0,
		"evidenceLevel": "contract",
		"scope": "Serializable town manifest, startup readiness, and generic NPC order-acceptance contracts. No production caller or live gameplay behavior is exercised.",
		"resultCount": results.size(),
		"failureCount": failure_count,
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify(report, "  "))
	quit(0 if failure_count == 0 else 1)
