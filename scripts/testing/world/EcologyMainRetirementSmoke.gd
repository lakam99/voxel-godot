extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://scenes/Main.tscn")
	var fixture_scene := load("res://scenes/testing/world/EcologyMainRetirementPlaytest.tscn")
	var fixture_script := load("res://scripts/testing/world/EcologyMainRetirementPlaytest.gd")
	var native_fixture_script := load("res://scripts/testing/world/EcologyNativeRetirementFixture.gd")
	var loaded: bool = main_scene is PackedScene and fixture_scene is PackedScene \
		and fixture_script is Script and fixture_script.can_instantiate() \
		and native_fixture_script is Script and native_fixture_script.can_instantiate()
	if loaded:
		print("ECOLOGY_MAIN_RETIREMENT_SMOKE_OK")
		quit(0)
	else:
		push_error("Ecology Main retirement scene/script failed to load or compile")
		quit(1)
