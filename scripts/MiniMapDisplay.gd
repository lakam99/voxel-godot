extends Control
class_name MiniMapDisplay

var points: Array = []
var terrain_samples: Array = []
var sample_count := 0
var radius := 96.0
var heading := 0.0
var render_key := ""

func set_map_state(state: Dictionary) -> void:
    var next_key := String(state.get("renderKey", ""))
    if next_key == "":
        next_key = fallback_render_key(state)
    if next_key == render_key:
        return
    render_key = next_key
    points = state.get("points", [])
    terrain_samples = state.get("terrainSamples", [])
    sample_count = int(state.get("sampleCount", 0))
    radius = maxf(12.0, float(state.get("radius", 96.0)))
    heading = float(state.get("heading", 0.0))
    queue_redraw()

func fallback_render_key(state: Dictionary) -> String:
    var state_points: Array = state.get("points", []) if state.get("points", []) is Array else []
    var state_samples: Array = state.get("terrainSamples", []) if state.get("terrainSamples", []) is Array else []
    return "%.1f:%d:%d:%d:%d" % [
        float(state.get("radius", 96.0)),
        roundi(rad_to_deg(float(state.get("heading", 0.0)))),
        state_points.size(),
        state_samples.size(),
        int(state.get("sampleCount", 0))
    ]

func _draw() -> void:
    var size_min: float = min(size.x, size.y)
    if size_min <= 2.0:
        return
    var center := size * 0.5
    var draw_radius := size_min * 0.46
    draw_circle(center, draw_radius, Color(0.05, 0.08, 0.09, 0.58))
    draw_terrain_samples(center, draw_radius)
    draw_arc(center, draw_radius, 0.0, TAU, 96, Color(0.78, 0.88, 0.82, 0.85), 2.0)

    var heading_vector := Vector2(sin(heading), -cos(heading))
    draw_line(center, center + heading_vector * draw_radius * 0.72, Color(1.0, 0.92, 0.58, 0.95), 2.0)
    draw_circle(center, 4.0, Color(0.95, 0.95, 0.86, 1.0))

    for point_value in points:
        if not (point_value is Dictionary):
            continue
        var offset: Vector2 = point_value.get("offset", Vector2.ZERO)
        if offset.length() > radius:
            offset = offset.normalized() * radius
        var normalized := offset / radius
        var point_position := center + Vector2(normalized.x, normalized.y) * draw_radius
        if point_position.distance_to(center) > draw_radius:
            continue
        draw_circle(point_position, float(point_value.get("size", 3.0)), color_for_kind(String(point_value.get("kind", ""))))

    draw_string(get_theme_default_font(), center + Vector2(-4.0, -draw_radius - 6.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, Color(0.86, 0.95, 0.94, 0.9))

func draw_terrain_samples(center: Vector2, draw_radius: float) -> void:
    if terrain_samples.is_empty() or sample_count <= 0:
        return
    var tile_size := draw_radius * 2.0 / float(sample_count)
    for sample_value in terrain_samples:
        if not (sample_value is Dictionary):
            continue
        var offset: Vector2 = sample_value.get("offset", Vector2.ZERO)
        if offset.length() > radius:
            continue
        var normalized := offset / radius
        if normalized.length() > 1.0:
            continue
        var point_position := center + Vector2(normalized.x, normalized.y) * draw_radius
        var color: Color = sample_value.get("color", Color(0.34, 0.52, 0.35, 0.72))
        color.a = 0.82
        draw_rect(Rect2(point_position - Vector2(tile_size, tile_size) * 0.5, Vector2(tile_size + 1.0, tile_size + 1.0)), color)

func color_for_kind(kind: String) -> Color:
    if kind == "town":
        return Color(0.94, 0.78, 0.42, 0.95)
    if kind == "trader":
        return Color(0.49, 0.84, 0.71, 0.95)
    if kind == "beacon":
        return Color(0.95, 0.86, 0.45, 0.98)
    if kind == "bed":
        return Color(0.91, 0.64, 0.84, 0.95)
    if kind == "ward":
        return Color(0.56, 0.96, 0.84, 0.95)
    if kind == "anchor":
        return Color(0.82, 0.55, 1.0, 0.96)
    if kind == "landmark":
        return Color(0.74, 0.60, 0.96, 0.95)
    if kind == "structure":
        return Color(0.72, 0.86, 0.96, 0.92)
    if kind == "hostile":
        return Color(0.88, 0.24, 0.32, 0.95)
    if kind == "water":
        return Color(0.34, 0.66, 0.86, 0.82)
    return Color(0.62, 0.92, 0.58, 0.9)
