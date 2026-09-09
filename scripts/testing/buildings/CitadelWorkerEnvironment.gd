extends SceneTree
func _initialize() -> void:
	var engine = Engine.get_singleton("VoxelEngine") if Engine.has_singleton("VoxelEngine") else null
	var settings := {}
	for property in ProjectSettings.get_property_list():
		if String(property.name).begins_with("voxel/threads/"): settings[property.name]=ProjectSettings.get_setting(property.name)
	for key in ["voxel/threads/count/minimum","voxel/threads/count/margin_below_maximum","voxel/threads/count/ratio_over_maximum","threading/worker_pool/max_threads","rendering/driver/threads/thread_model"]:
		settings[key]=ProjectSettings.get_setting(key)
	var checks := {"voxel_engine_available":engine!=null}
	var report := {"passed":engine!=null,"checks":checks,"processors":OS.get_processor_count(),"settings":settings,"scope":"Engine configuration observation only; no live worker attribution or gameplay acceptance."}
	if engine!=null:
		report["stats"]=engine.get_stats()
		for method in ["get_thread_count","get_version_git_hash","get_threaded_graphics_resource_building_enabled"]:
			if engine.has_method(method): report[method]=engine.call(method)
	var file := FileAccess.open(OS.get_environment("WORKER_ENV_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	quit(0 if engine!=null else 1)
