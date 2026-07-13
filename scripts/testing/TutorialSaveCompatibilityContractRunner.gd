extends SceneTree

const TutorialSystemScript := preload("res://scripts/TutorialSystem.gd")
const TutorialTownSaveContractScript := preload("res://scripts/tutorial/TutorialTownSaveContract.gd")
const NpcSimulationLodServiceScript := preload("res://scripts/npc_ai/lifecycle/NpcSimulationLodService.gd")

class FakeNpcSystem:
    extends RefCounted

    var entry := {}
    var saved_facts := {}
    var wait_calls := 0
    var home_calls := 0
    var resume_calls := 0

    func npc_entry_for_actor(actor_id) -> Dictionary:
        return entry if String(actor_id) == String(entry.get("id", "")) else {}

    func saved_npc_fact(actor_id) -> Dictionary:
        var value = saved_facts.get(String(actor_id), {})
        return value.duplicate(true) if value is Dictionary else {}

    func settle_home_if_reached(target: Dictionary) -> void:
        target["insideHome"] = bool(target.get("strictInside", false))

    func scripted_order_status(actor_id) -> Dictionary:
        if String(actor_id) != String(entry.get("id", "")):
            return {"state": "FAILED_TARGET_GONE"}
        return entry.get("scriptedOrder", {}) if entry.get("scriptedOrder", {}) is Dictionary else {}

    func order_wait(actor_id, reason := "") -> Dictionary:
        wait_calls += 1
        return set_order(actor_id, "wait", reason)

    func order_go_home(actor_id, reason := "") -> Dictionary:
        home_calls += 1
        return set_order(actor_id, "go_home", reason)

    func order_resume_schedule(actor_id) -> Dictionary:
        resume_calls += 1
        if String(actor_id) != String(entry.get("id", "")):
            return {"state": "FAILED_TARGET_GONE", "reason": "missing_actor"}
        var result := {
            "kind": "resume_schedule",
            "state": "CANCELLED",
            "reason": "resume_schedule",
            "submissionReason": "resume_schedule"
        }
        entry["scriptedOrder"] = result
        return result

    func set_order(actor_id, kind: String, reason: String) -> Dictionary:
        if String(actor_id) != String(entry.get("id", "")):
            return {"state": "FAILED_TARGET_GONE", "reason": "missing_actor"}
        var result := {
            "kind": kind,
            "state": "PENDING",
            "reason": reason,
            "submissionReason": reason,
            "statusReason": reason,
            "failureReason": "",
            "usesRouteStack": kind == "go_home"
        }
        entry["scriptedOrder"] = result
        return result

class FakeMain:
    extends RefCounted

    var npc_system = FakeNpcSystem.new()

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
    call_deferred("run")

func run() -> void:
    report_path = OS.get_environment("VOXEL_TUTORIAL_SAVE_COMPATIBILITY_CONTRACT_REPORT").strip_edges()
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/tutorial-town/tutorial-save-compatibility-contract.json")
    DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
    test_manifest_reference_round_trip_and_mismatch()
    test_legacy_contract_migrates_without_actor_specific_data()
    test_durable_fact_preserves_semantic_home_identity_without_routes()
    test_wait_restore_retains_equivalent_generic_order()
    test_home_restore_reissues_once_then_retains()
    test_strict_home_restore_resumes_schedule_without_knock_replay()
    test_assignment_mismatch_is_reported_without_mutating_regenerated_profile()
    finish()

func sample_manifest() -> Dictionary:
    return {
        "schemaVersion": 1,
        "townKey": "town:1,0",
        "seed": "atlas-save-contract",
        "generationRevision": 1
    }

func sample_specs() -> Array:
    return [{
        "id": "mira",
        "profile": {
            "homeKey": 3,
            "homeStableId": "town:1,0:home:3",
            "doorPortalId": "door:town:1,0:3"
        }
    }]

func sample_entry() -> Dictionary:
    return {
        "id": "mira",
        "homeKey": 3,
        "homeStableId": "town:1,0:home:3",
        "doorPortalId": "door:town:1,0:3",
        "insideHome": false,
        "strictInside": false,
        "scriptedOrder": {}
    }

func make_tutorial(intent: Dictionary, strict_inside := false, active_order := {}, saved_fact := {}) -> Dictionary:
    var main := FakeMain.new()
    main.npc_system.entry = sample_entry()
    main.npc_system.entry["strictInside"] = strict_inside
    main.npc_system.entry["scriptedOrder"] = active_order.duplicate(true) if active_order is Dictionary else {}
    main.npc_system.saved_facts["mira"] = saved_fact.duplicate(true) if saved_fact is Dictionary else {}
    var tutorial = TutorialSystemScript.new()
    tutorial.main = main
    tutorial.started = true
    tutorial.intro_repair_active = true
    tutorial.intro_elder_dialogue_acknowledged = String(intent.get("kind", "")) != TutorialTownSaveContractScript.INTENT_WAIT
    tutorial.startup_town_manifest = sample_manifest()
    tutorial.startup_actor_specs = sample_specs()
    tutorial.restored_tutorial_save_contract = TutorialTownSaveContractScript.normalize({
        "schemaVersion": 1,
        "manifestReference": TutorialTownSaveContractScript.manifest_reference(sample_manifest(), sample_specs()),
        "introKnockIntent": intent
    }, intent)
    return {"tutorial": tutorial, "main": main}

func test_manifest_reference_round_trip_and_mismatch() -> void:
    var reference := TutorialTownSaveContractScript.manifest_reference(sample_manifest(), sample_specs())
    var valid := TutorialTownSaveContractScript.validate_manifest_reference(reference, sample_manifest(), sample_specs())
    var mismatch_reference := reference.duplicate(true)
    var homes: Dictionary = mismatch_reference.get("actorHomes", {})
    var mira_home: Dictionary = homes.get("mira", {})
    mira_home["doorPortalId"] = "door:wrong"
    homes["mira"] = mira_home
    mismatch_reference["actorHomes"] = homes
    var mismatch := TutorialTownSaveContractScript.validate_manifest_reference(mismatch_reference, sample_manifest(), sample_specs())
    add_result(
        "deterministic_manifest_reference_validates_regenerated_actor_homes",
        bool(valid.get("ok", false)) and not bool(mismatch.get("ok", true)) and (mismatch.get("mismatches", []) as Array).has("actor_home_mismatch:mira"),
        {"valid": valid, "mismatch": mismatch}
    )

func test_legacy_contract_migrates_without_actor_specific_data() -> void:
    var normalized := TutorialTownSaveContractScript.normalize({}, {
        "kind": TutorialTownSaveContractScript.INTENT_GO_HOME,
        "reason": "tutorial_knock_complete"
    })
    var reference: Dictionary = normalized.get("manifestReference", {}) if normalized.get("manifestReference", {}) is Dictionary else {}
    var validation := TutorialTownSaveContractScript.validate_manifest_reference(reference, sample_manifest(), sample_specs())
    add_result(
        "legacy_tutorial_save_without_contract_migrates_to_semantic_intent",
        String(normalized.get("migration", "")) == "tutorial_save_contract_missing" \
            and String((normalized.get("introKnockIntent", {}) as Dictionary).get("kind", "")) == TutorialTownSaveContractScript.INTENT_GO_HOME \
            and String(reference.get("townKey", "")) == "" \
            and (reference.get("actorHomes", {}) as Dictionary).is_empty() \
            and String(validation.get("status", "")) == "legacy_missing",
        {"normalized": normalized, "validation": validation}
    )

func test_durable_fact_preserves_semantic_home_identity_without_routes() -> void:
    var service = NpcSimulationLodServiceScript.new()
    var body := Node3D.new()
    var entry := sample_entry()
    entry.merge({
        "body": body,
        "townKey": "town:1,0",
        "homeCell": Vector2i(10, 12),
        "porchCell": Vector2i(10, 13),
        "guardCell": Vector2i(10, 15),
        "interiorMinCell": Vector2i(9, 11),
        "interiorMaxCell": Vector2i(11, 13),
        "level": 16.0,
        "role": "Elder",
        "job": "idle",
        "jobResource": "",
        "personalInventory": {},
        "hunger": 90.0,
        "maxHunger": 100.0,
        "nightGuard": false,
        "jobRuns": 0,
        "goal": "idle",
        "simulationLod": "active"
    }, true)
    var fact: Dictionary = service.durable_snapshot(entry)
    add_result(
        "durable_npc_fact_carries_home_identity_without_transient_route_state",
        int(fact.get("homeKey", -1)) == 3 \
            and String(fact.get("homeStableId", "")) == "town:1,0:home:3" \
            and String(fact.get("doorPortalId", "")) == "door:town:1,0:3" \
            and not service.snapshot_has_transient_state(fact),
        fact
    )
    body.free()

func test_wait_restore_retains_equivalent_generic_order() -> void:
    var intent := {"kind": TutorialTownSaveContractScript.INTENT_WAIT, "reason": "tutorial_knock_pending"}
    var fixture := make_tutorial(intent, false, {
        "kind": "wait",
        "state": "ACTIVE",
        "reason": "tutorial_knock_pending",
        "submissionReason": "tutorial_knock_pending"
    })
    var tutorial = fixture.tutorial
    var main = fixture.main
    var result: Dictionary = tutorial.reconcile_restored_tutorial_save_contract()
    add_result(
        "pre_ack_restore_retains_equivalent_generic_wait_order",
        bool(result.get("ok", false)) and String(result.get("action", "")) == "retained" and main.npc_system.wait_calls == 0,
        result
    )
    tutorial.free()

func test_home_restore_reissues_once_then_retains() -> void:
    var intent := {"kind": TutorialTownSaveContractScript.INTENT_GO_HOME, "reason": "tutorial_knock_complete"}
    var fixture := make_tutorial(intent)
    var tutorial = fixture.tutorial
    var main = fixture.main
    var first: Dictionary = tutorial.reconcile_restored_tutorial_save_contract()
    var second: Dictionary = tutorial.reconcile_restored_tutorial_save_contract()
    add_result(
        "post_ack_restore_reissues_one_generic_home_order_and_is_idempotent",
        bool(first.get("ok", false)) \
            and String(first.get("action", "")) == "submitted" \
            and bool(second.get("ok", false)) \
            and String(second.get("action", "")) == "retained" \
            and main.npc_system.home_calls == 1,
        {"first": first, "second": second, "homeCalls": main.npc_system.home_calls}
    )
    tutorial.free()

func test_strict_home_restore_resumes_schedule_without_knock_replay() -> void:
    var intent := {"kind": TutorialTownSaveContractScript.INTENT_GO_HOME, "reason": "tutorial_knock_complete"}
    var fixture := make_tutorial(intent, true, {
        "kind": "go_home",
        "state": "ACTIVE",
        "reason": "tutorial_knock_complete",
        "submissionReason": "tutorial_knock_complete"
    })
    var tutorial = fixture.tutorial
    var main = fixture.main
    var first: Dictionary = tutorial.reconcile_restored_tutorial_save_contract()
    var second: Dictionary = tutorial.reconcile_restored_tutorial_save_contract()
    add_result(
        "strict_home_restore_resumes_schedule_without_replaying_wait_or_home",
        bool(first.get("ok", false)) \
            and String(first.get("action", "")) == "resumed_schedule" \
            and bool(second.get("ok", false)) \
            and String(second.get("action", "")) == "retained" \
            and main.npc_system.home_calls == 0 \
            and main.npc_system.wait_calls == 0 \
            and main.npc_system.resume_calls == 1,
        {"first": first, "second": second, "resumeCalls": main.npc_system.resume_calls}
    )
    tutorial.free()

func test_assignment_mismatch_is_reported_without_mutating_regenerated_profile() -> void:
    var intent := {"kind": TutorialTownSaveContractScript.INTENT_WAIT, "reason": "tutorial_knock_pending"}
    var saved_fact := {
        "homeKey": 99,
        "homeStableId": "wrong-home",
        "doorPortalId": "door:wrong"
    }
    var fixture := make_tutorial(intent, false, {
        "kind": "wait",
        "state": "ACTIVE",
        "reason": "tutorial_knock_pending",
        "submissionReason": "tutorial_knock_pending"
    }, saved_fact)
    var tutorial = fixture.tutorial
    var main = fixture.main
    var before := TutorialTownSaveContractScript.assignment_identity(main.npc_system.entry)
    var result: Dictionary = tutorial.reconcile_restored_tutorial_save_contract()
    var after := TutorialTownSaveContractScript.assignment_identity(main.npc_system.entry)
    var validation: Dictionary = result.get("assignmentValidation", {}) if result.get("assignmentValidation", {}) is Dictionary else {}
    add_result(
        "saved_assignment_mismatch_is_reported_without_overwriting_regenerated_profile",
        bool(result.get("ok", false)) \
            and String(validation.get("status", "")) == "mismatch" \
            and before == after \
            and int(after.get("homeKey", -1)) == 3,
        {"result": result, "before": before, "after": after}
    )
    tutorial.free()

func add_result(name: String, passed: bool, details) -> void:
    results.append({"name": name, "passed": passed, "details": details})
    print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func finish() -> void:
    var failures := results.filter(func(result): return not bool(result.get("passed", false)))
    var report := {
        "schemaVersion": 1,
        "runnerId": "tutorial_save_compatibility_contract",
        "testId": "vox_76_tutorial_save_compatibility_contract",
        "finished": true,
        "passed": failures.is_empty(),
        "evidenceLevel": "contract",
        "scope": "Synthetic contract coverage for tutorial save intent, manifest references, assignment validation, and idempotent generic-order restoration. No live gameplay acceptance is claimed.",
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
