extends SceneTree

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")

var report_path := "res://artifacts/caves/cave-debug-progress.json"
var events: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_CAVE_DEBUG_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/caves/cave-debug-progress.json")
	mark("start")
	OS.set_environment("VOXEL_PLAYTEST", "1")
	OS.set_environment("VOXEL_TEST_SEED", "atlas-1492")
	var main := MAIN_SCENE.instantiate()
	mark("main-instantiated")
	root.add_child(main)
	mark("main-added")
	for i in range(90):
		await process_frame
		if i % 10 == 0:
			mark("frame-%d" % i)
	var structure_system = main.get("structure_system")
	var subsurface_system = main.get("subsurface_system")
	mark("systems", {
		"structure": structure_system != null,
		"subsurface": subsurface_system != null
	})
	if structure_system == null:
		quit(1)
		return
	var plan: Dictionary = structure_system.call("cave_plan_for_region", -2, 2, "cliff", false)
	mark("plan-selected", {
		"id": String(plan.get("id", "")),
		"empty": plan.is_empty(),
		"nodes": (plan.get("caveNodes", []) as Array).size() if plan.get("caveNodes", []) is Array else 0,
		"edges": (plan.get("caveEdges", []) as Array).size() if plan.get("caveEdges", []) is Array else 0,
		"path": int(plan.get("pathLength", 0))
	})
	if plan.is_empty():
		quit(1)
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 51093
	structure_system.call("build_cave", plan, rng)
	mark("cave-built")
	if subsurface_system != null:
		var samples := [
			Vector3(-314.55, 26.336, 511.65),
			Vector3(-314.55, 26.286, 506.25),
			Vector3(-314.55, 26.236, 500.85),
			Vector3(-314.19, 26.123, 506.25)
		]
		for sample in samples:
			var point := Vector2(sample.x, sample.z)
			mark("sample", {
				"world": { "x": sample.x, "y": sample.y, "z": sample.z },
				"axes": subsurface_system.call("cave_mouth_depth_lateral", plan, point),
				"volume": subsurface_system.call("cave_volume_value", plan, point),
				"floor": subsurface_system.call("cave_floor_y_at_surface", plan, point, float(plan.get("level", 0.0))),
				"ceiling": subsurface_system.call("cave_ceiling_y_at_surface", plan, point, 0.0),
				"surface": subsurface_system.call("surface_height_for_plan_point", plan, point),
				"solid": subsurface_system.call("solid_at_world", plan, sample),
				"surfaceCut": subsurface_system.call("surface_patch_quad_cut_by_cave_pipe", plan, point, point, point, point)
			})
	quit(0)

func mark(label: String, data := {}) -> void:
	var event := {
		"label": label,
		"ticksMsec": Time.get_ticks_msec()
	}
	if data is Dictionary:
		for key in (data as Dictionary).keys():
			event[String(key)] = (data as Dictionary)[key]
	events.append(event)
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({ "events": events }, "  "))
		file.close()
