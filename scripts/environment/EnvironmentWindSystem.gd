extends Node
class_name EnvironmentWindSystem

const BiomeEnvironmentCatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")

const GLOBAL_DIRECTION := "environment_wind_direction"
const GLOBAL_STRENGTH := "environment_wind_strength"
const GLOBAL_GUST_STRENGTH := "environment_wind_gust_strength"
const GLOBAL_GUST_FREQUENCY := "environment_wind_gust_frequency"
const GLOBAL_TIME := "environment_wind_time"

var environment_catalog: BiomeEnvironmentCatalog
var seed_hash := 1
var elapsed := 0.0
var base_angle := 0.0
var direction_angle := 0.0
var direction := Vector3(0.8, 0.0, 0.6).normalized()
var strength := 0.22
var gust_strength := 0.08
var gust_frequency := 0.28
var target_strength := 0.22
var target_gust_strength := 0.08
var target_gust_frequency := 0.28
var observer_biome := "default"
var weather_kind := "clear"
var biome_response := 1.0
var update_count := 0
var global_write_count := 0
var last_update_usec := 0

func setup(seed_value: int, catalog: BiomeEnvironmentCatalog = null) -> void:
    environment_catalog = catalog
    if environment_catalog == null:
        environment_catalog = BiomeEnvironmentCatalogScript.new()
        environment_catalog.setup()
    reset_for_seed(seed_value)

func reset_for_seed(seed_value: int) -> void:
    seed_hash = seed_value
    elapsed = 0.0
    base_angle = hash01("prevailing-direction") * TAU
    direction_angle = base_angle
    direction = Vector3(cos(direction_angle), 0.0, sin(direction_angle)).normalized()
    strength = 0.22
    gust_strength = 0.08
    gust_frequency = 0.28
    target_strength = strength
    target_gust_strength = gust_strength
    target_gust_frequency = gust_frequency
    observer_biome = "default"
    weather_kind = "clear"
    biome_response = 1.0
    update_count = 0
    global_write_count = 0
    last_update_usec = 0
    publish_globals()

func update_wind(delta: float, weather: Dictionary, biome: String) -> Dictionary:
    var started := Time.get_ticks_usec()
    var step := clampf(delta, 0.0, 0.25)
    elapsed = fposmod(elapsed + step, 3600.0)
    observer_biome = biome if biome != "" else "default"
    weather_kind = String(weather.get("kind", "clear"))
    var precipitation := clampf(float(weather.get("intensity", 0.0)), 0.0, 1.0)
    var clouds := clampf(float(weather.get("cloudCover", 0.28)), 0.0, 1.0)
    var profile := environment_catalog.profile_values_for_biome(observer_biome) if environment_catalog != null else {}
    biome_response = clampf(float(profile.get("wind_response", 1.0)), 0.0, 2.0)

    var weather_boost := precipitation * (0.48 if weather_kind == "rain" else 0.38)
    if weather_kind == "snow":
        weather_boost *= 0.72
    target_strength = clampf((0.16 + clouds * 0.14 + weather_boost) * biome_response, 0.0, 1.0)
    target_gust_strength = clampf((0.06 + clouds * 0.08 + precipitation * 0.48) * biome_response, 0.0, 0.90)
    target_gust_frequency = lerpf(0.22, 0.78, clampf(clouds * 0.35 + precipitation * 0.75, 0.0, 1.0))

    var seed_phase := hash01("direction-phase") * TAU
    var target_angle := base_angle + sin(elapsed * 0.031 + seed_phase) * (0.14 + precipitation * 0.12)
    direction_angle = lerp_angle(direction_angle, target_angle, smoothing_alpha(step, 0.55))
    direction = Vector3(cos(direction_angle), 0.0, sin(direction_angle)).normalized()
    strength = lerpf(strength, target_strength, smoothing_alpha(step, 1.35))
    gust_strength = lerpf(gust_strength, target_gust_strength, smoothing_alpha(step, 1.05))
    gust_frequency = lerpf(gust_frequency, target_gust_frequency, smoothing_alpha(step, 0.85))
    update_count += 1
    publish_globals()
    last_update_usec = Time.get_ticks_usec() - started
    return snapshot()

func publish_globals() -> void:
    RenderingServer.global_shader_parameter_set(GLOBAL_DIRECTION, direction)
    RenderingServer.global_shader_parameter_set(GLOBAL_STRENGTH, strength)
    RenderingServer.global_shader_parameter_set(GLOBAL_GUST_STRENGTH, gust_strength)
    RenderingServer.global_shader_parameter_set(GLOBAL_GUST_FREQUENCY, gust_frequency)
    RenderingServer.global_shader_parameter_set(GLOBAL_TIME, elapsed)
    global_write_count += 5

func snapshot() -> Dictionary:
    return {
        "seedHash": seed_hash,
        "elapsed": elapsed,
        "direction": direction,
        "strength": strength,
        "gustStrength": gust_strength,
        "gustFrequency": gust_frequency,
        "targetStrength": target_strength,
        "targetGustStrength": target_gust_strength,
        "targetGustFrequency": target_gust_frequency,
        "observerBiome": observer_biome,
        "weatherKind": weather_kind,
        "biomeResponse": biome_response,
        "updateCount": update_count,
        "globalWriteCount": global_write_count,
        "lastUpdateUsec": last_update_usec
    }

func smoothing_alpha(delta: float, response: float) -> float:
    return 1.0 - exp(-maxf(0.0, delta) * response)

func hash01(text: String) -> float:
    var h := 2166136261
    var input := "%s:%s" % [str(seed_hash), text]
    for index in range(input.length()):
        h = int((h ^ input.unicode_at(index)) * 16777619) & 0xffffffff
    return float(h % 100000) / 100000.0
