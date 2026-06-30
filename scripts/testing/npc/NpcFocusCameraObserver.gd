extends RefCounted
class_name NpcFocusCameraObserver

const CELL := 1.35
const FOCUS_DISTANCE := CELL * 9.5
const FOCUS_HEIGHT := CELL * 11.5
const FOCUS_TARGET_HEIGHT := CELL * 1.15
const TOP_DOWN_HEIGHT := CELL * 18.0
const DOOR_CLOSEUP_DISTANCE := CELL * 5.6
const DOOR_CLOSEUP_HEIGHT := CELL * 3.8

var camera: Camera3D
var light: OmniLight3D
var last_summary := {}

func setup(camera_node: Camera3D, light_node: OmniLight3D = null) -> void:
    camera = camera_node
    light = light_node

func focus_overview(center: Vector3, radius: float, level: float) -> Dictionary:
    if camera == null or not is_instance_valid(camera):
        return {}
    var height := maxf(CELL * 18.0, radius * 0.58)
    var offset := Vector3(radius * 0.88, height, radius * 0.88)
    var target := center + Vector3(0.0, CELL * 1.2, 0.0)
    _place_camera(center + offset, target, "overview")
    last_summary = {
        "mode": "overview",
        "focusId": "",
        "position": _vec3(camera.global_position),
        "target": _vec3(target),
        "level": _round(level),
        "radius": _round(radius)
    }
    return last_summary

func focus_entry(entry: Dictionary, mode := "front_overhead", context := {}) -> Dictionary:
    if camera == null or not is_instance_valid(camera):
        return {}
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return focus_overview(
            context.get("townCenterPosition", Vector3.ZERO),
            float(context.get("townRadius", CELL * 24.0)),
            float(context.get("townLevel", 0.0))
        )
    var position := body.global_position
    var forward := _observer_forward(entry, body, context)
    var distance := float(context.get("distance", FOCUS_DISTANCE))
    var height := float(context.get("height", FOCUS_HEIGHT))
    var camera_position := position + forward * distance + Vector3(0.0, height, 0.0)
    var target := position + Vector3(0.0, FOCUS_TARGET_HEIGHT, 0.0)
    if mode == "rear_follow":
        camera_position = position - _route_forward(entry, body) * distance + Vector3(0.0, height, 0.0)
    elif mode == "top_down_route":
        camera_position = position + Vector3(0.0, maxf(height, TOP_DOWN_HEIGHT), CELL * 0.08)
        target = _route_target(entry, position)
    elif mode == "route_context":
        var route_target := _route_target(entry, position)
        var midpoint := (position + route_target) * 0.5
        camera_position = midpoint + Vector3(0.0, maxf(height, CELL * 24.0), CELL * 0.12)
        target = midpoint + Vector3(0.0, CELL * 0.4, 0.0)
    elif mode == "side_route":
        var route_forward := _route_forward(entry, body)
        var side := Vector3(-route_forward.z, 0.0, route_forward.x)
        camera_position = position + side * distance + Vector3(0.0, height, 0.0)
        target = _route_target(entry, position)
    elif mode == "door_inspection":
        var porch_position := _entry_vector3(entry, "porchPosition", position)
        var home_position := _entry_vector3(entry, "homePosition", position)
        var outward := porch_position - home_position
        outward.y = 0.0
        if outward.length_squared() <= 0.05:
            outward = _observer_forward(entry, body, context)
        else:
            outward = outward.normalized()
        target = (porch_position + home_position) * 0.5 + Vector3(0.0, FOCUS_TARGET_HEIGHT, 0.0)
        camera_position = porch_position + outward * maxf(distance, CELL * 7.5) + Vector3(0.0, maxf(height, CELL * 5.3), 0.0)
        forward = outward
    elif mode == "door_closeup":
        var porch_position := _entry_vector3(entry, "porchPosition", position)
        var home_position := _entry_vector3(entry, "homePosition", position)
        var outward := porch_position - home_position
        outward.y = 0.0
        if outward.length_squared() <= 0.05:
            outward = _observer_forward(entry, body, context)
        else:
            outward = outward.normalized()
        var route_forward := _route_forward(entry, body)
        var side := Vector3(-route_forward.z, 0.0, route_forward.x)
        target = (position + porch_position + home_position) / 3.0 + Vector3(0.0, CELL * 1.0, 0.0)
        camera_position = porch_position + outward * maxf(DOOR_CLOSEUP_DISTANCE, distance * 0.62) + side * CELL * 1.2 + Vector3(0.0, maxf(DOOR_CLOSEUP_HEIGHT, height * 0.34), 0.0)
        forward = outward
    _place_camera(camera_position, target, mode)
    last_summary = {
        "mode": mode,
        "focusId": String(entry.get("id", "")),
        "name": String(entry.get("name", "")),
        "role": String(entry.get("role", "")),
        "job": String(entry.get("job", "")),
        "routeStatus": String(entry.get("routeStatus", "")),
        "routeReason": String(entry.get("routeReason", "")),
        "activeGoalKind": String(entry.get("activeGoalKind", "")),
        "jobPhase": String(entry.get("jobPhase", "")),
        "insideHome": bool(entry.get("insideHome", false)),
        "position": _vec3(camera.global_position),
        "target": _vec3(target),
        "npcPosition": _vec3(position),
        "routeTarget": _vec3(_route_target(entry, position)),
        "viewDirection": _vec3(forward)
    }
    return last_summary

func summary() -> Dictionary:
    return last_summary.duplicate(true)

func configure_light(mode := "wide") -> void:
    if light == null or not is_instance_valid(light):
        return
    light.visible = true
    if mode == "overview" or mode == "wide":
        light.light_energy = 8.0
        light.omni_range = CELL * 72.0
    elif mode == "night_suspect" or mode == "door_inspection" or mode == "door_closeup":
        light.light_energy = 10.0
        light.omni_range = CELL * 40.0
    else:
        light.light_energy = 7.0
        light.omni_range = CELL * 28.0

func _place_camera(position: Vector3, target: Vector3, mode: String) -> void:
    camera.global_position = position
    camera.look_at(target, Vector3.UP)
    camera.make_current()
    configure_light("wide" if mode == "overview" else mode)

func _route_forward(entry: Dictionary, body: Node3D) -> Vector3:
    var path: Array = entry.get("pathWaypoints", []) if entry.get("pathWaypoints", []) is Array else []
    var from := body.global_position
    for waypoint_value in path:
        if not (waypoint_value is Vector3):
            continue
        var waypoint: Vector3 = waypoint_value
        var delta := waypoint - from
        delta.y = 0.0
        if delta.length_squared() > 0.05:
            return delta.normalized()
    var velocity := Vector3.ZERO
    if body is CharacterBody3D:
        velocity = (body as CharacterBody3D).velocity
    velocity.y = 0.0
    if velocity.length_squared() > 0.05:
        return velocity.normalized()
    var forward := -body.global_transform.basis.z
    forward.y = 0.0
    if forward.length_squared() <= 0.05:
        return Vector3.FORWARD
    return forward.normalized()

func _observer_forward(entry: Dictionary, body: Node3D, context: Dictionary) -> Vector3:
    var center_value = context.get("townCenterPosition", null)
    if center_value is Vector3:
        var outward: Vector3 = body.global_position - center_value
        outward.y = 0.0
        if outward.length_squared() > 0.05:
            return outward.normalized()
    return _route_forward(entry, body)

func _route_target(entry: Dictionary, fallback: Vector3) -> Vector3:
    var path: Array = entry.get("pathWaypoints", []) if entry.get("pathWaypoints", []) is Array else []
    if not path.is_empty() and path[0] is Vector3:
        return path[0]
    var goal = entry.get("jobTarget", null)
    if goal is Vector3:
        return goal
    goal = entry.get("homePosition", null)
    if goal is Vector3:
        return goal
    return fallback

func _entry_vector3(entry: Dictionary, key: String, fallback: Vector3) -> Vector3:
    var value = entry.get(key, fallback)
    if value is Vector3:
        return value
    return fallback

func _vec3(value: Vector3) -> Dictionary:
    return {
        "x": _round(value.x),
        "y": _round(value.y),
        "z": _round(value.z)
    }

func _round(value: float) -> float:
    return snappedf(value, 0.001)
