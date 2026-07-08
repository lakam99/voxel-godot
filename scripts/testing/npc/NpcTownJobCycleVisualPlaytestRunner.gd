extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const NpcFocusCameraObserverScript := preload("res://scripts/testing/npc/NpcFocusCameraObserver.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")

const TEST_ID := "npc_generated_town_job_cycle_visual"
const CELL := 1.35
const STARTUP_FRAMES := 90
const LOAD_SETTLE_FRAMES := 150
const SAMPLE_EVERY_FRAMES := 30
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const DAY_OBSERVE_SECONDS := 10.0
const NIGHT_HOME_TIMEOUT_SECONDS := 7.0
const MORNING_OBSERVE_SECONDS := 8.0
const SETTLED_FRAMES_REQUIRED := 8
const FAST_FORWARD_TIME_SCALE := 180.0
const OBSERVE_TIME_SCALE := 18.0
const DEFAULT_WATCHDOG_SECONDS := 430.0
const MAX_TIMELINE_SAMPLES := 96
const MAX_NIGHT_DOOR_TIMELINE_SAMPLES := 160
const MAX_NIGHT_DIAGNOSTIC_SUSPECTS := 3
const MAX_NIGHT_DOOR_TRANSITION_VISUALS := 10
const NIGHT_DIAGNOSTIC_SEQUENCE_FRAMES := 30
const NIGHT_LOOP_SEQUENCE_FRAMES := 10
const DOOR_LOOP_TRANSITION_MIN_DELTA := 3
const TOWN_STREAMING_MAX_FRAMES := 1500

const REQUIRED_ROLE_LABELS := ["Guard", "Forager", "Farmer", "Carpenter", "Mason", "Trader"]
const REQUIRED_JOB_TYPES := ["guard", "forage", "wood", "stone", "trade"]
const REQUIRED_CAPTURE_STAGES := [
    "town_setup_fenced_gate",
    "day_jobs_overview",
    "day_forager_forage",
    "day_guard_guarding",
    "night_all_inside_homes",
    "morning_emerge_jobs"
]

var main: Node3D
var player: CharacterBody3D
var npc_system: Node
var observer_camera: Camera3D
var observer_torch: OmniLight3D
var focus_observer
var town: Dictionary = {}
var town_key := ""
var town_center := Vector2i.ZERO
var town_level := 0.0
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var run_token := ""
var seed := ""
var watchdog_seconds := DEFAULT_WATCHDOG_SECONDS
var wall_started_msec := 0
var elapsed := 0.0
var finished := false
var failed := false
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var npc_entries: Array[Dictionary] = []
var initial_positions := {}
var town_summary := {}
var role_summary := {}
var fence_gate_summary := {}
var day_matrix: Array[Dictionary] = []
var night_matrix: Array[Dictionary] = []
var morning_matrix: Array[Dictionary] = []
var night_door_timeline: Array[Dictionary] = []
var night_loop_diagnostics_captured := false
var night_loop_diagnostics := {}
var night_door_transition_visuals: Array[Dictionary] = []
var night_transition_last_counts := {}
var last_observer_camera_target := Vector3.ZERO
var last_town_streaming_summary := {}
var precondition_blocked := false
var stopped_phase := ""

func _ready() -> void:
    wall_started_msec = Time.get_ticks_msec()
    configure_from_environment()
    apply_resolution()
    write_progress("start")
    call_deferred("run")

func _process(_delta: float) -> void:
    if finished:
        return
    elapsed = float(Time.get_ticks_msec() - wall_started_msec) / 1000.0
    if elapsed > watchdog_seconds:
        add_result("runner_watchdog", false, "watchdog %.1fs exceeded" % watchdog_seconds)
        finish(1)

func configure_from_environment() -> void:
    seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
    if seed == "":
        seed = "town-cycle-%d" % Time.get_unix_time_from_system()
    report_path = OS.get_environment("VOXEL_NPC_TOWN_JOB_CYCLE_REPORT")
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/npc/reports/town-job-cycle-visual-playtest.json")
    progress_path = OS.get_environment("VOXEL_NPC_TOWN_JOB_CYCLE_PROGRESS")
    screenshot_dir = OS.get_environment("VOXEL_NPC_TOWN_JOB_CYCLE_SCREENSHOT_DIR")
    if screenshot_dir == "":
        screenshot_dir = ProjectSettings.globalize_path("res://artifacts/npc/screenshots/town-job-cycle-visual")
    run_token = OS.get_environment("VOXEL_NPC_TOWN_JOB_CYCLE_RUN_TOKEN")
    var watchdog_value := OS.get_environment("VOXEL_NPC_TOWN_JOB_CYCLE_WATCHDOG_SECONDS").strip_edges()
    if watchdog_value != "":
        watchdog_seconds = maxf(60.0, float(watchdog_value))
    ensure_dir(report_path.get_base_dir())
    ensure_dir(screenshot_dir)
    if progress_path != "":
        ensure_dir(progress_path.get_base_dir())

func apply_resolution() -> void:
    DisplayServer.window_set_size(Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))
    var root_window := get_tree().root
    root_window.set("size", Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))
    root_window.set("content_scale_size", Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))

func run() -> void:
    OS.set_environment("VOXEL_TEST_SEED", seed)
    main = MAIN_SCENE.instantiate()
    add_child(main)
    write_progress("main_instantiated")
    await wait_process_frames(2)
    bind_scene_nodes()
    if main == null or player == null or npc_system == null:
        add_result("scene_bootstrap", false, "main/player/npc_system missing")
        finish(1)
        return

    configure_observer_scene()
    if not await wait_startup_physics_frames(STARTUP_FRAMES, "startup"):
        add_result("startup_physics_frames_advanced", false, "physics frames did not advance during startup")
        finish(1)
        return
    await load_natural_generated_town()
    set_display_hour(10.0)
    write_progress("initial_day_staged")
    await wait_physics_frames(LOAD_SETTLE_FRAMES)
    collect_natural_npcs()
    write_town_summary()

    add_result("natural_town_selected_non_tutorial", is_non_tutorial_town(), JSON.stringify(town_summary))
    add_result("runner_does_not_mutate_town_or_npc_roster", true, "observer only: no town blocks, homes, resources, or NPCs are created by this runner")
    add_result("natural_town_has_generated_fence_and_gate", has_generated_fence_and_gate(), JSON.stringify(fence_gate_summary))
    add_result("natural_town_has_every_required_role", missing_required_roles().is_empty(), JSON.stringify(role_summary))
    add_result("natural_town_has_every_required_job_type", missing_required_jobs().is_empty(), JSON.stringify(role_summary))
    add_result("natural_npcs_are_not_tutorial_npcs", natural_npc_filter_clean(), JSON.stringify(role_summary))
    await capture_stage("town_setup_fenced_gate", "overview")
    if failed:
        precondition_blocked = true
        record_timeline(phase_sample("precondition_blocked", current_npc_matrix("precondition_blocked")))
        add_result("precondition_blocker_reported", true, "Natural generated town does not satisfy fenced town plus required NPC/job spread preconditions; stopping before invalid day/night acceptance.")
        finish(1)
        return

    await observe_day_jobs()
    if failed:
        stop_after_failed_phase("day")
        return
    await fast_forward_until_display_hour(21.0, "fast_forward_to_night")
    await observe_night_home_return()
    if failed:
        stop_after_failed_phase("night")
        return
    await fast_forward_until_display_hour(8.4, "fast_forward_to_day")
    await observe_morning_emergence()
    if failed:
        stopped_phase = "morning"
    add_result("visual_screenshots_saved", required_captures_saved(), JSON.stringify(capture_names()))
    finish(1 if failed else 0)

func stop_after_failed_phase(phase: String) -> void:
    stopped_phase = phase
    record_timeline(phase_sample("%s_phase_failed" % phase, current_npc_matrix("%s_phase_failed" % phase)))
    add_result("%s_phase_failure_reported_before_later_phases" % phase, true, "Stopping after %s failure; later phase screenshots are intentionally not required for this failed acceptance run." % phase)
    finish(1)

func bind_scene_nodes() -> void:
    if main == null:
        return
    player = main.get("player") as CharacterBody3D
    npc_system = main.get("npc_system") as Node

func configure_observer_scene() -> void:
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    if player != null:
        player.set("automated_input", true)
        player.set("automated_move", Vector3.ZERO)
        player.set("automated_sprint", false)
        player.set_physics_process(false)
        player.collision_layer = 0
        player.collision_mask = 0
    var hud = main.get("hud") if main != null else null
    if hud != null and hud.get("hud_root") is Control:
        (hud.get("hud_root") as Control).visible = false
    if main.has_method("apply_runtime_setting"):
        main.call("apply_runtime_setting", "headBob", false, false)
        main.call("apply_runtime_setting", "handSway", false, false)
    neutralize_intro_clock_freeze()
    observer_camera = Camera3D.new()
    observer_camera.name = "NpcTownJobCycleVisualCamera"
    observer_camera.fov = 58.0
    add_child(observer_camera)
    observer_camera.make_current()
    observer_torch = OmniLight3D.new()
    observer_torch.name = "NpcTownJobCycleObserverTorch"
    observer_torch.light_color = Color(1.0, 0.82, 0.55)
    observer_torch.shadow_enabled = false
    observer_torch.visible = true
    observer_camera.add_child(observer_torch)
    focus_observer = NpcFocusCameraObserverScript.new()
    focus_observer.setup(observer_camera, observer_torch)
    configure_observer_torch("wide")

func neutralize_intro_clock_freeze() -> void:
    var tutorial = main.get("tutorial_system") if main != null else null
    if tutorial == null:
        return
    tutorial.set("intro_repair_active", false)
    tutorial.set("intro_repair_complete", true)
    tutorial.set("intro_bed_used", true)
    tutorial.set("final_night_active", false)
    tutorial.set("final_night_complete", true)

func load_natural_generated_town() -> void:
    write_progress("load_town_find_start")
    town = find_non_tutorial_town()
    if town.is_empty():
        add_result("natural_town_found", false, "no non-tutorial generated town found for seed %s" % seed)
        return
    write_progress("load_town_found")
    town_center = Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0)))
    town_level = float(town.get("level", 16.0))
    town_key = "%d,%d" % [town_center.x, town_center.y]
    write_progress("load_town_move_player")
    move_player_for_lod(town_center, town_level)
    if main.has_method("update_chunks"):
        write_progress("load_town_budgeted_stream_start")
        if not await stream_town_chunks_budgeted():
            add_result("natural_town_budgeted_streaming_ready", false, JSON.stringify(last_town_streaming_summary))
            return
        write_progress("load_town_budgeted_stream_done")
    write_progress("load_town_settle_start")
    await wait_physics_frames(LOAD_SETTLE_FRAMES)
    write_progress("load_town_settle_done")

func stream_town_chunks_budgeted() -> bool:
    var stable_frames := 0
    for frame in range(TOWN_STREAMING_MAX_FRAMES):
        main.call("update_chunks", false)
        pump_runtime_structure_streaming()
        last_town_streaming_summary = town_streaming_summary()
        if frame % SAMPLE_EVERY_FRAMES == 0:
            write_progress("load_town_stream_%04d_l%d_t%d_q%d_r%d_c%d_p%d_s%d_h%d_m%d" % [
                frame,
                int(last_town_streaming_summary.get("loadedVisibleChunks", 0)),
                int(last_town_streaming_summary.get("temporaryVisibleChunks", 0)),
                int(last_town_streaming_summary.get("pendingChunkLoads", 0)),
                int(last_town_streaming_summary.get("pendingTerrainRefreshes", 0)),
                int(last_town_streaming_summary.get("pendingCollisionRefreshes", 0)),
                int(last_town_streaming_summary.get("pendingPropSpawns", 0)),
                int(last_town_streaming_summary.get("pendingStructureOps", 0)),
                int(last_town_streaming_summary.get("homeRecords", 0)),
                int(last_town_streaming_summary.get("terrainMeshingPendingJobs", 0))
            ])
        if town_streaming_ready(last_town_streaming_summary):
            stable_frames += 1
            if stable_frames >= SETTLED_FRAMES_REQUIRED:
                return true
        else:
            stable_frames = 0
        await get_tree().process_frame
    return false

func pump_runtime_structure_streaming() -> void:
    if main == null:
        return
    if main.has_method("process_streaming_structure_work"):
        main.call("process_streaming_structure_work")
    else:
        var structure_system = main.get("structure_system")
        if structure_system != null and structure_system.has_method("update_around_budgeted"):
            structure_system.call("update_around_budgeted", town_center, true)
    if main.has_method("process_pending_chunk_prop_spawns"):
        for _drain_index in range(8):
            if int(main.call("process_pending_chunk_prop_spawns")) <= 0:
                break

func town_streaming_ready(summary: Dictionary) -> bool:
    return int(summary.get("loadedVisibleChunks", 0)) >= int(summary.get("expectedVisibleChunks", 0)) \
        and int(summary.get("pendingChunkLoads", 0)) == 0 \
        and int(summary.get("pendingCollisionRefreshes", 0)) == 0 \
        and int(summary.get("pendingStructureOps", 0)) == 0 \
        and int(summary.get("homeRecords", 0)) > 0

func town_streaming_summary() -> Dictionary:
    var chunk_size := int(main.CHUNK_SIZE) if main != null else 28
    var render_distance := int(main.get("render_distance")) if main != null else 3
    if render_distance <= 0 and main != null:
        render_distance = int(main.RENDER_DISTANCE)
    var center := Vector2i.ZERO
    if player != null:
        var chunk_world_size := float(chunk_size) * CELL
        center = Vector2i(floori(player.global_position.x / chunk_world_size), floori(player.global_position.z / chunk_world_size))
    var expected := (render_distance * 2 + 1) * (render_distance * 2 + 1)
    var loaded := 0
    var temporary := 0
    var chunk_value = main.get("chunks") if main != null else null
    var chunks_dict: Dictionary = chunk_value if chunk_value is Dictionary else {}
    for dz in range(-render_distance, render_distance + 1):
        for dx in range(-render_distance, render_distance + 1):
            var key := Vector2i(center.x + dx, center.y + dz)
            if not chunks_dict.has(key):
                continue
            loaded += 1
            if chunk_has_temporary_terrain(chunks_dict[key]):
                temporary += 1
    return {
        "centerChunk": center,
        "expectedVisibleChunks": expected,
        "loadedVisibleChunks": loaded,
        "temporaryVisibleChunks": temporary,
        "pendingChunkLoads": main_dictionary_size("pending_chunk_loads"),
        "pendingTerrainRefreshes": main_dictionary_size("pending_chunk_terrain_refreshes"),
        "pendingCollisionRefreshes": main_dictionary_size("pending_chunk_collision_refreshes"),
        "pendingPropSpawns": main_dictionary_size("pending_chunk_prop_spawns"),
        "pendingGeneratedVolumeExposureScans": main_dictionary_size("pending_generated_volume_exposure_scans"),
        "pendingStructureOps": pending_structure_op_count(),
        "homeRecords": town_records().size(),
        "terrainMeshingPendingJobs": terrain_meshing_pending_job_count(),
        "terrainMeshingCompletedJobs": terrain_meshing_completed_job_count()
    }

func chunk_has_temporary_terrain(chunk_value) -> bool:
    var chunk := chunk_value as Node
    if chunk == null or not is_instance_valid(chunk):
        return true
    var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
    if mesh_instance == null or mesh_instance.mesh == null:
        return true
    var mesh := mesh_instance.mesh
    return bool(mesh.get_meta("terrainStreamingLod", false)) or bool(mesh.get_meta("terrainMeshingProvisional", false))

func main_dictionary_size(property_name: String) -> int:
    if main == null:
        return 0
    var value = main.get(property_name)
    return (value as Dictionary).size() if value is Dictionary else 0

func pending_structure_op_count() -> int:
    if main == null:
        return 0
    var structure_system = main.get("structure_system")
    if structure_system != null and structure_system.has_method("pending_structure_op_count"):
        return int(structure_system.call("pending_structure_op_count"))
    return 0

func terrain_meshing_pending_job_count() -> int:
    if main == null:
        return 0
    var service = main.get("terrain_meshing_service")
    if service != null and service.has_method("pending_job_count"):
        return int(service.call("pending_job_count"))
    return 0

func terrain_meshing_completed_job_count() -> int:
    if main == null:
        return 0
    var service = main.get("terrain_meshing_service")
    if service != null and service.has_method("completed_job_count"):
        return int(service.call("completed_job_count"))
    return 0

func find_non_tutorial_town() -> Dictionary:
    var candidates: Array[Vector2i] = []
    for radius in range(1, 10):
        for rz in range(-radius, radius + 1):
            for rx in range(-radius, radius + 1):
                if abs(rx) != radius and abs(rz) != radius:
                    continue
                if rx == 1 and rz == 0:
                    continue
                candidates.append(Vector2i(rx, rz))
    var best := {}
    var best_radius := -1
    for region in candidates:
        var candidate: Dictionary = main.call("town_region", region.x, region.y)
        if candidate.is_empty():
            continue
        candidate["selectedRegion"] = region
        var radius := int(candidate.get("radius", 0))
        if radius > best_radius:
            best = candidate
            best_radius = radius
    return best

func collect_natural_npcs() -> void:
    npc_entries.clear()
    initial_positions.clear()
    if npc_system == null:
        return
    var entries = npc_system.get("npcs")
    if not (entries is Array):
        return
    for entry_value in entries:
        var entry := entry_value as Dictionary
        if entry.is_empty():
            continue
        if String(entry.get("townKey", "")) != town_key:
            continue
        var id := String(entry.get("id", ""))
        if is_tutorial_id(id):
            continue
        var body := entry.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            continue
        npc_entries.append(entry)
        initial_positions[id] = body.global_position
    role_summary = build_role_summary()

func build_role_summary() -> Dictionary:
    var roles := {}
    var jobs := {}
    var rows: Array[Dictionary] = []
    for entry in npc_entries:
        var role := String(entry.get("role", ""))
        var job := String(entry.get("job", ""))
        roles[role] = int(roles.get(role, 0)) + 1
        jobs[job] = int(jobs.get(job, 0)) + 1
        rows.append({
            "id": String(entry.get("id", "")),
            "name": String(entry.get("name", "")),
            "role": role,
            "job": job,
            "canFight": bool(entry.get("canFight", false)),
            "nightGuard": bool(entry.get("nightGuard", false))
        })
    return {
        "npcCount": npc_entries.size(),
        "roles": roles,
        "jobs": jobs,
        "missingRoles": missing_from_counts(roles, REQUIRED_ROLE_LABELS),
        "missingJobs": missing_from_counts(jobs, REQUIRED_JOB_TYPES),
        "npcs": rows
    }

func write_town_summary() -> void:
    fence_gate_summary = natural_fence_gate_summary()
    town_summary = {
        "seed": seed,
        "townKey": town_key,
        "town": sanitize_value(town),
        "townCenter": vec2i(town_center),
        "townLevel": rounded(town_level),
        "homeRecords": town_records().size(),
        "fenceGate": fence_gate_summary,
        "roleSummary": role_summary,
        "environmentSetupOnly": [
            "random seed world load",
            "non-tutorial generated town selection",
            "player/camera placement for chunk loading and observation",
            "intro tutorial clock-freeze neutralized so the global day/night clock can fast-forward"
        ],
        "forbiddenFixtureSetup": [
            "no NPC creation or registration",
            "no NPC job, role, home, or schedule injection",
            "no town home, fence, gate, block, or resource placement",
            "no direct NPC orders or door service calls"
        ]
    }

func natural_fence_gate_summary() -> Dictionary:
    var blocks_value = main.get("blocks") if main != null else {}
    var fence_blocks := 0
    var gate_doors := 0
    var town_doors_near_perimeter := 0
    var sample_fences: Array[Dictionary] = []
    var sample_gates: Array[Dictionary] = []
    if not (blocks_value is Dictionary):
        return { "fenceBlocks": 0, "gateDoorBlocks": 0, "townDoorsNearPerimeter": 0 }
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as Node3D
        if block == null or not is_instance_valid(block):
            continue
        var cell: Vector3i = block.get_meta("cell", Vector3i.ZERO)
        var near_perimeter := is_near_town_perimeter(Vector2i(cell.x, cell.z))
        if not near_perimeter:
            continue
        var block_type := String(block.get_meta("block_type", ""))
        var accent := String(block.get_meta("accentRole", ""))
        if block_type == "woodBlock" and accent == "fencePost":
            fence_blocks += 1
            if sample_fences.size() < 8:
                sample_fences.append(block_summary(block))
        elif block_type == "door":
            town_doors_near_perimeter += 1
            if bool(block.get_meta("door_public_access", block.get_meta("doorPublicAccess", false))):
                gate_doors += 1
                if sample_gates.size() < 8:
                    sample_gates.append(block_summary(block))
    return {
        "fenceBlocks": fence_blocks,
        "gateDoorBlocks": gate_doors,
        "townDoorsNearPerimeter": town_doors_near_perimeter,
        "requiredFenceBlocksMinimum": max(24, int(town.get("radius", 30)) * 2),
        "requiredGateDoorsMinimum": 2,
        "sampleFences": sample_fences,
        "sampleGates": sample_gates
    }

func has_generated_fence_and_gate() -> bool:
    var fence_blocks := int(fence_gate_summary.get("fenceBlocks", 0))
    var gate_doors := int(fence_gate_summary.get("gateDoorBlocks", 0))
    return fence_blocks >= int(fence_gate_summary.get("requiredFenceBlocksMinimum", 24)) and gate_doors >= int(fence_gate_summary.get("requiredGateDoorsMinimum", 2))

func observe_day_jobs() -> void:
    write_progress("observe_day_jobs")
    var frames := ceili(DAY_OBSERVE_SECONDS * float(Engine.physics_ticks_per_second))
    var observed_forage := false
    var observed_guard := false
    var non_special_distance_by_id := {}
    var old_scale := Engine.time_scale
    Engine.time_scale = OBSERVE_TIME_SCALE
    for frame in range(frames):
        position_observer_camera("forager")
        await get_tree().physics_frame
        if frame % SAMPLE_EVERY_FRAMES == 0:
            var matrix := current_npc_matrix("day")
            day_matrix = matrix
            record_timeline(phase_sample("day_%04d" % frame, matrix))
            write_progress("observe_day_jobs_%04d" % frame)
            if frame % (SAMPLE_EVERY_FRAMES * 6) == 0:
                write_report(false)
            var forage_now := matrix_has_forager_work(matrix)
            var guard_now := matrix_has_guard_work(matrix)
            observed_forage = observed_forage or forage_now
            observed_guard = observed_guard or guard_now
            for row in matrix:
                if is_non_special_town_worker(row):
                    var id := String(row.get("id", ""))
                    non_special_distance_by_id[id] = maxf(float(non_special_distance_by_id.get(id, 0.0)), float(row.get("distanceFromInitial", 0.0)))
            if matrix_has_forager_visual_work(matrix) and not capture_stage_saved("day_forager_forage"):
                await capture_stage("day_forager_forage", "forager")
            if guard_now and not capture_stage_saved("day_guard_guarding"):
                await capture_stage("day_guard_guarding", "guard")
            if observed_forage and observed_guard and capture_stage_saved("day_forager_forage") and capture_stage_saved("day_guard_guarding") and non_special_workers_near_town(matrix) and non_special_workers_move_or_work(non_special_distance_by_id, matrix):
                break
    Engine.time_scale = old_scale
    day_matrix = current_npc_matrix("day_final")
    if not capture_stage_saved("day_forager_forage"):
        await capture_stage("day_forager_forage", "forager")
    if not capture_stage_saved("day_guard_guarding"):
        await capture_stage("day_guard_guarding", "guard")
    await capture_stage("day_jobs_overview", "overview")
    add_result("day_forager_uses_builtin_forage", observed_forage, JSON.stringify(filtered_job_rows(day_matrix, "forage")))
    add_result("day_guard_uses_builtin_guard", observed_guard, JSON.stringify(filtered_job_rows(day_matrix, "guard")))
    add_result("day_non_guard_non_foragers_stay_near_town", non_special_workers_near_town(day_matrix), JSON.stringify(filtered_non_special_rows(day_matrix)))
    add_result("day_non_guard_non_foragers_move_or_work_in_town", non_special_workers_move_or_work(non_special_distance_by_id, day_matrix), JSON.stringify(sanitize_value(non_special_distance_by_id)))

func fast_forward_until_display_hour(target_hour: float, label: String) -> void:
    write_progress(label)
    var start_phase := clock_phase()
    var target_phase := fposmod(target_hour / 24.0, 1.0)
    var required_progress := fposmod(target_phase - start_phase, 1.0)
    if required_progress <= 0.001:
        return
    var capture_night_transitions := label == "fast_forward_to_night"
    if capture_night_transitions:
        night_transition_last_counts = door_transition_counts_by_portal().duplicate(true)
    var old_scale := Engine.time_scale
    Engine.time_scale = FAST_FORWARD_TIME_SCALE
    var last_capture_progress := 0.0
    var frame_count := 0
    while fposmod(clock_phase() - start_phase, 1.0) < required_progress:
        position_observer_camera("route_suspect")
        await get_tree().physics_frame
        neutralize_intro_clock_freeze()
        frame_count += 1
        if capture_night_transitions:
            await capture_night_door_transition_visuals(frame_count)
        var progress := fposmod(clock_phase() - start_phase, 1.0) / required_progress
        if progress - last_capture_progress >= 0.22:
            last_capture_progress = progress
            record_timeline(phase_sample("%s_%.2f" % [label, progress], current_npc_matrix(label)))
            write_progress("%s_%.2f" % [label, progress])
            write_report(false)
        elif frame_count % int(Engine.physics_ticks_per_second * 4) == 0:
            write_progress("%s_heartbeat_%.2f" % [label, progress])
        if elapsed > watchdog_seconds:
            break
    Engine.time_scale = old_scale
    await wait_physics_frames(12)
    record_timeline(phase_sample("%s_arrived" % label, current_npc_matrix(label)))
    write_report(false)

func set_display_hour(hour: float) -> void:
    if main == null:
        return
    main.set("time_of_day", fposmod((hour / 24.0) - 0.25, 1.0))
    if main.has_method("update_sky"):
        main.call("update_sky", 0.0)

func observe_night_home_return() -> void:
    write_progress("observe_night_home_return")
    var frames := ceili(NIGHT_HOME_TIMEOUT_SECONDS * float(Engine.physics_ticks_per_second))
    var settled_frames := 0
    var transition_baseline := door_transition_counts_by_portal()
    if night_transition_last_counts.is_empty():
        night_transition_last_counts = transition_baseline.duplicate(true)
    var old_scale := Engine.time_scale
    Engine.time_scale = OBSERVE_TIME_SCALE
    for frame in range(frames):
        position_observer_camera("night_suspect")
        await get_tree().physics_frame
        await capture_night_door_transition_visuals(frame)
        if frame % SAMPLE_EVERY_FRAMES == 0:
            night_matrix = current_npc_matrix("night")
            record_timeline(phase_sample("night_%04d" % frame, night_matrix))
            record_night_door_sample("night_%04d" % frame, frame)
            write_progress("observe_night_home_%04d" % frame)
            var detected_loop_rows := door_transition_loops(transition_baseline)
            if not detected_loop_rows.is_empty() and not night_loop_diagnostics_captured:
                await capture_night_door_loop_diagnostics(detected_loop_rows, "during_observation_%04d" % frame)
            if frame % (SAMPLE_EVERY_FRAMES * 6) == 0:
                write_report(false)
        if all_non_guard_npcs_strict_inside_with_closed_doors():
            settled_frames += 1
        else:
            settled_frames = 0
        if settled_frames >= SETTLED_FRAMES_REQUIRED:
            break
    Engine.time_scale = old_scale
    night_matrix = current_npc_matrix("night_final")
    record_night_door_sample("night_final", frames)
    var final_all_inside := all_non_guard_npcs_strict_inside_with_closed_doors()
    var loop_rows := door_transition_loops(transition_baseline)
    if not final_all_inside:
        await capture_night_failure_diagnostics()
        await capture_stage("night_focus_last_suspect", "night_suspect")
    if not loop_rows.is_empty() and not night_loop_diagnostics_captured:
        await capture_night_door_loop_diagnostics(loop_rows, "final")
    await capture_stage("night_all_inside_homes", "overview")
    add_result("night_door_state_timeline_recorded", not night_door_timeline.is_empty(), JSON.stringify(night_door_timeline.slice(maxi(0, night_door_timeline.size() - 12), night_door_timeline.size())))
    add_result("night_door_transition_visuals_recorded", not night_door_transition_visuals.is_empty(), JSON.stringify(night_door_transition_visuals))
    add_result("night_home_route_evidence_recorded", night_home_route_evidence_ok(night_matrix), JSON.stringify(night_home_route_evidence_rows(night_matrix)))
    add_result("night_home_doors_do_not_open_close_loop", loop_rows.is_empty(), JSON.stringify(loop_rows))
    add_result("night_all_non_guard_npcs_return_home_without_orders", final_all_inside, JSON.stringify(night_matrix))

func observe_morning_emergence() -> void:
    write_progress("observe_morning_emergence")
    var frames := ceili(MORNING_OBSERVE_SECONDS * float(Engine.physics_ticks_per_second))
    var emerged := false
    var forager_resumed := false
    var guard_resumed := false
    var old_scale := Engine.time_scale
    Engine.time_scale = OBSERVE_TIME_SCALE
    for frame in range(frames):
        position_observer_camera("morning_worker")
        await get_tree().physics_frame
        if frame % SAMPLE_EVERY_FRAMES == 0:
            morning_matrix = current_npc_matrix("morning")
            record_timeline(phase_sample("morning_%04d" % frame, morning_matrix))
            write_progress("observe_morning_%04d" % frame)
            if frame % (SAMPLE_EVERY_FRAMES * 6) == 0:
                write_report(false)
            emerged = emerged or all_npcs_outside_home(morning_matrix)
            forager_resumed = forager_resumed or matrix_has_forager_work(morning_matrix)
            guard_resumed = guard_resumed or matrix_has_guard_work(morning_matrix)
        if emerged and forager_resumed and guard_resumed:
            break
    Engine.time_scale = old_scale
    morning_matrix = current_npc_matrix("morning_final")
    await capture_stage("morning_emerge_jobs", "overview")
    add_result("morning_all_npcs_emerge_from_homes", emerged, JSON.stringify(morning_matrix))
    add_result("morning_forager_returns_to_forage", forager_resumed, JSON.stringify(filtered_job_rows(morning_matrix, "forage")))
    add_result("morning_guard_returns_to_guard", guard_resumed, JSON.stringify(filtered_job_rows(morning_matrix, "guard")))
    add_result("morning_non_guard_non_foragers_remain_near_town", non_special_workers_near_town(morning_matrix), JSON.stringify(filtered_non_special_rows(morning_matrix)))

func current_npc_matrix(phase: String) -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    for entry in npc_entries:
        if entry.is_empty():
            continue
        rows.append(npc_summary(entry, phase))
    return rows

func npc_summary(entry: Dictionary, phase: String) -> Dictionary:
    var body := entry.get("body") as Node3D
    var valid := body != null and is_instance_valid(body)
    var position := body.global_position if valid else Vector3.ZERO
    var id := String(entry.get("id", ""))
    var initial = initial_positions.get(id, position)
    var initial_position: Vector3 = initial if initial is Vector3 else position
    var door := npc_home_door(entry)
    var home_status := strict_home_status(entry)
    var home_route := home_route_summary(entry, position)
    var porch_position: Vector3 = entry.get("porchPosition", position) if entry.get("porchPosition", position) is Vector3 else position
    var home_position: Vector3 = entry.get("homePosition", position) if entry.get("homePosition", position) is Vector3 else position
    var guard_position: Vector3 = entry.get("guardPosition", position) if entry.get("guardPosition", position) is Vector3 else position
    var guard_cell: Vector2i = entry.get("guardCell", flat_cell(guard_position)) if entry.get("guardCell", flat_cell(guard_position)) is Vector2i else flat_cell(guard_position)
    var door_position := (door as Node3D).global_position if door is Node3D else position
    return {
        "phase": phase,
        "id": id,
        "name": String(entry.get("name", "")),
        "role": String(entry.get("role", "")),
        "job": String(entry.get("job", "")),
        "goal": String(entry.get("goal", "")),
        "activeGoalKind": String(entry.get("activeGoalKind", "")),
        "activeMotionGoal": sanitize_value(entry.get("activeMotionGoal", {})),
        "scheduleState": String(entry.get("scheduleState", "")),
        "jobPhase": String(entry.get("jobPhase", "")),
        "jobTimer": rounded(float(entry.get("jobTimer", 0.0))),
        "jobRuns": int(entry.get("jobRuns", 0)),
        "jobObjectId": String(entry.get("jobObjectId", "")),
        "jobTarget": vec3(entry.get("jobTarget", position) if entry.get("jobTarget", position) is Vector3 else position),
        "homePosition": vec3(entry.get("homePosition", position) if entry.get("homePosition", position) is Vector3 else position),
        "porchPosition": vec3(entry.get("porchPosition", position) if entry.get("porchPosition", position) is Vector3 else position),
        "guardPosition": vec3(guard_position),
        "guardCell": vec2i(guard_cell),
        "homeActiveTargetCell": vec2i(entry.get("homeActiveTargetCell", Vector2i(999999, 999999)) if entry.get("homeActiveTargetCell", Vector2i(999999, 999999)) is Vector2i else Vector2i(999999, 999999)),
        "homeRoute": home_route,
        "homeRouteIndex": int(home_route.get("index", 0)),
        "homeRoutePositionCount": int(home_route.get("count", 0)),
        "distanceToHomeRouteTarget": rounded(float(home_route.get("distanceToCurrentTarget", 0.0))),
        "distanceToPorch": rounded(flat_distance(position, porch_position)),
        "distanceToHome": rounded(flat_distance(position, home_position)),
        "distanceToGuardPost": rounded(flat_distance(position, guard_position)),
        "distanceGuardPostToHome": rounded(flat_distance(guard_position, home_position)),
        "guardPostNearPerimeter": is_near_town_perimeter(guard_cell),
        "distanceToHomeDoor": rounded(flat_distance(position, door_position)),
        "insideHome": bool(entry.get("insideHome", false)),
        "lastMoveDistance": rounded(float(entry.get("lastMoveDistance", 0.0))),
        "routeStatus": String(entry.get("routeStatus", "")),
        "routeReason": String(entry.get("routeReason", "")),
        "routePriority": int(entry.get("routePriority", 0)),
        "routeGoalCell": vec2i(entry.get("routeGoalCell", Vector2i(999999, 999999)) if entry.get("routeGoalCell", Vector2i(999999, 999999)) is Vector2i else Vector2i(999999, 999999)),
        "routeFallbackCell": vec2i(entry.get("routeFallbackCell", Vector2i(999999, 999999)) if entry.get("routeFallbackCell", Vector2i(999999, 999999)) is Vector2i else Vector2i(999999, 999999)),
        "routeCellCount": (entry.get("routeCells", []) as Array).size(),
        "pathWaypointCount": (entry.get("pathWaypoints", []) as Array).size(),
        "routeCellSample": sanitize_value((entry.get("routeCells", []) as Array).slice(0, 8)),
        "pathWaypointSample": sanitize_value((entry.get("pathWaypoints", []) as Array).slice(0, 5)),
        "lastRoutePlanDebug": sanitize_value(entry.get("lastRoutePlanDebug", {})),
        "lastNavmeshTilePublishDebug": sanitize_value(entry.get("lastNavmeshTilePublishDebug", [])),
        "routePlannerStats": sanitize_value(npc_route_planner_stats()),
        "corridorFollow": sanitize_value(entry.get("corridorFollow", {})),
        "corridorProgress": sanitize_value(entry.get("corridorProgress", {})),
        "homeSettleDebug": sanitize_value(entry.get("homeSettleDebug", {})),
        "activeDoorPortalId": String(entry.get("activeDoorPortalId", "")),
        "simulationLod": String(entry.get("simulationLod", "")),
        "abstractSimulated": bool(entry.get("abstractSimulated", false)),
        "lodBrainDue": bool(entry.get("npc_lod_brain_due", true)),
        "brainUpdates": int(entry.get("npc_brain_updates", 0)),
        "brainBudgetSkipped": int(entry.get("npc_brain_budget_skipped", 0)),
        "brainSkipReason": String(entry.get("npc_brain_skipped_reason", "")),
        "motionUpdates": int(entry.get("npc_motion_updates", 0)),
        "motionSkippedReason": String(entry.get("npc_motion_skipped_reason", "")),
        "position": vec3(position),
        "cell": vec2i(flat_cell(position)),
        "distanceFromInitial": rounded(flat_distance(position, initial_position)),
        "distanceFromTownCenter": rounded(flat_distance(position, town_center_position())),
        "insideTown": point_inside_town(position),
        "insideRoleLeash": point_inside_role_leash(entry, position),
        "roleLeashRadius": rounded(role_leash_radius_world(entry)),
        "strictHome": home_status,
        "door": block_summary(door),
        "homeDoorOpen": any_home_door_open(entry),
        "canFight": bool(entry.get("canFight", false)),
        "nightGuard": bool(entry.get("nightGuard", false))
    }

func npc_route_planner_stats() -> Dictionary:
    if npc_system == null:
        return {}
    var pathing = npc_system.get("pathing")
    if pathing == null or not pathing.has_method("stats"):
        return {}
    var stats_value = pathing.call("stats")
    return stats_value if stats_value is Dictionary else {}

func phase_sample(label: String, matrix: Array[Dictionary]) -> Dictionary:
    return {
        "label": label,
        "elapsed": rounded(elapsed),
        "timeOfDay": rounded(float(main.get("time_of_day")) if main != null else 0.0),
        "displayHour": rounded(display_hour()),
        "clockPhase": rounded(clock_phase()),
        "focusCamera": observer_camera_summary(),
        "matrix": matrix
    }

func record_timeline(sample: Dictionary) -> void:
    timeline.append(sample)
    while timeline.size() > MAX_TIMELINE_SAMPLES:
        timeline.pop_front()

func matrix_has_forager_work(matrix: Array[Dictionary]) -> bool:
    for row in matrix:
        if String(row.get("job", "")) != "forage":
            continue
        var phase := String(row.get("jobPhase", ""))
        var strict_home_value = row.get("strictHome", {})
        var strict_home: Dictionary = strict_home_value if strict_home_value is Dictionary else {}
        var outside_home := not bool(strict_home.get("strictInside", false))
        var visible_search := phase == "searching" and String(row.get("activeGoalKind", "")) == "forage" and (not bool(row.get("insideTown", false)) or float(row.get("distanceFromInitial", 0.0)) >= CELL * 4.0)
        var has_work_state := visible_search or phase in ["outbound", "gathering", "returning"] or int(row.get("jobRuns", 0)) > 0 or String(row.get("jobObjectId", "")) != ""
        var route_status := String(row.get("routeStatus", ""))
        var has_motion_or_target := int(row.get("pathWaypointCount", 0)) > 0 or route_status in ["moving", "pending", "waiting"] or String(row.get("jobObjectId", "")) != "" or float(row.get("distanceFromInitial", 0.0)) >= CELL * 0.65
        if outside_home and has_work_state and has_motion_or_target:
            return true
    return false

func matrix_has_forager_visual_work(matrix: Array[Dictionary]) -> bool:
    for row in matrix:
        if String(row.get("job", "")) != "forage":
            continue
        var strict_home_value = row.get("strictHome", {})
        var strict_home: Dictionary = strict_home_value if strict_home_value is Dictionary else {}
        if bool(strict_home.get("strictInside", false)):
            continue
        if not bool(row.get("insideRoleLeash", false)):
            continue
        var phase := String(row.get("jobPhase", ""))
        var active := String(row.get("activeGoalKind", "")) == "forage"
        var away_from_home := float(row.get("distanceToHome", 0.0)) >= CELL * 8.0 or float(row.get("distanceFromInitial", 0.0)) >= CELL * 8.0
        if active and (not bool(row.get("insideTown", false)) or phase == "gathering" or away_from_home):
            return true
    return false

func matrix_has_guard_work(matrix: Array[Dictionary]) -> bool:
    for row in matrix:
        if row_is_visual_guard(row):
            return true
    return false

func row_is_visual_guard(row: Dictionary) -> bool:
    if String(row.get("job", "")) != "guard":
        return false
    if not bool(row.get("insideTown", false)):
        return false
    if not bool(row.get("guardPostNearPerimeter", false)):
        return false
    if float(row.get("distanceGuardPostToHome", 0.0)) < CELL * 8.0:
        return false
    if float(row.get("distanceToGuardPost", 999999.0)) > CELL * 5.0:
        return false
    return String(row.get("goal", "")).find("guard") >= 0 or String(row.get("activeGoalKind", "")) == "guard"

func non_special_workers_near_town(matrix: Array[Dictionary]) -> bool:
    var checked := 0
    for row in matrix:
        if not is_non_special_town_worker(row):
            continue
        checked += 1
        if not bool(row.get("insideTown", false)):
            return false
    return checked > 0

func non_special_workers_move_or_work(distance_by_id: Dictionary, matrix: Array[Dictionary]) -> bool:
    var checked := 0
    for row in matrix:
        if not is_non_special_town_worker(row):
            continue
        checked += 1
        var id := String(row.get("id", ""))
        var job := String(row.get("job", ""))
        var phase := String(row.get("jobPhase", ""))
        var moved := float(distance_by_id.get(id, 0.0)) >= CELL * 0.65
        var working := job in ["wood", "stone", "trade"] and phase != "idle"
        if not moved and not working:
            return false
    return checked > 0

func all_non_guard_npcs_strict_inside_with_closed_doors() -> bool:
    if npc_entries.is_empty():
        return false
    var checked := 0
    for entry in npc_entries:
        if bool(entry.get("nightGuard", false)):
            continue
        checked += 1
        if not bool(strict_home_status(entry).get("strictInside", false)):
            return false
        if any_home_door_open(entry):
            return false
    return checked > 0

func all_npcs_outside_home(matrix: Array[Dictionary]) -> bool:
    if matrix.is_empty():
        return false
    for row in matrix:
        var strict_home: Dictionary = row.get("strictHome", {})
        if bool(strict_home.get("strictInside", false)):
            return false
        if not bool(row.get("insideRoleLeash", false)):
            return false
    return true

func filtered_job_rows(matrix: Array[Dictionary], job: String) -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    for row in matrix:
        if String(row.get("job", "")) == job:
            rows.append(row)
    return rows

func filtered_non_special_rows(matrix: Array[Dictionary]) -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    for row in matrix:
        if is_non_special_town_worker(row):
            rows.append(row)
    return rows

func is_non_special_town_worker(row: Dictionary) -> bool:
    var job := String(row.get("job", ""))
    return job != "guard" and job != "forage"

func entry_by_id(id: String) -> Dictionary:
    for entry in npc_entries:
        if String(entry.get("id", "")) == id:
            return entry
    return {}

func missing_required_roles() -> Array[String]:
    return role_summary.get("missingRoles", []) as Array[String]

func missing_required_jobs() -> Array[String]:
    return role_summary.get("missingJobs", []) as Array[String]

func missing_from_counts(counts: Dictionary, required: Array) -> Array[String]:
    var missing: Array[String] = []
    for item in required:
        if int(counts.get(String(item), 0)) <= 0:
            missing.append(String(item))
    return missing

func natural_npc_filter_clean() -> bool:
    for entry in npc_entries:
        if is_tutorial_id(String(entry.get("id", ""))):
            return false
        if String(entry.get("townKey", "")) != town_key:
            return false
    return not npc_entries.is_empty()

func is_non_tutorial_town() -> bool:
    if town.is_empty():
        return false
    var selected_region: Vector2i = town.get("selectedRegion", Vector2i.ZERO)
    return selected_region != Vector2i(1, 0)

func capture_stage(stage: String, camera_mode: String) -> void:
    position_observer_camera(camera_mode)
    configure_observer_torch("wide" if camera_mode == "overview" else camera_mode)
    await wait_process_frames(3)
    save_capture(stage, camera_mode)

func capture_entry_stage(stage: String, entry: Dictionary, focus_mode: String, light_mode := "door_closeup") -> void:
    if focus_observer == null:
        return
    var context := observer_context()
    if focus_mode == "door_closeup":
        context["distance"] = CELL * 6.0
        context["height"] = CELL * 4.0
    elif focus_mode == "side_route":
        context["distance"] = CELL * 7.5
        context["height"] = CELL * 5.0
    elif focus_mode == "rear_follow":
        context["distance"] = CELL * 7.0
        context["height"] = CELL * 5.0
    elif focus_mode == "route_context":
        context["height"] = CELL * 28.0
    focus_observer.focus_entry(entry, focus_mode, context)
    configure_observer_torch(light_mode)
    var summary: Dictionary = focus_observer.summary()
    var target_summary: Dictionary = summary.get("target", {}) if summary.has("target") else {}
    last_observer_camera_target = Vector3(
        float(target_summary.get("x", observer_camera.global_position.x)),
        float(target_summary.get("y", observer_camera.global_position.y)),
        float(target_summary.get("z", observer_camera.global_position.z))
    )
    await wait_process_frames(3)
    save_capture(stage, focus_mode)

func save_capture(stage: String, camera_mode: String) -> void:
    var image := get_viewport().get_texture().get_image()
    var path := screenshot_dir.path_join("%s.png" % stage)
    var err := image.save_png(path)
    var capture := {
        "stage": stage,
        "path": path,
        "saved": err == OK,
        "cameraMode": camera_mode,
        "time": rounded(elapsed),
        "sample": phase_sample(stage, current_npc_matrix(stage)),
        "observerCamera": observer_camera_summary(),
        "observerTorch": observer_torch_summary()
    }
    captures.append(capture)
    if err != OK:
        add_result("capture_%s_saved" % stage, false, path)

func capture_night_failure_diagnostics() -> void:
    var suspects := night_failure_entries(MAX_NIGHT_DIAGNOSTIC_SUSPECTS)
    var index := 1
    for entry in suspects:
        var suffix := safe_stage_suffix(entry)
        await capture_entry_stage("night_failure_%02d_%s_door_closeup" % [index, suffix], entry, "door_closeup", "door_closeup")
        await wait_physics_frames(NIGHT_DIAGNOSTIC_SEQUENCE_FRAMES)
        await capture_entry_stage("night_failure_%02d_%s_door_cycle_01" % [index, suffix], entry, "door_closeup", "door_closeup")
        await wait_physics_frames(NIGHT_DIAGNOSTIC_SEQUENCE_FRAMES)
        await capture_entry_stage("night_failure_%02d_%s_door_cycle_02" % [index, suffix], entry, "door_closeup", "door_closeup")
        await wait_physics_frames(NIGHT_DIAGNOSTIC_SEQUENCE_FRAMES)
        await capture_entry_stage("night_failure_%02d_%s_door_cycle_03" % [index, suffix], entry, "door_closeup", "door_closeup")
        await capture_entry_stage("night_failure_%02d_%s_door_wide" % [index, suffix], entry, "door_inspection", "door_closeup")
        await capture_entry_stage("night_failure_%02d_%s_route_context" % [index, suffix], entry, "route_context", "wide")
        await capture_entry_stage("night_failure_%02d_%s_rear_follow" % [index, suffix], entry, "rear_follow", "wide")
        index += 1
    add_result("night_failure_visual_diagnostics_saved", not suspects.is_empty(), JSON.stringify({
        "suspectCount": suspects.size(),
        "stages": capture_names().filter(func(name): return String(name).begins_with("night_failure_"))
    }))

func capture_night_door_loop_diagnostics(loop_rows: Array[Dictionary], trigger: String) -> void:
    if night_loop_diagnostics_captured:
        return
    var entries := door_loop_entries(loop_rows, MAX_NIGHT_DIAGNOSTIC_SUSPECTS)
    var stages: Array[String] = []
    var index := 1
    for entry in entries:
        var suffix := safe_stage_suffix(entry)
        var stage_1 := "night_door_loop_%02d_%s_closeup_01" % [index, suffix]
        await capture_entry_stage(stage_1, entry, "door_closeup", "door_closeup")
        stages.append(stage_1)
        record_night_door_sample("%s_%s" % [trigger, stage_1], -1)
        await wait_physics_frames(NIGHT_LOOP_SEQUENCE_FRAMES)
        var stage_2 := "night_door_loop_%02d_%s_closeup_02" % [index, suffix]
        await capture_entry_stage(stage_2, entry, "door_closeup", "door_closeup")
        stages.append(stage_2)
        record_night_door_sample("%s_%s" % [trigger, stage_2], -1)
        await wait_physics_frames(NIGHT_LOOP_SEQUENCE_FRAMES)
        var stage_3 := "night_door_loop_%02d_%s_closeup_03" % [index, suffix]
        await capture_entry_stage(stage_3, entry, "door_closeup", "door_closeup")
        stages.append(stage_3)
        record_night_door_sample("%s_%s" % [trigger, stage_3], -1)
        var stage_wide := "night_door_loop_%02d_%s_wide" % [index, suffix]
        await capture_entry_stage(stage_wide, entry, "door_inspection", "door_closeup")
        stages.append(stage_wide)
        record_night_door_sample("%s_%s" % [trigger, stage_wide], -1)
        index += 1
    night_loop_diagnostics_captured = true
    var missing: Array[String] = []
    for stage in stages:
        if not capture_stage_saved(stage):
            missing.append(stage)
    night_loop_diagnostics = {
        "trigger": trigger,
        "detectedAtElapsed": rounded(elapsed),
        "detectedAtDisplayHour": rounded(display_hour()),
        "loopRows": sanitize_value(loop_rows),
        "suspectCount": entries.size(),
        "stages": stages,
        "missingStages": missing
    }
    add_result("night_door_loop_visual_diagnostics_saved", not stages.is_empty() and missing.is_empty(), JSON.stringify(night_loop_diagnostics))

func capture_night_door_transition_visuals(frame: int) -> void:
    if night_door_transition_visuals.size() >= MAX_NIGHT_DOOR_TRANSITION_VISUALS:
        return
    var current := door_transition_counts_by_portal()
    for portal_id_value in current.keys():
        if night_door_transition_visuals.size() >= MAX_NIGHT_DOOR_TRANSITION_VISUALS:
            return
        var portal_id := String(portal_id_value)
        var now: Dictionary = current.get(portal_id, {})
        var before: Dictionary = night_transition_last_counts.get(portal_id, {})
        var open_delta := int(now.get("open", 0)) - int(before.get("open", 0))
        var close_delta := int(now.get("close", 0)) - int(before.get("close", 0))
        if open_delta <= 0 and close_delta <= 0:
            continue
        night_transition_last_counts[portal_id] = now.duplicate(true)
        var entry := entry_for_portal(portal_id)
        if entry.is_empty():
            continue
        var transition_kind := "open_close"
        if open_delta > 0 and close_delta <= 0:
            transition_kind = "open"
        elif close_delta > 0 and open_delta <= 0:
            transition_kind = "close"
        var suffix := safe_stage_suffix(entry)
        var stage := "night_door_transition_%02d_%s_%s" % [night_door_transition_visuals.size() + 1, transition_kind, suffix]
        await capture_entry_stage(stage, entry, "door_closeup", "door_closeup")
        var row := night_door_row(entry)
        var visual := {
            "stage": stage,
            "frame": frame,
            "displayHour": rounded(display_hour()),
            "elapsed": rounded(elapsed),
            "portalId": portal_id,
            "transitionKind": transition_kind,
            "openDelta": open_delta,
            "closeDelta": close_delta,
            "counts": now.duplicate(true),
            "npc": {
                "id": String(entry.get("id", "")),
                "name": String(entry.get("name", "")),
                "role": String(entry.get("role", "")),
                "job": String(entry.get("job", ""))
            },
            "row": row,
            "saved": capture_stage_saved(stage)
        }
        night_door_transition_visuals.append(visual)
        record_night_door_sample("night_transition_%s_%04d" % [transition_kind, frame], frame)

func position_observer_camera(mode: String) -> void:
    if observer_camera == null:
        return
    var radius := float(town.get("radius", 30)) * CELL
    var context := observer_context()
    var center := town_center_position()
    if focus_observer == null:
        var target := center + Vector3(0.0, CELL * 1.2, 0.0)
        observer_camera.global_position = center + Vector3(CELL * 35.0, CELL * 22.0, CELL * 35.0)
        observer_camera.look_at(target, Vector3.UP)
        last_observer_camera_target = target
        update_lod_observer_anchor(target)
        observer_camera.make_current()
        return
    if mode == "overview":
        focus_observer.focus_overview(center, radius, town_level)
    else:
        var entry := focus_entry_for_mode(mode)
        var focus_mode := "front_overhead"
        if mode == "guard":
            focus_mode = "front_overhead"
        elif mode == "night_suspect":
            focus_mode = "door_inspection"
        elif mode == "route_suspect":
            focus_mode = "front_overhead"
        elif mode == "morning_worker":
            focus_mode = "rear_follow"
        focus_observer.focus_entry(entry, focus_mode, context)
    var summary: Dictionary = focus_observer.summary()
    var target_summary: Dictionary = summary.get("target", {}) if summary.has("target") else {}
    last_observer_camera_target = Vector3(
        float(target_summary.get("x", center.x)),
        float(target_summary.get("y", center.y)),
        float(target_summary.get("z", center.z))
    )
    update_lod_observer_anchor(last_observer_camera_target)

func update_lod_observer_anchor(target: Vector3) -> void:
    if player == null:
        return
    player.global_position = Vector3(target.x, town_level + 0.15, target.z) # town_job_cycle_fixture_camera_load
    player.velocity = Vector3.ZERO

func observer_context() -> Dictionary:
    return {
        "townCenterPosition": town_center_position(),
        "townRadius": float(town.get("radius", 30)) * CELL,
        "townLevel": town_level
    }

func first_entry_with_job(job: String, prefer_outside_home := false) -> Dictionary:
    var fallback := {}
    for entry in npc_entries:
        if String(entry.get("job", "")) == job:
            if not prefer_outside_home or not bool(strict_home_status(entry).get("strictInside", false)):
                return entry
            if fallback.is_empty():
                fallback = entry
    return fallback

func focus_entry_for_mode(mode: String) -> Dictionary:
    if mode == "forager":
        return best_focus_entry_for_job("forage", true)
    if mode == "guard":
        return best_focus_entry_for_job("guard")
    if mode == "morning_worker":
        var worker := first_non_special_worker(false)
        return worker if not worker.is_empty() else first_entry_with_job("forage")
    if mode == "night_suspect" or mode == "route_suspect":
        var suspect := first_night_return_suspect()
        return suspect if not suspect.is_empty() else first_non_guard_entry()
    return first_non_guard_entry()

func best_focus_entry_for_job(job: String, require_visual_forager := false) -> Dictionary:
    var best := {}
    var best_score := -999999.0
    for entry in npc_entries:
        if String(entry.get("job", "")) != job:
            continue
        var body := entry.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if require_visual_forager and job == "forage" and not entry_is_visual_forager(entry):
            continue
        if job == "guard" and not entry_is_visual_guard(entry):
            continue
        var position := body.global_position
        var score := 0.0
        if not bool(strict_home_status(entry).get("strictInside", false)):
            score += 20.0
        if String(entry.get("activeGoalKind", "")) == job or (job == "guard" and String(entry.get("activeGoalKind", "")) == "guard"):
            score += 20.0
        var phase := String(entry.get("jobPhase", ""))
        if job == "forage":
            if not point_inside_town(position):
                score += 45.0
            if phase == "gathering":
                score += 35.0
            elif phase in ["outbound", "returning"]:
                score += 18.0
            score += minf(flat_distance(position, entry.get("homePosition", position)) / CELL, 40.0)
        elif job == "guard":
            if String(entry.get("goal", "")).find("guard") >= 0:
                score += 25.0
            if String(entry.get("routeStatus", "")) != "blocked":
                score += 10.0
            score += minf(flat_distance(position, entry.get("homePosition", position)) / CELL, 40.0)
        if best.is_empty() or score > best_score:
            best = entry
            best_score = score
    if not best.is_empty():
        return best
    return {} if require_visual_forager else first_entry_with_job(job, true)

func entry_is_visual_forager(entry: Dictionary) -> bool:
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return false
    if bool(strict_home_status(entry).get("strictInside", false)):
        return false
    if not point_inside_role_leash(entry, body.global_position):
        return false
    if String(entry.get("activeGoalKind", "")) != "forage":
        return false
    var phase := String(entry.get("jobPhase", ""))
    var position := body.global_position
    var home_position: Vector3 = entry.get("homePosition", position) if entry.get("homePosition", position) is Vector3 else position
    var away_from_home := flat_distance(position, home_position) >= CELL * 8.0 or float(entry.get("distanceFromInitial", 0.0)) >= CELL * 8.0
    return (not point_inside_town(position)) or phase == "gathering" or away_from_home

func entry_is_visual_guard(entry: Dictionary) -> bool:
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return false
    if bool(strict_home_status(entry).get("strictInside", false)):
        return false
    var position := body.global_position
    if not point_inside_town(position):
        return false
    var guard_position: Vector3 = entry.get("guardPosition", position) if entry.get("guardPosition", position) is Vector3 else position
    var guard_cell: Vector2i = entry.get("guardCell", flat_cell(guard_position)) if entry.get("guardCell", flat_cell(guard_position)) is Vector2i else flat_cell(guard_position)
    var home_position: Vector3 = entry.get("homePosition", position) if entry.get("homePosition", position) is Vector3 else position
    if not is_near_town_perimeter(guard_cell):
        return false
    if flat_distance(guard_position, home_position) < CELL * 8.0:
        return false
    if flat_distance(position, guard_position) > CELL * 5.0:
        return false
    return String(entry.get("goal", "")).find("guard") >= 0 or String(entry.get("activeGoalKind", "")) == "guard"

func first_night_return_suspect() -> Dictionary:
    for entry in npc_entries:
        if entry.is_empty() or bool(entry.get("nightGuard", false)):
            continue
        var body := entry.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            return entry
        if not bool(strict_home_status(entry).get("strictInside", false)):
            return entry
        if any_home_door_open(entry):
            return entry
    return {}

func night_failure_entries(max_count := 999) -> Array[Dictionary]:
    var suspects: Array[Dictionary] = []
    for entry in npc_entries:
        if entry.is_empty() or bool(entry.get("nightGuard", false)):
            continue
        if not bool(strict_home_status(entry).get("strictInside", false)) or any_home_door_open(entry):
            suspects.append(entry)
            if suspects.size() >= max_count:
                break
    return suspects

func door_loop_entries(loop_rows: Array[Dictionary], max_count := 999) -> Array[Dictionary]:
    var entries: Array[Dictionary] = []
    var seen := {}
    for row in loop_rows:
        var ids_value = row.get("affectedNpcIds", [])
        if not (ids_value is Array):
            continue
        for id_value in ids_value:
            var id := String(id_value)
            if seen.has(id):
                continue
            seen[id] = true
            var entry := entry_by_id(id)
            if entry.is_empty():
                continue
            entries.append(entry)
            if entries.size() >= max_count:
                return entries
    return entries

func entry_for_portal(portal_id: String) -> Dictionary:
    for entry in npc_entries:
        var door := npc_home_door(entry)
        if door == null:
            continue
        if String(door.get_meta("door_portal_id", "")) == portal_id:
            return entry
    return {}

func record_night_door_sample(label: String, frame: int) -> void:
    night_door_timeline.append({
        "label": label,
        "frame": frame,
        "elapsed": rounded(elapsed),
        "displayHour": rounded(display_hour()),
        "rows": night_door_rows()
    })
    while night_door_timeline.size() > MAX_NIGHT_DOOR_TIMELINE_SAMPLES:
        night_door_timeline.pop_front()

func night_door_rows() -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    for entry in npc_entries:
        if entry.is_empty() or bool(entry.get("nightGuard", false)):
            continue
        rows.append(night_door_row(entry))
    return rows

func night_door_row(entry: Dictionary) -> Dictionary:
    var door := npc_home_door(entry)
    var portal_id := String(door.get_meta("door_portal_id", "")) if door != null else String(entry.get("activeDoorPortalId", ""))
    var home_status := strict_home_status(entry)
    var body := entry.get("body") as Node3D
    var position := body.global_position if body != null and is_instance_valid(body) else Vector3.ZERO
    var home_route := home_route_summary(entry, position)
    return {
        "id": String(entry.get("id", "")),
        "name": String(entry.get("name", "")),
        "role": String(entry.get("role", "")),
        "job": String(entry.get("job", "")),
        "strictInside": bool(home_status.get("strictInside", false)),
        "insideHome": bool(entry.get("insideHome", false)),
        "homeDoorOpen": any_home_door_open(entry),
        "activeDoorPortalId": String(entry.get("activeDoorPortalId", "")),
        "activeDoorDirection": String(entry.get("activeDoorDirection", "")),
        "routeStatus": String(entry.get("routeStatus", "")),
        "routeReason": String(entry.get("routeReason", "")),
        "routeCellCount": (entry.get("routeCells", []) as Array).size(),
        "pathWaypointCount": (entry.get("pathWaypoints", []) as Array).size(),
        "homeRoute": home_route,
        "homeRouteIndex": int(home_route.get("index", 0)),
        "homeRoutePositionCount": int(home_route.get("count", 0)),
        "distanceToHomeRouteTarget": rounded(float(home_route.get("distanceToCurrentTarget", 0.0))),
        "cell": vec2i(flat_cell(position)) if body != null and is_instance_valid(body) else {},
        "homeActiveTargetCell": vec2i(entry.get("homeActiveTargetCell", Vector2i(999999, 999999)) if entry.get("homeActiveTargetCell", Vector2i(999999, 999999)) is Vector2i else Vector2i(999999, 999999)),
        "door": block_summary(door),
        "portal": door_portal_summary(portal_id),
        "controllerTransitions": door_controller_transition_counts(portal_id)
    }

func night_home_route_evidence_ok(matrix: Array[Dictionary]) -> bool:
    var checked := 0
    for row in matrix:
        if bool(row.get("nightGuard", false)):
            continue
        checked += 1
        if int(row.get("homeRoutePositionCount", 0)) <= 0:
            return false
        var home_route_value = row.get("homeRoute", {})
        if not (home_route_value is Dictionary):
            return false
        var home_route: Dictionary = home_route_value
        if not bool(home_route.get("hasCurrentTarget", false)) and not bool(home_route.get("complete", false)):
            return false
    return checked > 0

func night_home_route_evidence_rows(matrix: Array[Dictionary]) -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    for row in matrix:
        if bool(row.get("nightGuard", false)):
            continue
        rows.append({
            "id": String(row.get("id", "")),
            "name": String(row.get("name", "")),
            "role": String(row.get("role", "")),
            "job": String(row.get("job", "")),
            "cell": row.get("cell", {}),
            "strictHome": row.get("strictHome", {}),
            "homeActiveTargetCell": row.get("homeActiveTargetCell", {}),
            "homeRoute": row.get("homeRoute", {}),
            "routeStatus": String(row.get("routeStatus", "")),
            "routeReason": String(row.get("routeReason", "")),
            "lastRoutePlanDebug": row.get("lastRoutePlanDebug", {})
        })
    return rows

func door_transition_counts_by_portal() -> Dictionary:
    var counts := {}
    var door_portals = autonomy_door_portals()
    if door_portals == null:
        return counts
    var controllers: Dictionary = door_portals.get("controllers") if door_portals.get("controllers") is Dictionary else {}
    for portal_id_value in controllers.keys():
        var portal_id := String(portal_id_value)
        counts[portal_id] = door_controller_transition_counts(portal_id)
    return counts

func door_transition_loops(baseline: Dictionary) -> Array[Dictionary]:
    var loops: Array[Dictionary] = []
    var current := door_transition_counts_by_portal()
    for portal_id_value in current.keys():
        var portal_id := String(portal_id_value)
        var now: Dictionary = current.get(portal_id, {})
        var before: Dictionary = baseline.get(portal_id, {})
        var open_delta := int(now.get("open", 0)) - int(before.get("open", 0))
        var close_delta := int(now.get("close", 0)) - int(before.get("close", 0))
        if open_delta >= DOOR_LOOP_TRANSITION_MIN_DELTA and close_delta >= DOOR_LOOP_TRANSITION_MIN_DELTA:
            loops.append({
                "portalId": portal_id,
                "openDelta": open_delta,
                "closeDelta": close_delta,
                "current": now,
                "baseline": before,
                "affectedNpcIds": npc_ids_for_portal(portal_id)
            })
    return loops

func npc_ids_for_portal(portal_id: String) -> Array[String]:
    var ids: Array[String] = []
    for entry in npc_entries:
        var door := npc_home_door(entry)
        if door == null:
            continue
        if String(door.get_meta("door_portal_id", "")) == portal_id:
            ids.append(String(entry.get("id", "")))
    ids.sort()
    return ids

func autonomy_door_portals():
    if npc_system == null:
        return null
    var autonomy = npc_system.get("autonomy_system")
    if autonomy == null:
        return null
    return autonomy.get("door_portals")

func door_portal_summary(portal_id: String) -> Dictionary:
    if portal_id == "":
        return {}
    var door_portals = autonomy_door_portals()
    if door_portals == null:
        return {}
    var portals: Dictionary = door_portals.get("portals") if door_portals.get("portals") is Dictionary else {}
    var portal = portals.get(portal_id)
    if portal == null:
        return {}
    if portal.has_method("to_summary"):
        return sanitize_value(portal.call("to_summary"))
    return {}

func door_controller_transition_counts(portal_id: String) -> Dictionary:
    if portal_id == "":
        return {}
    var door_portals = autonomy_door_portals()
    if door_portals == null:
        return {}
    var controllers: Dictionary = door_portals.get("controllers") if door_portals.get("controllers") is Dictionary else {}
    var controller = controllers.get(portal_id)
    if controller == null:
        return {}
    var counts = controller.get("transition_counts")
    return counts.duplicate(true) if counts is Dictionary else {}

func door_lifecycle_trace_snapshot(portal_id := "", limit := 96) -> Array[Dictionary]:
    var door_portals = autonomy_door_portals()
    if door_portals == null or not door_portals.has_method("lifecycle_trace_snapshot"):
        return []
    return door_portals.call("lifecycle_trace_snapshot", portal_id, limit)

func safe_stage_suffix(entry: Dictionary) -> String:
    var raw := "%s_%s" % [String(entry.get("name", "npc")), String(entry.get("id", "unknown"))]
    var result := ""
    for i in range(raw.length()):
        var ch := raw.substr(i, 1)
        if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
            result += ch.to_lower()
        else:
            result += "_"
    while result.find("__") >= 0:
        result = result.replace("__", "_")
    while result.begins_with("_"):
        result = result.substr(1)
    while result.ends_with("_"):
        result = result.substr(0, result.length() - 1)
    return result

func first_non_special_worker(require_outside_home := false) -> Dictionary:
    for entry in npc_entries:
        var job := String(entry.get("job", ""))
        if job == "guard" or job == "forage":
            continue
        if require_outside_home and bool(strict_home_status(entry).get("strictInside", false)):
            continue
        return entry
    return {}

func first_non_guard_entry() -> Dictionary:
    for entry in npc_entries:
        if not bool(entry.get("nightGuard", false)):
            return entry
    return {}

func configure_observer_torch(mode: String) -> void:
    if focus_observer != null:
        focus_observer.configure_light(mode)
        return
    if observer_torch == null or not is_instance_valid(observer_torch):
        return
    observer_torch.visible = true
    if mode == "wide":
        observer_torch.light_energy = 4.5
        observer_torch.omni_range = CELL * 18.0
    else:
        observer_torch.light_energy = 4.8
        observer_torch.omni_range = CELL * 10.0

func npc_home_door(entry: Dictionary) -> Node3D:
    if entry.is_empty() or main == null:
        return null
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    var porch_position: Vector3 = entry.get("porchPosition", entry.get("homePosition", Vector3.ZERO))
    var home_position: Vector3 = entry.get("homePosition", porch_position)
    var best: Node3D = null
    var best_distance := INF
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as Node3D
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("block_type", "")) != "door":
            continue
        var distance := minf(flat_distance(block.global_position, porch_position), flat_distance(block.global_position, home_position))
        if distance < best_distance:
            best_distance = distance
            best = block
    return best

func any_home_door_open(entry: Dictionary) -> bool:
    var door := npc_home_door(entry)
    if door == null:
        return false
    var group_id := String(door.get_meta("door_group_id", ""))
    var portal_id := String(door.get_meta("door_portal_id", ""))
    var blocks_value = main.get("blocks") if main != null else {}
    if not (blocks_value is Dictionary):
        return bool(door.get_meta("open", false))
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as Node
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("block_type", "")) != "door":
            continue
        var same_group := group_id != "" and String(block.get_meta("door_group_id", "")) == group_id
        var same_portal := portal_id != "" and String(block.get_meta("door_portal_id", "")) == portal_id
        if (same_group or same_portal or block == door) and bool(block.get_meta("open", false)):
            return true
    return false

func strict_home_status(entry: Dictionary) -> Dictionary:
    if entry.is_empty():
        return { "strictInside": false, "reason": "entry_missing" }
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return { "strictInside": false, "reason": "body_missing" }
    return HomeInteriorServiceScript.status(entry, body.global_position, home_door_portal(entry))

func home_route_summary(entry: Dictionary, position: Vector3) -> Dictionary:
    var route_positions: Array = entry.get("homeRoutePositions", []) if entry.get("homeRoutePositions", []) is Array else []
    var index := clampi(int(entry.get("homeRouteIndex", 0)), 0, route_positions.size())
    var current_target := {}
    var distance_to_current := 0.0
    var has_current_target := false
    if index < route_positions.size() and route_positions[index] is Vector3:
        var target: Vector3 = route_positions[index]
        has_current_target = true
        distance_to_current = flat_distance(position, target)
        current_target = {
            "index": index,
            "position": vec3(target),
            "cell": vec2i(flat_cell(target))
        }
    var next_targets: Array[Dictionary] = []
    var end_index := mini(route_positions.size(), index + 5)
    for route_index in range(index, end_index):
        var value = route_positions[route_index]
        if value is Vector3:
            var route_position: Vector3 = value
            next_targets.append({
                "index": route_index,
                "position": vec3(route_position),
                "cell": vec2i(flat_cell(route_position)),
                "distanceFromNpc": rounded(flat_distance(position, route_position))
            })
        else:
            next_targets.append({
                "index": route_index,
                "value": sanitize_value(value)
            })
    return {
        "count": route_positions.size(),
        "index": index,
        "remaining": maxi(0, route_positions.size() - index),
        "complete": index >= route_positions.size(),
        "hasCurrentTarget": has_current_target,
        "currentTarget": current_target,
        "distanceToCurrentTarget": rounded(distance_to_current),
        "nextTargets": next_targets
    }

func home_door_volume_occupied(entry: Dictionary, position: Vector3, volume: String) -> bool:
    var portal = home_door_portal(entry)
    if portal == null:
        return false
    var bounds_value = portal.get("%s_bounds" % volume)
    if not (bounds_value is AABB):
        return false
    var bounds: AABB = bounds_value
    if bounds.size == Vector3.ZERO:
        return false
    var expanded := bounds.grow(NpcConstantsScript.DEFAULT_NPC_RADIUS)
    expanded.position.y -= NpcConstantsScript.CELL_SIZE
    expanded.size.y += NpcConstantsScript.CELL_SIZE
    return expanded.has_point(position)

func home_door_portal(entry: Dictionary):
    var door := npc_home_door(entry)
    if door == null:
        return null
    var portal_id := String(door.get_meta("door_portal_id", ""))
    if portal_id == "":
        return null
    var door_portals = autonomy_door_portals()
    if door_portals == null:
        return null
    var portals: Dictionary = door_portals.get("portals") if door_portals.get("portals") is Dictionary else {}
    return portals.get(portal_id)

func block_summary(block: Node) -> Dictionary:
    if block == null or not is_instance_valid(block):
        return {}
    return {
        "name": block.name,
        "blockType": String(block.get_meta("block_type", "")),
        "cell": vec3i(block.get_meta("cell", Vector3i.ZERO)),
        "accentRole": String(block.get_meta("accentRole", "")),
        "open": bool(block.get_meta("open", false)),
        "doorGroupId": String(block.get_meta("door_group_id", "")),
        "doorPortalId": String(block.get_meta("door_portal_id", "")),
        "position": vec3((block as Node3D).global_position) if block is Node3D else {}
    }

func move_player_for_lod(center: Vector2i, level: float) -> void:
    if player == null:
        return
    var radius := int(town.get("radius", 30))
    player.global_position = Vector3(float(center.x - radius - 8) * CELL, level + 0.15, float(center.y - radius - 8) * CELL) # town_job_cycle_fixture_camera_load
    player.velocity = Vector3.ZERO

func town_records() -> Array:
    var structure_system = main.get("structure_system") if main != null else null
    if structure_system == null or not structure_system.has_method("town_home_records_snapshot"):
        return []
    var records_by_town: Dictionary = structure_system.call("town_home_records_snapshot")
    var records = records_by_town.get(town_key, [])
    return records if records is Array else []

func point_inside_town(position: Vector3) -> bool:
    return flat_distance(position, town_center_position()) <= float(town.get("radius", 30)) * CELL

func point_inside_role_leash(entry: Dictionary, position: Vector3) -> bool:
    return flat_distance(position, town_center_position()) <= role_leash_radius_world(entry)

func role_leash_radius_world(entry: Dictionary) -> float:
    var radius_cells := float(entry.get("townRadius", town.get("radius", 30)))
    var job := String(entry.get("job", ""))
    var role := String(entry.get("role", "")).to_lower()
    if job == "forage":
        radius_cells += 24.0
    elif job == "guard" or role.find("guard") >= 0:
        radius_cells += 8.0
    return radius_cells * CELL

func is_near_town_perimeter(cell: Vector2i) -> bool:
    var radius := int(town.get("radius", 30))
    var dx: int = absi(cell.x - town_center.x)
    var dz: int = absi(cell.y - town_center.y)
    return abs(maxi(dx, dz) - radius) <= 3

func town_center_position() -> Vector3:
    return Vector3(float(town_center.x) * CELL, town_level + 0.04, float(town_center.y) * CELL)

func flat_cell(position: Vector3) -> Vector2i:
    return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func flat_distance(a: Vector3, b: Vector3) -> float:
    return Vector2(a.x - b.x, a.z - b.z).length()

func display_hour() -> float:
    return clock_phase() * 24.0

func clock_phase() -> float:
    if main == null:
        return 0.0
    return fposmod(float(main.get("time_of_day")) + 0.25, 1.0)

func add_result(name: String, passed: bool, details := "") -> void:
    results.append({
        "name": name,
        "passed": passed,
        "details": details
    })
    if not passed:
        failed = true
    print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])
    write_report(false)

func finish(exit_code: int) -> void:
    if finished:
        return
    finished = true
    Engine.time_scale = 1.0
    write_report(true)
    write_progress("finished")
    get_tree().quit(exit_code)

func write_report(verbose := true) -> void:
    var failure_count := 0
    for result in results:
        if not bool(result.get("passed", false)):
            failure_count += 1
    var report := {
        "schemaVersion": 1,
        "testId": TEST_ID,
        "seed": seed,
        "runToken": run_token,
        "nonHeadlessRequired": true,
        "finished": finished,
        "passed": failure_count == 0,
        "failureCount": failure_count,
        "resultCount": results.size(),
        "preconditionBlocked": precondition_blocked,
        "stoppedPhase": stopped_phase,
        "results": results,
        "town": town_summary,
        "behaviorAuthority": {
            "mode": "natural_generated_world_observation_only",
            "directNpcActionOrders": false,
            "directNpcRosterInjection": false,
            "directTownFixtureConstruction": false,
            "directDoorServiceCalls": false,
            "directInsideHomeMetadata": false,
            "clockTransitions": "time_scale_fast_forward"
        },
        "captures": captures,
        "timeline": timeline,
        "timelineTail": timeline.slice(maxi(0, timeline.size() - 36), timeline.size()),
        "nightDoorTimeline": night_door_timeline,
        "nightDoorTimelineTail": night_door_timeline.slice(maxi(0, night_door_timeline.size() - 24), night_door_timeline.size()),
        "nightDoorLoopDiagnostics": night_loop_diagnostics,
        "nightDoorTransitionVisuals": night_door_transition_visuals,
        "doorLifecycleTraceTail": door_lifecycle_trace_snapshot("", 192),
        "dayMatrix": day_matrix,
        "nightMatrix": night_matrix,
        "morningMatrix": morning_matrix
    }
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write town job-cycle visual report: %s" % report_path)
        return
    file.store_string(JSON.stringify(sanitize_value(report), "  "))
    file.close()
    if verbose:
        print("NPC town job-cycle visual report: %s" % report_path)

func write_progress(label: String) -> void:
    if progress_path == "":
        return
    var file := FileAccess.open(progress_path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\nelapsed=%.3f\ntime=%.2f\nresults=%d\nfailed=%s\n" % [label, elapsed, display_hour(), results.size(), str(failed)])
    file.close()

func required_captures_saved() -> bool:
    var saved := {}
    for capture in captures:
        if bool(capture.get("saved", false)):
            saved[String(capture.get("stage", ""))] = true
    for stage in REQUIRED_CAPTURE_STAGES:
        if not bool(saved.get(String(stage), false)):
            return false
    return true

func capture_stage_saved(stage: String) -> bool:
    for capture in captures:
        if String(capture.get("stage", "")) == stage and bool(capture.get("saved", false)):
            return true
    return false

func capture_names() -> Array[String]:
    var names: Array[String] = []
    for capture in captures:
        names.append(String(capture.get("stage", "")))
    return names

func observer_camera_summary() -> Dictionary:
    if observer_camera == null:
        return {}
    if focus_observer != null:
        var summary: Dictionary = focus_observer.summary()
        if not summary.is_empty():
            return summary
    return {
        "position": vec3(observer_camera.global_position),
        "target": vec3(last_observer_camera_target),
        "fov": rounded(observer_camera.fov)
    }

func observer_torch_summary() -> Dictionary:
    if observer_torch == null:
        return {}
    return {
        "visible": observer_torch.visible,
        "energy": rounded(observer_torch.light_energy),
        "range": rounded(observer_torch.omni_range)
    }

func is_tutorial_id(id: String) -> bool:
    var lowered := id.to_lower()
    return lowered in ["mira", "rowan", "niko", "sera", "toma", "lyra"] or lowered.begins_with("tutorial")

func wait_physics_frames(count: int) -> void:
    for _i in range(count):
        await get_tree().physics_frame

func wait_startup_physics_frames(count: int, label: String) -> bool:
    Engine.time_scale = 1.0
    get_tree().paused = false
    var start_frame := int(Engine.get_physics_frames())
    var process_frames := 0
    var max_process_frames := maxi(count * 8, 180)
    while int(Engine.get_physics_frames()) - start_frame < count and process_frames < max_process_frames:
        await get_tree().process_frame
        process_frames += 1
        if process_frames % 30 == 0:
            write_progress("%s_physics_%d_%d" % [label, int(Engine.get_physics_frames()) - start_frame, count])
    var advanced := int(Engine.get_physics_frames()) - start_frame
    write_progress("%s_physics_ready_%d_%d" % [label, advanced, count])
    return advanced >= count

func wait_process_frames(count: int) -> void:
    for _i in range(count):
        await get_tree().process_frame

func rounded(value: float) -> float:
    return snappedf(value, 0.001)

func vec2i(value: Vector2i) -> Dictionary:
    return { "x": value.x, "z": value.y }

func vec3i(value: Vector3i) -> Dictionary:
    return { "x": value.x, "y": value.y, "z": value.z }

func vec3(value: Vector3) -> Dictionary:
    return { "x": rounded(value.x), "y": rounded(value.y), "z": rounded(value.z) }

func sanitize_value(value):
    if value is Vector2i:
        return vec2i(value)
    if value is Vector3i:
        return vec3i(value)
    if value is Vector3:
        return vec3(value)
    if value is Color:
        return { "r": value.r, "g": value.g, "b": value.b, "a": value.a }
    if value is Node:
        return (value as Node).name
    if value is Dictionary:
        var out := {}
        for key in value.keys():
            out[String(key)] = sanitize_value(value[key])
        return out
    if value is Array:
        var out_array := []
        for item in value:
            out_array.append(sanitize_value(item))
        return out_array
    return value

func ensure_dir(path: String) -> void:
    if path == "":
        return
    DirAccess.make_dir_recursive_absolute(path)
