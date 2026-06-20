extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const CELL := 1.35
const WATER_LEVEL := 11.1
const INTERACT_RANGE := 10.5

var main: Node3D
var player: CharacterBody3D
var camera: Camera3D
var results: Array[Dictionary] = []
var failed := false

func _ready() -> void:
    call_deferred("run")

func run() -> void:
    main = MAIN_SCENE.instantiate()
    add_child(main)
    await wait_physics_frames(20)

    player = main.get("player") as CharacterBody3D
    if player:
        player.set("automated_input", true)
        camera = player.get("camera") as Camera3D
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

    await wait_physics_frames(80)
    test_scene_bootstrap()
    test_terrain_collision_shapes()
    test_sky_light_consistency()
    test_spawn_clearance()
    await test_player_movement()
    await test_jump()
    await wait_until_grounded(120)
    await test_block_destroy_ray()
    save_optional_screenshot()
    save_report()
    get_tree().quit(1 if failed else 0)

func wait_physics_frames(count: int) -> void:
    for i in range(count):
        await get_tree().physics_frame

func add_result(name: String, passed: bool, details: String = "") -> void:
    results.append({
        "name": name,
        "passed": passed,
        "details": details
    })
    if not passed:
        failed = true
    var status: String = "PASS" if passed else "FAIL"
    print("[%s] %s %s" % [status, name, details])

func test_scene_bootstrap() -> void:
    var chunks := get_chunks()
    add_result("scene_bootstrap", main != null and player != null and camera != null, "main/player/camera present")
    add_result("initial_chunks_loaded", chunks.size() >= 25, "%d chunks" % chunks.size())
    if player:
        add_result("controller_ticks", int(player.get("physics_ticks")) > 0, "%d ticks" % int(player.get("physics_ticks")))

func test_spawn_clearance() -> void:
    if not player or not camera:
        add_result("spawn_clearance", false, "player or camera missing")
        return
    var terrain_height: float = main.call("height_at_world", player.global_position.x, player.global_position.z)
    var camera_clearance: float = camera.global_position.y - terrain_height
    var above_water: bool = player.global_position.y > WATER_LEVEL + 1.2
    var clear: bool = camera_clearance > 1.25 and above_water
    add_result("spawn_clearance", clear, "camera clearance %.2f, player y %.2f" % [camera_clearance, player.global_position.y])

func test_terrain_collision_shapes() -> void:
    var chunks := get_chunks()
    var checked := 0
    var with_shape := 0
    for chunk_node in chunks.values():
        var chunk := chunk_node as Node
        if not chunk:
            continue
        var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D
        if not body:
            continue
        checked += 1
        var shape_node := body.get_node_or_null("TerrainCollision") as CollisionShape3D
        if shape_node and shape_node.shape:
            with_shape += 1
    add_result("terrain_collision_shapes", checked > 0 and checked == with_shape, "%d/%d chunks with shapes" % [with_shape, checked])

func test_sky_light_consistency() -> void:
    if not main or not player:
        add_result("sky_light_consistency", false, "main or player missing")
        return
    var sun_light := main.get("sun") as DirectionalLight3D
    var sun_disc := main.get("sun_visual") as MeshInstance3D
    if not sun_light or not sun_disc:
        add_result("sky_light_consistency", false, "sun light or disc missing")
        return
    var casts_day_shadows := sun_light.shadow_enabled and sun_light.light_energy > 0.1
    var sun_above_player := sun_disc.visible and sun_disc.global_position.y > player.global_position.y + 40.0
    add_result(
        "sky_light_consistency",
        not casts_day_shadows or sun_above_player,
        "sun shadows %s, disc visible %s, disc y %.2f, player y %.2f" % [
            str(casts_day_shadows),
            str(sun_disc.visible),
            sun_disc.global_position.y,
            player.global_position.y
        ]
    )

func test_player_movement() -> void:
    if not player:
        add_result("player_movement", false, "player missing")
        return
    var start: Vector3 = player.global_position
    player.set("automated_move", Vector3.RIGHT)
    await wait_physics_frames(70)
    player.set("automated_move", Vector3.ZERO)
    await wait_physics_frames(10)
    var travel: float = Vector2(player.global_position.x - start.x, player.global_position.z - start.z).length()
    var velocity: Vector3 = player.velocity
    var move_value: Vector3 = player.get("automated_move")
    var max_downward_correction: float = player.get("max_downward_terrain_correction")
    add_result(
        "player_movement",
        travel > 4.0,
        "travel %.2f, ticks %d, floor %s, velocity %s, automated_move %s" % [
            travel,
            int(player.get("physics_ticks")),
            str(is_player_grounded()),
            str(velocity),
            str(move_value)
        ]
    )
    add_result("terrain_descent_smoothing", max_downward_correction <= 0.22, "max downward correction %.3f" % max_downward_correction)

func test_jump() -> void:
    if not player:
        add_result("jump", false, "player missing")
        return
    for i in range(90):
        if is_player_grounded():
            break
        await get_tree().physics_frame
    var start_y: float = player.global_position.y
    player.set("automated_jump", true)
    var peak_y: float = start_y
    var landing_frame := -1
    var became_airborne := false
    for i in range(90):
        await get_tree().physics_frame
        peak_y = max(peak_y, player.global_position.y)
        if not is_player_grounded():
            became_airborne = true
        elif became_airborne:
            landing_frame = i + 1
            break
    var rise: float = peak_y - start_y
    var natural_air_time := landing_frame >= 36 or landing_frame == -1
    add_result(
        "jump",
        rise > 0.55 and natural_air_time,
        "rise %.2f, landing frame %d, floor %s" % [rise, landing_frame, str(is_player_grounded())]
    )

func test_block_destroy_ray() -> void:
    if not player or not camera:
        add_result("block_destroy_ray", false, "player or camera missing")
        return
    var forward: Vector3 = -camera.global_transform.basis.z
    forward = forward.normalized()
    var target_pos: Vector3 = camera.global_position + forward * 4.0
    var test_cell := Vector3i(roundi(target_pos.x / CELL), roundi(target_pos.y / CELL), roundi(target_pos.z / CELL))
    main.call("create_block", test_cell, "dirtBlock")
    await wait_physics_frames(4)
    var block_center := Vector3(test_cell.x * CELL, test_cell.y * CELL, test_cell.z * CELL)
    aim_player_at(block_center)
    await wait_physics_frames(2)

    var hit: Dictionary = player.call("view_ray", INTERACT_RANGE)
    var hit_block: bool = false
    if not hit.is_empty():
        var collider: Node = hit["collider"]
        hit_block = collider != null and collider.has_meta("kind") and String(collider.get_meta("kind")) == "block"
    if not hit_block:
        add_result("block_destroy_ray", false, "ray did not hit placed block")
        return

    main.call("destroy_target")
    await wait_physics_frames(4)
    var blocks := get_blocks()
    add_result("block_destroy_ray", not blocks.has(test_cell), "placed block removed")

func save_optional_screenshot() -> void:
    var screenshot_path: String = OS.get_environment("VOXEL_PLAYTEST_SCREENSHOT")
    if screenshot_path == "":
        return
    var image: Image = get_viewport().get_texture().get_image()
    var err: Error = image.save_png(screenshot_path)
    add_result("screenshot_saved", err == OK, screenshot_path)

func save_report() -> void:
    var report_path: String = OS.get_environment("VOXEL_PLAYTEST_REPORT")
    if report_path == "":
        report_path = "user://playtest-report.json"
    var report: Dictionary = {
        "passed": not failed,
        "results": results
    }
    var file: FileAccess = FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write playtest report: %s" % report_path)
        return
    file.store_string(JSON.stringify(report, "  "))
    file.close()
    print("Playtest report: %s" % report_path)

func get_chunks() -> Dictionary:
    if not main:
        return {}
    var value: Variant = main.get("chunks")
    if value is Dictionary:
        return value
    return {}

func get_blocks() -> Dictionary:
    if not main:
        return {}
    var value: Variant = main.get("blocks")
    if value is Dictionary:
        return value
    return {}

func is_player_grounded() -> bool:
    if not player:
        return false
    return player.is_on_floor() or bool(player.get("terrain_grounded"))

func wait_until_grounded(max_frames: int) -> void:
    for i in range(max_frames):
        if is_player_grounded():
            return
        await get_tree().physics_frame

func aim_player_at(world_point: Vector3) -> void:
    if not player or not camera:
        return
    var eye: Vector3 = camera.global_position
    var direction: Vector3 = world_point - eye
    var flat_direction := Vector3(direction.x, 0.0, direction.z)
    if flat_direction.length_squared() > 0.0001:
        player.rotation.y = atan2(-flat_direction.x, -flat_direction.z)
    var local_direction: Vector3 = player.global_transform.basis.inverse() * direction.normalized()
    var pitch_value: float = clamp(atan2(local_direction.y, -local_direction.z), deg_to_rad(-82.0), deg_to_rad(82.0))
    player.set("pitch", pitch_value)
    camera.rotation.x = pitch_value
