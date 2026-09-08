extends SceneTree
const Options = preload("res://scripts/world/GameLaunchOptions.gd")
const MainClock = preload("res://scripts/MainGameLoop.gd")

func _initialize() -> void:
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
	var file := FileAccess.open(OS.get_environment("GAME_LAUNCH_OPTIONS_REPORT"),FileAccess.WRITE)
	if file==null: quit(2); return
	var passed := not checks.values().has(false)
	file.store_string(JSON.stringify({"passed":passed,"checks":checks,"scope":"Launch parsing and clock contract only; no gameplay acceptance"}))
	file.close()
	quit(0 if passed else 1)
