extends SceneTree
const Options = preload("res://scripts/world/GameLaunchOptions.gd")
const MainClock = preload("res://scripts/MainGameLoop.gd")
const Weather = preload("res://scripts/WeatherSystem.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var checks := {}
	var defaults := Options.parse([])
	checks.defaults=defaults=={"skipTutorial":false,"forceDaytime":false,"forceClearWeather":false}
	checks.readonly=defaults.is_read_only()
	checks.explicit=Options.parse(["-SkipTutorial","--force-daytime","-ForceClearWeather"])=={"skipTutorial":true,"forceDaytime":true,"forceClearWeather":true}
	checks.unrelated=Options.parse(["--seed=abc","-ForceDaytime=false"])==defaults
	var main = MainClock.new()
	main.launch_options=defaults
	main.time_of_day=0.1
	main.advance_world_clock(0.0)
	checks.ordinary_clock=is_equal_approx(main.time_of_day,0.1)
	main.launch_options=Options.parse(["-ForceDaytime"])
	main.advance_world_clock(1000.0)
	checks.noon=is_equal_approx(main.clock_phase(),0.5)
	main.free()
	var weather = Weather.new()
	root.add_child(weather)
	weather.setup_materials()
	weather.setup_stars()
	weather.setup_precipitation()
	weather.force_weather("clear",0.0,0.0,Vector3.ZERO,0.0)
	checks.clear_night_stars=weather.star_root.visible
	var night_transform: Transform3D=weather.star_root.multimesh.get_instance_transform(0)
	weather.elapsed=100.0
	weather.force_weather("clear",0.0,0.0,Vector3.ZERO,1.0)
	checks.clear_day_hides_stars=not weather.star_root.visible
	checks.clear_day_skips_star_transforms=weather.star_root.multimesh.get_instance_transform(0)==night_transform
	checks.clear_no_precipitation=not weather.rain.visible and not weather.snow.visible and is_zero_approx(weather.intensity)
	weather.force_weather("clear",0.0,0.0,Vector3.ZERO)
	checks.existing_force_call_preserved=weather.star_root.visible
	weather.free()
	var file := FileAccess.open(OS.get_environment("GAME_LAUNCH_OPTIONS_REPORT"),FileAccess.WRITE)
	if file==null: quit(2); return
	var passed := not checks.values().has(false)
	file.store_string(JSON.stringify({"passed":passed,"checks":checks,"scope":"Launch parsing, clock and direct weather-service contract only; no gameplay acceptance"}))
	file.close()
	quit(0 if passed else 1)
