extends Node

const MAIN_SCENE := preload("res://scenes/Main.tscn")
const PlaytestSurvivalPolicyScript := preload("res://scripts/testing/PlaytestSurvivalPolicy.gd")
const RenderObservationScript := preload("res://scripts/perf/RuntimeRenderObservation.gd")
const RuntimePerformanceMonitorScript := preload("res://scripts/perf/RuntimePerformanceMonitor.gd")
const NormalRuntimePerformancePassRunnerScript := preload("res://scripts/testing/NormalRuntimePerformancePassRunner.gd")
const DEFAULT_SCENARIOS := ["DayWork", "DuskReturnHome", "MidnightTown", "CrowdedDoorTraffic", "SprintTraversal", "UndergroundTraversal", "AutosaveEnabled", "AutosaveDisabled"]
const GATE5_TOWN_WORKLOAD := "Gate5Town32Npc"
const TARGET_NPC_COUNT := 32
const GATE5_ACCEPTANCE_MIN_WARMUP_FRAMES := 90
const GATE5_RESIDENT_SLOT_INNER_RADIUS_CELLS := 3
const GATE5_RESIDENT_SLOT_MAX_RADIUS_CELLS := 18
const SAMPLE_INTERVAL_USEC := 100000
const UNDERGROUND_SEARCH_RADIUS := 96
const SPRINT_TRAVERSAL_DIRECTION := Vector3(1.0, 0.0, 0.0)
const SPRINT_TRAVERSAL_CELL_DIRECTION := Vector2i(1, 0)
const SPRINT_TRAVERSAL_SPEED_MPS := 15.5
const SPRINT_TRAVERSAL_MIN_MEASURED_DISTANCE := 80.0
const GATE5_NPC_ROUTINE_SECTION_BUDGET_MS := 2.0
const PERFORMANCE_MONITOR_END_FRAME_P99_BUDGET_MS := 0.5
const PERFORMANCE_MONITOR_END_FRAME_MAX_BUDGET_MS := 1.0
const ROUTE_PLAN_CHEAP_STEP_CAP := 48
const ROUTE_PLAN_VALIDATOR_CALL_CAP := 2
const ROUTE_PLAN_DETAILED_TIMING_ENV := "VOXEL_ROUTE_PLAN_DETAILED_TIMING"
const ENGINE_TIMING_MONITOR_SCOPE := "Godot built-in last process frame, last physics frame, and last navigation step durations sampled every 100ms. Built-in monitors may update up to one second late and are not aligned with presentation cadence, rendering, or Main-script samples. They are directional evidence only and must not be subtracted from cadence or used as exact spike attribution."
const CURRENT_NPC_ROUTINE_SECTIONS := [
    "npc_routine_v2_candidates",
    "npc_routine_v2_plan",
    "npc_routine_v2_probe_commit"
]
const NPC_PHYSICS_ATTRIBUTION_SECTIONS := [
    "npc_physics_callback",
    "npc_physics_navigation_changes",
    "npc_physics_tile_build",
    "npc_physics_dirty_regions",
    "npc_physics_traffic",
    "npc_physics_route_service"
]

var scenario := "All"
var seed := "atlas-1492"
var report_path := ""
var progress_path := ""
var run_token := ""
var duration_seconds := 60.0
var watchdog_seconds := 300.0
var warmup_frames_override := -1
var configuration_error := ""
var finished := false
var main: Node = null
var acceptance_mode := false
var runner_started_usec := 0
var render_observation: Node = null
var scenario_retirement_active := false
var pending_exit_code := 0
var measured_player_start := Vector3.INF
var measured_player_end := Vector3.INF
var traversal_direction := SPRINT_TRAVERSAL_DIRECTION
var traversal_cell_direction := SPRINT_TRAVERSAL_CELL_DIRECTION
var sprint_traversal_start_world := Vector3.INF
var underground_traversal_id := ""
var underground_traversal_cell := Vector3i.ZERO
var underground_traversal_start_world := Vector3.INF
var scenario_population_provenance := {}

func _ready() -> void:
    runner_started_usec = Time.get_ticks_usec()
    configure_from_environment()
    render_observation = RenderObservationScript.new()
    add_child(render_observation)
    render_observation.call("set_provenance_provider", Callable(self, "_runtime_cadence_provenance"))
    render_observation.call("start", get_viewport())
    write_progress("start")
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    if float(Time.get_ticks_usec() - runner_started_usec) / 1000000.0 > watchdog_seconds:
        write_report(make_failure_report("runtime performance watchdog exceeded %.1fs" % watchdog_seconds))
        finish(1)

func configure_from_environment() -> void:
    scenario = OS.get_environment("VOXEL_RUNTIME_PERF_SCENARIO")
    if scenario == "":
        scenario = "All"
    acceptance_mode = OS.get_environment("VOXEL_RUNTIME_PERF_ACCEPTANCE").strip_edges() == "1"
    if acceptance_mode and scenario == "All":
        scenario = GATE5_TOWN_WORKLOAD
    seed = OS.get_environment("VOXEL_TEST_SEED")
    if seed == "":
        seed = "atlas-1492"
    report_path = OS.get_environment("VOXEL_RUNTIME_PERF_REPORT")
    if report_path == "":
        report_path = "user://runtime-performance-observation.json"
    progress_path = OS.get_environment("VOXEL_RUNTIME_PERF_PROGRESS")
    run_token = OS.get_environment("VOXEL_RUNTIME_PERF_RUN_TOKEN")
    var duration_value := OS.get_environment("VOXEL_RUNTIME_PERF_DURATION_SECONDS")
    if duration_value != "":
        duration_seconds = maxf(1.0, float(duration_value))
    var warmup_value := OS.get_environment("VOXEL_RUNTIME_PERF_WARMUP_FRAMES").strip_edges()
    if warmup_value != "":
        warmup_frames_override = max(0, int(warmup_value))
    if acceptance_mode and scenario == GATE5_TOWN_WORKLOAD \
            and warmup_frames_override >= 0 and warmup_frames_override < GATE5_ACCEPTANCE_MIN_WARMUP_FRAMES:
        configuration_error = "gate5 acceptance requires at least %d warmup frames; requested %d" % [
            GATE5_ACCEPTANCE_MIN_WARMUP_FRAMES,
            warmup_frames_override
        ]
    var watchdog_value := OS.get_environment("VOXEL_RUNTIME_PERF_WATCHDOG_SECONDS")
    var requested_watchdog := watchdog_seconds
    if watchdog_value != "":
        requested_watchdog = float(watchdog_value)
    watchdog_seconds = maxf(minimum_watchdog_seconds(), requested_watchdog)

func minimum_watchdog_seconds() -> float:
    return duration_seconds * float(scenarios_to_run().size()) + 30.0

func run() -> void:
    if configuration_error != "":
        write_report(make_failure_report(configuration_error))
        finish(1)
        return
    var started_utc := Time.get_datetime_string_from_system(true)
    var results := []
    var failure_count := 0
    for scenario_name in scenarios_to_run():
        write_progress("scenario:%s" % scenario_name)
        var result: Dictionary = await run_scenario(scenario_name)
        if finished:
            return # Startup failure has already written the report and begun shutdown.
        results.append(result)
        if not bool(result.get("passed", false)):
            failure_count += 1
    var report := {
        "schemaVersion": 1,
        "runnerId": "runtime_performance_observation",
        "suite": "runtime_performance_observation",
        "evidenceLevel": "headed_realtime_integration" if acceptance_mode else "diagnostic_integration",
        "startupScope": "ordinary_startup_gate5_32_npc" if acceptance_mode else "ordinary_startup_diagnostic_scenarios",
        "gameplayAcceptance": acceptance_mode,
        "acceptanceMode": acceptance_mode,
        "scenario": scenario,
        "seed": seed,
        "runToken": run_token,
        "durationSecondsPerScenario": duration_seconds,
        "startedUtc": started_utc,
        "finishedUtc": Time.get_datetime_string_from_system(true),
        "resultCount": results.size(),
        "failureCount": failure_count,
        "results": results,
        "metrics": summarize_results(results),
        "artifacts": {
            "report": report_path,
            "progress": progress_path
        }
    }
    write_report(report)
    finish(1 if failure_count > 0 else 0)

func scenarios_to_run() -> Array:
    if scenario == "All":
        return DEFAULT_SCENARIOS.duplicate()
    return [scenario]

func run_scenario(scenario_name: String) -> Dictionary:
    var phase_durations_ms := {}
    var phase_started_usec := Time.get_ticks_usec()
    write_progress("scenario:%s:instantiate" % scenario_name)
    main = MAIN_SCENE.instantiate()
    write_progress("scenario:%s:add_child" % scenario_name)
    add_child(main)
    write_progress("scenario:%s:ordinary_startup" % scenario_name)
    var startup_ready: bool = await main.wait_for_startup_loading_complete(240.0, false)
    phase_durations_ms["startup"] = elapsed_ms(phase_started_usec)
    if finished:
        return {}
    if not startup_ready:
        var report := make_failure_report("startup_not_ready")
        report["startupLoadingFailureResult"] = main.get("startup_loading_failure_result").duplicate(true) if is_instance_valid(main) else {}
        report["failedScenario"] = scenario_name
        write_report(report)
        finish(1)
        return report
    write_progress("scenario:%s:configure" % scenario_name)
    phase_started_usec = Time.get_ticks_usec()
    scenario_population_provenance = await configure_main_for_scenario(scenario_name)
    # Scenario placement is diagnostic; ordinary demand and motion gates remain active.
    main.update_streaming_region_demand()
    var playtest_survival_policy: Dictionary = {
        "required": scenario_uses_night(scenario_name),
        "enabled": false,
        "scope": "not_applicable_day_scenario"
    }
    if scenario_uses_night(scenario_name):
        playtest_survival_policy = PlaytestSurvivalPolicyScript.enable_player_god_mode(
            main,
            "runtime_performance_%s" % scenario_name.to_lower()
        )
    var warmup_count := 90
    if scenario_name == "CrowdedDoorTraffic":
        warmup_count = 240
    elif scenario_name == "SprintTraversal":
        warmup_count = 120
    elif scenario_name == "TerrainMeshingWarmup":
        warmup_count = 30
    if warmup_frames_override >= 0:
        warmup_count = warmup_frames_override
    phase_durations_ms["configure"] = elapsed_ms(phase_started_usec)
    if is_instance_valid(render_observation):
        render_observation.set("phase", "%s:warmup" % scenario_name)
    write_progress("scenario:%s:warmup:%d" % [scenario_name, warmup_count])
    phase_started_usec = Time.get_ticks_usec()
    await warmup_frames(warmup_count)
    phase_durations_ms["warmup"] = elapsed_ms(phase_started_usec)
    if finished:
        return {}
    if acceptance_mode and scenario_name == GATE5_TOWN_WORKLOAD:
        var post_warmup_actor_audit := current_gate5_actor_provenance_audit()
        scenario_population_provenance["postWarmupActorAudit"] = post_warmup_actor_audit
        if int(post_warmup_actor_audit.get("physicalSimulationActorCount", 0)) < TARGET_NPC_COUNT:
            scenario_population_provenance["ok"] = false
            scenario_population_provenance["reason"] = "source_backed_population_cannot_supply_32_physical_simulation_actors"
    write_progress("scenario:%s:prime_navigation" % scenario_name)
    phase_started_usec = Time.get_ticks_usec()
    prime_navigation_snapshot()
    phase_durations_ms["primeNavigation"] = elapsed_ms(phase_started_usec)
    write_progress("scenario:%s:measure" % scenario_name)
    reset_performance_monitor()
    begin_measurement_for_scenario(scenario_name)
    measured_player_start = measured_player_position()
    var samples := []
    var frame := 0
    var measurement_started_usec := Time.get_ticks_usec()
    var measurement_deadline_usec := measurement_started_usec + int(duration_seconds * 1000000.0)
    var measurement_process_frame_start := Engine.get_process_frames()
    var measurement_physics_frame_start := Engine.get_physics_frames()
    var next_sample_usec := measurement_started_usec
    var next_overlap_sample_usec := measurement_started_usec
    var overlap_tracker := {"sampleCount": 0, "pairs": {}}
    var overlap_sampling_overhead_ms: Array[float] = []
    var sampling_overhead_ms: Array[float] = []
    var engine_process_monitor_ms: Array[float] = []
    var engine_physics_monitor_ms: Array[float] = []
    var engine_navigation_monitor_ms: Array[float] = []
    var engine_timing_sampling_overhead_ms: Array[float] = []
    var active_npc_count_min := 2147483647
    var active_npc_count_max := 0
    var active_npc_count_observations := 0
    var phase_label := "%s:measure" % scenario_name
    if is_instance_valid(render_observation):
        render_observation.set("phase", phase_label)
    while Time.get_ticks_usec() < measurement_deadline_usec:
        if frame < 8 or frame % 30 == 0:
            write_progress("scenario:%s:measure_frame:%d:update" % [scenario_name, frame])
        var measurement_elapsed_seconds := float(Time.get_ticks_usec() - measurement_started_usec) / 1000000.0
        update_scenario_frame(scenario_name, measurement_elapsed_seconds)
        if frame < 8 or frame % 30 == 0:
            write_progress("scenario:%s:measure_frame:%d:await" % [scenario_name, frame])
        await get_tree().process_frame
        if finished:
            return {}
        if frame < 8 or frame % 30 == 0:
            write_progress("scenario:%s:measure_frame:%d:sample" % [scenario_name, frame])
        var active_count := active_npc_count()
        active_npc_count_min = mini(active_npc_count_min, active_count)
        active_npc_count_max = maxi(active_npc_count_max, active_count)
        active_npc_count_observations += 1
        var sample_now_usec := Time.get_ticks_usec()
        if acceptance_mode and scenario_name == GATE5_TOWN_WORKLOAD \
                and sample_now_usec >= next_overlap_sample_usec:
            var overlap_sample_started_usec := Time.get_ticks_usec()
            update_overlap_persistence_tracker(overlap_tracker, current_gate5_capsule_overlap_audit(), sample_now_usec)
            overlap_sampling_overhead_ms.append(float(Time.get_ticks_usec() - overlap_sample_started_usec) / 1000.0)
            next_overlap_sample_usec = sample_now_usec + SAMPLE_INTERVAL_USEC
        if sample_now_usec >= next_sample_usec and main != null and main.has_method("debug_performance_state"):
            var sample_started_usec := Time.get_ticks_usec()
            append_engine_timing_monitor_sample(
                engine_process_monitor_ms,
                engine_physics_monitor_ms,
                engine_navigation_monitor_ms
            )
            engine_timing_sampling_overhead_ms.append(
                float(Time.get_ticks_usec() - sample_started_usec) / 1000.0
            )
            sample_started_usec = Time.get_ticks_usec()
            samples.append(main.debug_performance_state(false, false))
            sampling_overhead_ms.append(float(Time.get_ticks_usec() - sample_started_usec) / 1000.0)
            next_sample_usec = sample_now_usec + SAMPLE_INTERVAL_USEC
        frame += 1
    phase_durations_ms["measurement"] = elapsed_ms(measurement_started_usec)
    if acceptance_mode and scenario_name == GATE5_TOWN_WORKLOAD:
        var post_measurement_actor_audit := current_gate5_actor_provenance_audit()
        var overlap_persistence_audit := summarize_overlap_persistence_tracker(overlap_tracker)
        overlap_persistence_audit["observerOverhead"] = duration_distribution(overlap_sampling_overhead_ms)
        scenario_population_provenance["postMeasurementActorAudit"] = post_measurement_actor_audit
        scenario_population_provenance["overlapPersistenceAudit"] = overlap_persistence_audit
        if not bool(post_measurement_actor_audit.get("jobRouteAudit", {}).get("ok", false)):
            scenario_population_provenance["ok"] = false
            scenario_population_provenance["reason"] = "no_active_or_completed_source_backed_job_route"
        elif int(post_measurement_actor_audit.get("physicalSimulationActorCount", 0)) < TARGET_NPC_COUNT:
            scenario_population_provenance["ok"] = false
            scenario_population_provenance["reason"] = "source_backed_population_dropped_below_32_physical_simulation_actors"
        elif not bool(overlap_persistence_audit.get("ok", false)):
            scenario_population_provenance["ok"] = false
            scenario_population_provenance["reason"] = \
                "invalid_source_backed_resident_collider_authority" \
                if int(overlap_persistence_audit.get("invalidColliderSamples", 0)) > 0 \
                else "persistent_source_backed_resident_capsule_overlap"
    if is_instance_valid(render_observation):
        render_observation.set("phase", "%s:retire" % scenario_name)
    measured_player_end = measured_player_position()
    var metrics := summarize_samples(samples)
    append_scenario_metrics(metrics, scenario_name)
    var render_summary: Dictionary = render_observation.call("summary") if is_instance_valid(render_observation) else {}
    var phase_summary := render_phase_summary(render_summary, phase_label)
    var periodic_spikes := periodic_spike_summary(
        phase_summary.get("cadenceSpikes", render_summary.get("cadenceSpikes", [])), phase_label)
    metrics["presentationCadence"] = phase_summary.get("cadence", {})
    metrics["presentationRender"] = phase_summary.duplicate(true)
    metrics["renderObservation"] = render_observation_report_summary(render_summary, phase_label)
    metrics["presentationPhase"] = phase_label
    metrics["presentationPeriodicSpikes"] = periodic_spikes
    metrics["presentationObserverAvailable"] = bool(render_summary.get("available", false))
    metrics["activeNpcCountMin"] = 0 if active_npc_count_min == 2147483647 else active_npc_count_min
    metrics["activeNpcCountMax"] = active_npc_count_max
    metrics["activeNpcCountObservations"] = active_npc_count_observations
    metrics["measuredProcessFrames"] = frame
    metrics["engineFrameDeltas"] = {
        "processFrames": Engine.get_process_frames() - measurement_process_frame_start,
        "physicsFrames": Engine.get_physics_frames() - measurement_physics_frame_start
    }
    metrics["samplingOverhead"] = duration_distribution(sampling_overhead_ms)
    metrics["engineTimingMonitors"] = engine_timing_monitor_summary(
        engine_process_monitor_ms,
        engine_physics_monitor_ms,
        engine_navigation_monitor_ms,
        engine_timing_sampling_overhead_ms
    )
    var measured_monitor = main.get("runtime_perf_monitor") if main != null else null
    metrics["sectionPercentiles"] = measured_monitor.section_percentiles() \
        if measured_monitor != null and measured_monitor.has_method("section_percentiles") else {}
    var measured_monitor_summary: Dictionary = measured_monitor.summary() \
        if measured_monitor != null and measured_monitor.has_method("summary") else {}
    metrics["sectionMaxima"] = measured_monitor_summary.get("sectionMaxMs", {}).duplicate(true) \
        if measured_monitor_summary.get("sectionMaxMs", {}) is Dictionary else {}
    metrics["routePlanCompliance"] = route_plan_compliance_summary(
        metrics.get("sectionPercentiles", {}),
        measured_monitor_summary.get("sectionMaxMs", {}) \
            if measured_monitor_summary.get("sectionMaxMs", {}) is Dictionary else {},
        measured_monitor_summary.get("maxGauges", {}) \
            if measured_monitor_summary.get("maxGauges", {}) is Dictionary else {},
        OS.get_environment(ROUTE_PLAN_DETAILED_TIMING_ENV).strip_edges() == "1"
    )
    metrics["npcPhysicsAttribution"] = npc_physics_attribution_summary(
        metrics.get("sectionPercentiles", {}),
        measured_monitor_summary.get("sectionMaxMs", {}) \
            if measured_monitor_summary.get("sectionMaxMs", {}) is Dictionary else {},
        measured_monitor_summary.get("counters", {}) \
            if measured_monitor_summary.get("counters", {}) is Dictionary else {},
        measured_monitor_summary.get("gauges", {}) \
            if measured_monitor_summary.get("gauges", {}) is Dictionary else {},
        measured_monitor_summary.get("maxGauges", {}) \
            if measured_monitor_summary.get("maxGauges", {}) is Dictionary else {}
    )
    metrics["performanceMonitorEndFrameOverhead"] = {
        "retainedDistribution": metrics.get("sectionPercentiles", {}).get(
            "performance_monitor_end_frame", {}),
        "measurementMaxMs": metrics.get("sectionMaxima", {}).get(
            "performance_monitor_end_frame", null),
        "scope": "p99 is calculated from the last 900 retained samples; maximum is cumulative across the whole measurement window."
    }
    metrics["performanceMonitorEndFrameThresholds"] = {
        "p99Ms": PERFORMANCE_MONITOR_END_FRAME_P99_BUDGET_MS,
        "maxMs": PERFORMANCE_MONITOR_END_FRAME_MAX_BUDGET_MS
    }
    metrics["warmupFrameCount"] = warmup_count
    metrics["populationProvenance"] = scenario_population_provenance.duplicate(true)
    metrics["phaseDurationsMs"] = phase_durations_ms.duplicate(true)
    metrics["presentationThresholds"] = {
        "p99TargetMs": 16.7,
        "p99ToleranceMs": 22.0,
        "maxMs": 33.0,
        "over33ms": 0,
        "periodicSpikeWindowSeconds": [2.0, 7.0],
        "periodicSpikePairs": 0
    }
    metrics["presentationTargetMet"] = phase_summary.has("cadence") \
        and phase_summary.get("cadence", {}).get("p99Ms", null) != null \
        and float(phase_summary.get("cadence", {}).get("p99Ms", 0.0)) <= 16.7
    var failures: Array[String] = performance_failures(metrics)
    if not bool(scenario_population_provenance.get("ok", false)):
        failures.append("scenario population preparation failed: %s" % String(
            scenario_population_provenance.get("reason", "population_provenance_unavailable")
        ))
    if acceptance_mode:
        failures.append_array(gate5_presentation_failures(
            metrics.get("presentationCadence", {}),
            periodic_spikes,
            bool(metrics.get("presentationObserverAvailable", false)),
            int(metrics.get("activeNpcCountMin", 0))
        ))
    if scenario_uses_night(scenario_name) and not bool(playtest_survival_policy.get("enabled", false)):
        failures.append("night scenario player godmode was not enabled")
    if scenario_name == "SprintTraversal" and float(metrics.get("playerTravelDistance", 0.0)) < SPRINT_TRAVERSAL_MIN_MEASURED_DISTANCE:
        failures.append("sprint traversal did not move far enough to exercise streaming")
    if is_instance_valid(main):
        scenario_retirement_active = true
        write_progress("scenario:%s:retiring" % scenario_name)
        phase_started_usec = Time.get_ticks_usec()
        main.set_process(false)
        main.set_process_unhandled_input(false)
        main.set_physics_process(false)
        main.set_registered_npc_physics_enabled(false)
        var player_body := main.get("player") as CharacterBody3D
        if is_instance_valid(player_body):
            player_body.velocity = Vector3.ZERO
            player_body.set_physics_process(false)
        # Reuse production drains without quitting the process between scenarios.
        await main.wait_for_async_save_before_quit()
        await main.wait_for_terrain_workers_before_quit()
        await main.wait_for_npc_navigation_before_quit()
        var owned_work := owned_work_census()
        metrics["ownedWorkAfterDrain"] = owned_work
        if acceptance_mode and not bool(owned_work.get("zeroOwnedWork", false)):
            failures.append("owned work remained after the production shutdown drains")
        main.queue_free()
        main = null
        await get_tree().process_frame
        phase_durations_ms["retirement"] = elapsed_ms(phase_started_usec)
        metrics["phaseDurationsMs"] = phase_durations_ms.duplicate(true)
        scenario_retirement_active = false
        if finished:
            get_tree().quit(pending_exit_code)
            return {}
    var cadence: Dictionary = metrics.get("presentationCadence", {})
    var passed := not samples.is_empty() and failures.is_empty()
    var details := "samples=%d cadenceP99=%s cadenceMax=%s cadenceOver33=%d activeNpcMin=%d mainP99=%.2f mainMax=%.2f routeMax=%.2f navMax=%.2f jobMax=%.2f saveMax=%.2f failures=%d" % [
        samples.size(),
        str(cadence.get("p99Ms", null)),
        str(cadence.get("maxMs", null)),
        int(cadence.get("over33ms", 0)),
        int(metrics.get("activeNpcCountMin", 0)),
        float(metrics.get("frameP99Ms", 0.0)),
        float(metrics.get("frameMaxMs", 0.0)),
        float(metrics.get("maxRoutePlanMs", 0.0)),
        float(metrics.get("maxNavSnapshotMs", 0.0)),
        float(metrics.get("maxJobScanMs", 0.0)),
        float(metrics.get("maxAutosaveMs", 0.0)),
        failures.size()
    ]
    return {
        "id": "runtime_perf_%s" % scenario_name.to_lower(),
        "scenario": scenario_name,
        "seed": seed,
        "passed": passed,
        "gameplayAcceptance": acceptance_mode,
        "durationSeconds": duration_seconds,
        "details": details,
        "metrics": metrics,
        "failures": failures,
        "playtestSurvivalPolicy": playtest_survival_policy,
        "sampleCount": samples.size()
    }

func scenario_uses_night(scenario_name: String) -> bool:
    return scenario_name in ["DuskReturnHome", "MidnightTown"]

func configure_main_for_scenario(scenario_name: String) -> Dictionary:
    if main == null:
        return {"ok": false, "reason": "main_unavailable"}
    if main.get("tutorial_system") != null:
        var tutorial = main.get("tutorial_system")
        tutorial.set("intro_repair_active", false)
        tutorial.set("intro_bed_used", true)
        tutorial.set("final_night_active", false)
        tutorial.set("final_night_complete", true)
    if scenario_name == "DuskReturnHome":
        main.set("time_of_day", 0.52)
    elif scenario_name == "MidnightTown":
        main.set("time_of_day", 0.75)
    else:
        main.set("time_of_day", 0.25)
    main.set("autosave_enabled", scenario_name != "AutosaveDisabled")
    main.set("autosave_interval_seconds", 60.0)
    if scenario_name in ["AutosaveEnabled", GATE5_TOWN_WORKLOAD] and main.has_method("mark_world_dirty"):
        main.set("autosave_elapsed", 59.5)
        main.mark_world_dirty("performance_observation")
    if main.get("player") != null:
        main.get("player").set("automated_input", true)
        main.get("player").set("automated_sprint", false)
        main.get("player").set("automated_move", Vector3.ZERO)
    traversal_direction = SPRINT_TRAVERSAL_DIRECTION
    traversal_cell_direction = SPRINT_TRAVERSAL_CELL_DIRECTION
    sprint_traversal_start_world = Vector3.INF
    underground_traversal_id = ""
    underground_traversal_cell = Vector3i.ZERO
    underground_traversal_start_world = Vector3.INF
    var population_provenance: Dictionary
    if acceptance_mode and scenario_name == GATE5_TOWN_WORKLOAD:
        population_provenance = await prepare_gate5_source_backed_town_workload(TARGET_NPC_COUNT)
    else:
        population_provenance = force_npc_count_diagnostic(TARGET_NPC_COUNT)
    if scenario_name == "CrowdedDoorTraffic":
        setup_crowded_door_traffic()
    elif scenario_name == "SprintTraversal":
        setup_sprint_traversal()
    elif scenario_name == "UndergroundTraversal":
        setup_underground_traversal()
    elif scenario_name == "TerrainMeshingWarmup":
        setup_terrain_meshing_warmup()
    return population_provenance

func setup_sprint_traversal() -> void:
    if main == null:
        return
    var player_body := main.get("player") as CharacterBody3D
    if player_body == null:
        return
    var start_cell := sprint_traversal_start_cell()
    var start_y := float(main.call("surface_y_at_cell", Vector3i(start_cell.x, 0, start_cell.y))) + 0.08
    sprint_traversal_start_world = Vector3(float(start_cell.x) * 1.35, start_y, float(start_cell.y) * 1.35)
    player_body.global_position = sprint_traversal_start_world
    player_body.velocity = Vector3.ZERO
    player_body.set("automated_input", true)
    player_body.set("automated_sprint", true)
    player_body.set("automated_move", traversal_direction)
    if main.has_method("update_chunks"):
        main.call("update_chunks", false)

func setup_underground_traversal() -> void:
    if main == null:
        return
    var player_body := main.get("player") as CharacterBody3D
    var world_generation = main.get("world_generation_system")
    if player_body == null or world_generation == null or not world_generation.has_method("find_underground_air_sample"):
        setup_sprint_traversal()
        return
    main.set("force_underground_volume_debug", false)
    main.set("force_underground_volume_fine_focus", false)
    var found: Dictionary = world_generation.call("find_underground_air_sample", UNDERGROUND_SEARCH_RADIUS, 4, 30)
    if found.is_empty():
        setup_sprint_traversal()
        return
    underground_traversal_id = String(found.get("id", ""))
    underground_traversal_cell = found.get("cell", Vector3i.ZERO)
    traversal_cell_direction = Vector2i(1, 0)
    traversal_direction = Vector3(1.0, 0.0, 0.0)
    var sample_position: Vector3 = found.get("position", Vector3.ZERO)
    underground_traversal_start_world = sample_position + Vector3(0.0, 1.35 * 0.65, 0.0)
    player_body.global_position = underground_traversal_start_world
    player_body.velocity = Vector3.ZERO
    player_body.set("automated_input", true)
    player_body.set("automated_sprint", true)
    player_body.set("automated_move", traversal_direction)
    if main.has_method("update_chunks"):
        main.call("update_chunks", false)

func setup_terrain_meshing_warmup() -> void:
    if main == null:
        return
    var player_body := main.get("player") as CharacterBody3D
    var world_generation = main.get("world_generation_system")
    if player_body == null or world_generation == null or not world_generation.has_method("find_underground_air_sample"):
        return
    main.set("force_underground_volume_debug", false)
    main.set("force_underground_volume_fine_focus", false)
    var found: Dictionary = world_generation.call("find_underground_air_sample", UNDERGROUND_SEARCH_RADIUS, 4, 30)
    if found.is_empty():
        return
    underground_traversal_id = String(found.get("id", ""))
    underground_traversal_cell = found.get("cell", Vector3i.ZERO)
    var sample_position: Vector3 = found.get("position", Vector3.ZERO)
    underground_traversal_start_world = sample_position + Vector3(0.0, 1.35 * 0.65, 0.0)
    player_body.global_position = underground_traversal_start_world
    player_body.velocity = Vector3.ZERO
    player_body.set("automated_input", true)
    player_body.set("automated_sprint", false)
    player_body.set("automated_move", Vector3.ZERO)
    if main.has_method("update_chunks"):
        main.call("update_chunks", false)

func begin_measurement_for_scenario(scenario_name: String) -> void:
    if scenario_name == "TerrainMeshingWarmup":
        queue_terrain_meshing_warmup_jobs()

func queue_terrain_meshing_warmup_jobs() -> int:
    if main == null or not main.has_method("world_to_chunk") or not main.has_method("request_chunk_terrain_mesh_assets"):
        return 0
    var player_body := main.get("player") as Node3D
    if player_body == null:
        return 0
    var chunks_value = main.get("chunks")
    if not (chunks_value is Dictionary):
        return 0
    var chunks: Dictionary = chunks_value
    var center: Vector2i = main.call("world_to_chunk", player_body.global_position.x, player_body.global_position.z)
    var queued := 0
    for dz in range(-1, 2):
        for dx in range(-1, 2):
            var key := center + Vector2i(dx, dz)
            if not chunks.has(key):
                continue
            if main.has_method("chunk_should_queue_terrain_meshing") and not bool(main.call("chunk_should_queue_terrain_meshing", key.x, key.y)):
                continue
            if main.has_method("invalidate_chunk_asset_cache"):
                main.call("invalidate_chunk_asset_cache", key)
            if bool(main.call("request_chunk_terrain_mesh_assets", key, true, 20)):
                queued += 1
    return queued

func sprint_traversal_start_cell() -> Vector2i:
    var player_body := main.get("player") as Node3D
    var origin := player_body.global_position if player_body != null else Vector3.ZERO
    var origin_cell := Vector2i(int(main.call("world_to_cell", origin.x)), int(main.call("world_to_cell", origin.z)))
    var offsets: Array[Vector2i] = [
        Vector2i(96, 24),
        Vector2i(128, -32),
        Vector2i(160, 48),
        Vector2i(192, -64),
        Vector2i(224, 80),
        Vector2i(256, -96)
    ]
    for offset in offsets:
        var candidate: Vector2i = origin_cell + offset
        if sprint_traversal_lane_ok(candidate):
            return candidate
    return origin_cell + offsets[0]

func sprint_traversal_lane_ok(start_cell: Vector2i) -> bool:
    var previous_height: float = INF
    for step in range(48):
        var cell: Vector2i = start_cell + SPRINT_TRAVERSAL_CELL_DIRECTION * step
        var height := float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))
        if height < 1.35 * 3.0 or height > 92.0:
            return false
        var biome := String(main.call("surface_biome_at_cell", Vector3i(cell.x, 0, cell.y)))
        if biome in ["ocean", "beach", "town"]:
            return false
        if previous_height != INF and absf(height - previous_height) > 1.35 * 1.15:
            return false
        previous_height = height
    return true

func update_scenario_frame(scenario_name: String, measurement_elapsed_seconds: float) -> void:
    if not (scenario_name in ["SprintTraversal", "UndergroundTraversal", "TerrainMeshingWarmup"]) or main == null:
        return
    var player_body := main.get("player") as CharacterBody3D
    if player_body == null:
        return
    if scenario_name == "TerrainMeshingWarmup":
        player_body.velocity = Vector3.ZERO
        player_body.set("automated_input", true)
        player_body.set("automated_sprint", false)
        player_body.set("automated_move", Vector3.ZERO)
        return
    if scenario_name == "SprintTraversal" and sprint_traversal_start_world != Vector3.INF:
        var sprint_distance := SPRINT_TRAVERSAL_SPEED_MPS * measurement_elapsed_seconds
        var sprint_position := sprint_traversal_start_world + traversal_direction * sprint_distance
        var sprint_cell_x := int(main.call("world_to_cell", sprint_position.x))
        var sprint_cell_z := int(main.call("world_to_cell", sprint_position.z))
        sprint_position.y = float(main.call("surface_y_at_cell", Vector3i(sprint_cell_x, 0, sprint_cell_z))) + 0.08
        player_body.global_position = sprint_position
        player_body.velocity = traversal_direction * SPRINT_TRAVERSAL_SPEED_MPS
        player_body.set("terrain_grounded", true)
    if scenario_name == "UndergroundTraversal" and underground_traversal_start_world != Vector3.INF:
        var distance := SPRINT_TRAVERSAL_SPEED_MPS * measurement_elapsed_seconds
        var position := underground_traversal_start_world + traversal_direction * distance
        player_body.global_position = position
        player_body.velocity = Vector3.ZERO
        player_body.set("terrain_grounded", true)
    player_body.set("automated_input", true)
    player_body.set("automated_sprint", true)
    player_body.set("automated_move", traversal_direction)

func measured_player_position() -> Vector3:
    if main == null:
        return Vector3.INF
    var player_body := main.get("player") as Node3D
    if player_body == null:
        return Vector3.INF
    return player_body.global_position

func append_scenario_metrics(metrics: Dictionary, scenario_name: String) -> void:
    if not (scenario_name in ["SprintTraversal", "UndergroundTraversal", "TerrainMeshingWarmup"]):
        return
    if measured_player_start == Vector3.INF or measured_player_end == Vector3.INF:
        metrics["playerTravelDistance"] = 0.0
        return
    var delta := measured_player_end - measured_player_start
    delta.y = 0.0
    metrics["playerTravelDistance"] = delta.length()
    metrics["playerStart"] = [measured_player_start.x, measured_player_start.y, measured_player_start.z]
    metrics["playerEnd"] = [measured_player_end.x, measured_player_end.y, measured_player_end.z]
    if scenario_name == "UndergroundTraversal":
        metrics["undergroundSampleId"] = underground_traversal_id
        metrics["undergroundCell"] = [underground_traversal_cell.x, underground_traversal_cell.y, underground_traversal_cell.z]
    elif scenario_name == "TerrainMeshingWarmup":
        metrics["undergroundSampleId"] = underground_traversal_id
        metrics["undergroundCell"] = [underground_traversal_cell.x, underground_traversal_cell.y, underground_traversal_cell.z]

func setup_crowded_door_traffic() -> void:
    if main == null:
        return
    var npc_system = main.get("npc_system")
    var player_body := main.get("player") as Node3D
    if npc_system == null or player_body == null:
        return
    var center := Vector2i(main.call("world_to_cell", player_body.global_position.x), main.call("world_to_cell", player_body.global_position.z)) + Vector2i(22, 0)
    var base_height: float = main.call("surface_y_at_cell", Vector3i(center.x, 0, center.y))
    var wall_y := base_height + 1.35 * 0.48
    var wall_cell_y := floori(wall_y / 1.35) + 1
    var door_cell := Vector3i(center.x, wall_cell_y, center.y)
    for dz in range(-4, 5):
        var cell := Vector3i(center.x, wall_cell_y, center.y + dz)
        main.call("create_block", cell, "door" if cell == door_cell else "stoneBlock", { "world_y": wall_y })
    var entries: Array = npc_system.get("npcs")
    for i in range(entries.size()):
        var entry: Dictionary = entries[i]
        var body := entry.get("body") as CharacterBody3D
        if body == null or not is_instance_valid(body):
            continue
        var side := -1 if i % 2 == 0 else 1
        var lane := int(i / 2) % 8 - 4
        var start_cell := center + Vector2i(side * 6, lane)
        var target_cell := center + Vector2i(-side * 6, -lane)
        var start_position := Vector3(float(start_cell.x) * 1.35, float(main.call("surface_y_at_cell", Vector3i(start_cell.x, 0, start_cell.y))) + 0.04, float(start_cell.y) * 1.35)
        var target_position := Vector3(float(target_cell.x) * 1.35, float(main.call("surface_y_at_cell", Vector3i(target_cell.x, 0, target_cell.y))) + 0.04, float(target_cell.y) * 1.35)
        npc_system.safe_place_npc(body, start_position, entry.get("motorProfile"), "runtime_perf_crowded_door")
        entry["townCenter"] = center
        entry["townRadius"] = 30
        entry["homeCell"] = start_cell
        entry["porchCell"] = start_cell
        entry["guardCell"] = center + Vector2i(0, lane)
        if npc_system.has_method("set_scripted_target"):
            npc_system.set_scripted_target(body, target_position, true, true)


static func audit_town_home_sources(records_by_town_value: Variant, target_count: int) -> Dictionary:
    var failures: Array[String] = []
    var records_by_town: Dictionary = records_by_town_value if records_by_town_value is Dictionary else {}
    if not (records_by_town_value is Dictionary):
        failures.append("town_home_records_snapshot was not a dictionary")
    var town_keys: Array[String] = []
    for town_key_value in records_by_town.keys():
        town_keys.append(String(town_key_value))
    town_keys.sort()
    var actor_ids := {}
    var stable_home_ids := {}
    var door_portal_ids := {}
    var valid_records_by_id := {}
    var counts_by_town := {}
    var available_record_count := 0
    for town_key in town_keys:
        var records_value = records_by_town.get(town_key, [])
        if not (records_value is Array):
            failures.append("town %s records were not an array" % town_key)
            continue
        var records: Array = records_value
        counts_by_town[town_key] = records.size()
        available_record_count += records.size()
        for index in range(records.size()):
            if not (records[index] is Dictionary):
                failures.append("town %s record %d was not a dictionary" % [town_key, index])
                continue
            var record: Dictionary = records[index]
            var actor_id := String(record.get("id", "")).strip_edges()
            var stable_home_id := String(record.get("stableId", "")).strip_edges()
            var record_town_key := String(record.get("townKey", "")).strip_edges()
            var door_portal_id := String(record.get("doorPortalId", "")).strip_edges()
            var record_valid := true
            if town_key.is_empty() or record_town_key != town_key:
                failures.append("record %s did not preserve its snapshot town source" % actor_id)
                record_valid = false
            if actor_id.is_empty() or actor_ids.has(actor_id):
                failures.append("record actor id was missing or duplicated: %s" % actor_id)
                record_valid = false
            if stable_home_id.is_empty() or stable_home_ids.has(stable_home_id):
                failures.append("record stable home id was missing or duplicated: %s" % stable_home_id)
                record_valid = false
            if door_portal_id.is_empty() or door_portal_ids.has(door_portal_id):
                failures.append("record door portal id was missing or duplicated: %s" % door_portal_id)
                record_valid = false
            var home_cell_value = record.get("homeCell")
            var porch_cell_value = record.get("porchCell")
            var door_cell_value = record.get("doorCell")
            var interior_min_value = record.get("interiorMinCell")
            var interior_max_value = record.get("interiorMaxCell")
            if not (home_cell_value is Vector2i and porch_cell_value is Vector2i \
                    and door_cell_value is Vector2i and interior_min_value is Vector2i \
                    and interior_max_value is Vector2i):
                failures.append("record %s lacked typed home/porch/door/interior cells" % actor_id)
                record_valid = false
            else:
                var home_cell: Vector2i = home_cell_value
                var interior_min: Vector2i = interior_min_value
                var interior_max: Vector2i = interior_max_value
                if home_cell.x < interior_min.x or home_cell.y < interior_min.y \
                        or home_cell.x > interior_max.x or home_cell.y > interior_max.y:
                    failures.append("record %s home cell was outside its production interior" % actor_id)
                    record_valid = false
            if not actor_id.is_empty():
                actor_ids[actor_id] = true
            if not stable_home_id.is_empty():
                stable_home_ids[stable_home_id] = true
            if not door_portal_id.is_empty():
                door_portal_ids[door_portal_id] = true
            if record_valid:
                valid_records_by_id[actor_id] = record.duplicate(true)
    var valid_record_count := valid_records_by_id.size()
    if valid_record_count < target_count:
        failures.append("only %d source-backed town homes were available; %d required" % [valid_record_count, target_count])
    return {
        "ok": failures.is_empty(),
        "targetCount": target_count,
        "townCount": town_keys.size(),
        "townKeys": town_keys,
        "countsByTown": counts_by_town,
        "availableRecordCount": available_record_count,
        "validRecordCount": valid_record_count,
        "uniqueActorIdCount": actor_ids.size(),
        "uniqueStableHomeIdCount": stable_home_ids.size(),
        "uniqueDoorPortalIdCount": door_portal_ids.size(),
        "recordsByActorId": valid_records_by_id,
        "failures": failures
    }


static func select_source_backed_town(records_by_town_value: Variant, observer_cell: Vector2i) -> Dictionary:
    if not (records_by_town_value is Dictionary):
        return {"ok": false, "reason": "town_home_records_snapshot_was_not_dictionary"}
    var candidates: Array[Dictionary] = []
    var rejected := {}
    var records_by_town: Dictionary = records_by_town_value
    var town_keys: Array[String] = []
    for town_key_value in records_by_town.keys(): town_keys.append(String(town_key_value))
    town_keys.sort()
    for town_key in town_keys:
        var records_value = records_by_town.get(town_key, [])
        var records: Array = records_value if records_value is Array else []
        var audit := audit_town_home_sources({town_key: records}, 1)
        if not bool(audit.get("ok", false)) or records.is_empty():
            rejected[town_key] = audit.get("failures", [])
            continue
        var first: Dictionary = records[0]
        var center: Vector2i = first.get("townCenter", first.get("homeCell", Vector2i.ZERO))
        candidates.append({
            "townKey": town_key,
            "records": records.duplicate(true),
            "sourceAudit": audit,
            "distanceSquared": (center - observer_cell).length_squared()
        })
    candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        var a_distance := int(a.get("distanceSquared", 0))
        var b_distance := int(b.get("distanceSquared", 0))
        return String(a.get("townKey", "")) < String(b.get("townKey", "")) if a_distance == b_distance \
            else a_distance < b_distance
    )
    if candidates.is_empty():
        return {"ok": false, "reason": "no_complete_source_backed_town", "rejectedTowns": rejected}
    var selected: Dictionary = candidates[0]
    selected["ok"] = true
    selected["rejectedTowns"] = rejected
    selected["candidateTownCount"] = candidates.size()
    return selected


static func shared_resident_record(source_record: Dictionary, town_key: String, resident_index: int) -> Dictionary:
    var result := source_record.duplicate(true)
    result["id"] = "%s:resident:%02d" % [town_key, resident_index]
    result["gate5SourceHomeRecordId"] = String(source_record.get("id", ""))
    result["gate5ResidentIndex"] = resident_index
    return result


static func resident_street_slot_cells(source_record: Dictionary) -> Array[Vector2i]:
    var center: Vector2i = source_record.get("townCenter", Vector2i.ZERO)
    var radius := mini(GATE5_RESIDENT_SLOT_MAX_RADIUS_CELLS,
        maxi(GATE5_RESIDENT_SLOT_INNER_RADIUS_CELLS, int(source_record.get("townRadius", 18)) - 2))
    var result: Array[Vector2i] = []
    for distance in range(GATE5_RESIDENT_SLOT_INNER_RADIUS_CELLS, radius + 1):
        result.append(center + Vector2i(distance, 0))
        result.append(center + Vector2i(-distance, 0))
        result.append(center + Vector2i(0, distance))
        result.append(center + Vector2i(0, -distance))
    return result


static func audit_spawned_town_actor_provenance(entries_value: Variant, source_records_value: Variant,
        town_key: String, target_count: int, require_live_bodies := false) -> Dictionary:
    var failures: Array[String] = []
    var entries: Array = entries_value if entries_value is Array else []
    var source_records: Array = source_records_value if source_records_value is Array else []
    var source_by_home_id := {}
    var source_by_record_id := {}
    for source_value in source_records:
        if not (source_value is Dictionary): continue
        var source: Dictionary = source_value
        source_by_home_id[String(source.get("stableId", ""))] = source
        source_by_record_id[String(source.get("id", ""))] = source
    var matched_actor_ids := {}
    var matched_home_ids := {}
    var matched_door_ids := {}
    var live_actor_count := 0
    var physical_simulation_actor_count := 0
    var simulation_lod_counts := {}
    for entry_value in entries:
        if not (entry_value is Dictionary): continue
        var entry: Dictionary = entry_value
        if String(entry.get("townKey", "")) != town_key: continue
        var actor_id := String(entry.get("id", "")).strip_edges()
        var home_id := String(entry.get("homeStableId", "")).strip_edges()
        var source_record_id := String(entry.get("gate5SourceHomeRecordId", "")).strip_edges()
        var source: Dictionary = source_by_record_id.get(source_record_id, {}) \
            if not source_record_id.is_empty() else source_by_home_id.get(home_id, {})
        if source.is_empty():
            failures.append("actor %s did not map to a real selected-town home record" % actor_id)
            continue
        if actor_id.is_empty() or matched_actor_ids.has(actor_id):
            failures.append("spawned resident actor id was missing or duplicated: %s" % actor_id)
            continue
        if home_id != String(source.get("stableId", "")) \
                or String(entry.get("doorPortalId", "")) != String(source.get("doorPortalId", "")) \
                or entry.get("homeCell") != source.get("homeCell") \
                or entry.get("porchCell") != source.get("porchCell") \
                or entry.get("doorCell") != source.get("doorCell") \
                or entry.get("interiorMinCell") != source.get("interiorMinCell") \
                or entry.get("interiorMaxCell") != source.get("interiorMaxCell"):
            failures.append("actor %s changed source-backed home/door/interior geography" % actor_id)
        var body = entry.get("body")
        var live_body := body is CharacterBody3D and is_instance_valid(body) and (body as Node).is_inside_tree()
        if live_body: live_actor_count += 1
        elif require_live_bodies: failures.append("actor %s had no live CharacterBody3D" % actor_id)
        var simulation_lod := String(entry.get("simulationLod", "active"))
        simulation_lod_counts[simulation_lod] = int(simulation_lod_counts.get(simulation_lod, 0)) + 1
        if simulation_lod != "abstract": physical_simulation_actor_count += 1
        matched_actor_ids[actor_id] = true
        matched_home_ids[home_id] = true
        matched_door_ids[String(entry.get("doorPortalId", ""))] = true
    if matched_actor_ids.size() != target_count:
        failures.append("selected town supplied %d source-backed residents; exactly %d required" % [
            matched_actor_ids.size(), target_count
        ])
    return {
        "ok": failures.is_empty(),
        "targetCount": target_count,
        "townKey": town_key,
        "sourceHomeRecordCount": source_records.size(),
        "sourceBackedActorCount": matched_actor_ids.size(),
        "liveSourceBackedActorCount": live_actor_count,
        "physicalSimulationActorCount": physical_simulation_actor_count,
        "simulationLodCounts": simulation_lod_counts,
        "uniqueActorIdCount": matched_actor_ids.size(),
        "sharedStableHomeCount": matched_home_ids.size(),
        "sharedDoorPortalCount": matched_door_ids.size(),
        "failures": failures
    }


static func audit_capsule_overlap(entries_value: Variant) -> Dictionary:
    var entries: Array = entries_value if entries_value is Array else []
    var overlaps: Array[Dictionary] = []
    var clearance_intrusions: Array[Dictionary] = []
    var invalid_colliders: Array[Dictionary] = []
    var geometries: Array[Dictionary] = []
    for a_index in range(entries.size()):
        var a: Dictionary = entries[a_index] if entries[a_index] is Dictionary else {}
        var geometry := live_capsule_geometry(a)
        geometries.append(geometry)
        if not bool(geometry.get("ok", false)):
            invalid_colliders.append({
                "actorId": String(a.get("id", "")),
                "reason": String(geometry.get("reason", "invalid_live_capsule")),
                "enabledCapsuleCount": int(geometry.get("enabledCapsuleCount", 0)),
                "disabledCapsuleCount": int(geometry.get("disabledCapsuleCount", 0))
            })
    for a_index in range(geometries.size()):
        var a_geometry: Dictionary = geometries[a_index]
        if not bool(a_geometry.get("ok", false)):
            continue
        for b_index in range(a_index + 1, geometries.size()):
            var b_geometry: Dictionary = geometries[b_index]
            if not bool(b_geometry.get("ok", false)):
                continue
            var physical := capsule_intersection(a_geometry, b_geometry)
            if bool(physical.get("intersects", false)):
                overlaps.append(_capsule_pair_observation(a_geometry, b_geometry, physical))
            var a_clearance: Dictionary = a_geometry.get("clearanceGeometry", {})
            var b_clearance: Dictionary = b_geometry.get("clearanceGeometry", {})
            if bool(a_clearance.get("ok", false)) and bool(b_clearance.get("ok", false)):
                var clearance := capsule_intersection(a_clearance, b_clearance)
                if bool(clearance.get("intersects", false)):
                    clearance_intrusions.append(_capsule_pair_observation(
                        a_clearance, b_clearance, clearance))
    return {
        "ok": overlaps.is_empty() and invalid_colliders.is_empty(),
        "overlapCount": overlaps.size(),
        "physicalOverlapCount": overlaps.size(),
        "overlaps": overlaps,
        "invalidColliderCount": invalid_colliders.size(),
        "invalidColliders": invalid_colliders,
        "clearanceEnvelopeIntrusionCount": clearance_intrusions.size(),
        "clearanceEnvelopeIntrusions": clearance_intrusions,
        "clearanceEnvelopeIsGating": false,
        "authority": "enabled_live_capsule_shape_3d"
    }


static func live_capsule_geometry(entry: Dictionary) -> Dictionary:
    var actor_id := String(entry.get("id", ""))
    var body := entry.get("body") as CharacterBody3D
    if body == null or not is_instance_valid(body) or not body.is_inside_tree():
        return {"ok": false, "actorId": actor_id, "reason": "missing_live_character_body",
            "enabledCapsuleCount": 0, "disabledCapsuleCount": 0}
    var enabled: Array[CollisionShape3D] = []
    var disabled_count := 0
    for child in body.get_children():
        # Godot only treats a CollisionShape3D as this body's physics shape
        # when it is a direct child of the CollisionObject3D.
        var collider := child as CollisionShape3D
        if collider != null:
            if collider.shape is CapsuleShape3D:
                if collider.disabled or not collider.is_inside_tree():
                    disabled_count += 1
                else:
                    enabled.append(collider)
    if enabled.size() != 1:
        return {
            "ok": false,
            "actorId": actor_id,
            "reason": "missing_enabled_live_capsule" if enabled.is_empty() else "ambiguous_enabled_live_capsules",
            "enabledCapsuleCount": enabled.size(),
            "disabledCapsuleCount": disabled_count
        }
    var collider := enabled[0]
    var shape := collider.shape as CapsuleShape3D
    var geometry := _capsule_geometry_from_dimensions(
        actor_id, collider, shape.radius, shape.height, body.safe_margin)
    if not bool(geometry.get("ok", false)):
        geometry["enabledCapsuleCount"] = 1
        geometry["disabledCapsuleCount"] = disabled_count
        return geometry
    geometry["enabledCapsuleCount"] = 1
    geometry["disabledCapsuleCount"] = disabled_count
    var motor_profile = entry.get("motorProfile")
    if motor_profile != null:
        geometry["clearanceGeometry"] = _capsule_geometry_from_dimensions(
            actor_id, collider, float(motor_profile.get("capsule_radius")),
            float(motor_profile.get("capsule_height")), body.safe_margin)
    else:
        geometry["clearanceGeometry"] = {"ok": false, "reason": "motor_profile_unavailable"}
    return geometry


static func _capsule_geometry_from_dimensions(
    actor_id: String,
    collider: CollisionShape3D,
    local_radius: float,
    local_height: float,
    safe_margin: float
) -> Dictionary:
    var transform := collider.global_transform
    var scale := transform.basis.get_scale().abs()
    var radial_scale := maxf(scale.x, scale.z)
    var axis_scale := scale.y
    if not transform.origin.is_finite() or not is_finite(local_radius) or not is_finite(local_height) \
            or local_radius <= 0.0 or local_height < local_radius * 2.0 \
            or radial_scale <= 0.0 or axis_scale <= 0.0:
        return {"ok": false, "actorId": actor_id, "reason": "invalid_live_capsule_geometry"}
    var largest_scale := maxf(scale.x, maxf(scale.y, scale.z))
    var smallest_scale := minf(scale.x, minf(scale.y, scale.z))
    if largest_scale - smallest_scale > maxf(0.00001, largest_scale * 0.0001):
        # A non-uniform affine transform turns spherical capsule caps into
        # ellipsoids. Reject it rather than labelling a conservative envelope
        # as the actual live capsule.
        return {"ok": false, "actorId": actor_id,
            "reason": "non_uniform_live_capsule_scale_is_not_capsule_geometry"}
    var basis_x := transform.basis.x.normalized()
    var basis_y := transform.basis.y.normalized()
    var basis_z := transform.basis.z.normalized()
    if absf(basis_x.dot(basis_y)) > 0.0001 or absf(basis_y.dot(basis_z)) > 0.0001 \
            or absf(basis_x.dot(basis_z)) > 0.0001:
        return {"ok": false, "actorId": actor_id,
            "reason": "sheared_live_capsule_transform_is_not_capsule_geometry"}
    var axis := transform.basis.y
    if axis.length_squared() <= 0.0000001:
        return {"ok": false, "actorId": actor_id, "reason": "collapsed_live_capsule_axis"}
    axis = axis.normalized()
    var radius := local_radius * radial_scale
    var half_segment := maxf(0.0, local_height * axis_scale * 0.5 - radius)
    return {
        "ok": true,
        "actorId": actor_id,
        "colliderPath": String(collider.get_path()),
        "center": transform.origin,
        "segmentStart": transform.origin - axis * half_segment,
        "segmentEnd": transform.origin + axis * half_segment,
        "radius": radius,
        "height": radius * 2.0 + half_segment * 2.0,
        "safeMargin": safe_margin,
        "worldScale": scale,
        "radialScaleMode": "maximum_transverse_axis"
    }


static func capsule_intersection(a: Dictionary, b: Dictionary) -> Dictionary:
    var distance := _segment_distance(
        a.get("segmentStart", Vector3.ZERO), a.get("segmentEnd", Vector3.ZERO),
        b.get("segmentStart", Vector3.ZERO), b.get("segmentEnd", Vector3.ZERO))
    var required := float(a.get("radius", 0.0)) + float(b.get("radius", 0.0))
    var penetration := required - distance
    return {
        "intersects": penetration > 0.000001,
        "segmentDistance": distance,
        "requiredSeparation": required,
        "penetration": maxf(0.0, penetration)
    }


static func _segment_distance(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> float:
    var d1 := q1 - p1
    var d2 := q2 - p2
    var r := p1 - p2
    var a := d1.dot(d1)
    var e := d2.dot(d2)
    var f := d2.dot(r)
    var s := 0.0
    var t := 0.0
    if a <= 0.0000001 and e <= 0.0000001:
        return p1.distance_to(p2)
    if a <= 0.0000001:
        t = clampf(f / e, 0.0, 1.0)
    else:
        var c := d1.dot(r)
        if e <= 0.0000001:
            s = clampf(-c / a, 0.0, 1.0)
        else:
            var b_dot := d1.dot(d2)
            var denominator := a * e - b_dot * b_dot
            if absf(denominator) > 0.0000001:
                s = clampf((b_dot * f - c * e) / denominator, 0.0, 1.0)
            t = (b_dot * s + f) / e
            if t < 0.0:
                t = 0.0
                s = clampf(-c / a, 0.0, 1.0)
            elif t > 1.0:
                t = 1.0
                s = clampf((b_dot - c) / a, 0.0, 1.0)
    return (p1 + d1 * s).distance_to(p2 + d2 * t)


static func _capsule_pair_observation(a: Dictionary, b: Dictionary, intersection: Dictionary) -> Dictionary:
    return {
        "a": String(a.get("actorId", "")),
        "b": String(b.get("actorId", "")),
        "aPosition": a.get("center", Vector3.ZERO),
        "bPosition": b.get("center", Vector3.ZERO),
        "segmentDistance": float(intersection.get("segmentDistance", 0.0)),
        "requiredSeparation": float(intersection.get("requiredSeparation", 0.0)),
        "penetration": float(intersection.get("penetration", 0.0)),
        "aRadius": float(a.get("radius", 0.0)),
        "bRadius": float(b.get("radius", 0.0)),
        "aSafeMargin": float(a.get("safeMargin", 0.001)),
        "bSafeMargin": float(b.get("safeMargin", 0.001))
    }


static func update_overlap_persistence_tracker(tracker: Dictionary, audit: Dictionary, now_usec: int) -> void:
    var sample_index := int(tracker.get("sampleCount", 0))
    tracker["sampleCount"] = sample_index + 1
    var invalid_colliders: Array = audit.get("invalidColliders", []) \
        if audit.get("invalidColliders", []) is Array else []
    if not invalid_colliders.is_empty():
        tracker["invalidColliderSamples"] = int(tracker.get("invalidColliderSamples", 0)) + 1
        var invalid_observations: Dictionary = tracker.get("invalidColliderObservations", {}) \
            if tracker.get("invalidColliderObservations", {}) is Dictionary else {}
        for invalid_value in invalid_colliders:
            if not (invalid_value is Dictionary):
                continue
            var invalid: Dictionary = invalid_value
            var invalid_key := "%s|%s" % [
                String(invalid.get("actorId", "")), String(invalid.get("reason", ""))]
            var observation: Dictionary = invalid_observations.get(invalid_key, {}) \
                if invalid_observations.get(invalid_key, {}) is Dictionary else {}
            if observation.is_empty():
                observation["actorId"] = String(invalid.get("actorId", ""))
                observation["reason"] = String(invalid.get("reason", ""))
                observation["firstSampleIndex"] = sample_index
                observation["firstUsec"] = now_usec
            observation["lastSampleIndex"] = sample_index
            observation["lastUsec"] = now_usec
            observation["sampleCount"] = int(observation.get("sampleCount", 0)) + 1
            observation["lastObservation"] = invalid.duplicate(true)
            invalid_observations[invalid_key] = observation
        tracker["invalidColliderObservations"] = invalid_observations
    var clearance_intrusions: Array = audit.get("clearanceEnvelopeIntrusions", []) \
        if audit.get("clearanceEnvelopeIntrusions", []) is Array else []
    if not clearance_intrusions.is_empty():
        tracker["clearanceEnvelopeIntrusionSamples"] = \
            int(tracker.get("clearanceEnvelopeIntrusionSamples", 0)) + 1
        var clearance_pairs: Dictionary = tracker.get("clearanceEnvelopePairs", {}) \
            if tracker.get("clearanceEnvelopePairs", {}) is Dictionary else {}
        for intrusion_value in clearance_intrusions:
            if not (intrusion_value is Dictionary):
                continue
            var intrusion: Dictionary = intrusion_value
            var clearance_ids: Array[String] = [
                String(intrusion.get("a", "")), String(intrusion.get("b", ""))]
            clearance_ids.sort()
            var clearance_key := "%s|%s" % [clearance_ids[0], clearance_ids[1]]
            clearance_pairs[clearance_key] = intrusion.duplicate(true)
        tracker["clearanceEnvelopePairs"] = clearance_pairs
    var pairs: Dictionary = tracker.get("pairs", {}) if tracker.get("pairs", {}) is Dictionary else {}
    var overlaps: Array = audit.get("overlaps", []) if audit.get("overlaps", []) is Array else []
    for overlap_value in overlaps:
        if not (overlap_value is Dictionary):
            continue
        var overlap: Dictionary = overlap_value
        var actor_ids: Array[String] = [String(overlap.get("a", "")), String(overlap.get("b", ""))]
        actor_ids.sort()
        var pair_key := "%s|%s" % [actor_ids[0], actor_ids[1]]
        var penetration := float(overlap.get("penetration", 0.0))
        var solver_allowance := maxf(0.001,
            float(overlap.get("aSafeMargin", 0.001)) + float(overlap.get("bSafeMargin", 0.001)))
        var state: Dictionary = pairs.get(pair_key, {}) if pairs.get(pair_key, {}) is Dictionary else {}
        state["actorIds"] = actor_ids
        state["lastUsec"] = now_usec
        state["lastSampleIndex"] = sample_index
        state["totalSamples"] = int(state.get("totalSamples", 0)) + 1
        state["maxPenetration"] = maxf(float(state.get("maxPenetration", 0.0)), penetration)
        state["maxSolverAllowance"] = maxf(float(state.get("maxSolverAllowance", 0.0)), solver_allowance)
        state["solverAllowance"] = solver_allowance
        state["lastObservation"] = overlap.duplicate(true)
        if penetration > solver_allowance:
            var consecutive := 1
            var first_material_usec := now_usec
            if int(state.get("lastMaterialSampleIndex", -2)) == sample_index - 1:
                consecutive = int(state.get("consecutiveMaterialSamples", 0)) + 1
                first_material_usec = int(state.get("firstMaterialUsec", now_usec))
            state["firstMaterialUsec"] = first_material_usec
            state["lastMaterialSampleIndex"] = sample_index
            state["consecutiveMaterialSamples"] = consecutive
            state["maxConsecutiveMaterialSamples"] = maxi(
                int(state.get("maxConsecutiveMaterialSamples", 0)), consecutive)
            state["materialSamples"] = int(state.get("materialSamples", 0)) + 1
            if consecutive >= 3 and now_usec - first_material_usec >= 250000:
                state["persistentMaterialOverlap"] = true
        else:
            # Contact inside the two CharacterBody safe margins is expected
            # solver tolerance, not part of a material-penetration streak.
            state["consecutiveMaterialSamples"] = 0
        pairs[pair_key] = state
    tracker["pairs"] = pairs


static func summarize_overlap_persistence_tracker(tracker: Dictionary) -> Dictionary:
    var persistent: Array[Dictionary] = []
    var observed: Array[Dictionary] = []
    var pairs: Dictionary = tracker.get("pairs", {}) if tracker.get("pairs", {}) is Dictionary else {}
    for pair_key_value in pairs.keys():
        var pair_key := String(pair_key_value)
        var state: Dictionary = pairs[pair_key_value]
        var row := {
            "pairKey": pair_key,
            "actorIds": state.get("actorIds", []),
            "totalSamples": int(state.get("totalSamples", 0)),
            "materialSamples": int(state.get("materialSamples", 0)),
            "maxConsecutiveMaterialSamples": int(state.get("maxConsecutiveMaterialSamples", 0)),
            "maxConsecutiveSamples": int(state.get("maxConsecutiveMaterialSamples", 0)),
            "maxPenetration": float(state.get("maxPenetration", 0.0)),
            "maxSolverAllowance": float(state.get("maxSolverAllowance", 0.001)),
            "lastObservation": state.get("lastObservation", {})
        }
        observed.append(row)
        if bool(state.get("persistentMaterialOverlap", false)):
            persistent.append(row.duplicate(true))
    observed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return String(a.get("pairKey", "")) < String(b.get("pairKey", ""))
    )
    persistent.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return String(a.get("pairKey", "")) < String(b.get("pairKey", ""))
    )
    var invalid_samples := int(tracker.get("invalidColliderSamples", 0))
    var clearance_pairs: Dictionary = tracker.get("clearanceEnvelopePairs", {}) \
        if tracker.get("clearanceEnvelopePairs", {}) is Dictionary else {}
    return {
        "ok": persistent.is_empty() and invalid_samples == 0,
        "sampleCount": int(tracker.get("sampleCount", 0)),
        "observedPairCount": observed.size(),
        "persistentPairCount": persistent.size(),
        "persistentPairs": persistent,
        "observedPairs": observed,
        "invalidColliderSamples": invalid_samples,
        "invalidColliderObservations": (tracker.get("invalidColliderObservations", {}) as Dictionary).values() \
            if tracker.get("invalidColliderObservations", {}) is Dictionary else [],
        "clearanceEnvelopeIntrusionSamples": int(tracker.get("clearanceEnvelopeIntrusionSamples", 0)),
        "clearanceEnvelopeIntrusionPairCount": clearance_pairs.size(),
        "clearanceEnvelopeIntrusions": clearance_pairs.values(),
        "clearanceEnvelopeIsGating": false,
        "classification": "invalid_physical_collider_authority" if invalid_samples > 0 \
            else ("persistent_material_overlap" if not persistent.is_empty() \
            else ("transient_contact_only" if not observed.is_empty() else "no_overlap_observed")),
        "policy": "Actual live CapsuleShape3D penetration beyond both CharacterBody safe margins must persist for at least three consecutive 10 Hz samples and 250 ms. Initial physical placement remains strictly overlap-free. Motor-profile clearance-envelope intrusion is reported separately and does not gate physical overlap."
    }


func current_gate5_capsule_overlap_audit() -> Dictionary:
    if main == null or scenario_population_provenance.is_empty():
        return {"ok": false, "overlapCount": 0, "overlaps": [], "reason": "gate5_population_setup_unavailable"}
    var selected: Dictionary = scenario_population_provenance.get("sourceSelection", {})
    var town_key := String(selected.get("townKey", ""))
    var npc_system = main.get("npc_system")
    if npc_system == null or town_key.is_empty():
        return {"ok": false, "overlapCount": 0, "overlaps": [], "reason": "selected_source_town_unavailable"}
    return audit_capsule_overlap(gate5_selected_town_entries(npc_system.get("npcs"), town_key))


static func audit_job_route_activity(entries_value: Variant) -> Dictionary:
    var active_ids: Array[String] = []
    var completed_ids: Array[String] = []
    if entries_value is Array:
        for entry_value in entries_value:
            if not (entry_value is Dictionary): continue
            var entry: Dictionary = entry_value
            var actor_id := String(entry.get("id", ""))
            var job_phase := String(entry.get("jobPhase", "idle"))
            var route_status := String(entry.get("routeStatus", "idle"))
            var goal_kind := String(entry.get("activeGoalKind", entry.get("goal", "idle")))
            var job_context := job_phase not in ["", "idle"] or goal_kind in ["work", "forage", "job", "guard"]
            if job_context and (route_status in ["moving", "pending", "waiting", "arrived", "partial"] \
                    or not (entry.get("routeCells", []) as Array).is_empty()):
                active_ids.append(actor_id)
            if int(entry.get("jobRuns", 0)) > 0:
                completed_ids.append(actor_id)
    active_ids.sort(); completed_ids.sort()
    return {
        "ok": not active_ids.is_empty() or not completed_ids.is_empty(),
        "activeActorIds": active_ids,
        "completedActorIds": completed_ids
    }


func prepare_gate5_source_backed_town_workload(target_count: int) -> Dictionary:
    var npc_system = main.get("npc_system") if main != null else null
    var structure_system = main.get("structure_system") if main != null else null
    if npc_system == null or structure_system == null:
        return {"ok":false,"reason":"production_town_population_authority_unavailable",
            "mode":"gate5_source_backed_derived_stress_population","synthetic":false,
            "derivedStressPopulation":true,"naturallyGeneratedPopulation":false,"targetCount":target_count}
    var player_body := main.get("player") as Node3D
    var observer_cell := Vector2i.ZERO if player_body == null else Vector2i(
        int(main.call("world_to_cell",player_body.global_position.x)),
        int(main.call("world_to_cell",player_body.global_position.z)))
    var snapshot: Dictionary = structure_system.town_home_records_snapshot()
    var selected := select_source_backed_town(snapshot, observer_cell)
    if not bool(selected.get("ok", false)):
        return {"ok":false,"reason":String(selected.get("reason","no_complete_source_backed_town")),
            "mode":"gate5_source_backed_derived_stress_population","synthetic":false,
            "derivedStressPopulation":true,"naturallyGeneratedPopulation":false,"targetCount":target_count,
            "sourceSelection":selected}
    var town_key := String(selected.get("townKey", ""))
    var records: Array = selected.get("records", [])
    npc_system.spawn_generic_town_npcs()
    var selected_entries := gate5_selected_town_entries(npc_system.get("npcs"), town_key)
    var existing_actor_ids := {}
    for entry in selected_entries: existing_actor_ids[String(entry.get("id", ""))] = true
    var resident_index := 0
    while selected_entries.size() < target_count:
        var source: Dictionary = records[resident_index % records.size()]
        var resident_record := shared_resident_record(source, town_key, resident_index)
        var actor_id := String(resident_record.get("id", ""))
        resident_index += 1
        if existing_actor_ids.has(actor_id): continue
        npc_system.spawn_town_npc(resident_record, selected_entries.size())
        var entry: Dictionary = npc_system.npc_entry_for_actor(actor_id)
        if entry.is_empty():
            return {"ok":false,"reason":"shared_resident_spawn_failed","actorId":actor_id,
                "mode":"gate5_source_backed_derived_stress_population","synthetic":false,
                "derivedStressPopulation":true,"naturallyGeneratedPopulation":false,"sourceSelection":selected}
        entry["gate5SourceHomeRecordId"] = String(source.get("id", ""))
        entry["gate5ResidentIndex"] = resident_index - 1
        selected_entries.append(entry)
        existing_actor_ids[actor_id] = true
    for entry in selected_entries:
        if String(entry.get("gate5SourceHomeRecordId", "")).is_empty():
            entry["gate5SourceHomeRecordId"] = source_record_id_for_entry(entry, records)
    npc_system.prebake_town_navmesh(records)
    var placement := place_gate5_town_residents(selected_entries, records[0])
    var actor_audit := audit_spawned_town_actor_provenance(selected_entries, records, town_key, target_count, true)
    var overlap_audit := audit_capsule_overlap(selected_entries)
    var ok := bool(placement.get("ok", false)) and bool(actor_audit.get("ok", false)) \
        and bool(overlap_audit.get("ok", false))
    var overlap_reason := ""
    if not bool(overlap_audit.get("ok", false)):
        overlap_reason = "invalid_resident_collider_authority" \
            if int(overlap_audit.get("invalidColliderCount", 0)) > 0 else "resident_capsule_overlap"
    return {
        "ok":ok,
        "reason":"" if ok else String(placement.get("reason",
            "spawned_actor_source_provenance_failed" if not bool(actor_audit.get("ok",false)) else overlap_reason)),
        "mode":"gate5_source_backed_derived_stress_population",
        "synthetic":false,
        "derivedStressPopulation":true,
        "naturallyGeneratedPopulation":false,
        "targetCount":target_count,
        "sourceSelection":selected,
        "actorAudit":actor_audit,
        "placementAudit":placement,
        "capsuleOverlapAudit":overlap_audit,
        "setupContract":"one production town_home_records_snapshot source -> derived shared-household stress population -> production spawn/prebake/route authority; not evidence of a naturally generated 32-resident town",
        "playerRelocated":false
    }


func gate5_selected_town_entries(entries_value: Variant, town_key: String) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if entries_value is Array:
        for entry_value in entries_value:
            if entry_value is Dictionary and String((entry_value as Dictionary).get("townKey", "")) == town_key:
                result.append(entry_value)
    result.sort_custom(func(a: Dictionary,b: Dictionary): return String(a.get("id","")) < String(b.get("id","")))
    return result


func source_record_id_for_entry(entry: Dictionary, records: Array) -> String:
    for source_value in records:
        if not (source_value is Dictionary): continue
        var source: Dictionary = source_value
        if String(source.get("stableId", "")) == String(entry.get("homeStableId", "")):
            return String(source.get("id", ""))
    return ""


func place_gate5_town_residents(entries: Array[Dictionary], source_record: Dictionary) -> Dictionary:
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return {"ok":false,"reason":"npc_system_unavailable"}
    var slots := resident_street_slot_cells(source_record)
    var slot_cursor := 0
    var placements: Array[Dictionary] = []
    for entry in entries:
        var body := entry.get("body") as CharacterBody3D
        var placed := false
        while slot_cursor < slots.size():
            var cell: Vector2i = slots[slot_cursor]
            slot_cursor += 1
            var level := float(main.call("surface_y_at_cell",Vector3i(cell.x,0,cell.y))) + 0.04
            var target := Vector3(float(cell.x)*float(main.CELL),level,float(cell.y)*float(main.CELL))
            var placement: Dictionary = npc_system.safe_place_npc(body,target,entry.get("motorProfile"),"gate5_source_town_slot")
            if not bool(placement.get("ok",false)): continue
            placements.append({"actorId":String(entry.get("id","")),"cell":cell,"position":placement.get("position",target)})
            placed = true
            break
        if not placed:
            return {"ok":false,"reason":"insufficient_collision_safe_real_town_street_slots",
                "placedCount":placements.size(),"requiredCount":entries.size(),"placements":placements}
    return {"ok":true,"placedCount":placements.size(),"requiredCount":entries.size(),"placements":placements}


func current_gate5_actor_provenance_audit() -> Dictionary:
    if main == null or scenario_population_provenance.is_empty():
        return {"ok":false,"reason":"gate5_population_setup_unavailable"}
    var selected: Dictionary = scenario_population_provenance.get("sourceSelection", {})
    var town_key := String(selected.get("townKey", ""))
    var records: Array = selected.get("records", []) if selected.get("records", []) is Array else []
    var npc_system = main.get("npc_system")
    if npc_system == null or town_key.is_empty() or records.is_empty():
        return {"ok":false,"reason":"selected_source_town_unavailable"}
    var entries := gate5_selected_town_entries(npc_system.get("npcs"),town_key)
    var result := audit_spawned_town_actor_provenance(entries,records,town_key,TARGET_NPC_COUNT,true)
    result["capsuleOverlapAudit"] = audit_capsule_overlap(entries)
    result["jobRouteAudit"] = audit_job_route_activity(entries)
    result["ok"] = bool(result.get("ok",false)) and bool(result.capsuleOverlapAudit.get("ok",false))
    return result


func force_npc_count_diagnostic(target_count: int) -> Dictionary:
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return {"ok": false, "reason": "npc_system_unavailable", "mode": "diagnostic_synthetic"}
    if npc_system.has_method("spawn_generic_town_npcs"):
        npc_system.spawn_generic_town_npcs()
    var entries: Array = npc_system.get("npcs")
    if entries.size() >= target_count:
        return {
            "ok": true,
            "mode": "diagnostic_existing_population",
            "synthetic": false,
            "actorCount": entries.size()
        }
    var player_body := main.get("player") as Node3D
    var origin := player_body.global_position if player_body != null else Vector3.ZERO
    var center := Vector2i(main.call("world_to_cell", origin.x), main.call("world_to_cell", origin.z))
    var level := float(main.call("surface_y_at_position", origin))
    var start_index := entries.size()
    var synthetic_records: Array = []
    for i in range(start_index, target_count):
        var offset := Vector2i((i % 8) * 2 - 8, int(i / 8) * 2 + 6)
        var home_cell := center + offset
        var record := {
            "id": "perf_npc_%02d" % i,
            "townKey": "runtime_perf",
            "townCenter": center,
            "townRadius": 24,
            "level": level,
            "homeCell": home_cell,
            "porchCell": home_cell + Vector2i(0, 1),
            "interiorMinCell": home_cell + Vector2i(-1, -1),
            "interiorMaxCell": home_cell + Vector2i(1, 1),
            "guardCell": center + Vector2i(i % 6 - 3, -6)
        }
        npc_system.spawn_town_npc(record, i)
        synthetic_records.append(record)
    # Keep the diagnostic fixture on the production town-spawn contract. The
    # production path pre-bakes a town's navigation envelope immediately after
    # spawning its records; synthetic population top-up must do the same before
    # warmup or the measured interval is mostly cold convergence work.
    if not synthetic_records.is_empty() and npc_system.has_method("prebake_town_navmesh"):
        npc_system.prebake_town_navmesh(synthetic_records)
    return {
        "ok": entries.size() >= target_count,
        "mode": "diagnostic_synthetic",
        "synthetic": true,
        "actorCount": entries.size(),
        "syntheticRecordCount": synthetic_records.size(),
        "reason": "" if entries.size() >= target_count else "diagnostic_population_target_unmet"
    }

func active_npc_count() -> int:
    if main == null or not is_instance_valid(main):
        return 0
    var npc_system = main.get("npc_system")
    if npc_system == null or not is_instance_valid(npc_system):
        return 0
    var entries_value = npc_system.get("npcs")
    if not (entries_value is Array):
        return 0
    var count := 0
    for entry_value in entries_value:
        if not (entry_value is Dictionary):
            continue
        var entry: Dictionary = entry_value
        if String(entry.get("simulationLod", "active")) == "abstract":
            continue
        var body := entry.get("body") as CharacterBody3D
        if body != null and is_instance_valid(body) and body.is_inside_tree() and body.is_physics_processing():
            count += 1
    return count

func owned_work_census() -> Dictionary:
    if main == null or not is_instance_valid(main):
        return {"zeroOwnedWork": false, "reason": "main_missing_before_census"}
    var save_system = main.get("save_system")
    var save_pending: bool = save_system != null and save_system.has_method("has_async_save_pending") \
        and bool(save_system.call("has_async_save_pending"))
    var voxel_runtime = main.get("voxel_terrain_runtime")
    var voxel_tasks: int = int(voxel_runtime.call("voxel_engine_pending_task_count")) \
        if voxel_runtime != null and is_instance_valid(voxel_runtime) and voxel_runtime.has_method("voxel_engine_pending_task_count") else 0
    var terrain_service = main.get("terrain_meshing_service")
    var terrain_work: int = int(terrain_service.call("shutdown_pending_work_count")) \
        if terrain_service != null and is_instance_valid(terrain_service) and terrain_service.has_method("shutdown_pending_work_count") else 0
    var structure_system = main.get("structure_system")
    var admission_shutdown := true
    var publication_shutdown := true
    if structure_system != null and is_instance_valid(structure_system):
        var admission = structure_system.get("citadel_terrain_admission")
        var publication = structure_system.get("citadel_publication")
        if admission != null and admission.has_method("stats"):
            admission_shutdown = bool(admission.call("stats").get("shutdownComplete", false))
        if publication != null and publication.has_method("stats"):
            publication_shutdown = bool(publication.call("stats").get("shutdownComplete", false))
    var npc_system = main.get("npc_system")
    var npc_navigation_released: bool = npc_system == null or not is_instance_valid(npc_system) \
        or (npc_system.get("pathing") == null and npc_system.get("autonomy_system") == null)
    return {
        "savePending": save_pending,
        "voxelEnginePendingTasks": voxel_tasks,
        "terrainMeshingPendingWork": terrain_work,
        "citadelAdmissionShutdownComplete": admission_shutdown,
        "citadelPublicationShutdownComplete": publication_shutdown,
        "npcNavigationReleased": npc_navigation_released,
        "zeroOwnedWork": not save_pending and voxel_tasks == 0 and terrain_work == 0 \
            and admission_shutdown and publication_shutdown and npc_navigation_released
    }

func warmup_frames(count: int) -> void:
    for _i in range(count):
        await get_tree().process_frame

func prime_navigation_snapshot() -> void:
    if main == null:
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        return
    var entries: Array = npc_system.get("npcs")
    if entries.is_empty():
        return
    var pathing = npc_system.get("pathing")
    var world = pathing.get("navigation_world") if pathing != null else null
    if world != null and world.has_method("build_snapshot"):
        world.build_snapshot(entries[0], true, false)

func reset_performance_monitor() -> void:
    if main == null:
        return
    var monitor = main.get("runtime_perf_monitor")
    if monitor != null and monitor.has_method("reset"):
        monitor.reset()
    var npc_system = main.get("npc_system")
    var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    var navmesh_world = autonomy.get("navmesh_world") if autonomy != null else null
    if navmesh_world != null and navmesh_world.has_method("reset_timing_stats"):
        navmesh_world.reset_timing_stats()

func summarize_samples(samples: Array) -> Dictionary:
    var frames := []
    # Compact debug snapshots historically omitted this field. The monitor is
    # the authority for what its frame timer measures, so keep its exact scope
    # as the reducer fallback rather than inferring total frame latency.
    var frame_metric_scope := RuntimePerformanceMonitorScript.FRAME_METRIC_SCOPE
    var rolling_frame_max := 0.0
    var max_npc := 0.0
    var max_route := 0.0
    var max_legacy_route := 0.0
    var max_routine_candidates := 0.0
    var max_routine_plan := 0.0
    var max_routine_probe_commit := 0.0
    var max_route_request := 0.0
    var max_route_search := 0.0
    var max_route_record := 0.0
    var max_route_convert := 0.0
    var max_chunk := 0.0
    var max_chunk_create := 0.0
    var max_chunk_build_mesh := 0.0
    var max_chunk_trimesh := 0.0
    var max_chunk_spawn_props := 0.0
    var chunks_created := 0
    var chunk_asset_cache_misses := 0
    var chunk_volume_columns := 0
    var chunk_volume_cubes := 0
    var chunk_volume_faces := 0
    var chunk_fluid_faces := 0
    var chunk_fluid_mesh_deferred_during_collision_refresh := 0
    var terrain_meshing_fallback_chunks := 0
    var terrain_meshing_native_chunks := 0
    var terrain_meshing_direct_build_deferred_without_native := 0
    var terrain_fluid_direct_build_deferred_without_native := 0
    var terrain_meshing_jobs_queued := 0
    var terrain_meshing_jobs_processed := 0
    var terrain_meshing_jobs_deferred_without_native := 0
    var terrain_meshing_completed_applied := 0
    var terrain_meshing_provisional_chunks := 0
    var terrain_meshing_job_queue_depth := 0
    var terrain_meshing_completed_queue_depth := 0
    var terrain_meshing_payload_cells_prepared := 0
    var terrain_volume_sections_prepared_for_mesh := 0
    var terrain_volume_exposure_scan_deferred_without_native := 0
    var terrain_fluid_jobs_queued := 0
    var terrain_fluid_jobs_completed := 0
    var terrain_fluid_jobs_dropped := 0
    var terrain_fluid_payload_cells_prepared := 0
    var terrain_fluid_payload_sections_prepared := 0
    var terrain_fluid_exact_cells := 0
    var terrain_fluid_water_faces := 0
    var terrain_fluid_lava_faces := 0
    var terrain_fluid_stale_results_rejected := 0
    var terrain_fluid_stale_mesh_cleared := 0
    var terrain_fluid_forbidden_coarse_payload_attempts := 0
    var surface_prop_volume_projection_queries := 0
    var underground_prop_cells_scanned := 0
    var underground_prop_candidates_found := 0
    var underground_prop_volume_service_scans := 0
    var max_terrain_meshing_payload_prep := 0.0
    var max_terrain_meshing_job_elapsed := 0.0
    var max_terrain_fluid_payload_prep := 0.0
    var max_terrain_fluid_native_build := 0.0
    var max_runtime_graph := 0.0
    var max_runtime_graph_snapshot := 0.0
    var max_runtime_graph_targets := 0.0
    var max_runtime_graph_candidates := 0.0
    var max_runtime_graph_continue := 0.0
    var max_runtime_graph_sync_nodes := 0.0
    var max_runtime_graph_sync_edges := 0.0
    var max_nav := 0.0
    var max_job := 0.0
    var max_save := 0.0
    var static_rebuild_count := 0
    var dynamic_update_count := 0
    var route_jobs_completed := 0
    var route_jobs_pending := 0
    var route_jobs_completed_available := false
    var route_jobs_pending_events_available := false
    var autosave_completed := 0
    var autosave_pending := false
    var max_autosave_read_parse := 0.0
    var max_autosave_stringify_write := 0.0
    var job_scan_nodes := 0
    var forage_scan_nodes := 0
    var indexed_resource_queries := 0
    var max_navmesh_install_usec := 0
    var max_navmesh_install_p95_usec := 0
    var max_navmesh_path_query_usec := 0
    var max_navmesh_path_query_p95_usec := 0
    var max_navmesh_path_query_failures := 0
    var slowest_navmesh_path_query := {}
    # Tree recipe work is intentionally asynchronous, so runtime samples must
    # retain both the queue pressure and the bounded main-thread publication
    # stage timing. Without this, a normal traversal report can only speculate
    # about vegetation's contribution to a hitch.
    var max_tree_publication_pending := 0
    var max_tree_publication_active_workers := 0
    var max_tree_publication_completed := 0
    var tree_publication_queued := 0
    var tree_publication_published := 0
    var tree_publication_dropped := 0
    var max_tree_publication_p99_usec := 0
    var max_tree_publication_usec := 0
    var max_tree_publication_frame_p99_usec := 0
    var max_tree_publication_frame_usec := 0
    var max_tree_publication_scheduler_p99_usec := 0
    var max_tree_publication_scheduler_usec := 0
    var max_tree_publication_validation_p99_usec := 0
    var max_tree_publication_validation_usec := 0
    var max_tree_publication_bookkeeping_p99_usec := 0
    var max_tree_publication_bookkeeping_usec := 0
    var max_tree_publication_reporting_p99_usec := 0
    var max_tree_publication_reporting_usec := 0
    var max_tree_publication_unattributed_p99_usec := 0
    var max_tree_publication_unattributed_usec := 0
    var max_tree_publication_loop_tail_p99_usec := 0
    var max_tree_publication_loop_tail_usec := 0
    var worst_tree_publication_frame := {}
    var max_tree_priority_selection_p99_usec := 0
    var max_tree_priority_selection_usec := 0
    var max_tree_priority_selection_candidates := 0
    var max_tree_priority_full_fallbacks := 0
    var max_tree_priority_viewless_fifo_selections := 0
    var max_tree_worker_priority_selection_p99_usec := 0
    var max_tree_worker_priority_selection_usec := 0
    var max_tree_worker_priority_selection_candidates := 0
    var max_tree_worker_priority_full_fallbacks := 0
    var max_tree_root_p99_usec := 0
    var max_tree_bole_p99_usec := 0
    var max_tree_distal_p99_usec := 0
    var max_tree_foliage_p99_usec := 0
    var max_tree_commit_p99_usec := 0
    var max_tree_retier_p99_usec := 0
    var max_tree_cancellation_p99_usec := 0
    # These are publication-boundary aggregates from the canonical recipe.
    # They quantify the renderer load without walking live scene nodes during
    # the observation loop.
    var max_tree_render_visible_trees := 0
    var max_tree_render_branch_instances := 0
    var max_tree_render_foliage_instances := 0
    var max_tree_render_draw_calls := 0
    var max_tree_render_triangles := 0
    var max_tree_render_shadow_triangles := 0
    var max_tree_render_lod_distribution := {"near": 0, "mid": 0, "far": 0, "impostor": 0}
    var section_maxima := {}
    var last_spike := {}
    for sample_value in samples:
        var sample: Dictionary = sample_value
        var sample_frame_metric_scope := String(sample.get("frameMetricScope", "")).strip_edges()
        if not sample_frame_metric_scope.is_empty():
            frame_metric_scope = sample_frame_metric_scope
        frames.append(float(sample.get("frameMs", 0.0)))
        rolling_frame_max = maxf(rolling_frame_max, float(sample.get("frameMaxMs", 0.0)))
        max_npc = maxf(max_npc, float(sample.get("npcMs", 0.0)))
        var section_max: Dictionary = sample.get("perfSectionMaxMs", {}) if sample.get("perfSectionMaxMs", {}) is Dictionary else {}
        for section_name in section_max.keys():
            section_maxima[String(section_name)] = maxf(float(section_maxima.get(String(section_name), 0.0)), float(section_max.get(section_name, 0.0)))
        max_legacy_route = maxf(max_legacy_route, maxf(float(sample.get("routePlanMs", 0.0)), float(section_max.get("route_planning", 0.0))))
        max_routine_candidates = maxf(max_routine_candidates, float(section_max.get("npc_routine_v2_candidates", 0.0)))
        max_routine_plan = maxf(max_routine_plan, float(section_max.get("npc_routine_v2_plan", 0.0)))
        max_routine_probe_commit = maxf(max_routine_probe_commit, float(section_max.get("npc_routine_v2_probe_commit", 0.0)))
        max_route = maxf(max_route, maxf(max_routine_candidates, maxf(max_routine_plan, max_routine_probe_commit)))
        max_route_request = maxf(max_route_request, float(section_max.get("route_runtime_request", 0.0)))
        max_route_search = maxf(max_route_search, float(section_max.get("route_search_step", 0.0)))
        max_route_record = maxf(max_route_record, float(section_max.get("route_record_result", 0.0)))
        max_route_convert = maxf(max_route_convert, float(section_max.get("route_result_convert", 0.0)))
        max_chunk = maxf(max_chunk, maxf(float(sample.get("chunkMs", 0.0)), float(section_max.get("chunk", 0.0))))
        max_chunk_create = maxf(max_chunk_create, float(section_max.get("chunk_create", 0.0)))
        max_chunk_build_mesh = maxf(max_chunk_build_mesh, float(section_max.get("chunk_build_mesh", 0.0)))
        max_chunk_trimesh = maxf(max_chunk_trimesh, float(section_max.get("chunk_create_trimesh_shape", 0.0)))
        max_chunk_spawn_props = maxf(max_chunk_spawn_props, float(section_max.get("chunk_spawn_props", 0.0)))
        max_runtime_graph = maxf(max_runtime_graph, float(section_max.get("runtime_graph_build", 0.0)))
        max_runtime_graph_snapshot = maxf(max_runtime_graph_snapshot, float(section_max.get("runtime_graph_snapshot", 0.0)))
        max_runtime_graph_targets = maxf(max_runtime_graph_targets, float(section_max.get("runtime_graph_targets", 0.0)))
        max_runtime_graph_candidates = maxf(max_runtime_graph_candidates, float(section_max.get("runtime_graph_candidates", 0.0)))
        max_runtime_graph_continue = maxf(max_runtime_graph_continue, float(section_max.get("runtime_graph_continue", 0.0)))
        max_runtime_graph_sync_nodes = maxf(max_runtime_graph_sync_nodes, float(section_max.get("runtime_graph_sync_nodes", 0.0)))
        max_runtime_graph_sync_edges = maxf(max_runtime_graph_sync_edges, float(section_max.get("runtime_graph_sync_edges", 0.0)))
        max_nav = maxf(max_nav, maxf(float(sample.get("navSnapshotMs", 0.0)), float(section_max.get("navigation_snapshot_rebuild", 0.0))))
        max_job = maxf(max_job, maxf(float(sample.get("jobScanMs", 0.0)), float(section_max.get("job_forage_scan", 0.0))))
        max_save = maxf(max_save, maxf(float(sample.get("autosaveMs", 0.0)), float(section_max.get("autosave_snapshot", 0.0))))
        var counters: Dictionary = sample.get("perfCounters", {})
        static_rebuild_count = max(static_rebuild_count, int(counters.get("nav_static_rebuild_count", static_rebuild_count)))
        dynamic_update_count = max(dynamic_update_count, int(counters.get("nav_dynamic_update_count", dynamic_update_count)))
        var autosave_stats: Dictionary = sample.get("autosaveStats", {})
        max_autosave_read_parse = maxf(max_autosave_read_parse, float(autosave_stats.get("lastReadParseMs", 0.0)))
        max_autosave_stringify_write = maxf(max_autosave_stringify_write, maxf(
            float(autosave_stats.get("lastStringifyWriteMs", 0.0)),
            float(section_max.get("autosave_json_stringify_write", 0.0))
        ))
        autosave_completed = max(autosave_completed, int(autosave_stats.get("asyncCompleted", autosave_completed)))
        autosave_pending = autosave_pending or bool(autosave_stats.get("asyncPending", false))
        chunks_created = max(chunks_created, int(counters.get("chunks_created", chunks_created)))
        chunk_asset_cache_misses = max(chunk_asset_cache_misses, int(counters.get("chunk_asset_cache_misses", chunk_asset_cache_misses)))
        chunk_volume_columns = max(chunk_volume_columns, int(counters.get("chunk_volume_columns", chunk_volume_columns)))
        chunk_volume_cubes = max(chunk_volume_cubes, int(counters.get("chunk_volume_cubes", chunk_volume_cubes)))
        chunk_volume_faces = max(chunk_volume_faces, int(counters.get("chunk_volume_faces", chunk_volume_faces)))
        chunk_fluid_faces = max(chunk_fluid_faces, int(counters.get("chunk_fluid_faces", chunk_fluid_faces)))
        chunk_fluid_mesh_deferred_during_collision_refresh = max(chunk_fluid_mesh_deferred_during_collision_refresh, int(counters.get("chunk_fluid_mesh_deferred_during_collision_refresh", chunk_fluid_mesh_deferred_during_collision_refresh)))
        terrain_meshing_fallback_chunks = max(terrain_meshing_fallback_chunks, int(counters.get("terrain_meshing_gdscript_fallback_chunks", terrain_meshing_fallback_chunks)))
        terrain_meshing_native_chunks = max(terrain_meshing_native_chunks, int(counters.get("terrain_meshing_native_chunks", terrain_meshing_native_chunks)))
        terrain_meshing_direct_build_deferred_without_native = max(terrain_meshing_direct_build_deferred_without_native, int(counters.get("terrain_meshing_direct_build_deferred_without_native", terrain_meshing_direct_build_deferred_without_native)))
        terrain_fluid_direct_build_deferred_without_native = max(terrain_fluid_direct_build_deferred_without_native, int(counters.get("terrain_fluid_direct_build_deferred_without_native", terrain_fluid_direct_build_deferred_without_native)))
        terrain_meshing_jobs_queued = max(terrain_meshing_jobs_queued, int(counters.get("terrain_meshing_jobs_queued", terrain_meshing_jobs_queued)))
        terrain_meshing_jobs_processed = max(terrain_meshing_jobs_processed, int(counters.get("terrain_meshing_jobs_processed", terrain_meshing_jobs_processed)))
        terrain_meshing_jobs_deferred_without_native = max(terrain_meshing_jobs_deferred_without_native, int(counters.get("terrain_meshing_jobs_deferred_without_native", terrain_meshing_jobs_deferred_without_native)))
        terrain_meshing_completed_applied = max(terrain_meshing_completed_applied, int(counters.get("terrain_meshing_completed_applied", terrain_meshing_completed_applied)))
        terrain_meshing_provisional_chunks = max(terrain_meshing_provisional_chunks, int(counters.get("terrain_meshing_provisional_chunks", terrain_meshing_provisional_chunks)))
        terrain_meshing_job_queue_depth = max(terrain_meshing_job_queue_depth, int(counters.get("terrain_meshing_job_queue_depth", terrain_meshing_job_queue_depth)))
        terrain_meshing_completed_queue_depth = max(terrain_meshing_completed_queue_depth, int(counters.get("terrain_meshing_completed_queue_depth", terrain_meshing_completed_queue_depth)))
        terrain_meshing_payload_cells_prepared = max(terrain_meshing_payload_cells_prepared, int(counters.get("terrain_meshing_payload_cells_prepared", terrain_meshing_payload_cells_prepared)))
        terrain_volume_sections_prepared_for_mesh = max(terrain_volume_sections_prepared_for_mesh, int(counters.get("terrain_volume_sections_prepared_for_mesh", terrain_volume_sections_prepared_for_mesh)))
        terrain_volume_exposure_scan_deferred_without_native = max(terrain_volume_exposure_scan_deferred_without_native, int(counters.get("terrain_volume_exposure_scan_deferred_without_native", terrain_volume_exposure_scan_deferred_without_native)))
        terrain_fluid_jobs_queued = max(terrain_fluid_jobs_queued, int(counters.get("terrain_fluid_jobs_queued", terrain_fluid_jobs_queued)))
        terrain_fluid_jobs_completed = max(terrain_fluid_jobs_completed, int(counters.get("terrain_fluid_jobs_completed", terrain_fluid_jobs_completed)))
        terrain_fluid_jobs_dropped = max(terrain_fluid_jobs_dropped, int(counters.get("terrain_fluid_jobs_dropped", terrain_fluid_jobs_dropped)))
        terrain_fluid_payload_cells_prepared = max(terrain_fluid_payload_cells_prepared, int(counters.get("terrain_fluid_payload_cells_prepared", terrain_fluid_payload_cells_prepared)))
        terrain_fluid_payload_sections_prepared = max(terrain_fluid_payload_sections_prepared, int(counters.get("terrain_fluid_payload_sections_prepared", terrain_fluid_payload_sections_prepared)))
        terrain_fluid_exact_cells = max(terrain_fluid_exact_cells, int(counters.get("terrain_fluid_exact_cells", terrain_fluid_exact_cells)))
        terrain_fluid_water_faces = max(terrain_fluid_water_faces, int(counters.get("terrain_fluid_water_faces", terrain_fluid_water_faces)))
        terrain_fluid_lava_faces = max(terrain_fluid_lava_faces, int(counters.get("terrain_fluid_lava_faces", terrain_fluid_lava_faces)))
        terrain_fluid_stale_results_rejected = max(terrain_fluid_stale_results_rejected, int(counters.get("terrain_fluid_stale_results_rejected", terrain_fluid_stale_results_rejected)))
        terrain_fluid_stale_mesh_cleared = max(terrain_fluid_stale_mesh_cleared, int(counters.get("terrain_fluid_stale_mesh_cleared", terrain_fluid_stale_mesh_cleared)))
        terrain_fluid_forbidden_coarse_payload_attempts = max(terrain_fluid_forbidden_coarse_payload_attempts, int(counters.get("terrain_fluid_forbidden_coarse_payload_attempts", terrain_fluid_forbidden_coarse_payload_attempts)))
        surface_prop_volume_projection_queries = max(surface_prop_volume_projection_queries, int(counters.get("surface_prop_volume_projection_queries", surface_prop_volume_projection_queries)))
        underground_prop_cells_scanned = max(underground_prop_cells_scanned, int(counters.get("underground_prop_cells_scanned", underground_prop_cells_scanned)))
        underground_prop_candidates_found = max(underground_prop_candidates_found, int(counters.get("underground_prop_candidates_found", underground_prop_candidates_found)))
        underground_prop_volume_service_scans = max(underground_prop_volume_service_scans, int(counters.get("underground_prop_volume_service_scans", underground_prop_volume_service_scans)))
        max_terrain_meshing_payload_prep = maxf(max_terrain_meshing_payload_prep, float(section_max.get("terrain_meshing_payload_prep", 0.0)))
        max_terrain_meshing_job_elapsed = maxf(max_terrain_meshing_job_elapsed, float(section_max.get("terrain_meshing_job_elapsed", 0.0)))
        max_terrain_fluid_payload_prep = maxf(max_terrain_fluid_payload_prep, float(section_max.get("terrain_fluid_payload_prep", 0.0)))
        max_terrain_fluid_native_build = maxf(max_terrain_fluid_native_build, float(section_max.get("terrain_meshing_native_fluid_build", 0.0)))
        if counters.has("route_jobs_completed"):
            route_jobs_completed_available = true
            route_jobs_completed = max(route_jobs_completed, int(counters.get("route_jobs_completed", route_jobs_completed)))
        if counters.has("route_jobs_pending"):
            route_jobs_pending_events_available = true
            route_jobs_pending = max(route_jobs_pending, int(counters.get("route_jobs_pending", route_jobs_pending)))
        job_scan_nodes = max(job_scan_nodes, int(counters.get("job_scan_nodes", job_scan_nodes)))
        forage_scan_nodes = max(forage_scan_nodes, int(counters.get("forage_scan_nodes", forage_scan_nodes)))
        indexed_resource_queries = max(indexed_resource_queries, int(counters.get("indexed_resource_queries", indexed_resource_queries)))
        var navmesh_stats: Dictionary = sample.get("navmeshWorld", {}) if sample.get("navmeshWorld", {}) is Dictionary else {}
        max_navmesh_install_usec = max(max_navmesh_install_usec, int(navmesh_stats.get("lastInstallUsec", 0)))
        max_navmesh_install_p95_usec = max(max_navmesh_install_p95_usec, int(navmesh_stats.get("installP95Usec", 0)))
        var sample_navmesh_path_query_usec := int(navmesh_stats.get("maxPathQueryUsec", 0))
        if sample_navmesh_path_query_usec >= max_navmesh_path_query_usec:
            slowest_navmesh_path_query = navmesh_stats.get("slowestPathQuery", {}) if navmesh_stats.get("slowestPathQuery", {}) is Dictionary else {}
        max_navmesh_path_query_usec = max(max_navmesh_path_query_usec, sample_navmesh_path_query_usec)
        max_navmesh_path_query_p95_usec = max(max_navmesh_path_query_p95_usec, int(navmesh_stats.get("pathQueryP95Usec", 0)))
        max_navmesh_path_query_failures = max(max_navmesh_path_query_failures, int(navmesh_stats.get("pathQueryFailureCount", 0)))
        var tree_publication: Dictionary = sample.get("treePublication", {}) if sample.get("treePublication", {}) is Dictionary else {}
        max_tree_publication_pending = max(max_tree_publication_pending, int(tree_publication.get("pending", 0)))
        max_tree_publication_active_workers = max(max_tree_publication_active_workers, int(tree_publication.get("activeWorkers", 0)))
        max_tree_publication_completed = max(max_tree_publication_completed, int(tree_publication.get("completed", 0)))
        tree_publication_queued = max(tree_publication_queued, int(tree_publication.get("queued", 0)))
        tree_publication_published = max(tree_publication_published, int(tree_publication.get("published", 0)))
        tree_publication_dropped = max(tree_publication_dropped, int(tree_publication.get("dropped", 0)))
        var tree_timing: Dictionary = tree_publication.get("publicationTiming", {}) if tree_publication.get("publicationTiming", {}) is Dictionary else {}
        max_tree_publication_p99_usec = max(max_tree_publication_p99_usec, int(tree_timing.get("p99Usec", 0)))
        max_tree_publication_usec = max(max_tree_publication_usec, int(tree_timing.get("maxUsec", 0)))
        var tree_frame_timing: Dictionary = tree_publication.get("publicationFrameTiming", {}) if tree_publication.get("publicationFrameTiming", {}) is Dictionary else {}
        max_tree_publication_frame_p99_usec = max(max_tree_publication_frame_p99_usec, int(tree_frame_timing.get("p99Usec", 0)))
        max_tree_publication_frame_usec = max(max_tree_publication_frame_usec, int(tree_frame_timing.get("maxUsec", 0)))
        var tree_scheduler_timing: Dictionary = tree_publication.get("publicationSchedulerTiming", {}) if tree_publication.get("publicationSchedulerTiming", {}) is Dictionary else {}
        max_tree_publication_scheduler_p99_usec = max(max_tree_publication_scheduler_p99_usec, int(tree_scheduler_timing.get("p99Usec", 0)))
        max_tree_publication_scheduler_usec = max(max_tree_publication_scheduler_usec, int(tree_scheduler_timing.get("maxUsec", 0)))
        var tree_validation_timing: Dictionary = tree_publication.get("publicationValidationTiming", {}) if tree_publication.get("publicationValidationTiming", {}) is Dictionary else {}
        max_tree_publication_validation_p99_usec = max(max_tree_publication_validation_p99_usec, int(tree_validation_timing.get("p99Usec", 0)))
        max_tree_publication_validation_usec = max(max_tree_publication_validation_usec, int(tree_validation_timing.get("maxUsec", 0)))
        var tree_bookkeeping_timing: Dictionary = tree_publication.get("publicationBookkeepingTiming", {}) if tree_publication.get("publicationBookkeepingTiming", {}) is Dictionary else {}
        max_tree_publication_bookkeeping_p99_usec = max(max_tree_publication_bookkeeping_p99_usec, int(tree_bookkeeping_timing.get("p99Usec", 0)))
        max_tree_publication_bookkeeping_usec = max(max_tree_publication_bookkeeping_usec, int(tree_bookkeeping_timing.get("maxUsec", 0)))
        var tree_reporting_timing: Dictionary = tree_publication.get("publicationReportingTiming", {}) if tree_publication.get("publicationReportingTiming", {}) is Dictionary else {}
        max_tree_publication_reporting_p99_usec = max(max_tree_publication_reporting_p99_usec, int(tree_reporting_timing.get("p99Usec", 0)))
        max_tree_publication_reporting_usec = max(max_tree_publication_reporting_usec, int(tree_reporting_timing.get("maxUsec", 0)))
        var tree_unattributed_timing: Dictionary = tree_publication.get("publicationUnattributedTiming", {}) if tree_publication.get("publicationUnattributedTiming", {}) is Dictionary else {}
        max_tree_publication_unattributed_p99_usec = max(max_tree_publication_unattributed_p99_usec, int(tree_unattributed_timing.get("p99Usec", 0)))
        max_tree_publication_unattributed_usec = max(max_tree_publication_unattributed_usec, int(tree_unattributed_timing.get("maxUsec", 0)))
        var tree_loop_tail_timing: Dictionary = tree_publication.get("publicationLoopTailTiming", {}) if tree_publication.get("publicationLoopTailTiming", {}) is Dictionary else {}
        max_tree_publication_loop_tail_p99_usec = max(max_tree_publication_loop_tail_p99_usec, int(tree_loop_tail_timing.get("p99Usec", 0)))
        max_tree_publication_loop_tail_usec = max(max_tree_publication_loop_tail_usec, int(tree_loop_tail_timing.get("maxUsec", 0)))
        var tree_worst_frame: Dictionary = tree_publication.get("publicationWorstFrame", {}) if tree_publication.get("publicationWorstFrame", {}) is Dictionary else {}
        if int(tree_worst_frame.get("elapsedUsec", 0)) > int(worst_tree_publication_frame.get("elapsedUsec", 0)):
            worst_tree_publication_frame = tree_worst_frame.duplicate()
        var tree_priority: Dictionary = tree_publication.get("priorityScheduling", {}) if tree_publication.get("priorityScheduling", {}) is Dictionary else {}
        var tree_priority_timing: Dictionary = tree_priority.get("selectionTiming", {}) if tree_priority.get("selectionTiming", {}) is Dictionary else {}
        max_tree_priority_selection_p99_usec = max(max_tree_priority_selection_p99_usec, int(tree_priority_timing.get("p99Usec", 0)))
        max_tree_priority_selection_usec = max(max_tree_priority_selection_usec, int(tree_priority_timing.get("maxUsec", 0)))
        max_tree_priority_selection_candidates = max(max_tree_priority_selection_candidates, int(tree_priority.get("maxSelectionCandidates", 0)))
        max_tree_priority_full_fallbacks = max(max_tree_priority_full_fallbacks, int(tree_priority.get("fullFallbackSelections", 0)))
        max_tree_priority_viewless_fifo_selections = max(max_tree_priority_viewless_fifo_selections, int(tree_priority.get("viewlessFifoSelections", 0)))
        var tree_worker_priority: Dictionary = tree_publication.get("workerPriorityScheduling", {}) if tree_publication.get("workerPriorityScheduling", {}) is Dictionary else {}
        var tree_worker_priority_timing: Dictionary = tree_worker_priority.get("selectionTiming", {}) if tree_worker_priority.get("selectionTiming", {}) is Dictionary else {}
        max_tree_worker_priority_selection_p99_usec = max(max_tree_worker_priority_selection_p99_usec, int(tree_worker_priority_timing.get("p99Usec", 0)))
        max_tree_worker_priority_selection_usec = max(max_tree_worker_priority_selection_usec, int(tree_worker_priority_timing.get("maxUsec", 0)))
        max_tree_worker_priority_selection_candidates = max(max_tree_worker_priority_selection_candidates, int(tree_worker_priority.get("maxSelectionCandidates", 0)))
        max_tree_worker_priority_full_fallbacks = max(max_tree_worker_priority_full_fallbacks, int(tree_worker_priority.get("fullFallbackSelections", 0)))
        var tree_stage_timing: Dictionary = tree_publication.get("publicationStageTiming", {}) if tree_publication.get("publicationStageTiming", {}) is Dictionary else {}
        var tree_root_timing: Dictionary = tree_stage_timing.get("root", {}) if tree_stage_timing.get("root", {}) is Dictionary else {}
        var tree_bole_timing: Dictionary = tree_stage_timing.get("bole", {}) if tree_stage_timing.get("bole", {}) is Dictionary else {}
        var tree_distal_timing: Dictionary = tree_stage_timing.get("distal", {}) if tree_stage_timing.get("distal", {}) is Dictionary else {}
        var tree_foliage_timing: Dictionary = tree_stage_timing.get("foliage", {}) if tree_stage_timing.get("foliage", {}) is Dictionary else {}
        var tree_commit_timing: Dictionary = tree_stage_timing.get("commit", {}) if tree_stage_timing.get("commit", {}) is Dictionary else {}
        var tree_retier_timing: Dictionary = tree_stage_timing.get("retier", {}) if tree_stage_timing.get("retier", {}) is Dictionary else {}
        var tree_cancellation_timing: Dictionary = tree_stage_timing.get("cancellation", {}) if tree_stage_timing.get("cancellation", {}) is Dictionary else {}
        max_tree_root_p99_usec = max(max_tree_root_p99_usec, int(tree_root_timing.get("p99Usec", 0)))
        max_tree_bole_p99_usec = max(max_tree_bole_p99_usec, int(tree_bole_timing.get("p99Usec", 0)))
        max_tree_distal_p99_usec = max(max_tree_distal_p99_usec, int(tree_distal_timing.get("p99Usec", 0)))
        max_tree_foliage_p99_usec = max(max_tree_foliage_p99_usec, int(tree_foliage_timing.get("p99Usec", 0)))
        max_tree_commit_p99_usec = max(max_tree_commit_p99_usec, int(tree_commit_timing.get("p99Usec", 0)))
        max_tree_retier_p99_usec = max(max_tree_retier_p99_usec, int(tree_retier_timing.get("p99Usec", 0)))
        max_tree_cancellation_p99_usec = max(max_tree_cancellation_p99_usec, int(tree_cancellation_timing.get("p99Usec", 0)))
        var tree_render: Dictionary = tree_publication.get("render", {}) if tree_publication.get("render", {}) is Dictionary else {}
        max_tree_render_visible_trees = max(max_tree_render_visible_trees, int(tree_render.get("visibleTrees", 0)))
        max_tree_render_branch_instances = max(max_tree_render_branch_instances, int(tree_render.get("branchInstances", 0)))
        max_tree_render_foliage_instances = max(max_tree_render_foliage_instances, int(tree_render.get("foliageInstances", 0)))
        max_tree_render_draw_calls = max(max_tree_render_draw_calls, int(tree_render.get("estimatedDrawCalls", 0)))
        max_tree_render_triangles = max(max_tree_render_triangles, int(tree_render.get("estimatedTriangles", 0)))
        max_tree_render_shadow_triangles = max(max_tree_render_shadow_triangles, int(tree_render.get("estimatedShadowTriangles", 0)))
        var tree_render_lods: Dictionary = tree_render.get("lodDistribution", {}) if tree_render.get("lodDistribution", {}) is Dictionary else {}
        for tier in max_tree_render_lod_distribution.keys():
            max_tree_render_lod_distribution[tier] = max(
                int(max_tree_render_lod_distribution.get(tier, 0)),
                int(tree_render_lods.get(tier, 0))
            )
        if float(sample.get("lastSpikeFrameMs", 0.0)) >= float(last_spike.get("frameMs", 0.0)):
            last_spike = {
                "frameMs": float(sample.get("lastSpikeFrameMs", 0.0)),
                "reason": String(sample.get("lastSpikeReason", "")),
                "topSections": sample.get("lastSpikeTopSections", [])
            }
    return {
        "frameMetricScope": frame_metric_scope,
        "frameP50Ms": percentile(frames, 0.50),
        "frameP95Ms": percentile(frames, 0.95),
        "frameP99Ms": percentile(frames, 0.99),
        "frameMaxMs": maxf(max_value(frames), rolling_frame_max),
        "maxUpdateNpcsMs": max_npc,
        "maxNpcMs": max_npc,
        "maxRoutePlanMs": max_route,
        "maxNpcRoutineV2CandidatesMs": max_routine_candidates,
        "maxNpcRoutineV2PlanMs": max_routine_plan,
        "maxNpcRoutineV2ProbeCommitMs": max_routine_probe_commit,
        "maxLegacyRoutePlanMs": max_legacy_route,
        "maxRouteRequestMs": max_route_request,
        "maxRouteSearchMs": max_route_search,
        "maxRouteRecordMs": max_route_record,
        "maxRouteConvertMs": max_route_convert,
        "maxChunkMs": max_chunk,
        "maxChunkCreateMs": max_chunk_create,
        "maxChunkBuildMeshMs": max_chunk_build_mesh,
        "maxChunkCreateTrimeshShapeMs": max_chunk_trimesh,
        "maxChunkSpawnPropsMs": max_chunk_spawn_props,
        "chunksCreated": chunks_created,
        "chunkAssetCacheMisses": chunk_asset_cache_misses,
        "chunkVolumeColumns": chunk_volume_columns,
        "chunkVolumeCubes": chunk_volume_cubes,
        "chunkVolumeFaces": chunk_volume_faces,
        "chunkFluidFaces": chunk_fluid_faces,
        "chunkFluidMeshDeferredDuringCollisionRefresh": chunk_fluid_mesh_deferred_during_collision_refresh,
        "terrainMeshingFallbackChunks": terrain_meshing_fallback_chunks,
        "terrainMeshingNativeChunks": terrain_meshing_native_chunks,
        "terrainMeshingDirectBuildDeferredWithoutNative": terrain_meshing_direct_build_deferred_without_native,
        "terrainFluidDirectBuildDeferredWithoutNative": terrain_fluid_direct_build_deferred_without_native,
        "terrainMeshingJobsQueued": terrain_meshing_jobs_queued,
        "terrainMeshingJobsProcessed": terrain_meshing_jobs_processed,
        "terrainMeshingJobsDeferredWithoutNative": terrain_meshing_jobs_deferred_without_native,
        "terrainMeshingCompletedApplied": terrain_meshing_completed_applied,
        "terrainMeshingProvisionalChunks": terrain_meshing_provisional_chunks,
        "terrainMeshingJobQueueDepth": terrain_meshing_job_queue_depth,
        "terrainMeshingCompletedQueueDepth": terrain_meshing_completed_queue_depth,
        "terrainMeshingPayloadCellsPrepared": terrain_meshing_payload_cells_prepared,
        "terrainVolumeSectionsPreparedForMesh": terrain_volume_sections_prepared_for_mesh,
        "terrainVolumeExposureScanDeferredWithoutNative": terrain_volume_exposure_scan_deferred_without_native,
        "terrainFluidJobsQueued": terrain_fluid_jobs_queued,
        "terrainFluidJobsCompleted": terrain_fluid_jobs_completed,
        "terrainFluidJobsDropped": terrain_fluid_jobs_dropped,
        "terrainFluidPayloadCellsPrepared": terrain_fluid_payload_cells_prepared,
        "terrainFluidPayloadSectionsPrepared": terrain_fluid_payload_sections_prepared,
        "terrainFluidExactCells": terrain_fluid_exact_cells,
        "terrainFluidWaterFaces": terrain_fluid_water_faces,
        "terrainFluidLavaFaces": terrain_fluid_lava_faces,
        "terrainFluidStaleResultsRejected": terrain_fluid_stale_results_rejected,
        "terrainFluidStaleMeshCleared": terrain_fluid_stale_mesh_cleared,
        "terrainFluidForbiddenCoarsePayloadAttempts": terrain_fluid_forbidden_coarse_payload_attempts,
        "surfacePropVolumeProjectionQueries": surface_prop_volume_projection_queries,
        "undergroundPropCellsScanned": underground_prop_cells_scanned,
        "undergroundPropCandidatesFound": underground_prop_candidates_found,
        "undergroundPropVolumeServiceScans": underground_prop_volume_service_scans,
        "maxTerrainMeshingPayloadPrepMs": max_terrain_meshing_payload_prep,
        "maxTerrainMeshingJobElapsedMs": max_terrain_meshing_job_elapsed,
        "maxTerrainFluidPayloadPrepMs": max_terrain_fluid_payload_prep,
        "maxTerrainFluidNativeBuildMs": max_terrain_fluid_native_build,
        "maxRuntimeGraphBuildMs": max_runtime_graph,
        "maxRuntimeGraphSnapshotMs": max_runtime_graph_snapshot,
        "maxRuntimeGraphTargetsMs": max_runtime_graph_targets,
        "maxRuntimeGraphCandidatesMs": max_runtime_graph_candidates,
        "maxRuntimeGraphContinueMs": max_runtime_graph_continue,
        "maxRuntimeGraphSyncNodesMs": max_runtime_graph_sync_nodes,
        "maxRuntimeGraphSyncEdgesMs": max_runtime_graph_sync_edges,
        "maxNavSnapshotMs": max_nav,
        "maxJobScanMs": max_job,
        "maxAutosaveMs": max_save,
        "maxAutosaveJsonReadParseMs": max_autosave_read_parse,
        "maxAutosaveJsonStringifyWriteMs": max_autosave_stringify_write,
        "navStaticRebuildCount": static_rebuild_count,
        "navDynamicUpdateCount": dynamic_update_count,
        # The legacy counters are cumulative events, not a current job census.
        # Preserve them under honest names and leave the ambiguous historical
        # fields explicitly unavailable rather than reporting false zeroes.
        "routeJobsCompleted": null,
        "routeJobsPending": null,
        "routeJobTelemetry": {
            "completedEventsAvailable": route_jobs_completed_available,
            "completedEvents": route_jobs_completed if route_jobs_completed_available else null,
            "pendingEventsAvailable": route_jobs_pending_events_available,
            "pendingEvents": route_jobs_pending if route_jobs_pending_events_available else null,
            "currentPendingAvailable": false,
            "currentPending": null,
            "semantics": "cumulative coordinator events; no authoritative current pending-job census"
        },
        "autosaveJobsCompleted": autosave_completed,
        "autosaveJobsPending": autosave_pending,
        "jobScanNodes": job_scan_nodes,
        "forageScanNodes": forage_scan_nodes,
        "indexedResourceQueries": indexed_resource_queries,
        "maxNavmeshInstallUsec": max_navmesh_install_usec,
        "maxNavmeshInstallP95Usec": max_navmesh_install_p95_usec,
        "maxNavmeshPathQueryUsec": max_navmesh_path_query_usec,
        "maxNavmeshPathQueryP95Usec": max_navmesh_path_query_p95_usec,
        "maxNavmeshPathQueryFailures": max_navmesh_path_query_failures,
        "slowestNavmeshPathQuery": slowest_navmesh_path_query,
        "treePublication": {
            "maxPending": max_tree_publication_pending,
            "maxActiveWorkers": max_tree_publication_active_workers,
            "maxCompleted": max_tree_publication_completed,
            "queued": tree_publication_queued,
            "published": tree_publication_published,
            "dropped": tree_publication_dropped,
            "maxP99Usec": max_tree_publication_p99_usec,
            "maxUsec": max_tree_publication_usec,
            "maxFrameP99Usec": max_tree_publication_frame_p99_usec,
            "maxFrameUsec": max_tree_publication_frame_usec,
            "maxSchedulerP99Usec": max_tree_publication_scheduler_p99_usec,
            "maxSchedulerUsec": max_tree_publication_scheduler_usec,
            "maxValidationP99Usec": max_tree_publication_validation_p99_usec,
            "maxValidationUsec": max_tree_publication_validation_usec,
            "maxBookkeepingP99Usec": max_tree_publication_bookkeeping_p99_usec,
            "maxBookkeepingUsec": max_tree_publication_bookkeeping_usec,
            "maxReportingP99Usec": max_tree_publication_reporting_p99_usec,
            "maxReportingUsec": max_tree_publication_reporting_usec,
            "maxUnattributedP99Usec": max_tree_publication_unattributed_p99_usec,
            "maxUnattributedUsec": max_tree_publication_unattributed_usec,
            "maxLoopTailP99Usec": max_tree_publication_loop_tail_p99_usec,
            "maxLoopTailUsec": max_tree_publication_loop_tail_usec,
            "worstFrame": worst_tree_publication_frame,
            "maxPrioritySelectionP99Usec": max_tree_priority_selection_p99_usec,
            "maxPrioritySelectionUsec": max_tree_priority_selection_usec,
            "maxPrioritySelectionCandidates": max_tree_priority_selection_candidates,
            "maxPriorityFullFallbacks": max_tree_priority_full_fallbacks,
            "maxPriorityViewlessFifoSelections": max_tree_priority_viewless_fifo_selections,
            "maxWorkerPrioritySelectionP99Usec": max_tree_worker_priority_selection_p99_usec,
            "maxWorkerPrioritySelectionUsec": max_tree_worker_priority_selection_usec,
            "maxWorkerPrioritySelectionCandidates": max_tree_worker_priority_selection_candidates,
            "maxWorkerPriorityFullFallbacks": max_tree_worker_priority_full_fallbacks,
            "maxRootP99Usec": max_tree_root_p99_usec,
            "maxBoleP99Usec": max_tree_bole_p99_usec,
            "maxDistalP99Usec": max_tree_distal_p99_usec,
            "maxFoliageP99Usec": max_tree_foliage_p99_usec,
            "maxCommitP99Usec": max_tree_commit_p99_usec,
            "maxRetierP99Usec": max_tree_retier_p99_usec,
            "maxCancellationP99Usec": max_tree_cancellation_p99_usec,
            "render": {
                "maxVisibleTrees": max_tree_render_visible_trees,
                "maxBranchInstances": max_tree_render_branch_instances,
                "maxFoliageInstances": max_tree_render_foliage_instances,
                "maxEstimatedDrawCalls": max_tree_render_draw_calls,
                "maxEstimatedTriangles": max_tree_render_triangles,
                "maxEstimatedShadowTriangles": max_tree_render_shadow_triangles,
                "maxLodDistribution": max_tree_render_lod_distribution
            }
        },
        "topSectionMaxMs": top_section_maxima(section_maxima, 20),
        "lastSpike": last_spike
    }

func top_section_maxima(section_maxima: Dictionary, limit: int) -> Array:
    var rows := []
    for section_name in section_maxima.keys():
        rows.append({
            "name": String(section_name),
            "ms": float(section_maxima.get(section_name, 0.0))
        })
    rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return float(a.get("ms", 0.0)) > float(b.get("ms", 0.0))
    )
    if rows.size() > limit:
        rows.resize(limit)
    return rows

func _runtime_cadence_provenance() -> Dictionary:
    var monitor = main.get("runtime_perf_monitor") if main != null and is_instance_valid(main) else null
    var process_frame := Engine.get_process_frames()
    if monitor == null:
        return {"processFrame": process_frame, "streamingAttributed": false}
    var frame_ms := float(monitor.get("last_frame_ms"))
    var sections: Dictionary = monitor.get("last_frame_sections") \
        if monitor.get("last_frame_sections") is Dictionary else {}
    var counters: Dictionary = monitor.get("last_frame_counters") \
        if monitor.get("last_frame_counters") is Dictionary else {}
    return NormalRuntimePerformancePassRunnerScript.classify_streaming_cadence_provenance(
        frame_ms, sections, counters, process_frame, process_frame)

static func render_phase_summary(render_summary: Dictionary, phase_label: String) -> Dictionary:
    var phases_value = render_summary.get("phases", {})
    if not (phases_value is Dictionary):
        return {}
    var phase_value = (phases_value as Dictionary).get(phase_label, {})
    return (phase_value as Dictionary).duplicate(true) if phase_value is Dictionary else {}

static func render_observation_report_summary(render_summary: Dictionary, phase_label: String) -> Dictionary:
    return {
        "schema": String(render_summary.get("schema", "")),
        "available": bool(render_summary.get("available", false)),
        "renderer": String(render_summary.get("renderer", "")),
        "initialViewportSize": render_summary.get("initialViewportSize", []),
        "viewportSize": render_summary.get("viewportSize", []),
        "viewportSizeChanges": int(render_summary.get("viewportSizeChanges", 0)),
        "renderTargetSize": render_summary.get("renderTargetSize", []),
        "renderScale3D": float(render_summary.get("renderScale3D", 0.0)),
        "renderConfigurationChanges": int(render_summary.get("renderConfigurationChanges", 0)),
        "pacingIdentity": render_summary.get("pacingIdentity", {}).duplicate(true) \
            if render_summary.get("pacingIdentity", {}) is Dictionary else {},
        "cadenceScope": String(render_summary.get("cadenceScope", "")),
        "renderScope": String(render_summary.get("renderScope", "")),
        "sizeScope": String(render_summary.get("sizeScope", "")),
        "observerCpuUsec": int(render_summary.get("observerCpuUsec", 0)),
        "observerMaxUsec": int(render_summary.get("observerMaxUsec", 0)),
        "provenanceCpuUsec": int(render_summary.get("provenanceCpuUsec", 0)),
        "provenanceMaxUsec": int(render_summary.get("provenanceMaxUsec", 0)),
        "phase": phase_label,
        "phaseSummary": render_phase_summary(render_summary, phase_label)
    }

static func append_engine_timing_monitor_sample(
    process_values: Array[float],
    physics_values: Array[float],
    navigation_values: Array[float]
) -> void:
    var process_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
    var physics_ms := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
    var navigation_ms := float(Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS)) * 1000.0
    if is_finite(process_ms) and process_ms >= 0.0:
        process_values.append(process_ms)
    if is_finite(physics_ms) and physics_ms >= 0.0:
        physics_values.append(physics_ms)
    if is_finite(navigation_ms) and navigation_ms >= 0.0:
        navigation_values.append(navigation_ms)

static func engine_timing_monitor_summary(
    process_values: Array[float],
    physics_values: Array[float],
    navigation_values: Array[float],
    sampling_overhead_values: Array[float]
) -> Dictionary:
    return {
        "scope": ENGINE_TIMING_MONITOR_SCOPE,
        "sampleIntervalMs": float(SAMPLE_INTERVAL_USEC) / 1000.0,
        "frameAligned": false,
        "exactSpikeAttribution": false,
        "cadenceSubtractionPermitted": false,
        "processFrameMs": duration_distribution(process_values),
        "physicsFrameMs": duration_distribution(physics_values),
        "navigationStepMs": duration_distribution(navigation_values),
        "samplingOverhead": duration_distribution(sampling_overhead_values)
    }

static func npc_physics_attribution_summary(
    section_percentiles: Dictionary,
    section_maxima: Dictionary,
    counters: Dictionary,
    gauges: Dictionary,
    max_gauges: Dictionary
) -> Dictionary:
    var sections := {}
    var all_sections_available := true
    for section_name: String in NPC_PHYSICS_ATTRIBUTION_SECTIONS:
        var section_value = section_percentiles.get(section_name, {})
        var distribution: Dictionary = section_value if section_value is Dictionary else {}
        sections[section_name] = {
            "retainedDistribution": distribution.duplicate(true),
            "measurementMaxMs": float(section_maxima.get(section_name, 0.0)) \
                if section_maxima.has(section_name) else null
        }
        all_sections_available = all_sections_available \
            and int(distribution.get("sampleCount", 0)) > 0 \
            and section_maxima.has(section_name)
    var counts_available := counters.has("npc_physics_callbacks") \
        and counters.has("npc_physics_owned_actor_count") \
        and counters.has("npc_physics_route_service_invocation_count") \
        and gauges.has("npc_physics_owned_actor_count") \
        and gauges.has("npc_physics_route_service_invocation_count") \
        and max_gauges.has("npc_physics_owned_actor_count") \
        and max_gauges.has("npc_physics_route_service_invocation_count")
    return {
        "available": all_sections_available and counts_available,
        "sections": sections,
        "callbackCount": int(counters.get("npc_physics_callbacks", 0)),
        "ownedActorSamplesTotal": int(counters.get("npc_physics_owned_actor_count", 0)),
        "routeServiceInvocationTotal": int(counters.get(
            "npc_physics_route_service_invocation_count", 0)),
        "currentOwnedActorCount": float(gauges.get("npc_physics_owned_actor_count", 0.0)) \
            if gauges.has("npc_physics_owned_actor_count") else null,
        "maxOwnedActorCount": float(max_gauges.get("npc_physics_owned_actor_count", 0.0)) \
            if max_gauges.has("npc_physics_owned_actor_count") else null,
        "currentRouteServiceInvocationCount": float(gauges.get(
            "npc_physics_route_service_invocation_count", 0.0)) \
            if gauges.has("npc_physics_route_service_invocation_count") else null,
        "maxRouteServiceInvocationCount": float(max_gauges.get(
            "npc_physics_route_service_invocation_count", 0.0)) \
            if max_gauges.has("npc_physics_route_service_invocation_count") else null,
        "scope": "Physics-callback and child-stage durations are nested and must not be summed. Counts report current, measurement-maximum, and cumulative route-service ownership and executor invocations; an invocation may truthfully produce no movement advance. No per-actor timing is published."
    }

static func route_plan_compliance_summary(
    section_percentiles: Dictionary,
    section_maxima: Dictionary,
    max_gauges: Dictionary,
    detailed_timing_enabled: bool
) -> Dictionary:
    var outer_value = section_percentiles.get("npc_routine_v2_plan", {})
    var outer: Dictionary = outer_value if outer_value is Dictionary else {}
    var cheap_residual_available := max_gauges.has("npc_route_plan_cheap_bookkeeping_residual_ms")
    var cheap_steps_available := max_gauges.has("npc_route_plan_cheap_steps_this_call")
    var validators_available := max_gauges.has("npc_route_plan_validator_calls_this_call")
    var outer_available := section_maxima.has("npc_routine_v2_plan")
    var outer_measurement_max_ms: Variant = float(section_maxima.get(
        "npc_routine_v2_plan", 0.0)) if outer_available else null
    var all_available := outer_available and cheap_residual_available \
        and cheap_steps_available and validators_available
    var max_cheap_steps: Variant = float(max_gauges.get(
        "npc_route_plan_cheap_steps_this_call", 0.0)) if cheap_steps_available else null
    var max_validator_calls: Variant = float(max_gauges.get(
        "npc_route_plan_validator_calls_this_call", 0.0)) if validators_available else null
    return {
        "publicationMode": "detailed_opt_in" if detailed_timing_enabled else "minimal_three_gauges",
        "outerPlanRetainedDistribution": outer.duplicate(true),
        "outerPlanMeasurementMaxMs": outer_measurement_max_ms,
        "maxCheapBookkeepingResidualMs": float(max_gauges.get(
            "npc_route_plan_cheap_bookkeeping_residual_ms", 0.0)) if cheap_residual_available else null,
        "maxCheapStepsThisCall": max_cheap_steps,
        "maxValidatorCallsThisCall": max_validator_calls,
        "cheapStepCap": ROUTE_PLAN_CHEAP_STEP_CAP,
        "validatorCallCap": ROUTE_PLAN_VALIDATOR_CALL_CAP,
        "outerPlanBudgetMs": GATE5_NPC_ROUTINE_SECTION_BUDGET_MS,
        "outerPlanBudgetMet": float(outer_measurement_max_ms) <= GATE5_NPC_ROUTINE_SECTION_BUDGET_MS \
            if outer_available else null,
        "cheapStepCapMet": float(max_cheap_steps) <= ROUTE_PLAN_CHEAP_STEP_CAP \
            if cheap_steps_available else null,
        "validatorCallCapMet": float(max_validator_calls) <= ROUTE_PLAN_VALIDATOR_CALL_CAP \
            if validators_available else null,
        "allMinimalComplianceEvidenceAvailable": all_available,
        "compliant": all_available \
            and float(outer_measurement_max_ms) <= GATE5_NPC_ROUTINE_SECTION_BUDGET_MS \
            and float(max_cheap_steps) <= ROUTE_PLAN_CHEAP_STEP_CAP \
            and float(max_validator_calls) <= ROUTE_PLAN_VALIDATOR_CALL_CAP,
        "scope": "Whole-measurement cumulative maximum npc_routine_v2_plan duration plus measurement-window maximum compliance gauges. The separately reported retained distribution contains only the last 900 section samples. Detailed phase timings are opt-in and disabled by default."
    }

static func duration_distribution(values: Array[float]) -> Dictionary:
    if values.is_empty():
        return {"samples": 0, "p50Ms": null, "p95Ms": null, "p99Ms": null, "maxMs": null, "totalMs": 0.0}
    var sorted: Array[float] = values.duplicate()
    sorted.sort()
    var total_ms := 0.0
    for value in values:
        total_ms += value
    return {
        "samples": sorted.size(),
        "p50Ms": sorted[clampi(ceili(float(sorted.size()) * 0.50) - 1, 0, sorted.size() - 1)],
        "p95Ms": sorted[clampi(ceili(float(sorted.size()) * 0.95) - 1, 0, sorted.size() - 1)],
        "p99Ms": sorted[clampi(ceili(float(sorted.size()) * 0.99) - 1, 0, sorted.size() - 1)],
        "maxMs": sorted[sorted.size() - 1],
        "totalMs": total_ms
    }

static func periodic_spike_summary(spikes_value: Variant, phase_label: String) -> Dictionary:
    var phase_spikes: Array[Dictionary] = []
    if spikes_value is Array:
        for spike_value in spikes_value:
            if not (spike_value is Dictionary):
                continue
            var spike: Dictionary = spike_value
            if String(spike.get("fromPhase", "")) != phase_label or String(spike.get("toPhase", "")) != phase_label:
                continue
            phase_spikes.append(spike)
    phase_spikes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return int(a.get("startUsec", 0)) < int(b.get("startUsec", 0))
    )
    var periodic_pairs := 0
    var gaps_seconds: Array[float] = []
    for index in range(1, phase_spikes.size()):
        var gap_seconds := float(int(phase_spikes[index].get("startUsec", 0)) \
            - int(phase_spikes[index - 1].get("startUsec", 0))) / 1000000.0
        if gap_seconds >= 2.0 and gap_seconds <= 7.0:
            periodic_pairs += 1
            gaps_seconds.append(gap_seconds)
    return {
        "phase": phase_label,
        "recordedOver33msSpikes": phase_spikes.size(),
        "periodicPairCount": periodic_pairs,
        "periodicGapsSeconds": gaps_seconds,
        "windowSeconds": [2.0, 7.0]
    }

static func gate5_presentation_failures(
    cadence: Dictionary,
    periodic_spikes: Dictionary,
    observer_available: bool,
    active_npc_count_min: int
) -> Array[String]:
    var failures: Array[String] = []
    if not observer_available:
        failures.append("presentation cadence observer was unavailable")
    var p99_value = cadence.get("p99Ms", null)
    var max_value_variant = cadence.get("maxMs", null)
    if p99_value == null:
        failures.append("presentation cadence p99 was unavailable")
    elif float(p99_value) > 22.0:
        failures.append("presentation cadence p99 exceeded the 22ms tolerance")
    if max_value_variant == null:
        failures.append("presentation cadence maximum was unavailable")
    elif float(max_value_variant) > 33.0:
        failures.append("presentation cadence maximum exceeded 33ms")
    if int(cadence.get("over33ms", 0)) != 0:
        failures.append("presentation cadence contained intervals over 33ms")
    if int(periodic_spikes.get("periodicPairCount", 0)) != 0:
        failures.append("presentation cadence contained repeating 2-7 second spike intervals")
    if active_npc_count_min != TARGET_NPC_COUNT:
        failures.append("active NPC count minimum was %d instead of exactly %d" % [active_npc_count_min, TARGET_NPC_COUNT])
    return failures

func performance_failures(metrics: Dictionary) -> Array[String]:
    var failures: Array[String] = []
    if float(metrics.get("frameP99Ms", 0.0)) > 22.0:
        failures.append("p99 frame time exceeds 22ms tolerated threshold")
    if float(metrics.get("frameMaxMs", 0.0)) > 33.0:
        failures.append("max frame time exceeds 33ms threshold")
    if float(metrics.get("maxRoutePlanMs", 0.0)) > GATE5_NPC_ROUTINE_SECTION_BUDGET_MS:
        failures.append("routine-v2 NPC planning section exceeded 2ms call budget")
    if float(metrics.get("maxNavSnapshotMs", 0.0)) > 2.0:
        failures.append("navigation snapshot rebuild exceeded 2ms frame budget")
    if float(metrics.get("maxJobScanMs", 0.0)) > 2.0:
        failures.append("job scan exceeded 2ms frame budget")
    if float(metrics.get("maxAutosaveMs", 0.0)) > 2.0:
        failures.append("autosave exceeded 2ms main-thread budget")
    if int(metrics.get("jobScanNodes", 0)) > 0 or int(metrics.get("forageScanNodes", 0)) > 0:
        failures.append("job/forage target selection used recursive scan nodes")
    if int(metrics.get("maxNavmeshInstallP95Usec", 0)) > 4000:
        failures.append("navmesh install p95 exceeded 4ms budget")
    if int(metrics.get("maxNavmeshPathQueryP95Usec", 0)) > 1000:
        failures.append("navmesh path query p95 exceeded 1ms budget")
    if acceptance_mode and int(metrics.get("autosaveJobsCompleted", 0)) <= 0:
        failures.append("acceptance workload did not complete an autosave")
    if acceptance_mode:
        failures.append_array(gate5_npc_routine_failures(metrics.get("sectionPercentiles", {})))
        failures.append_array(performance_monitor_overhead_failures(
            metrics.get("sectionPercentiles", {}), metrics.get("sectionMaxima", {})))
        var route_compliance_value = metrics.get("routePlanCompliance", {})
        if not (route_compliance_value is Dictionary):
            failures.append("route-plan compliance evidence was unavailable")
        else:
            var route_compliance: Dictionary = route_compliance_value
            if String(route_compliance.get("publicationMode", "")) != "minimal_three_gauges":
                failures.append("detailed route-plan timing mode is acceptance-ineligible")
            elif not bool(route_compliance.get("compliant", false)):
                failures.append("route-plan compliance evidence was missing or exceeded a production cap")
    return failures

static func gate5_npc_routine_failures(section_percentiles: Dictionary) -> Array[String]:
    var failures: Array[String] = []
    for section_name in CURRENT_NPC_ROUTINE_SECTIONS:
        var section_value = section_percentiles.get(section_name, null)
        if not (section_value is Dictionary) or int((section_value as Dictionary).get("sampleCount", 0)) <= 0:
            failures.append("required current NPC timing %s was unavailable" % section_name)
            continue
        var section: Dictionary = section_value
        if section.get("maxMs", null) == null:
            failures.append("required current NPC timing %s had no maximum" % section_name)
        elif float(section.get("maxMs", 0.0)) > GATE5_NPC_ROUTINE_SECTION_BUDGET_MS:
            failures.append("%s exceeded the %.1fms call budget" % [section_name, GATE5_NPC_ROUTINE_SECTION_BUDGET_MS])
    return failures

static func performance_monitor_overhead_failures(
    section_percentiles: Dictionary,
    section_maxima: Dictionary
) -> Array[String]:
    var failures: Array[String] = []
    var section_value = section_percentiles.get("performance_monitor_end_frame", null)
    if not (section_value is Dictionary) or int((section_value as Dictionary).get("sampleCount", 0)) <= 0:
        return ["performance monitor end-frame overhead timing was unavailable"]
    var section: Dictionary = section_value
    if section.get("p99Ms", null) == null or float(section.get("p99Ms", 0.0)) > PERFORMANCE_MONITOR_END_FRAME_P99_BUDGET_MS:
        failures.append("performance monitor end-frame overhead p99 exceeded %.1fms" % PERFORMANCE_MONITOR_END_FRAME_P99_BUDGET_MS)
    if not section_maxima.has("performance_monitor_end_frame"):
        failures.append("performance monitor end-frame overhead cumulative maximum was unavailable")
    elif float(section_maxima.get("performance_monitor_end_frame", 0.0)) > PERFORMANCE_MONITOR_END_FRAME_MAX_BUDGET_MS:
        failures.append("performance monitor end-frame overhead maximum exceeded %.1fms" % PERFORMANCE_MONITOR_END_FRAME_MAX_BUDGET_MS)
    return failures

func summarize_results(results: Array) -> Dictionary:
    var worst := {}
    for result_value in results:
        var result: Dictionary = result_value
        var metrics: Dictionary = result.get("metrics", {})
        var worst_metrics: Dictionary = worst.get("metrics", {}) if worst.get("metrics", {}) is Dictionary else {}
        if float(metrics.get("frameMaxMs", 0.0)) > float(worst_metrics.get("frameMaxMs", 0.0)):
            worst = result
    return {
        "scenarioCount": results.size(),
        "worstScenario": String(worst.get("scenario", "")),
        "worstMetrics": worst.get("metrics", {})
    }

func percentile(values: Array, ratio: float) -> float:
    if values.is_empty():
        return 0.0
    var sorted := values.duplicate()
    sorted.sort()
    var index := clampi(ceili(float(sorted.size()) * ratio) - 1, 0, sorted.size() - 1)
    return float(sorted[index])

func max_value(values: Array) -> float:
    var result := 0.0
    for value in values:
        result = maxf(result, float(value))
    return result

func write_progress(label: String) -> void:
    if progress_path == "":
        return
    var file := FileAccess.open(progress_path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\n" % label)
    file.close()

func write_report(report: Dictionary) -> void:
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        push_error("Unable to write runtime performance report: %s" % report_path)
        return
    file.store_string(JSON.stringify(report, "  "))
    file.close()

func make_failure_report(reason: String) -> Dictionary:
    return {
        "schemaVersion": 1,
        "suite": "runtime_performance_observation",
        "startupScope": "ordinary_startup_gate5_32_npc" if acceptance_mode else "ordinary_startup_diagnostic_scenarios",
        "gameplayAcceptance": acceptance_mode,
        "acceptanceMode": acceptance_mode,
        "scenario": scenario,
        "seed": seed,
        "runToken": run_token,
        "resultCount": 1,
        "failureCount": 1,
        "results": [{
            "id": "runtime_perf_failure",
            "scenario": scenario,
            "passed": false,
            "details": reason
        }]
    }

func finish(code: int) -> void:
    if finished:
        return
    finished = true
    pending_exit_code = code
    if is_instance_valid(render_observation):
        render_observation.call("stop")
    write_progress("finished")
    if scenario_retirement_active:
        return # The in-flight owner drains finish before the process exits.
    if is_instance_valid(main) and main.is_inside_tree():
        main.request_graceful_quit(code)
        return
    get_tree().quit(code)

func elapsed_ms(start_usec: int) -> float:
    return float(Time.get_ticks_usec() - start_usec) / 1000.0
