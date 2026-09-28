extends SceneTree

const RunnerScript := preload("res://scripts/testing/RuntimePerformanceObservationRunner.gd")
const NormalRunnerScript := preload("res://scripts/testing/NormalRuntimePerformancePassRunner.gd")
const MonitorScript := preload("res://scripts/perf/RuntimePerformanceMonitor.gd")
const RenderObservationScript := preload("res://scripts/perf/RuntimeRenderObservation.gd")

func _initialize() -> void:
    var report_path := OS.get_environment("VOXEL_RUNTIME_PERF_CONTRACT_REPORT").strip_edges()
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/test-runners/runtime-performance-observation-contract.json")
    var checks: Array[Dictionary] = []
    var phase := "Gate5Town32Npc:measure"
    var spikes := [
        {"startUsec": 1000000, "fromPhase": phase, "toPhase": phase, "durationMs": 34.0},
        {"startUsec": 4000000, "fromPhase": phase, "toPhase": phase, "durationMs": 35.0},
        {"startUsec": 12000000, "fromPhase": phase, "toPhase": phase, "durationMs": 36.0},
        {"startUsec": 15000000, "fromPhase": "other", "toPhase": "other", "durationMs": 37.0}
    ]
    var periodic: Dictionary = RunnerScript.periodic_spike_summary(spikes, phase)
    check(checks, "periodic_spikes_are_scoped_to_the_measured_phase", int(periodic.get("recordedOver33msSpikes", 0)) == 3)
    check(checks, "periodic_2_to_7_second_pairs_are_counted", int(periodic.get("periodicPairCount", 0)) == 1)
    var passing_cadence := {"p99Ms": 16.7, "maxMs": 33.0, "over33ms": 0}
    check(checks, "gate5_cadence_boundaries_and_32_active_npcs_pass",
        RunnerScript.gate5_presentation_failures(passing_cadence, {"periodicPairCount": 0}, true, 32).is_empty())
    var tolerated := {"p99Ms": 21.9, "maxMs": 32.9, "over33ms": 0}
    check(checks, "declared_22ms_p99_tolerance_is_accepted",
        RunnerScript.gate5_presentation_failures(tolerated, {"periodicPairCount": 0}, true, 32).is_empty())
    var failures: Array[String] = RunnerScript.gate5_presentation_failures(
        {"p99Ms": 22.1, "maxMs": 33.1, "over33ms": 1},
        {"periodicPairCount": 1},
        false,
        31
    )
    check(checks, "every_gate5_failure_dimension_is_fail_closed", failures.size() == 6)
    var summary := RunnerScript.render_phase_summary({"phases": {phase: {"cadence": passing_cadence}}}, phase)
    check(checks, "public_render_observation_phase_summary_is_consumed", summary.get("cadence", {}) == passing_cadence)
    var render_report := RunnerScript.render_observation_report_summary({
        "schema": "runtime_render_observation/v2",
        "available": true,
        "renderer": "gl_compatibility",
        "viewportSize": [1280, 720],
        "renderTargetSize": [1280, 720],
        "renderScale3D": 1.0,
        "cadenceScope": "cadence contract",
        "renderScope": "render contract",
        "sizeScope": "size contract",
        "pacingIdentity": {"launchModeEnv": "ordinary_realtime_project_pacing"},
        "phases": {phase: {
            "cadence": passing_cadence,
            "renderCpu": {"p99Ms": 2.0},
            "renderGpu": {"p99Ms": 3.0},
            "frameSetupCpu": {"p99Ms": 0.5},
            "drawCallsMax": 42
        }}
    }, phase)
    var render_phase: Dictionary = render_report.get("phaseSummary", {})
    check(checks, "render_report_preserves_cpu_gpu_setup_draw_and_configuration",
        String(render_report.get("renderer", "")) == "gl_compatibility" \
        and render_report.get("viewportSize", []) == [1280, 720] \
        and render_phase.get("renderCpu", {}).get("p99Ms", 0.0) == 2.0 \
        and render_phase.get("renderGpu", {}).get("p99Ms", 0.0) == 3.0 \
        and render_phase.get("frameSetupCpu", {}).get("p99Ms", 0.0) == 0.5 \
        and int(render_phase.get("drawCallsMax", 0)) == 42)
    check(checks, "render_report_preserves_measurement_scopes_and_pacing_identity",
        String(render_report.get("cadenceScope", "")) == "cadence contract" \
        and String(render_report.get("renderScope", "")) == "render contract" \
        and String(render_report.get("sizeScope", "")) == "size contract" \
        and String(render_report.get("pacingIdentity", {}).get("launchModeEnv", "")) \
            == "ordinary_realtime_project_pacing")
    var render_observer = RenderObservationScript.new()
    var pacing_identity: Dictionary = render_observer.summary().get("pacingIdentity", {})
    check(checks, "render_summary_discloses_runtime_pacing_identity",
        pacing_identity.has("launchModeEnv") \
        and pacing_identity.has("effectiveVsyncMode") \
        and pacing_identity.has("screenRefreshRateHz") \
        and int(pacing_identity.get("engineMaxFps", -1)) == Engine.max_fps \
        and int(pacing_identity.get("physicsTicksPerSecond", -1)) == Engine.physics_ticks_per_second \
        and pacing_identity.has("configuredFrameQueueSize") \
        and pacing_identity.has("configuredSwapchainImageCount"))
    check(checks, "pacing_identity_distinguishes_frame_queue_and_swapchain_settings",
        String(pacing_identity.get("configuredFrameQueueSetting", "")) \
            == "rendering/rendering_device/vsync/frame_queue_size" \
        and String(pacing_identity.get("configuredSwapchainImageCountSetting", "")) \
            == "rendering/rendering_device/vsync/swapchain_image_count" \
        and bool(pacing_identity.get("configuredFrameQueueSizeAvailable", false)) \
            == (pacing_identity.get("configuredFrameQueueSize") != null) \
        and bool(pacing_identity.get("configuredSwapchainImageCountAvailable", false)) \
            == (pacing_identity.get("configuredSwapchainImageCount") != null))
    check(checks, "missing_integer_project_setting_is_reported_as_unavailable",
        RenderObservationScript.configured_int_project_setting(
            "testing/runtime_render_observation/int_setting_that_does_not_exist") == null)
    render_observer.free()
    var preserved_frame_scope := "Main game script _process callback only; excludes rendering and physics."
    var scope_runner = RunnerScript.new()
    var summarized_scope: Dictionary = scope_runner.summarize_samples([{
        "frameMs": 1.0,
        "frameMetricScope": preserved_frame_scope,
        "perfSectionMaxMs": {},
        "perfCounters": {}
    }])
    check(checks, "sample_frame_metric_scope_survives_summary_reduction",
        String(summarized_scope.get("frameMetricScope", "")) == preserved_frame_scope)
    var omitted_scope_summary: Dictionary = scope_runner.summarize_samples([{
        "frameMs": 1.0,
        "perfSectionMaxMs": {},
        "perfCounters": {}
    }])
    check(checks, "omitted_compact_snapshot_uses_exact_monitor_owned_frame_scope",
        String(omitted_scope_summary.get("frameMetricScope", "")) \
            == MonitorScript.FRAME_METRIC_SCOPE \
        and not String(omitted_scope_summary.get("frameMetricScope", "")).is_empty())
    scope_runner.free()
    var overhead := RunnerScript.duration_distribution([4.0, 1.0, 3.0, 2.0] as Array[float])
    check(checks, "sampling_overhead_distribution_is_order_independent",
        int(overhead.get("samples", 0)) == 4 \
        and float(overhead.get("p50Ms", 0.0)) == 2.0 \
        and float(overhead.get("p95Ms", 0.0)) == 4.0 \
        and float(overhead.get("totalMs", 0.0)) == 10.0)
    var engine_timing := RunnerScript.engine_timing_monitor_summary(
        [10.0, 12.0, 11.0] as Array[float],
        [4.0, 6.0, 5.0] as Array[float],
        [0.1, 0.3, 0.2] as Array[float],
        [0.01, 0.02] as Array[float]
    )
    check(checks, "engine_timing_monitor_distributions_preserve_each_distinct_domain",
        int(engine_timing.get("processFrameMs", {}).get("samples", 0)) == 3 \
        and float(engine_timing.get("processFrameMs", {}).get("p50Ms", 0.0)) == 11.0 \
        and float(engine_timing.get("physicsFrameMs", {}).get("maxMs", 0.0)) == 6.0 \
        and float(engine_timing.get("navigationStepMs", {}).get("p95Ms", 0.0)) == 0.3 \
        and int(engine_timing.get("samplingOverhead", {}).get("samples", 0)) == 2)
    check(checks, "engine_timing_monitor_scope_forbids_false_frame_alignment_and_subtraction",
        not bool(engine_timing.get("frameAligned", true)) \
        and not bool(engine_timing.get("exactSpikeAttribution", true)) \
        and not bool(engine_timing.get("cadenceSubtractionPermitted", true)) \
        and String(engine_timing.get("scope", "")).contains("up to one second late") \
        and String(engine_timing.get("scope", "")).contains("must not be subtracted"))
    var route_compliance := RunnerScript.route_plan_compliance_summary(
        {"npc_routine_v2_plan": {"sampleCount": 8, "p99Ms": 1.6, "maxMs": 1.9}},
        {"npc_routine_v2_plan": 1.9},
        {
            "npc_route_plan_cheap_bookkeeping_residual_ms": 1.2,
            "npc_route_plan_cheap_steps_this_call": 48.0,
            "npc_route_plan_validator_calls_this_call": 2.0
        },
        false
    )
    check(checks, "minimal_route_plan_compliance_uses_outer_section_and_exact_three_gauge_maxima",
        String(route_compliance.get("publicationMode", "")) == "minimal_three_gauges" \
        and bool(route_compliance.get("allMinimalComplianceEvidenceAvailable", false)) \
        and bool(route_compliance.get("outerPlanBudgetMet", false)) \
        and bool(route_compliance.get("cheapStepCapMet", false)) \
        and bool(route_compliance.get("validatorCallCapMet", false)) \
        and bool(route_compliance.get("compliant", false)))
    var npc_physics_sections := {}
    var npc_physics_maxima := {}
    for section_name: String in RunnerScript.NPC_PHYSICS_ATTRIBUTION_SECTIONS:
        npc_physics_sections[section_name] = {
            "sampleCount": 120,
            "p50Ms": 0.2,
            "p95Ms": 0.4,
            "p99Ms": 0.6,
            "maxMs": 0.8
        }
        npc_physics_maxima[section_name] = 0.8
    var npc_physics_attribution := RunnerScript.npc_physics_attribution_summary(
        npc_physics_sections,
        npc_physics_maxima,
        {
            "npc_physics_callbacks": 120,
            "npc_physics_owned_actor_count": 240,
            "npc_physics_route_service_invocation_count": 180
        },
        {
            "npc_physics_owned_actor_count": 1.0,
            "npc_physics_route_service_invocation_count": 2.0
        },
        {
            "npc_physics_owned_actor_count": 3.0,
            "npc_physics_route_service_invocation_count": 4.0
        }
    )
    check(checks, "default_observation_preserves_npc_physics_stages_and_counts",
        bool(npc_physics_attribution.get("available", false)) \
        and (npc_physics_attribution.get("sections", {}) as Dictionary).size() == 6 \
        and int(npc_physics_attribution.get("callbackCount", 0)) == 120 \
        and int(npc_physics_attribution.get("ownedActorSamplesTotal", 0)) == 240 \
        and int(npc_physics_attribution.get("routeServiceInvocationTotal", 0)) == 180 \
        and float(npc_physics_attribution.get("currentOwnedActorCount", 0.0)) == 1.0 \
        and float(npc_physics_attribution.get("maxOwnedActorCount", 0.0)) == 3.0 \
        and float(npc_physics_attribution.get("currentRouteServiceInvocationCount", 0.0)) == 2.0 \
        and float(npc_physics_attribution.get("maxRouteServiceInvocationCount", 0.0)) == 4.0)
    var incomplete_npc_physics_attribution := RunnerScript.npc_physics_attribution_summary(
        {"npc_physics_callback": {"sampleCount": 1}},
        {"npc_physics_callback": 0.1},
        {},
        {},
        {}
    )
    check(checks, "npc_physics_attribution_is_explicitly_unavailable_when_a_stage_is_missing",
        not bool(incomplete_npc_physics_attribution.get("available", true)) \
        and incomplete_npc_physics_attribution.get("maxOwnedActorCount", 0.0) == null \
        and incomplete_npc_physics_attribution.get("maxRouteServiceInvocationCount", 0.0) == null)
    var missing_npc_physics_counts := RunnerScript.npc_physics_attribution_summary(
        npc_physics_sections,
        npc_physics_maxima,
        {},
        {},
        {}
    )
    check(checks, "npc_physics_attribution_is_unavailable_when_counts_or_gauges_are_missing",
        not bool(missing_npc_physics_counts.get("available", true)) \
        and int(missing_npc_physics_counts.get("callbackCount", -1)) == 0 \
        and missing_npc_physics_counts.get("currentOwnedActorCount", 0.0) == null \
        and missing_npc_physics_counts.get("maxRouteServiceInvocationCount", 0.0) == null)
    var unavailable_route_compliance := RunnerScript.route_plan_compliance_summary(
        {"npc_routine_v2_plan": {"sampleCount": 1, "maxMs": 1.0}}, {}, {}, true
    )
    check(checks, "missing_minimal_route_gauges_are_explicitly_unavailable_in_detailed_mode",
        String(unavailable_route_compliance.get("publicationMode", "")) == "detailed_opt_in" \
        and not bool(unavailable_route_compliance.get("allMinimalComplianceEvidenceAvailable", true)) \
        and unavailable_route_compliance.get("maxCheapStepsThisCall", 0) == null \
        and not bool(unavailable_route_compliance.get("compliant", true)))
    var aged_route_monitor = MonitorScript.new()
    aged_route_monitor.observe_external_duration("npc_routine_v2_plan", 3.5)
    for _sample_index in range(900):
        aged_route_monitor.observe_external_duration("npc_routine_v2_plan", 1.0)
    aged_route_monitor.observe_gauge("npc_route_plan_cheap_bookkeeping_residual_ms", 0.8)
    aged_route_monitor.observe_gauge("npc_route_plan_cheap_steps_this_call", 48.0)
    aged_route_monitor.observe_gauge("npc_route_plan_validator_calls_this_call", 2.0)
    var aged_route_monitor_summary: Dictionary = aged_route_monitor.summary()
    var aged_route_compliance := RunnerScript.route_plan_compliance_summary(
        aged_route_monitor.section_percentiles(),
        aged_route_monitor_summary.get("sectionMaxMs", {}),
        aged_route_monitor_summary.get("maxGauges", {}),
        false
    )
    check(checks, "early_route_plan_budget_violation_cannot_age_out_after_900_retained_samples",
        float(aged_route_compliance.get("outerPlanRetainedDistribution", {}).get("maxMs", 0.0)) == 1.0 \
        and float(aged_route_compliance.get("outerPlanMeasurementMaxMs", 0.0)) == 3.5 \
        and not bool(aged_route_compliance.get("outerPlanBudgetMet", true)) \
        and not bool(aged_route_compliance.get("compliant", true)) \
        and String(aged_route_compliance.get("scope", "")).contains("last 900"))
    var material_streaming := NormalRunnerScript.classify_streaming_cadence_provenance(
        35.0, {"chunk": 5.0, "update_npcs": 3.0}, {}, 120, 120
    )
    check(checks, "exact_material_dominant_streaming_domain_is_attributed",
        bool(material_streaming.get("streamingAttributed", false)) \
        and String(material_streaming.get("streamingOwner", "")) == "chunk")
    var tiny_streaming := NormalRunnerScript.classify_streaming_cadence_provenance(
        35.0, {"chunk": 3.9, "update_npcs": 3.0}, {}, 121, 121
    )
    check(checks, "sub_four_millisecond_streaming_owner_is_not_attributed",
        not bool(tiny_streaming.get("streamingAttributed", true)))
    var broad_name_false_positive := NormalRunnerScript.classify_streaming_cadence_provenance(
        35.0, {"npc_motor_terrain_grounding": 12.0, "update_npcs": 12.0, "chunk": 1.0}, {}, 122, 122
    )
    check(checks, "nested_terrain_named_npc_work_is_not_streaming",
        not bool(broad_name_false_positive.get("streamingAttributed", true)) \
        and String(broad_name_false_positive.get("dominantTopLevelDomain", "")) == "npc")
    var mismatched_frame := NormalRunnerScript.classify_streaming_cadence_provenance(
        35.0, {"chunk": 8.0}, {}, 123, 124
    )
    check(checks, "stale_frame_provenance_is_rejected",
        not bool(mismatched_frame.get("streamingAttributed", true)))
    var authoritative_overrun := NormalRunnerScript.classify_streaming_cadence_provenance(
        35.0, {"chunk": 1.0, "update_npcs": 10.0}, {"gameplay_publication_budget_overrun": 1}, 125, 125
    )
    check(checks, "authoritative_publication_overrun_is_attributed_without_name_guessing",
        bool(authoritative_overrun.get("streamingAttributed", false)) \
        and String(authoritative_overrun.get("streamingOwner", "")).begins_with("overrun:"))
    var short_classification := NormalRunnerScript.gate5_evidence_classification("NormalSprintTraversal", 299.0)
    var focused_classification := NormalRunnerScript.gate5_evidence_classification("NormalWorldEditLatency", 300.0)
    var acceptance_classification := NormalRunnerScript.gate5_evidence_classification("NormalSprintTraversal", 300.0)
    check(checks, "short_and_focused_runs_are_explicitly_gate5_ineligible",
        not bool(short_classification.get("eligible", true)) \
        and String(short_classification.get("classification", "")) == "diagnostic" \
        and not bool(focused_classification.get("eligible", true)))
    check(checks, "full_sprint_configuration_is_gate5_eligible",
        bool(acceptance_classification.get("eligible", false)))
    check(checks, "cumulative_physics_hold_delta_is_fail_closed",
        NormalRunnerScript.cumulative_collision_hold_delta(17, 20) == 3 \
        and NormalRunnerScript.cumulative_collision_hold_delta(20, 17) == 0)
    var physical_a := live_capsule_entry("physical_a", Vector3.ZERO, 0.34, 1.62, 0.42, 1.72)
    var physical_b := live_capsule_entry("physical_b", Vector3(0.70, 0.0, 0.0), 0.34, 1.62, 0.42, 1.72)
    await process_frame
    var separation_070: Dictionary = RunnerScript.audit_capsule_overlap([physical_a, physical_b])
    check(checks, "0_70m_separation_passes_live_physical_capsules_but_reports_clearance_intrusion",
        bool(separation_070.get("ok", false)) \
        and int(separation_070.get("physicalOverlapCount", -1)) == 0 \
        and int(separation_070.get("clearanceEnvelopeIntrusionCount", 0)) == 1 \
        and not bool(separation_070.get("clearanceEnvelopeIsGating", true)))
    (physical_b.get("body") as CharacterBody3D).position.x = 0.66
    var separation_066: Dictionary = RunnerScript.audit_capsule_overlap([physical_a, physical_b])
    check(checks, "0_66m_separation_fails_live_physical_capsules",
        not bool(separation_066.get("ok", true)) \
        and int(separation_066.get("physicalOverlapCount", 0)) == 1 \
        and absf(float((separation_066.get("overlaps", []) as Array)[0].get("penetration", 0.0)) - 0.02) < 0.0001)
    (physical_a.get("body") as CharacterBody3D).get_node("Capsule").scale = Vector3.ONE * 0.5
    (physical_b.get("body") as CharacterBody3D).get_node("Capsule").scale = Vector3.ONE * 0.5
    (physical_b.get("body") as CharacterBody3D).position.x = 0.35
    var scaled_separation: Dictionary = RunnerScript.audit_capsule_overlap([physical_a, physical_b])
    check(checks, "uniform_collision_shape_scale_is_applied_to_physical_and_clearance_capsules",
        bool(scaled_separation.get("ok", false)) \
        and int(scaled_separation.get("physicalOverlapCount", -1)) == 0 \
        and int(scaled_separation.get("clearanceEnvelopeIntrusionCount", 0)) == 1)
    var missing_capsule := live_capsule_entry("missing_capsule", Vector3(2.0, 0.0, 0.0), 0.34, 1.62, 0.42, 1.72, "missing")
    var disabled_capsule := live_capsule_entry("disabled_capsule", Vector3(3.0, 0.0, 0.0), 0.34, 1.62, 0.42, 1.72, "disabled")
    var ambiguous_capsule := live_capsule_entry("ambiguous_capsule", Vector3(4.0, 0.0, 0.0), 0.34, 1.62, 0.42, 1.72, "ambiguous")
    await process_frame
    var invalid_authority: Dictionary = RunnerScript.audit_capsule_overlap([
        missing_capsule, disabled_capsule, ambiguous_capsule])
    var invalid_reasons := {}
    for invalid_value in invalid_authority.get("invalidColliders", []):
        if invalid_value is Dictionary:
            invalid_reasons[String(invalid_value.get("actorId", ""))] = String(invalid_value.get("reason", ""))
    check(checks, "missing_disabled_and_ambiguous_live_capsules_are_invalid",
        not bool(invalid_authority.get("ok", true)) \
        and int(invalid_authority.get("invalidColliderCount", 0)) == 3 \
        and invalid_reasons.get("missing_capsule") == "missing_enabled_live_capsule" \
        and invalid_reasons.get("disabled_capsule") == "missing_enabled_live_capsule" \
        and invalid_reasons.get("ambiguous_capsule") == "ambiguous_enabled_live_capsules")
    var invalid_tracker := {"sampleCount": 0, "pairs": {}}
    RunnerScript.update_overlap_persistence_tracker(invalid_tracker, invalid_authority, 0)
    var invalid_summary: Dictionary = RunnerScript.summarize_overlap_persistence_tracker(invalid_tracker)
    check(checks, "invalid_live_collider_authority_fails_closed_in_persistence_summary",
        not bool(invalid_summary.get("ok", true)) \
        and int(invalid_summary.get("invalidColliderSamples", 0)) == 1 \
        and String(invalid_summary.get("classification", "")) == "invalid_physical_collider_authority")
    var shallow_overlap_tracker := {"sampleCount": 0, "pairs": {}}
    for sample_usec in [0, 125000, 250000, 375000]:
        RunnerScript.update_overlap_persistence_tracker(
            shallow_overlap_tracker,
            overlap_audit("resident_a", "resident_b", 0.079, 0.04, 0.04),
            sample_usec
        )
    var shallow_overlap_summary: Dictionary = RunnerScript.summarize_overlap_persistence_tracker(
        shallow_overlap_tracker
    )
    check(checks, "shallow_penetration_within_summed_safe_margins_never_becomes_persistent",
        bool(shallow_overlap_summary.get("ok", false)) \
        and int(shallow_overlap_summary.get("persistentPairCount", -1)) == 0 \
        and String(shallow_overlap_summary.get("classification", "")) == "transient_contact_only")
    var changing_pair_tracker := {"sampleCount": 0, "pairs": {}}
    RunnerScript.update_overlap_persistence_tracker(
        changing_pair_tracker, overlap_audit("resident_a", "resident_b", 0.2), 0)
    RunnerScript.update_overlap_persistence_tracker(
        changing_pair_tracker, overlap_audit("resident_a", "resident_c", 0.2), 125000)
    RunnerScript.update_overlap_persistence_tracker(
        changing_pair_tracker, overlap_audit("resident_b", "resident_c", 0.2), 250000)
    var changing_pair_summary: Dictionary = RunnerScript.summarize_overlap_persistence_tracker(
        changing_pair_tracker
    )
    check(checks, "changing_actor_pairs_remain_transient",
        bool(changing_pair_summary.get("ok", false)) \
        and int(changing_pair_summary.get("observedPairCount", 0)) == 3 \
        and int(changing_pair_summary.get("persistentPairCount", -1)) == 0)
    var persistent_pair_tracker := {"sampleCount": 0, "pairs": {}}
    RunnerScript.update_overlap_persistence_tracker(
        persistent_pair_tracker, overlap_audit("resident_a", "resident_b", 0.2), 0)
    RunnerScript.update_overlap_persistence_tracker(
        persistent_pair_tracker, overlap_audit("resident_b", "resident_a", 0.2), 125000)
    RunnerScript.update_overlap_persistence_tracker(
        persistent_pair_tracker, overlap_audit("resident_a", "resident_b", 0.2), 250000)
    var persistent_pair_summary: Dictionary = RunnerScript.summarize_overlap_persistence_tracker(
        persistent_pair_tracker
    )
    check(checks, "same_materially_penetrating_pair_becomes_persistent_after_250ms",
        not bool(persistent_pair_summary.get("ok", true)) \
        and int(persistent_pair_summary.get("observedPairCount", 0)) == 1 \
        and int(persistent_pair_summary.get("persistentPairCount", 0)) == 1 \
        and String(persistent_pair_summary.get("classification", "")) == "persistent_material_overlap")
    RunnerScript.update_overlap_persistence_tracker(
        persistent_pair_tracker, {"ok": true, "overlapCount": 0, "overlaps": []}, 375000)
    RunnerScript.update_overlap_persistence_tracker(
        persistent_pair_tracker, overlap_audit("resident_a", "resident_b", 0.2), 500000)
    var reset_streak_summary: Dictionary = RunnerScript.summarize_overlap_persistence_tracker(
        persistent_pair_tracker
    )
    var reset_streak_pairs: Array = reset_streak_summary.get("observedPairs", []) \
        if reset_streak_summary.get("observedPairs", []) is Array else []
    check(checks, "maximum_consecutive_overlap_samples_survive_a_later_streak_reset",
        reset_streak_pairs.size() == 1 \
        and int((reset_streak_pairs[0] as Dictionary).get("maxConsecutiveSamples", 0)) == 3)
    var monitor = MonitorScript.new()
    for value in range(905):
        monitor.observe_external_duration("bounded", float(value))
    var retained: Array = monitor.section_sample_values("bounded")
    var bounded_percentiles: Dictionary = monitor.section_percentiles().get("bounded", {})
    check(checks, "section_history_is_a_fixed_last_900_sample_ring_in_chronological_order",
        retained.size() == 900 and retained[0] == 5.0 and retained[899] == 904.0)
    check(checks, "section_ring_percentiles_use_exact_retained_last_900_samples",
        int(bounded_percentiles.get("sampleCount", 0)) == 900 \
        and float(bounded_percentiles.get("p50Ms", 0.0)) == 454.0 \
        and float(bounded_percentiles.get("p95Ms", 0.0)) == 859.0 \
        and float(bounded_percentiles.get("p99Ms", 0.0)) == 895.0 \
        and float(bounded_percentiles.get("maxMs", 0.0)) == 904.0)
    monitor.reset()
    monitor.begin_frame(0.016)
    monitor.observe_duration("first_frame", 1.0)
    monitor.increment_counter("first_counter")
    monitor.end_frame()
    var external_summary: Dictionary = monitor.summary()
    external_summary.get("lastFrameSections", {})["first_frame"] = 999.0
    var external_history: Array = monitor.frame_sample_history()
    (external_history[0] as Dictionary).get("sections", {})["first_frame"] = 888.0
    monitor.begin_frame(0.016)
    monitor.observe_duration("second_frame", 2.0)
    monitor.end_frame()
    var preserved_history: Array = monitor.frame_sample_history()
    check(checks, "completed_frame_references_are_immutable_across_new_frames_and_external_snapshots",
        float((preserved_history[0] as Dictionary).get("sections", {}).get("first_frame", 0.0)) == 1.0 \
        and not (preserved_history[0] as Dictionary).get("sections", {}).has("second_frame") \
        and float(monitor.summary().get("lastFrameSections", {}).get("second_frame", 0.0)) == 2.0)
    var current_sections := {
        "npc_routine_v2_candidates": {"sampleCount": 2, "maxMs": 1.0},
        "npc_routine_v2_plan": {"sampleCount": 2, "maxMs": 2.0},
        "npc_routine_v2_probe_commit": {"sampleCount": 2, "maxMs": 0.5}
    }
    check(checks, "gate5_accepts_present_bounded_current_routine_v2_sections",
        RunnerScript.gate5_npc_routine_failures(current_sections).is_empty())
    var stale_only := {"route_planning": {"sampleCount": 100, "maxMs": 0.0}}
    check(checks, "stale_legacy_route_planning_cannot_satisfy_gate5_current_section_evidence",
        RunnerScript.gate5_npc_routine_failures(stale_only).size() == 3)
    current_sections["npc_routine_v2_probe_commit"] = {"sampleCount": 2, "maxMs": 2.01}
    check(checks, "gate5_current_routine_v2_budget_is_fail_closed",
        RunnerScript.gate5_npc_routine_failures(current_sections).size() == 1)
    var bounded_monitor := {
        "performance_monitor_end_frame": {"sampleCount": 900, "p99Ms": 0.5, "maxMs": 1.0}
    }
    check(checks, "performance_monitor_overhead_boundary_is_accepted",
        RunnerScript.performance_monitor_overhead_failures(
            bounded_monitor, {"performance_monitor_end_frame": 1.0}).is_empty())
    check(checks, "performance_monitor_overhead_missing_and_over_budget_are_fail_closed",
        RunnerScript.performance_monitor_overhead_failures({}, {}).size() == 1 \
        and RunnerScript.performance_monitor_overhead_failures({
            "performance_monitor_end_frame": {"sampleCount": 1, "p99Ms": 0.51, "maxMs": 1.01}
        }, {"performance_monitor_end_frame": 1.01}).size() == 2)
    var aged_overhead_monitor = MonitorScript.new()
    aged_overhead_monitor.observe_external_duration("performance_monitor_end_frame", 1.5)
    for _sample_index in range(900):
        aged_overhead_monitor.observe_external_duration("performance_monitor_end_frame", 0.1)
    var aged_overhead_summary: Dictionary = aged_overhead_monitor.summary()
    var aged_overhead_distribution: Dictionary = aged_overhead_monitor.section_percentiles()
    check(checks, "early_monitor_overhead_maximum_cannot_age_out_after_900_retained_samples",
        float(aged_overhead_distribution.get("performance_monitor_end_frame", {}).get("maxMs", 0.0)) == 0.1 \
        and float(aged_overhead_summary.get("sectionMaxMs", {}).get("performance_monitor_end_frame", 0.0)) == 1.5 \
        and RunnerScript.performance_monitor_overhead_failures(
            aged_overhead_distribution, aged_overhead_summary.get("sectionMaxMs", {})).size() == 1)
    var acceptance_runner = RunnerScript.new()
    acceptance_runner.acceptance_mode = true
    var acceptance_metrics := {
        "autosaveJobsCompleted": 1,
        "sectionPercentiles": {
            "npc_routine_v2_candidates": {"sampleCount": 1, "maxMs": 0.5},
            "npc_routine_v2_plan": {"sampleCount": 1, "maxMs": 0.5},
            "npc_routine_v2_probe_commit": {"sampleCount": 1, "maxMs": 0.5},
            "performance_monitor_end_frame": {"sampleCount": 1, "p99Ms": 0.1, "maxMs": 0.1}
        },
        "sectionMaxima": {"performance_monitor_end_frame": 0.1},
        "routePlanCompliance": {"publicationMode": "minimal_three_gauges", "compliant": false}
    }
    check(checks, "acceptance_fails_closed_when_minimal_route_compliance_is_missing_or_exceeded",
        acceptance_runner.performance_failures(acceptance_metrics).has(
            "route-plan compliance evidence was missing or exceeded a production cap"))
    acceptance_metrics["routePlanCompliance"] = {"publicationMode": "detailed_opt_in", "compliant": false}
    check(checks, "detailed_route_timing_mode_is_explicitly_acceptance_ineligible",
        acceptance_runner.performance_failures(acceptance_metrics).has(
            "detailed route-plan timing mode is acceptance-ineligible"))
    acceptance_runner.free()
    var source_records := {
        "420,0": [town_home_record("420,0", 0, Vector2i(421, 1)), town_home_record("420,0", 1, Vector2i(431, 1))]
    }
    var source_audit: Dictionary = RunnerScript.audit_town_home_sources(source_records, 2)
    check(checks, "gate5_town_sources_require_unique_stable_actor_home_door_and_town_provenance",
        bool(source_audit.get("ok", false)) \
        and int(source_audit.get("validRecordCount", 0)) == 2 \
        and int(source_audit.get("uniqueStableHomeIdCount", 0)) == 2 \
        and int(source_audit.get("uniqueDoorPortalIdCount", 0)) == 2)
    var source_entries := []
    for resident_index in range(4):
        var record: Dictionary = source_records["420,0"][resident_index % 2]
        source_entries.append({
            "id": "420,0:resident:%02d" % resident_index,
            "gate5SourceHomeRecordId": record.id,
            "homeStableId": record.stableId,
            "doorPortalId": record.doorPortalId,
            "townKey": record.townKey,
            "homeCell": record.homeCell,
            "porchCell": record.porchCell,
            "doorCell": record.doorCell,
            "interiorMinCell": record.interiorMinCell,
            "interiorMaxCell": record.interiorMaxCell,
            "body": null
        })
    var actor_audit: Dictionary = RunnerScript.audit_spawned_town_actor_provenance(
        source_entries, source_records["420,0"], "420,0", 4, false
    )
    check(checks, "shared_home_residents_round_trip_exact_ordinary_source_provenance",
        bool(actor_audit.get("ok", false)) \
        and int(actor_audit.get("sourceBackedActorCount", 0)) == 4 \
        and int(actor_audit.get("sharedStableHomeCount", 0)) == 2 \
        and int(actor_audit.get("sharedDoorPortalCount", 0)) == 2)
    var duplicate_actor_entries: Array = source_entries.duplicate(true)
    duplicate_actor_entries[3]["id"] = duplicate_actor_entries[0]["id"]
    check(checks, "shared_households_still_require_unique_resident_actor_ids",
        not bool(RunnerScript.audit_spawned_town_actor_provenance(
            duplicate_actor_entries, source_records["420,0"], "420,0", 4, false
        ).get("ok", true)))
    var synthetic_record := town_home_record("runtime_perf", 0, Vector2i.ZERO)
    synthetic_record.erase("stableId")
    synthetic_record.erase("doorPortalId")
    var synthetic_audit: Dictionary = RunnerScript.audit_town_home_sources({"runtime_perf": [synthetic_record]}, 1)
    check(checks, "invented_or_incomplete_perf_records_cannot_satisfy_gate5_source_acceptance",
        not bool(synthetic_audit.get("ok", true)) \
        and int(synthetic_audit.get("validRecordCount", 1)) == 0)
    var duplicate_door_records := source_records.duplicate(true)
    duplicate_door_records["420,0"][1]["doorPortalId"] = duplicate_door_records["420,0"][0]["doorPortalId"]
    check(checks, "duplicate_production_door_provenance_is_fail_closed",
        not bool(RunnerScript.audit_town_home_sources(duplicate_door_records, 2).get("ok", true)))
    var second_town_records := [town_home_record("0,420", 0, Vector2i(1, 421))]
    var selected_source: Dictionary = RunnerScript.select_source_backed_town({
        "420,0": source_records["420,0"], "0,420": second_town_records
    }, Vector2i(0, 400))
    check(checks, "nearest_complete_source_backed_town_selection_is_deterministic",
        bool(selected_source.get("ok", false)) \
        and String(selected_source.get("townKey", "")) == "0,420")
    var shared_record := RunnerScript.shared_resident_record(source_records["420,0"][0], "420,0", 7)
    check(checks, "resident_topup_changes_only_unique_actor_identity_and_keeps_source_geography",
        String(shared_record.get("id", "")) == "420,0:resident:07" \
        and String(shared_record.get("gate5SourceHomeRecordId", "")) == "420,0:home:0" \
        and shared_record.get("homeCell") == source_records["420,0"][0].homeCell \
        and shared_record.get("doorPortalId") == source_records["420,0"][0].doorPortalId)
    var street_slots: Array[Vector2i] = RunnerScript.resident_street_slot_cells(source_records["420,0"][0])
    var unique_street_slots := {}
    for street_slot in street_slots: unique_street_slots[street_slot] = true
    check(checks, "real_town_cross_streets_offer_deterministic_unique_capacity_for_32_residents",
        street_slots.size() >= 32 and unique_street_slots.size() == street_slots.size() \
        and street_slots[0] == Vector2i(423, 0))
    var route_activity := RunnerScript.audit_job_route_activity([
        {"id":"resident","jobPhase":"outbound","routeStatus":"moving","routeCells":[Vector2i.ZERO],"jobRuns":0}
    ])
    check(checks, "gate5_requires_active_or_completed_job_route_evidence",
        bool(route_activity.get("ok", false)) \
        and not bool(RunnerScript.audit_job_route_activity([{"id":"idle","jobPhase":"idle","routeStatus":"idle"}]).get("ok", true)))
    var runner = RunnerScript.new()
    var unavailable_route_jobs: Dictionary = runner.summarize_samples([{
        "frameMs": 1.0,
        "perfSectionMaxMs": {},
        "perfCounters": {}
    }])
    var unavailable_route_telemetry: Dictionary = unavailable_route_jobs.get("routeJobTelemetry", {})
    check(checks, "missing_route_job_census_is_explicitly_unavailable_instead_of_false_zero",
        unavailable_route_jobs.get("routeJobsCompleted", 0) == null \
        and unavailable_route_jobs.get("routeJobsPending", 0) == null \
        and not bool(unavailable_route_telemetry.get("completedEventsAvailable", true)) \
        and not bool(unavailable_route_telemetry.get("currentPendingAvailable", true)) \
        and unavailable_route_telemetry.get("currentPending", 0) == null)
    var cumulative_route_jobs: Dictionary = runner.summarize_samples([{
        "frameMs": 1.0,
        "perfSectionMaxMs": {},
        "perfCounters": {"route_jobs_completed": 4, "route_jobs_pending": 7}
    }]).get("routeJobTelemetry", {})
    check(checks, "legacy_route_job_counters_are_labeled_as_cumulative_events_not_current_pending_jobs",
        bool(cumulative_route_jobs.get("completedEventsAvailable", false)) \
        and int(cumulative_route_jobs.get("completedEvents", 0)) == 4 \
        and bool(cumulative_route_jobs.get("pendingEventsAvailable", false)) \
        and int(cumulative_route_jobs.get("pendingEvents", 0)) == 7 \
        and not bool(cumulative_route_jobs.get("currentPendingAvailable", true)))
    runner.free()
    var passed := checks.all(func(row: Dictionary) -> bool: return bool(row.get("passed", false)))
    DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify({
            "schemaVersion": 1,
            "runnerId": "runtime_performance_observation_contract",
            "evidenceLevel": "pure_contract",
            "passed": passed,
            "failureCount": checks.filter(func(row: Dictionary) -> bool: return not bool(row.get("passed", false))).size(),
            "checks": checks,
            "doesNotProve": "No Godot rendering, 32-NPC live workload, autosave timing, presentation cadence, worker drain, or process shutdown acceptance."
        }, "  "))
        file.close()
    quit(0 if passed else 1)

func check(checks: Array[Dictionary], name: String, passed: bool) -> void:
    checks.append({"name": name, "passed": passed})


func overlap_audit(
    actor_a: String,
    actor_b: String,
    penetration: float,
    actor_a_safe_margin: float = 0.04,
    actor_b_safe_margin: float = 0.04
) -> Dictionary:
    return {
        "ok": false,
        "overlapCount": 1,
        "overlaps": [{
            "a": actor_a,
            "b": actor_b,
            "penetration": penetration,
            "aSafeMargin": actor_a_safe_margin,
            "bSafeMargin": actor_b_safe_margin
        }]
    }


func live_capsule_entry(
    actor_id: String,
    body_position: Vector3,
    physical_radius: float,
    physical_height: float,
    clearance_radius: float,
    clearance_height: float,
    mode: String = "single"
) -> Dictionary:
    var body := CharacterBody3D.new()
    body.name = actor_id
    body.position = body_position
    root.add_child(body)
    if mode != "missing":
        var collider := CollisionShape3D.new()
        collider.name = "Capsule"
        var shape := CapsuleShape3D.new()
        shape.radius = physical_radius
        shape.height = physical_height
        collider.shape = shape
        collider.position.y = physical_height * 0.5
        collider.disabled = mode == "disabled"
        body.add_child(collider)
        if mode == "ambiguous":
            var second := CollisionShape3D.new()
            second.name = "SecondCapsule"
            var second_shape := CapsuleShape3D.new()
            second_shape.radius = physical_radius
            second_shape.height = physical_height
            second.shape = second_shape
            second.position.y = physical_height * 0.5
            body.add_child(second)
    return {
        "id": actor_id,
        "body": body,
        "motorProfile": {
            "capsule_radius": clearance_radius,
            "capsule_height": clearance_height
        }
    }


func town_home_record(town_key: String, index: int, home_cell: Vector2i) -> Dictionary:
    var parts := town_key.split(",")
    var town_center := Vector2i(int(parts[0]), int(parts[1])) if parts.size() == 2 else Vector2i.ZERO
    return {
        "id": "%s:home:%d" % [town_key, index],
        "stableId": "%s:home:%d" % [town_key, index],
        "townKey": town_key,
        "townCenter": town_center,
        "townRadius": 24,
        "level": 16.0,
        "homeKey": index,
        "buildingIndex": index,
        "homeCell": home_cell,
        "porchCell": home_cell + Vector2i(0, 1),
        "doorCell": home_cell + Vector2i(0, 1),
        "doorPortalId": "door:%s:%d" % [town_key, index],
        "interiorMinCell": home_cell - Vector2i.ONE,
        "interiorMaxCell": home_cell + Vector2i.ONE
    }
