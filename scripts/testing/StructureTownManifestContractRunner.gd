extends SceneTree

const StructureSystemScript := preload("res://scripts/StructureSystem.gd")
const TownRuntimeManifestScript := preload("res://scripts/world/TownRuntimeManifest.gd")

class FakeWorld:
	extends RefCounted
	var revision := 0
	func terrain_volume_chunk_revision(_chunk_key: Vector2i,_chunk_size: int) -> int: return revision

class FakeMain:
	extends RefCounted

	var seed_text := "atlas-1492"
	var CELL := 1.35
	var CHUNK_SIZE := 28
	var WATER_LEVEL := 2.0
	var TOWN_RADIUS_CELLS := 28
	var TOWN_REGION_CELLS := 280
	var STRUCTURE_REGION_CELLS := 140
	var STRUCTURE_SPAWN_CHANCE := 0.26
	var town_region_cache := {}
	var world_generation_system = FakeWorld.new()
	var runtime_perf_monitor = null
	var block_calls := 0

	func _init(seed_value: String) -> void:
		seed_text = seed_value

	func hash_string(text: String) -> int:
		return absi(text.hash())

	func hash01(text: String) -> float:
		return float(absi(text.hash()) % 1000000) / 1000000.0

	func surface_y_at_cell(_cell: Vector3i) -> float:
		return 16.0

	func surface_biome_at_cell(_cell: Vector3i) -> String:
		return "plains"

	func create_block(_cell: Vector3i, _block_type: String, _options: Dictionary):
		block_calls += 1
		return null

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_STRUCTURE_TOWN_MANIFEST_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/tutorial-town/structure-town-manifest-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	test_known_and_random_seed_determinism()
	test_required_home_records_are_complete()
	test_pending_town_ops_prevent_readiness()
	test_deferred_records_publish_only_after_fifo_marker()
	test_manifest_status_query_is_read_only()
	test_invalid_requirements_fail_without_generation()
	test_repeated_ready_polling_is_idempotent()
	test_bounded_generation_request_is_not_duplicated()
	test_bounded_deferred_generation_matches_synchronous_manifest()
	test_missing_required_site_is_structured_failure()
	test_standalone_admission_is_resumable_and_revision_checked()
	finish()

func test_known_and_random_seed_determinism() -> void:
	var fresh_seed_rng := RandomNumberGenerator.new()
	fresh_seed_rng.randomize()
	var seeds := [
		"atlas-1492",
		"atlas-16449406",
		"phase2-fresh-%d" % fresh_seed_rng.randi(),
		"phase2-fresh-%d" % fresh_seed_rng.randi()
	]
	var comparisons: Array = []
	var passed := true
	for seed_value in seeds:
		var first := generated_fixture(String(seed_value))
		var second := generated_fixture(String(seed_value))
		var first_status: Dictionary = first.system.town_manifest_status(first.town, requirements())
		var second_status: Dictionary = second.system.town_manifest_status(second.town, requirements())
		var first_json: String = TownRuntimeManifestScript.stable_json(first_status.get("manifest", {}))
		var second_json: String = TownRuntimeManifestScript.stable_json(second_status.get("manifest", {}))
		var same := String(first_status.get("status", "")) == "ready" \
			and String(second_status.get("status", "")) == "ready" \
			and first_json == second_json \
			and int(first.main.block_calls) == int(second.main.block_calls)
		passed = passed and same
		comparisons.append({
			"seed": seed_value,
			"same": same,
			"signature": first_json.sha256_text(),
			"blockCalls": first.main.block_calls
		})
	add_result("known_and_random_town_manifests_are_deterministic", passed, comparisons)

func test_required_home_records_are_complete() -> void:
	var fixture := generated_fixture("phase2-complete")
	var status: Dictionary = fixture.system.town_manifest_status(fixture.town, requirements())
	var manifest: Dictionary = status.get("manifest", {})
	var homes: Dictionary = manifest.get("homesByKey", {}) if manifest.get("homesByKey", {}) is Dictionary else {}
	var complete := String(status.get("status", "")) == "ready"
	for home_key in [0, 1, 2, 3]:
		var record: Dictionary = homes.get(str(home_key), {}) if homes.get(str(home_key), {}) is Dictionary else {}
		complete = complete \
			and String(record.get("stableId", "")) != "" \
			and String(record.get("doorPortalId", "")) != "" \
			and record.get("doorCell") is Vector2i \
			and record.get("interiorLandingCell") is Vector2i \
			and record.get("interiorMinCell") is Vector2i \
			and record.get("interiorMaxCell") is Vector2i
	add_result("required_home_keys_publish_complete_door_and_interior_records", complete, status)

func test_pending_town_ops_prevent_readiness() -> void:
	var fixture := generated_fixture("phase2-pending")
	var town_key: String = fixture.system.town_key_for(fixture.town)
	fixture.system.enqueue_structure_op({"type": "phase2_noop", "townKey": town_key})
	var status: Dictionary = fixture.system.town_manifest_status(fixture.town, requirements())
	add_result(
		"town_owned_pending_operation_prevents_manifest_readiness",
		String(status.get("status", "")) == "pending" \
			and String(status.get("reason", "")) == "required_town_structure_operations_pending" \
			and int((status.get("metrics", {}) as Dictionary).get("pendingOpCount", 0)) == 1,
		status
	)

func test_deferred_records_publish_only_after_fifo_marker() -> void:
	var source := generated_fixture("phase2-deferred")
	var town_key: String = source.system.town_key_for(source.town)
	var records: Array = (source.system.town_home_records.get(town_key, []) as Array).duplicate(true)
	var system = StructureSystemScript.new()
	system.setup(FakeMain.new("phase2-deferred"))
	system.deferred_town_home_records[town_key] = records
	system.town_manifest_publish_states[town_key] = {
		"status": "building",
		"generationAttempts": 1,
		"startedUsec": Time.get_ticks_usec(),
		"builtHomeCount": records.size()
	}
	system.enqueue_structure_op({"type": "phase2_noop", "townKey": town_key})
	system.enqueue_structure_op({"type": "publish_town_home_records", "townKey": town_key})
	var before: Dictionary = system.town_manifest_status(source.town, requirements())
	system.process_pending_structure_ops(1, 100.0)
	var middle: Dictionary = system.town_manifest_status(source.town, requirements())
	system.process_pending_structure_ops(1, 100.0)
	var after: Dictionary = system.town_manifest_status(source.town, requirements())
	add_result(
		"deferred_records_become_authoritative_only_after_publish_marker",
		String(before.get("status", "")) == "pending" \
			and String(middle.get("status", "")) == "pending" \
			and String(after.get("status", "")) == "ready" \
			and system.town_home_records.has(town_key) \
			and not system.deferred_town_home_records.has(town_key),
		{"before": before, "middle": middle, "after": after}
	)

func test_manifest_status_query_is_read_only() -> void:
	var system = StructureSystemScript.new()
	system.setup(FakeMain.new("phase2-read-only"))
	var town := town_fixture()
	var statuses: Array = []
	for index in range(12):
		statuses.append(String(system.town_manifest_status(town, requirements()).get("status", "")))
	var unchanged: bool = system.generated_town_count == 0 \
		and system.pending_structure_op_count() == 0 \
		and system.town_home_records.is_empty() \
		and system.deferred_town_home_records.is_empty() \
		and system.town_manifest_publish_states.is_empty()
	add_result(
		"manifest_status_is_a_read_only_validation_query",
		unchanged and statuses.all(func(status): return status == "pending"),
		{"statuses": statuses, "generatedTownCount": system.generated_town_count}
	)

func test_invalid_requirements_fail_without_generation() -> void:
	var system = StructureSystemScript.new()
	system.setup(FakeMain.new("phase2-invalid-requirements"))
	var status: Dictionary = system.request_town_manifest_publication(town_fixture(), {
		"ok": true,
		"requiredHomeKeys": [0, -1, "3"],
		"actorHomeAssignments": {"mira": 4},
		"problems": []
	})
	var failure_reasons: Array = (status.get("metrics", {}) as Dictionary).get("failureReasons", [])
	add_result(
		"invalid_semantic_requirements_fail_without_generation",
		String(status.get("status", "")) == "failed" \
			and String(status.get("reason", "")) == "invalid_town_requirements" \
			and failure_reasons.size() == 3 \
			and system.generated_town_count == 0 \
			and system.pending_structure_op_count() == 0,
		status
	)

func test_repeated_ready_polling_is_idempotent() -> void:
	var fixture := generated_fixture("phase2-idempotent")
	var town_key: String = fixture.system.town_key_for(fixture.town)
	var record_count := (fixture.system.town_home_records.get(town_key, []) as Array).size()
	var building_count := int(fixture.system.generated_building_count)
	var door_count := int(fixture.system.generated_door_count)
	var block_calls := int(fixture.main.block_calls)
	var stable := true
	for index in range(12):
		var status: Dictionary = fixture.system.request_town_manifest_publication(fixture.town, requirements(), 1, 0.1)
		stable = stable and String(status.get("status", "")) == "ready"
	stable = stable \
		and (fixture.system.town_home_records.get(town_key, []) as Array).size() == record_count \
		and int(fixture.system.generated_building_count) == building_count \
		and int(fixture.system.generated_door_count) == door_count \
		and int(fixture.main.block_calls) == block_calls \
		and fixture.system.pending_structure_op_count_for_town(town_key) == 0
	add_result("repeated_ready_polling_does_not_rebuild_or_consume_generation", stable, {
		"records": record_count,
		"buildings": building_count,
		"doors": door_count,
		"blockCalls": block_calls
	})

func test_bounded_generation_request_is_not_duplicated() -> void:
	var fake := FakeMain.new("phase2-bounded")
	var system = StructureSystemScript.new()
	system.setup(fake)
	var town := town_fixture()
	var first: Dictionary = system.request_town_manifest_publication(town, requirements(), 1, 100.0)
	var town_key := system.town_key_for(town)
	var queue_after_first := system.pending_structure_op_count_for_town(town_key)
	var attempts_after_first := int((system.town_manifest_publish_states.get(town_key, {}) as Dictionary).get("generationAttempts", 0))
	var second: Dictionary = system.request_town_manifest_publication(town, requirements(), 1, 100.0)
	var attempts_after_second := int((system.town_manifest_publish_states.get(town_key, {}) as Dictionary).get("generationAttempts", 0))
	add_result(
		"bounded_loading_poll_enqueues_generation_once",
		String(first.get("status", "")) == "pending" \
			and String(second.get("status", "")) == "pending" \
			and queue_after_first > 0 \
			and attempts_after_first == 1 \
			and attempts_after_second == 1 \
			and int(system.generated_town_count) == 1,
		{
			"first": first,
			"second": second,
			"queueAfterFirst": queue_after_first,
			"attemptsAfterFirst": attempts_after_first,
			"attemptsAfterSecond": attempts_after_second,
			"generatedTownCount": system.generated_town_count
		}
	)

func test_bounded_deferred_generation_matches_synchronous_manifest() -> void:
	var seed_value := "phase2-deferred-parity"
	var synchronous := generated_fixture(seed_value)
	var deferred_main := FakeMain.new(seed_value)
	var deferred_system = StructureSystemScript.new()
	deferred_system.setup(deferred_main)
	var town := town_fixture()
	var status: Dictionary = {}
	var poll_count := 0
	var queue_peak := 0
	while poll_count < 10000:
		status = deferred_system.request_town_manifest_publication(town, requirements(), 24, 1000.0)
		poll_count += 1
		queue_peak = maxi(queue_peak, deferred_system.pending_structure_op_count())
		if String(status.get("status", "")) != "pending":
			break
	var synchronous_status: Dictionary = synchronous.system.town_manifest_status(town, requirements())
	var town_key := deferred_system.town_key_for(town)
	var publish_state: Dictionary = deferred_system.town_manifest_publish_states.get(town_key, {})
	var same_manifest := TownRuntimeManifestScript.stable_json(status.get("manifest", {})) \
		== TownRuntimeManifestScript.stable_json(synchronous_status.get("manifest", {}))
	add_result(
		"bounded_deferred_generation_publishes_the_synchronous_manifest",
		String(status.get("status", "")) == "ready" \
			and String(synchronous_status.get("status", "")) == "ready" \
			and same_manifest \
			and deferred_main.block_calls == synchronous.main.block_calls \
			and deferred_system.generated_building_count == synchronous.system.generated_building_count \
			and deferred_system.generated_door_count == synchronous.system.generated_door_count \
			and int(publish_state.get("generationAttempts", 0)) == 1 \
			and deferred_system.pending_structure_op_count_for_town(town_key) == 0,
		{
			"pollCount": poll_count,
			"queuePeak": queue_peak,
			"sameManifest": same_manifest,
			"blockCalls": deferred_main.block_calls,
			"generationAttempts": publish_state.get("generationAttempts", 0)
		}
	)

func test_missing_required_site_is_structured_failure() -> void:
	var main := FakeMain.new("phase2-failure")
	var system = StructureSystemScript.new()
	system.setup(main)
	var town := town_fixture()
	town["homeExclusionRings"] = [{"radius": 1, "margin": 100}]
	system.build_town(town)
	var town_key := system.town_key_for(town)
	var records: Array = system.town_home_records.get(town_key, [])
	var status: Dictionary = system.town_manifest_status(town, requirements())
	add_result(
		"excluded_required_home_sites_produce_structured_generation_failure",
		String(status.get("status", "")) == "failed" \
			and String(status.get("reason", "")) == "required_town_manifest_generation_failed" \
			and records.is_empty() \
			and ((status.get("metrics", {}) as Dictionary).get("failureReasons", []) as Array).size() >= 2,
		status
	)

func test_standalone_admission_is_resumable_and_revision_checked() -> void:
	var fake:=FakeMain.new("standalone-admission")
	var system=StructureSystemScript.new()
	system.main=fake
	system.regional_source_generation=1
	var region:=Vector2i(3,-2)
	var candidate:={"baseCell":Vector2i(10,20),"dimensions":Vector2i(8,7),"structureType":"ruin"}
	var first: Dictionary=system.advance_standalone_terrain_admission(region,candidate)
	var first_cursor:=int(system.standalone_admission_states.get(region,{}).get("cursor",0))
	fake.world_generation_system.revision=1
	var restarted: Dictionary=system.advance_standalone_terrain_admission(region,candidate)
	var restarted_cursor:=int(system.standalone_admission_states.get(region,{}).get("cursor",0))
	var result:=restarted
	var slices:=1
	while result.get("status")=="pending" and slices<64:
		result=system.advance_standalone_terrain_admission(region,candidate)
		slices+=1
	var expected_samples:=2*8+2*7-4
	add_result("standalone_terrain_admission_is_bounded_resumable_and_restarts_on_local_revision",
		first.get("status")=="pending" and first_cursor<=system.STANDALONE_ADMISSION_SAMPLES_PER_SLICE \
		and restarted.get("status")=="pending" and restarted_cursor<=system.STANDALONE_ADMISSION_SAMPLES_PER_SLICE \
		and result.get("status")=="ready" and is_equal_approx(float(result.get("level",NAN)),16.0) \
		and int(result.get("sampleCount",0))==expected_samples and slices>1 \
		and not system.standalone_admission_states.has(region),
		{"first":first,"firstCursor":first_cursor,"restarted":restarted,"restartedCursor":restarted_cursor,
			"result":result,"slices":slices})

func generated_fixture(seed_value: String) -> Dictionary:
	var fake := FakeMain.new(seed_value)
	var system = StructureSystemScript.new()
	system.setup(fake)
	var town := town_fixture()
	system.build_town(town)
	return {"main": fake, "system": system, "town": town}

func town_fixture() -> Dictionary:
	return {
		"regionX": 1,
		"regionZ": 0,
		"centerX": 280,
		"centerZ": 0,
		"radius": 30,
		"level": 16.0,
		"homeExclusionRings": []
	}

func requirements() -> Dictionary:
	return TownRuntimeManifestScript.requirements_from_actor_specs([
		{"id": "starter", "homeKey": 0},
		{"id": "niko", "homeKey": 1},
		{"id": "rowan", "homeKey": 2},
		{"id": "mira", "homeKey": 3}
	])

func add_result(name: String, passed: bool, details) -> void:
	results.append({"name": name, "passed": passed, "details": TownRuntimeManifestScript.canonical_data(details)})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func finish() -> void:
	var failure_count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failure_count += 1
	var report := {
		"schemaVersion": 1,
		"runnerId": "structure_town_manifest_contract",
		"testId": "vox_72_structure_town_manifest_contract",
		"finished": true,
		"passed": failure_count == 0,
		"evidenceLevel": "contract",
		"scope": "StructureSystem deterministic town-manifest publication, queue ownership, pending readiness, failure, and idempotency contracts. No tutorial or NPC runtime caller is exercised.",
		"resultCount": results.size(),
		"failureCount": failure_count,
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify({
		"runnerId": report.runnerId,
		"passed": report.passed,
		"resultCount": report.resultCount,
		"failureCount": report.failureCount
	}, "  "))
	quit(0 if failure_count == 0 else 1)
