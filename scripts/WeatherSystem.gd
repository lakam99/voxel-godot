extends Node3D
class_name WeatherSystem

const CLOUD_COUNT := 18
const STAR_COUNT := 160
const PRECIP_COUNT := 128
const WATER_LEVEL := 11.1

var main
var seed_hash := 1
var elapsed := 0.0
var kind := "clear"
var cloud_cover := 0.28
var intensity := 0.0
var target_cloud_cover := 0.28
var target_intensity := 0.0
var water_influence := 0.0
var cloud_root: Node3D
var star_root: Node3D
var rain: MultiMeshInstance3D
var snow: MultiMeshInstance3D
var rain_positions: Array[Vector3] = []
var snow_positions: Array[Vector3] = []
var cloud_material: StandardMaterial3D
var star_material: StandardMaterial3D
var rain_material: StandardMaterial3D
var snow_material: StandardMaterial3D
var particle_quality := 1.0

func setup(main_node, seed_value: int) -> void:
    main = main_node
    reset_for_seed(seed_value)
    set_process(false)

func reset_for_seed(seed_value: int) -> void:
    seed_hash = seed_value
    elapsed = 0.0
    kind = "clear"
    cloud_cover = 0.28
    intensity = 0.0
    target_cloud_cover = 0.28
    target_intensity = 0.0
    water_influence = 0.0
    clear_generated_nodes()
    setup_materials()
    setup_clouds()
    setup_stars()
    setup_precipitation()

func clear_generated_nodes() -> void:
    for node in [cloud_root, star_root, rain, snow]:
        if node == null:
            continue
        if node.get_parent() == self:
            remove_child(node)
        node.queue_free()
    cloud_root = null
    star_root = null
    rain = null
    snow = null
    rain_positions.clear()
    snow_positions.clear()

func setup_materials() -> void:
    cloud_material = make_unshaded(Color(1.0, 0.94, 0.82, 0.34))
    star_material = make_unshaded(Color(0.92, 0.95, 1.0, 0.92))
    rain_material = make_unshaded(Color(0.54, 0.72, 0.84, 0.45))
    snow_material = make_unshaded(Color(0.94, 0.98, 1.0, 0.78))

func make_unshaded(color: Color) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
    return material

func setup_clouds() -> void:
    cloud_root = Node3D.new()
    cloud_root.name = "CloudLayer"
    add_child(cloud_root)
    for i in range(CLOUD_COUNT):
        var mesh := SphereMesh.new()
        mesh.radius = 5.5 + hash01("cloud-radius:%d" % i) * 7.0
        mesh.height = mesh.radius * 0.38
        mesh.radial_segments = 12
        mesh.rings = 6
        var cloud := MeshInstance3D.new()
        cloud.name = "Cloud_%02d" % i
        cloud.mesh = mesh
        cloud.material_override = cloud_material
        cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        var angle := hash01("cloud-angle:%d" % i) * TAU
        var distance := 70.0 + hash01("cloud-distance:%d" % i) * 190.0
        cloud.position = Vector3(cos(angle) * distance, 74.0 + hash01("cloud-height:%d" % i) * 34.0, sin(angle) * distance)
        cloud.scale = Vector3(1.8 + hash01("cloud-x:%d" % i) * 1.6, 0.28, 0.8 + hash01("cloud-z:%d" % i) * 1.3)
        cloud.set_meta("drift", Vector3(-0.7 + hash01("cloud-dx:%d" % i) * 1.4, 0.0, -0.45 + hash01("cloud-dz:%d" % i) * 0.9))
        cloud_root.add_child(cloud)

func setup_stars() -> void:
    star_root = Node3D.new()
    star_root.name = "StarField"
    add_child(star_root)
    var mesh := SphereMesh.new()
    mesh.radius = 0.34
    mesh.height = 0.34
    mesh.radial_segments = 5
    mesh.rings = 3
    for i in range(STAR_COUNT):
        var star := MeshInstance3D.new()
        star.name = "Star_%03d" % i
        star.mesh = mesh
        star.material_override = star_material
        star.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        var angle := hash01("star-angle:%d" % i) * TAU
        var elevation := 0.22 + hash01("star-elevation:%d" % i) * 0.66
        var radius := 260.0 + hash01("star-radius:%d" % i) * 230.0
        star.position = Vector3(cos(angle) * radius, elevation * 260.0, sin(angle) * radius)
        star.set_meta("base", 0.45 + hash01("star-base:%d" % i) * 0.85)
        star.set_meta("phase", hash01("star-phase:%d" % i) * TAU)
        star.set_meta("speed", 1.2 + hash01("star-speed:%d" % i) * 2.5)
        star_root.add_child(star)
    star_root.visible = false

func setup_precipitation() -> void:
    rain = MultiMeshInstance3D.new()
    rain.name = "Rain"
    var rain_mesh := BoxMesh.new()
    rain_mesh.size = Vector3(0.025, 0.62, 0.025)
    rain.multimesh = MultiMesh.new()
    rain.multimesh.transform_format = MultiMesh.TRANSFORM_3D
    rain.multimesh.mesh = rain_mesh
    rain.multimesh.instance_count = PRECIP_COUNT
    rain.material_override = rain_material
    rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    add_child(rain)

    snow = MultiMeshInstance3D.new()
    snow.name = "Snow"
    var snow_mesh := SphereMesh.new()
    snow_mesh.radius = 0.045
    snow_mesh.height = 0.045
    snow_mesh.radial_segments = 5
    snow_mesh.rings = 3
    snow.multimesh = MultiMesh.new()
    snow.multimesh.transform_format = MultiMesh.TRANSFORM_3D
    snow.multimesh.mesh = snow_mesh
    snow.multimesh.instance_count = PRECIP_COUNT
    snow.material_override = snow_material
    snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    add_child(snow)

    for i in range(PRECIP_COUNT):
        rain_positions.append(Vector3.ZERO)
        snow_positions.append(Vector3.ZERO)
    reset_precipitation(Vector3.ZERO, true)

func update_weather(delta: float, observer: Vector3, biome: String, day_factor: float, time_of_day: float) -> Dictionary:
    elapsed += delta
    var cell := Vector2i(0, 0)
    if main and main.has_method("world_to_cell"):
        cell = Vector2i(main.world_to_cell(observer.x), main.world_to_cell(observer.z))
    water_influence = water_influence_at_cell(cell)
    var profile := profile_for_biome(biome)
    var roll := weather_roll(cell)
    var humidity: float = clampf(float(profile.get("precip", 0.35)) * 0.48 + water_influence * 0.36 + roll * 0.28, 0.0, 1.0)
    target_intensity = clampf((humidity - 0.68) * 2.6, 0.0, 1.0)
    target_cloud_cover = clampf(float(profile.get("clouds", 0.35)) * 0.45 + humidity * 0.42 + roll * 0.26 + target_intensity * 0.25, 0.14, 0.95)
    cloud_cover = lerpf(cloud_cover, target_cloud_cover, clampf(delta * 0.30, 0.0, 1.0))
    intensity = lerpf(intensity, target_intensity, clampf(delta * 0.42, 0.0, 1.0))
    if intensity > 0.12:
        kind = "snow" if is_cold(biome, observer) else "rain"
    elif cloud_cover > 0.56:
        kind = "cloudy"
    else:
        kind = "clear"
    update_clouds(delta, observer, day_factor)
    update_stars(observer, day_factor)
    update_precipitation(delta, observer)
    return snapshot()

func update_clouds(delta: float, observer: Vector3, day_factor: float) -> void:
    cloud_root.global_position = Vector3(observer.x, observer.y * 0.08, observer.z)
    var alpha := lerpf(0.16, 0.54, cloud_cover) * lerpf(0.34, 1.0, day_factor)
    cloud_material.albedo_color = Color(1.0, 0.94, 0.80, alpha).lerp(Color(0.58, 0.62, 0.62, alpha + intensity * 0.16), cloud_cover * 0.65 + intensity * 0.25)
    for child in cloud_root.get_children():
        var cloud := child as MeshInstance3D
        if cloud == null:
            continue
        var drift: Vector3 = cloud.get_meta("drift", Vector3.ZERO)
        cloud.position += drift * delta
        var limit := 260.0
        if cloud.position.x > limit:
            cloud.position.x = -limit
        if cloud.position.x < -limit:
            cloud.position.x = limit
        if cloud.position.z > limit:
            cloud.position.z = -limit
        if cloud.position.z < -limit:
            cloud.position.z = limit

func update_stars(observer: Vector3, day_factor: float) -> void:
    var night_factor := 1.0 - day_factor
    var visibility := smoothstep(0.16, 0.74, night_factor) * clampf(1.0 - cloud_cover * 0.86 - intensity * 0.44, 0.0, 1.0)
    star_root.visible = visibility > 0.03
    star_root.global_position = observer
    if not star_root.visible:
        return
    star_material.albedo_color.a = visibility
    for child in star_root.get_children():
        var star := child as MeshInstance3D
        if star == null:
            continue
        var base := float(star.get_meta("base", 1.0))
        var phase := float(star.get_meta("phase", 0.0))
        var speed := float(star.get_meta("speed", 1.0))
        var twinkle := clampf(base * (0.72 + sin(elapsed * speed + phase) * 0.28), 0.22, 1.35)
        star.scale = Vector3.ONE * twinkle

func update_precipitation(delta: float, observer: Vector3) -> void:
    var rain_amount := intensity if kind == "rain" else 0.0
    var snow_amount := intensity if kind == "snow" else 0.0
    rain.visible = rain_amount > 0.035 and particle_quality > 0.01
    snow.visible = snow_amount > 0.035 and particle_quality > 0.01
    update_rain(delta, observer, rain_amount)
    update_snow(delta, observer, snow_amount)

func update_rain(delta: float, observer: Vector3, amount: float) -> void:
    var active := int(PRECIP_COUNT * clampf(amount, 0.0, 1.0) * particle_quality)
    rain_material.albedo_color.a = lerpf(0.20, 0.56, amount)
    for i in range(PRECIP_COUNT):
        var pos := rain_positions[i]
        if i < active:
            pos.y -= delta * (26.0 + hash01("rain-speed:%d" % i) * 18.0)
            pos.x += delta * -5.0
            if pos.y < observer.y - 8.0:
                pos = random_precip_position(observer, i, false)
            rain_positions[i] = pos
            rain.multimesh.set_instance_transform(i, Transform3D(Basis(), pos))
        else:
            rain.multimesh.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))

func update_snow(delta: float, observer: Vector3, amount: float) -> void:
    var active := int(PRECIP_COUNT * clampf(amount, 0.0, 1.0) * particle_quality)
    snow_material.albedo_color.a = lerpf(0.30, 0.86, amount)
    for i in range(PRECIP_COUNT):
        var pos := snow_positions[i]
        if i < active:
            pos.y -= delta * (4.8 + hash01("snow-speed:%d" % i) * 4.2)
            pos.x += sin(elapsed * 1.7 + i) * delta * 1.4
            pos.z += cos(elapsed * 1.3 + i * 0.3) * delta * 1.1
            if pos.y < observer.y - 5.0:
                pos = random_precip_position(observer, i, true)
            snow_positions[i] = pos
            snow.multimesh.set_instance_transform(i, Transform3D(Basis(), pos))
        else:
            snow.multimesh.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))

func reset_precipitation(observer: Vector3, initial := false) -> void:
    for i in range(PRECIP_COUNT):
        rain_positions[i] = random_precip_position(observer, i, false, initial)
        snow_positions[i] = random_precip_position(observer, i, true, initial)
        rain.multimesh.set_instance_transform(i, Transform3D(Basis(), rain_positions[i]))
        snow.multimesh.set_instance_transform(i, Transform3D(Basis(), snow_positions[i]))
    rain.visible = false
    snow.visible = false

func random_precip_position(observer: Vector3, index: int, snowing: bool, initial := false) -> Vector3:
    var radius := 58.0 if snowing else 68.0
    var spread_seed := elapsed * 0.07 + float(index) * 11.31
    var x := observer.x + (hash01("precip-x:%d:%0.2f" % [index, spread_seed]) - 0.5) * radius * 2.0
    var z := observer.z + (hash01("precip-z:%d:%0.2f" % [index, spread_seed]) - 0.5) * radius * 2.0
    var y_base := observer.y - 4.0 if initial else observer.y + 24.0
    var y := y_base + hash01("precip-y:%d:%0.2f" % [index, spread_seed]) * (76.0 if initial else 42.0)
    return Vector3(x, y, z)

func water_influence_at_cell(cell: Vector2i) -> float:
    if main == null or not main.has_method("terrain_height_cell"):
        return 0.0
    var offsets := [
        Vector2i(0, 0), Vector2i(6, 0), Vector2i(-6, 0), Vector2i(0, 6), Vector2i(0, -6),
        Vector2i(10, 10), Vector2i(-10, 10), Vector2i(10, -10), Vector2i(-10, -10),
        Vector2i(16, 0), Vector2i(-16, 0), Vector2i(0, 16), Vector2i(0, -16)
    ]
    var wet := 0
    for offset in offsets:
        if float(main.terrain_height_cell(cell.x + offset.x, cell.y + offset.y)) <= WATER_LEVEL + 0.45:
            wet += 1
    return float(wet) / float(offsets.size())

func profile_for_biome(biome: String) -> Dictionary:
    match biome:
        "ocean":
            return { "precip": 0.72, "clouds": 0.62 }
        "beach":
            return { "precip": 0.56, "clouds": 0.46 }
        "forest", "taiga", "swamp":
            return { "precip": 0.68, "clouds": 0.62 }
        "snow", "tundra", "alpine":
            return { "precip": 0.58, "clouds": 0.58 }
        "desert", "savanna":
            return { "precip": 0.16, "clouds": 0.28 }
        "town":
            return { "precip": 0.48, "clouds": 0.44 }
        _:
            return { "precip": 0.36, "clouds": 0.36 }

func is_cold(biome: String, observer: Vector3) -> bool:
    if biome in ["snow", "tundra", "alpine", "taiga"]:
        return true
    if main and main.has_method("height_at_world"):
        return float(main.height_at_world(observer.x, observer.z)) > 54.0
    return false

func weather_roll(cell: Vector2i) -> float:
    var phase := float(seed_hash % 997) * 0.017 + float(cell.x) * 0.073 - float(cell.y) * 0.061
    return sin(elapsed * 0.055 + phase) * 0.5 + 0.5

func force_weather(next_kind: String, next_intensity: float, next_cloud_cover: float, observer: Vector3) -> void:
    kind = next_kind
    intensity = clampf(next_intensity, 0.0, 1.0)
    cloud_cover = clampf(next_cloud_cover, 0.0, 1.0)
    target_intensity = intensity
    target_cloud_cover = cloud_cover
    update_clouds(0.0, observer, 1.0)
    update_stars(observer, 0.0)
    update_precipitation(0.016, observer)

func set_particle_quality(value: float) -> void:
    particle_quality = clampf(value, 0.0, 1.0)
    if particle_quality <= 0.01:
        if rain:
            rain.visible = false
        if snow:
            snow.visible = false

func snapshot() -> Dictionary:
    return {
        "kind": kind,
        "cloudCover": cloud_cover,
        "intensity": intensity,
        "waterInfluence": water_influence,
        "rainVisible": rain.visible if rain else false,
        "snowVisible": snow.visible if snow else false,
        "starsVisible": star_root.visible if star_root else false,
        "clouds": CLOUD_COUNT,
        "stars": STAR_COUNT,
        "particleQuality": particle_quality
    }

func hash01(text: String) -> float:
    var h := 2166136261
    var input := "%s:%s" % [str(seed_hash), text]
    for i in range(input.length()):
        h = int((h ^ input.unicode_at(i)) * 16777619) & 0xffffffff
    return float(h % 100000) / 100000.0
