extends Resource
class_name VisualStyle

@export_group("Sky")
@export var day_sky_top := Color(0.42, 0.66, 0.82)
@export var day_sky_horizon := Color(0.76, 0.88, 0.86)
@export var night_sky_top := Color(0.018, 0.022, 0.055)
@export var night_sky_horizon := Color(0.075, 0.095, 0.145)
@export var sunset_sky_top := Color(0.72, 0.42, 0.28)
@export var sunset_sky_horizon := Color(0.98, 0.64, 0.34)
@export var day_ground_horizon := Color(0.54, 0.64, 0.58)
@export var night_ground_horizon := Color(0.045, 0.055, 0.080)
@export var ground_bottom := Color(0.025, 0.030, 0.040)
@export_range(0.0, 1.0, 0.01) var sunset_width := 0.20
@export_range(0.0, 4.0, 0.01) var sky_energy_multiplier := 1.05
@export_range(0.0, 4.0, 0.01) var ground_energy_multiplier := 0.58
@export_range(0.0, 30.0, 0.1) var procedural_sun_angle := 4.5
@export_range(1.0, 80.0, 0.1) var sun_disc_radius := 22.0
@export_range(1.0, 80.0, 0.1) var moon_disc_radius := 15.5

@export_group("Light")
@export var sun_color_day := Color(1.0, 0.86, 0.58)
@export var sun_color_warm := Color(1.0, 0.64, 0.34)
@export var moon_color := Color(0.55, 0.64, 0.92)
@export var ambient_day := Color(0.67, 0.73, 0.68)
@export var ambient_night := Color(0.20, 0.23, 0.32)
@export var ambient_weather := Color(0.42, 0.48, 0.52)
@export_range(0.0, 3.0, 0.01) var sun_min_energy := 0.035
@export_range(0.0, 3.0, 0.01) var sun_max_energy := 1.48
@export_range(0.0, 3.0, 0.01) var moon_min_energy := 0.045
@export_range(0.0, 3.0, 0.01) var moon_max_energy := 0.24
@export_range(0.0, 2.0, 0.01) var ambient_min_energy := 0.18
@export_range(0.0, 2.0, 0.01) var ambient_max_energy := 0.52
@export_range(0.0, 1.0, 0.01) var ambient_sky_contribution := 0.78
@export_range(0.0, 2.0, 0.01) var sunset_sun_boost := 0.08

@export_group("Weather")
@export var weather_sky_top := Color(0.35, 0.43, 0.48)
@export var weather_sky_horizon := Color(0.52, 0.60, 0.60)
@export var weather_night_sky := Color(0.030, 0.040, 0.075)
@export var weather_fog_day := Color(0.55, 0.62, 0.62)
@export var weather_fog_night := Color(0.060, 0.072, 0.100)
@export_range(0.0, 1.0, 0.01) var cloud_sun_shade := 0.24
@export_range(0.0, 1.0, 0.01) var rain_sun_shade := 0.24
@export_range(0.0, 1.0, 0.01) var cloud_moon_shade := 0.20
@export_range(0.0, 1.0, 0.01) var rain_moon_shade := 0.18
@export_range(0.0, 1.0, 0.01) var max_weather_tint := 0.46
@export_range(0.0, 1.0, 0.01) var weather_ambient_tint := 0.42
@export_range(0.0, 1.0, 0.01) var weather_ambient_floor := 0.74

@export_group("Fog")
@export var fog_day := Color(0.64, 0.76, 0.76)
@export var fog_night := Color(0.075, 0.092, 0.130)
@export var fog_sunset := Color(0.94, 0.58, 0.34)
@export_range(0.0, 0.1, 0.0005) var fog_density_day := 0.0065
@export_range(0.0, 0.1, 0.0005) var fog_density_night := 0.0105
@export_range(0.0, 0.1, 0.0005) var fog_density_weather := 0.0140
@export_range(0.0, 1.0, 0.01) var fog_sky_affect := 0.42
@export_range(0.0, 2.0, 0.01) var fog_light_energy := 0.60
@export_range(0.0, 1.0, 0.01) var fog_sun_scatter := 0.24

@export_group("Tonemap and Occlusion")
@export_range(0.1, 4.0, 0.01) var tonemap_exposure := 0.88
@export_range(0.1, 12.0, 0.01) var tonemap_white := 1.95
@export var ssao_enabled := true
@export_range(0.05, 8.0, 0.01) var ssao_radius := 2.1
@export_range(0.0, 8.0, 0.01) var ssao_intensity := 1.0
@export_range(0.1, 8.0, 0.01) var ssao_power := 1.22

@export_group("Shadows")
@export_range(10.0, 1000.0, 1.0) var shadow_max_distance := 180.0
@export_range(0.0, 1.0, 0.01) var shadow_fade_start := 0.72
@export_range(0.0, 8.0, 0.01) var shadow_blur := 1.15
@export_range(0.0, 5.0, 0.01) var sun_angular_distance := 1.1
@export_range(0.0, 5.0, 0.01) var moon_angular_distance := 0.55

func sunset_amount(sun_progress: float, day_factor: float) -> float:
    var edge := clampf(sunset_width, 0.01, 0.49)
    var dawn := 1.0 - smoothstep(0.0, edge, sun_progress)
    var dusk := smoothstep(1.0 - edge, 1.0, sun_progress)
    return clampf(maxf(dawn, dusk) * day_factor, 0.0, 1.0)

func sky_top_color(day_factor: float, warmth: float, weather_tint: float) -> Color:
    var color := night_sky_top.lerp(day_sky_top, day_factor)
    color = color.lerp(sunset_sky_top, warmth)
    return color.lerp(weather_night_sky.lerp(weather_sky_top, day_factor), weather_tint)

func sky_horizon_color(day_factor: float, warmth: float, weather_tint: float) -> Color:
    var color := night_sky_horizon.lerp(day_sky_horizon, day_factor)
    color = color.lerp(sunset_sky_horizon, warmth)
    return color.lerp(weather_night_sky.lerp(weather_sky_horizon, day_factor), weather_tint)

func ground_horizon_color(day_factor: float, weather_tint: float) -> Color:
    var color := night_ground_horizon.lerp(day_ground_horizon, day_factor)
    return color.lerp(weather_night_sky.lerp(weather_sky_horizon, day_factor), weather_tint * 0.65)

func ambient_color(day_factor: float, weather_tint: float) -> Color:
    var color := ambient_night.lerp(ambient_day, day_factor)
    return color.lerp(ambient_weather, weather_tint * weather_ambient_tint)

func fog_color(day_factor: float, warmth: float, weather_tint: float) -> Color:
    var color := fog_night.lerp(fog_day, day_factor)
    color = color.lerp(fog_sunset, warmth * 0.72)
    return color.lerp(weather_fog_night.lerp(weather_fog_day, day_factor), weather_tint)

func sun_light_color(warmth: float) -> Color:
    return sun_color_day.lerp(sun_color_warm, warmth)

func weather_tint_amount(cloud_cover: float, intensity: float) -> float:
    return clampf(cloud_cover * 0.24 + intensity * 0.34, 0.0, max_weather_tint)
