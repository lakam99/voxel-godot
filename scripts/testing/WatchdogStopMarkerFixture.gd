extends SceneTree

## Headless process-lifecycle contract only; no game, NPCs, or world.
func _initialize() -> void:
	if DisplayServer.get_name() != "headless":
		quit(2)
		return
	var args := OS.get_cmdline_user_args()
	if "--fixture-stop-and-exit" in args:
		var path := OS.get_environment("VOXEL_WATCHDOG_STOP_REQUEST")
		if not path.is_absolute_path() or FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
			quit(2)
			return
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			quit(2)
			return
		file.store_string("fixture requests stop immediately before root exit")
		file.flush()
		var write_error := file.get_error()
		file.close()
		quit(0 if write_error == OK else 2)
		return
	print("WATCHDOG_FIXTURE_READY")
	if "--fixture-exit-immediately" in args:
		quit(0)
	# Otherwise the empty SceneTree waits for the watchdog to stop its job.
