extends SceneTree
## Pinned component replay. No complete candidate or live-game acceptance.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Shop = preload("res://scripts/buildings/CitadelShopRecipe.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate20-shop-capture-01/input.bin"
const INPUT_SHA := "314b05afeb053e6f57737c83aaff43231c200fa6d37699b874c07b1407280e66"

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("CITADEL_SHOP_ELIGIBILITY_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	var worker := Thread.new()
	if worker.start(_work) != OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "  ", true, true)); file.flush()
	var saved := file.get_error() == OK
	file.close(); quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var checks := {"pinned": FileAccess.get_sha256(INPUT) == INPUT_SHA}
	var report := {"passed": false, "checks": checks, "scope": "Pinned pre-shop source and real Shop.prepare with regenerated furnishings. Component evidence only."}
	if not checks.pinned: return report
	var file := FileAccess.open(INPUT, FileAccess.READ)
	var input: Dictionary = file.get_var(false); file.close()
	var source = Copy.copy_blueprint(input.blueprint)
	var before := var_to_bytes(source.snapshot())
	var furniture: Dictionary = Urban.prepare_furnishings(source, source.seed)
	checks.furniture_ready = furniture.get("ready", false)
	if not checks.furniture_ready: return report
	var plan = furniture.furnishingPlan
	var furniture_before := var_to_bytes([plan.snapshot(), plan.protected_access_reservations])
	var obstacles := Shop.furnishing_obstacles(plan.snapshot(), plan.protected_access_reservations)
	checks.obstacles_ready = obstacles.ready
	if not checks.obstacles_ready: return report
	var start := Time.get_ticks_usec()
	var result := Shop.prepare(source, obstacles.obstacles, Urban.add_market_stall_household, Urban.add_terminal_shop_row, Urban.plan_courtyard_household, Urban.plan_terminal_shop_household)
	report["elapsedUsec"] = Time.get_ticks_usec() - start
	report["result"] = result
	checks.shops_ready = result.get("ready", false)
	checks.source_immutable = before == var_to_bytes(source.snapshot())
	checks.furniture_immutable = furniture_before == var_to_bytes([plan.snapshot(), plan.protected_access_reservations])
	checks.artifact_unchanged = FileAccess.get_sha256(INPUT) == INPUT_SHA
	report.passed = checks.values().all(func(value): return value == true)
	return report
