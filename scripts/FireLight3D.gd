extends OmniLight3D
class_name FireLight3D

var base_energy := 1.0
var base_range := 6.0
var base_light_color := Color(1.0, 0.89, 0.72)
var dim_light_color := Color(0.86, 0.60, 0.38)
var bright_light_color := Color(1.0, 0.94, 0.80)
var flicker_amount := 0.88
var range_amount := 0.28
var flicker_speed := 2.10
var min_energy_scale := 0.10
var max_energy_scale := 1.38
var min_range_scale := 0.72
var max_range_scale := 1.28
var phase := 0.0
var day_factor := 0.0
var day_suppressed := false
var lod_visible := true

const RANDOM_MIN_ENERGY_LOW := 0.01
const RANDOM_MIN_ENERGY_HIGH := 0.99

func _ready() -> void:
    if base_energy <= 0.0:
        base_energy = light_energy
    if base_range <= 0.0:
        base_range = omni_range
    if phase == 0.0:
        phase = randf() * TAU
    set_process(true)

func configure(
    color: Color,
    energy: float,
    light_range: float,
    shadows: bool,
    flicker := 0.88,
    range_flicker := 0.28,
    speed := 2.10,
    min_scale := -1.0,
    max_scale := 1.38,
    attenuation := 0.62,
    light_role := "source",
    local_rig := false
) -> void:
    base_light_color = color
    dim_light_color = color.lerp(Color(0.98, 0.66, 0.42), 0.28)
    bright_light_color = color.lerp(Color(1.0, 0.98, 0.86), 0.45)
    light_color = base_light_color
    base_energy = energy
    base_range = light_range
    var randomized_min_scale := randf_range(RANDOM_MIN_ENERGY_LOW, RANDOM_MIN_ENERGY_HIGH) if min_scale < 0.0 else min_scale
    min_energy_scale = clampf(randomized_min_scale, RANDOM_MIN_ENERGY_LOW, RANDOM_MIN_ENERGY_HIGH)
    max_energy_scale = maxf(max_scale, min_energy_scale + 0.08)
    flicker_amount = maxf(flicker, 1.0 - min_energy_scale)
    range_amount = range_flicker
    flicker_speed = speed
    min_range_scale = maxf(0.45, 1.0 - range_amount)
    max_range_scale = 1.0 + range_amount
    phase = randf() * TAU
    light_energy = energy
    omni_range = light_range
    omni_attenuation = attenuation
    shadow_enabled = shadows
    shadow_blur = 1.25
    shadow_bias = 0.030
    set_meta("visual_role", "light")
    set_meta("fire_light", true)
    set_meta("flicker_amount", flicker_amount)
    set_meta("range_flicker", range_amount)
    set_meta("flicker_min_scale", min_energy_scale)
    set_meta("casts_shadow_when_enabled", shadows)
    set_meta("light_role", light_role)
    set_meta("local_light_rig", local_rig)
    add_to_group("fire_lights")
    set_process(true)

func set_day_suppressed(enabled: bool) -> void:
    day_suppressed = enabled
    set_meta("day_suppressed", enabled)

func set_day_factor(value: float) -> void:
    day_factor = clampf(value, 0.0, 1.0)

func set_lod_visible(enabled: bool) -> void:
    lod_visible = enabled

func set_lod_shadow_enabled(enabled: bool) -> void:
    shadow_enabled = enabled and bool(get_meta("casts_shadow_when_enabled", false))

func daylight_visibility() -> float:
    if not day_suppressed:
        return 1.0
    return 1.0 - smoothstep(0.18, 0.58, day_factor)

func _process(delta: float) -> void:
    phase += delta * flicker_speed
    var wave := (
        sin(phase)
        + sin(phase * 2.17 + 1.3) * 0.34
        + sin(phase * 4.11 + 2.1) * 0.16
    ) / 1.5
    var pulse := clampf(1.0 + wave * flicker_amount, min_energy_scale, max_energy_scale)
    var visibility := daylight_visibility()
    visible = visibility > 0.02 and lod_visible
    light_energy = base_energy * pulse * visibility
    omni_range = base_range * clampf(1.0 + wave * range_amount, min_range_scale, max_range_scale) * visibility
    var color_t := clampf((pulse - min_energy_scale) / maxf(0.001, max_energy_scale - min_energy_scale), 0.0, 1.0)
    light_color = dim_light_color.lerp(bright_light_color, pow(color_t, 0.70))
