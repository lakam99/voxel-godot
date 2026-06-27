extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const TEST_ID := "npc_tutorial_real_knock_to_morning_foragers"
const CELL := 1.35
const STARTUP_FRAMES := 80
const POST_ACTION_FRAMES := 24
const SAMPLE_EVERY_FRAMES := 6

var main: Node3D
var player: CharacterBody3D
var camera: Camera3D
var elapsed := 0.0
var finished := false
var failed := false
var report_data := {}
var results: Array[Dictionary] = []
var failure_reasons: Array[Dictionary] = []
var player_timeline: Array[Dictionary] = []
var door_timeline: Array[Dictionary] = []
var mira_timeline: Array[Dictionary] = []
var mira_speed_samples: Array[Dictionary] = []
var route_order_timeline: Array[Dictionary] = []
var schedule_matrix: Array[Dictionary] = []
var max_mira_flat_speed := 0.0
var mira_total_flat_distance := 0.0
var previous_mira_position := Vector3.ZERO
var previous_mira_valid := false
var physics_dt := 1.0 / 60.0
var gameplay_started := false

func _ready() -> void:
    physics_dt = 1.0 / float(Engine.physics_ticks_per_second)
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    elapsed += delta
    var limit := watchdog_seconds()
    if elapsed > limit:
        add_failure("runner_watchdog", "runner exceeded %.1f seconds" % limit)
        finish()

func run() -> void:
    mark_progress("start")
    report_data = {
        "schemaVersion": 1,
        "testId": TEST_ID,
        "seed": OS.get_environment("VOXEL_TEST_SEED").strip_edges(),
        "runToken": OS.get_environment("VOXEL_REAL_TUTORIAL_RUN_TOKEN"),
        "gitBranch": OS.get_environment("VOXEL_GIT_BRANCH"),
        "gitCommit": OS.get_environment("VOXEL_GIT_COMMIT"),
        "deterministicSetup": {},
        "scriptErrorScan": { "status": "pending-wrapper-scan", "matches": [] },
        "forbiddenCallSelfScan": { "status": "passed-by-wrapper-before-launch" }
    }

    main = MAIN_SCENE.instantiate()
    add_child(main)
    mark_progress("main_instantiated")
    await wait_physics_frames(30)
    bind_scene_nodes()
    await prepare_tutorial_world()
    await wait_physics_frames(STARTUP_FRAMES)
    bind_scene_nodes()

    if main == null or player == null or camera == null:
        add_failure("scene_bootstrap_failed", "main/player/camera missing")
        finish()
        return

    player.set("automated_input", true)
    player.set("automated_move", Vector3.ZERO)
    player.set("automated_sprint", false)
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    gameplay_started = true
    mark_progress("gameplay_started")

    await run_real_knock_to_morning_foragers()
    finish()

func prepare_tutorial_world() -> void:
    var tutorial = main.get("tutorial_system") if main != null else null
    if tutorial != null and tutorial.has_method("start_new_world"):
        var started := bool(tutorial.call("start_new_world"))
        report_data["deterministicSetup"] = {
            "usedTutorialWorldResetBeforeInput": true,
            "started": started
        }
    else:
        report_data["deterministicSetup"] = {
            "usedTutorialWorldResetBeforeInput": false,
            "started": false
        }
    if main != null and main.has_method("update_chunks"):
        main.call("update_chunks", true)
    if main != null and main.has_method("refresh_intro_knock_audio"):
        main.call("refresh_intro_knock_audio")
    await wait_physics_frames(20)

func run_real_knock_to_morning_foragers() -> void:
    var tutorial = main.get("tutorial_system")
    var before_state := tutorial_state_summary(tutorial)
    report_data["initialTutorialState"] = before_state
    sample_player("initial")
    var starter_door := nearest_block("door", player.global_position)
    if starter_door == null:
        add_failure("starter_door_missing", "no door block found near tutorial start")
        return
    sample_door("initial", starter_door)

    var door_position := starter_door.global_position
    mark_progress("walking_to_door")
    await walk_near(door_position, CELL * 1.55, 9.0)
    sample_player("near_door")
    aim_at(door_position + Vector3(0.0, CELL * 0.75, 0.0))
    await wait_physics_frames(POST_ACTION_FRAMES)
    sample_door("before_click", starter_door)
    mark_progress("dispatching_door_action")
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    sample_door("after_click", starter_door)
    sample_player("after_door_action")

    var after_state := tutorial_state_summary(tutorial)
    report_data["afterDoorTutorialState"] = after_state
    var opened := bool(after_state.get("doorOpened", false))
    var dialogue_open := hud_dialogue_open()
    results.append({
        "name": "real_door_input_opened_tutorial_dialogue",
        "passed": opened and dialogue_open,
        "details": "doorOpened=%s dialogueOpen=%s" % [str(opened), str(dialogue_open)]
    })
    if not opened or not dialogue_open:
        add_failure("real_input_path_failed_before_mira_observation", "doorOpened=%s dialogueOpen=%s" % [str(opened), str(dialogue_open)])
        return

    mark_progress("closing_dialogue")
    dispatch_key(KEY_ESCAPE, true)
    dispatch_key(KEY_ESCAPE, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    report_data["afterDialogueTutorialState"] = tutorial_state_summary(tutorial)
    sample_player("after_dialogue_ack")

    mark_progress("observing_mira_return_home")
    await observe_npcs_for_seconds(12.0)
    var mira := npc_entry("mira")
    var speed_limit := profile_speed_limit(mira)
    report_data["miraSpeedLimit"] = rounded(speed_limit)
    report_data["miraMaxFlatSpeed"] = rounded(max_mira_flat_speed)
    report_data["miraTotalFlatDistance"] = rounded(mira_total_flat_distance)
    report_data["miraFinalHomeInteriorStatus"] = strict_home_status(mira)
    if max_mira_flat_speed > speed_limit:
        add_failure(
            "mira_non_profile_speed",
            "max flat speed %.3f exceeded profile limit %.3f" % [max_mira_flat_speed, speed_limit]
        )
    elif mira_total_flat_distance < CELL * 0.4:
        add_failure(
            "mira_stalls_due_to_update_budget",
            "Mira moved only %.3f meters during observation" % mira_total_flat_distance
        )
    else:
        results.append({
            "name": "mira_timeline_speed_within_profile",
            "passed": true,
            "details": "max flat speed %.3f <= %.3f" % [max_mira_flat_speed, speed_limit]
        })

    report_data["nikoForagerState"] = forager_state_summary()
    report_data["repairTargetPlacementProof"] = repair_target_proof(tutorial)
    report_data["sleepTransitionProof"] = {
        "reached": false,
        "reason": "R00 stops at first honest NPC failure before repair and sleep automation"
    }
    report_data["morningNpcDepartureMatrix"] = {
        "reached": false,
        "reason": "R00 stops at first honest NPC failure before morning foraging"
    }

func observe_npcs_for_seconds(seconds: float) -> void:
    var frame_count := ceili(seconds * float(Engine.physics_ticks_per_second))
    for frame in range(frame_count):
        await get_tree().physics_frame
        track_mira_speed()
        if frame % SAMPLE_EVERY_FRAMES == 0:
            sample_player("observe_%03d" % frame)
            sample_mira("observe_%03d" % frame)
            route_order_timeline.append(route_order_sample("observe_%03d" % frame))
            schedule_matrix = npc_schedule_matrix()
            mark_progress("observing_%03d" % frame)

func track_mira_speed() -> void:
    var mira := npc_entry("mira")
    if mira.is_empty():
        previous_mira_valid = false
        return
    var body := mira.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        previous_mira_valid = false
        return
    var current := body.global_position
    if previous_mira_valid:
        var flat_delta := Vector2(current.x - previous_mira_position.x, current.z - previous_mira_position.z).length()
        mira_total_flat_distance += flat_delta
        var speed := flat_delta / maxf(physics_dt, 0.0001)
        max_mira_flat_speed = maxf(max_mira_flat_speed, speed)
        mira_speed_samples.append({
            "time": rounded(elapsed),
            "flatSpeed": rounded(speed),
            "flatDelta": rounded(flat_delta),
            "position": vec3(current),
            "lastMoveDistance": rounded(float(mira.get("lastMoveDistance", 0.0))),
            "routeStatus": String(mira.get("routeStatus", "")),
            "routeReason": String(mira.get("routeReason", ""))
        })
    previous_mira_position = current
    previous_mira_valid = true

func walk_near(target: Vector3, stop_distance: float, timeout_seconds: float) -> void:
    var started_at := elapsed
    while elapsed - started_at < timeout_seconds:
        var offset := Vector3(target.x - player.global_position.x, 0.0, target.z - player.global_position.z)
        if offset.length() <= stop_distance:
            break
        player.set("automated_move", offset.normalized())
        player.set("automated_sprint", false)
        await get_tree().physics_frame
        if int(Engine.get_physics_frames()) % SAMPLE_EVERY_FRAMES == 0:
            sample_player("walking_to_door")
    player.set("automated_move", Vector3.ZERO)

func aim_at(target: Vector3) -> void:
    if player == null or camera == null:
        return
    var flat_target := Vector3(target.x, player.global_position.y, target.z)
    if flat_target.distance_to(player.global_position) > 0.05:
        player.look_at(flat_target, Vector3.UP)
    if target.distance_to(camera.global_position) > 0.05:
        camera.look_at(target, Vector3.UP)
    player.set("pitch", camera.rotation.x)

func dispatch_mouse_button(button_index: int, pressed: bool) -> void:
    var event := InputEventMouseButton.new()
    event.button_index = button_index
    event.pressed = pressed
    var center := get_viewport().get_visible_rect().size * 0.5
    event.position = center
    event.global_position = center
    get_viewport().push_input(event)

func dispatch_key(keycode: Key, pressed: bool) -> void:
    var event := InputEventKey.new()
    event.keycode = keycode
    event.pressed = pressed
    get_viewport().push_input(event)

func wait_physics_frames(count: int) -> void:
    for i in range(count):
        await get_tree().physics_frame

func bind_scene_nodes() -> void:
    if main == null:
        return
    player = main.get("player") as CharacterBody3D
    if player != null:
        camera = player.get("camera") as Camera3D

func nearest_block(block_type: String, origin: Vector3) -> Node3D:
    if main == null:
        return null
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    var best: Node3D = null
    var best_distance := INF
    var blocks: Dictionary = blocks_value
    for block_value in blocks.values():
        var body := block_value as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if String(body.get_meta("block_type", "")) != block_type:
            continue
        var distance := Vector2(body.global_position.x - origin.x, body.global_position.z - origin.z).length()
        if distance < best_distance:
            best_distance = distance
            best = body
    return best

func hud_dialogue_open() -> bool:
    var hud = main.get("hud") if main != null else null
    return hud != null and hud.has_method("is_dialogue_open") and bool(hud.call("is_dialogue_open"))

func tutorial_state_summary(tutorial) -> Dictionary:
    if tutorial == null or not tutorial.has_method("state"):
        return {}
    var state: Dictionary = tutorial.call("state")
    return {
        "started": bool(state.get("started", false)),
        "stage": String(state.get("tutorialStage", "")),
        "doorOpened": bool(state.get("introDoorOpened", false)),
        "elderAcknowledged": bool(state.get("introElderDialogueAcknowledged", false)),
        "repairActive": bool(state.get("introRepairActive", false)),
        "repairComplete": bool(state.get("introRepairComplete", false)),
        "bedUsed": bool(state.get("introBedUsed", false)),
        "fencePlaced": int(state.get("introFencePlaced", 0)),
        "fenceRequired": int(state.get("introFenceRequired", 0)),
        "lampsPlaced": int(state.get("introLampsPlaced", 0)),
        "lampsRequired": int(state.get("introLampsRequired", 0)),
        "townCenter": vec2i(state.get("townCenter", Vector2i.ZERO)),
        "startCell": vec2i(state.get("startCell", Vector2i.ZERO)),
        "chestCell": vec2i(state.get("introRepairChestCell", Vector2i.ZERO))
    }

func repair_target_proof(tutorial) -> Dictionary:
    if tutorial == null or not tutorial.has_method("state"):
        return { "reached": false, "targets": {} }
    var state: Dictionary = tutorial.call("state")
    var targets: Dictionary = state.get("introRepairTargets", {})
    return {
        "reached": false,
        "fenceTargets": vec2i_array(targets.get("fence", [])),
        "lampTargets": vec2i_array(targets.get("lamps", [])),
        "placedFence": int(state.get("introFencePlaced", 0)),
        "placedLamps": int(state.get("introLampsPlaced", 0))
    }

func sample_player(label: String) -> void:
    if player == null:
        return
    player_timeline.append({
        "label": label,
        "time": rounded(elapsed),
        "position": vec3(player.global_position),
        "velocity": vec3(player.velocity),
        "automatedMove": vec3(player.get("automated_move")),
        "mouseMode": Input.get_mouse_mode()
    })

func sample_door(label: String, door: Node3D) -> void:
    if door == null or not is_instance_valid(door):
        return
    door_timeline.append({
        "label": label,
        "time": rounded(elapsed),
        "position": vec3(door.global_position),
        "open": bool(door.get_meta("open", false)),
        "cell": vec3i(door.get_meta("cell", Vector3i.ZERO)),
        "blockType": String(door.get_meta("block_type", ""))
    })

func sample_mira(label: String) -> void:
    var mira := npc_entry("mira")
    if mira.is_empty():
        mira_timeline.append({ "label": label, "time": rounded(elapsed), "missing": true })
        return
    var summary := npc_summary(mira)
    summary["label"] = label
    summary["time"] = rounded(elapsed)
    summary["strictHome"] = strict_home_status(mira)
    mira_timeline.append(summary)

func route_order_sample(label: String) -> Dictionary:
    var row := {
        "label": label,
        "time": rounded(elapsed),
        "mira": {}
    }
    var mira := npc_entry("mira")
    if not mira.is_empty():
        row["mira"] = {
            "homeRouteIndex": int(mira.get("homeRouteIndex", 0)),
            "homeActiveTargetCell": vec2i(mira.get("homeActiveTargetCell", Vector2i.ZERO)),
            "routePriority": int(mira.get("routePriority", 0)),
            "routeStatus": String(mira.get("routeStatus", "")),
            "routeReason": String(mira.get("routeReason", "")),
            "lastMoveDistance": rounded(float(mira.get("lastMoveDistance", 0.0)))
        }
    return row

func npc_entry(npc_id: String) -> Dictionary:
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return {}
    var entries: Array = npc_system.get("npcs")
    for entry_value in entries:
        var entry: Dictionary = entry_value
        if String(entry.get("id", "")) == npc_id:
            return entry
    return {}

func npc_schedule_matrix() -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return rows
    var entries: Array = npc_system.get("npcs")
    for entry_value in entries:
        var entry: Dictionary = entry_value
        rows.append(npc_summary(entry))
    return rows

func npc_summary(entry: Dictionary) -> Dictionary:
    var body := entry.get("body") as Node3D
    var body_valid := body != null and is_instance_valid(body)
    var position := body.global_position if body_valid else Vector3.ZERO
    var body_home_meta := false
    if body_valid:
        body_home_meta = bool(body.get_meta("npc_inside_home", false))
    return {
        "id": String(entry.get("id", "")),
        "name": String(entry.get("name", "")),
        "role": String(entry.get("role", "")),
        "job": String(entry.get("job", "")),
        "jobPhase": String(entry.get("jobPhase", "")),
        "canFight": bool(entry.get("canFight", false)),
        "nightGuard": bool(entry.get("nightGuard", false)),
        "holdDoorOrder": bool(entry.get("holdIntroDoor", false)),
        "position": vec3(position),
        "cell": vec2i(flat_cell(position)),
        "homeCell": vec2i(entry.get("homeCell", Vector2i.ZERO)),
        "porchCell": vec2i(entry.get("porchCell", Vector2i.ZERO)),
        "interiorMinCell": vec2i(entry.get("interiorMinCell", Vector2i.ZERO)),
        "interiorMaxCell": vec2i(entry.get("interiorMaxCell", Vector2i.ZERO)),
        "insideHomeMeta": body_home_meta,
        "strictInsideHome": bool(strict_home_status(entry).get("strictInside", false)),
        "routeStatus": String(entry.get("routeStatus", "")),
        "routeReason": String(entry.get("routeReason", "")),
        "routePriority": int(entry.get("routePriority", 0)),
        "lastMoveDistance": rounded(float(entry.get("lastMoveDistance", 0.0)))
    }

func strict_home_status(entry: Dictionary) -> Dictionary:
    if entry.is_empty():
        return { "strictInside": false, "reason": "entry_missing" }
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return { "strictInside": false, "reason": "body_missing" }
    var cell := flat_cell(body.global_position)
    var min_cell: Vector2i = entry.get("interiorMinCell", Vector2i.ZERO)
    var max_cell: Vector2i = entry.get("interiorMaxCell", Vector2i.ZERO)
    var porch: Vector2i = entry.get("porchCell", Vector2i.ZERO)
    var inside_bounds := (
        cell.x >= mini(min_cell.x, max_cell.x)
        and cell.x <= maxi(min_cell.x, max_cell.x)
        and cell.y >= mini(min_cell.y, max_cell.y)
        and cell.y <= maxi(min_cell.y, max_cell.y)
    )
    var strict_inside := inside_bounds and cell != porch
    return {
        "strictInside": strict_inside,
        "cell": vec2i(cell),
        "porchCell": vec2i(porch),
        "interiorMinCell": vec2i(min_cell),
        "interiorMaxCell": vec2i(max_cell),
        "insideBounds": inside_bounds,
        "reason": "interior_bounds" if strict_inside else "not_inside_interior"
    }

func forager_state_summary() -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return rows
    var entries: Array = npc_system.get("npcs")
    for entry_value in entries:
        var entry: Dictionary = entry_value
        var npc_id := String(entry.get("id", ""))
        if npc_id != "niko" and String(entry.get("job", "")) != "forage":
            continue
        var row := npc_summary(entry)
        row["target"] = vec3(entry.get("jobTarget", Vector3.ZERO))
        row["targetNode"] = target_node_summary(entry.get("jobTargetNode"))
        rows.append(row)
    return rows

func target_node_summary(node_value) -> Dictionary:
    if node_value == null:
        return { "state": "null" }
    if not is_instance_valid(node_value):
        return { "state": "freed" }
    var node := node_value as Node
    if node == null:
        return { "state": "valid_non_node" }
    var row := {
        "state": "valid",
        "name": node.name,
        "path": String(node.get_path())
    }
    var node_3d := node as Node3D
    if node_3d != null:
        row["position"] = vec3(node_3d.global_position)
    if node.has_meta("prop_id"):
        row["propId"] = String(node.get_meta("prop_id"))
    if node.has_meta("drop"):
        row["drop"] = String(node.get_meta("drop"))
    return row

func profile_speed_limit(entry: Dictionary) -> float:
    var limit := 6.4 * 1.15
    if entry.is_empty():
        return limit
    var profile = entry.get("motorProfile")
    if profile != null:
        var sprint_value = profile.get("sprint_speed")
        if sprint_value != null:
            limit = float(sprint_value) * 1.15
    return limit

func flat_cell(position: Vector3) -> Vector2i:
    if main != null and main.has_method("world_to_cell"):
        return Vector2i(int(main.call("world_to_cell", position.x)), int(main.call("world_to_cell", position.z)))
    return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func add_failure(code: String, details: String) -> void:
    failure_reasons.append({ "code": code, "details": details, "time": rounded(elapsed) })
    results.append({ "name": TEST_ID, "passed": false, "details": "%s: %s" % [code, details] })
    failed = true
    save_report()

func finish() -> void:
    if finished:
        return
    player_stop()
    finished = true
    report_data["finished"] = true
    report_data["passed"] = not failed
    report_data["failureCount"] = failure_reasons.size()
    report_data["resultCount"] = results.size()
    report_data["results"] = results
    report_data["failureReasons"] = failure_reasons
    report_data["playerTimeline"] = player_timeline
    report_data["doorStateTimeline"] = door_timeline
    report_data["miraTimeline"] = mira_timeline
    report_data["miraRouteOrderTimeline"] = route_order_timeline
    report_data["miraSpeedSamples"] = mira_speed_samples
    report_data["npcScheduleMatrix"] = schedule_matrix
    report_data["nikoForagerState"] = forager_state_summary()
    save_report()
    mark_progress("finished")
    get_tree().quit(1 if failed else 0)

func player_stop() -> void:
    if player != null:
        player.set("automated_move", Vector3.ZERO)
        player.set("automated_sprint", false)

func save_report() -> void:
    var path := OS.get_environment("VOXEL_REAL_TUTORIAL_REPORT")
    if path == "":
        path = "user://real-tutorial-playthrough-report.json"
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write real tutorial report: %s" % path)
        return
    file.store_string(JSON.stringify(report_data, "  "))
    file.close()

func mark_progress(label: String) -> void:
    var path := OS.get_environment("VOXEL_REAL_TUTORIAL_PROGRESS")
    if path == "":
        return
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\nelapsed=%.3f\nfailures=%d\nmaxMiraSpeed=%.3f\n" % [
        label,
        elapsed,
        failure_reasons.size(),
        max_mira_flat_speed
    ])
    file.close()

func watchdog_seconds() -> float:
    var raw := OS.get_environment("VOXEL_REAL_TUTORIAL_WATCHDOG_SECONDS").strip_edges()
    if raw == "":
        return 70.0
    return maxf(10.0, float(raw))

func vec3(value) -> Array:
    if value is Vector3:
        return [rounded(value.x), rounded(value.y), rounded(value.z)]
    return [0.0, 0.0, 0.0]

func vec2i(value) -> Array:
    if value is Vector2i:
        return [value.x, value.y]
    return [0, 0]

func vec3i(value) -> Array:
    if value is Vector3i:
        return [value.x, value.y, value.z]
    return [0, 0, 0]

func vec2i_array(values) -> Array:
    var result := []
    if not (values is Array):
        return result
    for value in values:
        result.append(vec2i(value))
    return result

func rounded(value: float) -> float:
    return roundf(value * 1000.0) / 1000.0
