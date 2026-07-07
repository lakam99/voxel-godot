extends SceneTree

const TerrainMeshingServiceScript := preload("res://scripts/TerrainMeshingService.gd")
const EXTENSION_PATH := "res://addons/terrain_meshing_backend/terrain_meshing_backend.gdextension"
const BACKEND_CLASS := "TerrainMeshingBackend"

func _init() -> void:
	var report_path := OS.get_environment("VOXEL_TERRAIN_MESHING_NATIVE_SMOKE_REPORT").strip_edges()
	if report_path == "":
		report_path = "artifacts/terrain-volume/terrain-meshing-native-smoke.json"
	var native_paths = ProjectSettings.get_setting("native_extensions/paths", [])
	var report := {
		"schemaVersion": 1,
		"runnerId": "terrain_meshing_native_smoke",
		"extensionPath": EXTENSION_PATH,
		"nativeExtensionPaths": native_paths,
		"resourceExists": ResourceLoader.exists(EXTENSION_PATH),
		"extensionManagerSingleton": Engine.has_singleton("GDExtensionManager"),
		"explicitLoadStatus": -1,
		"loadedExtensions": [],
		"classExists": ClassDB.class_exists(BACKEND_CLASS),
		"singletonExists": Engine.has_singleton(BACKEND_CLASS),
		"instantiated": false,
		"backendSummary": {},
		"serviceSummary": {},
		"status": "failed"
	}
	if Engine.has_singleton("GDExtensionManager"):
		var manager = Engine.get_singleton("GDExtensionManager")
		if manager != null:
			if manager.has_method("is_extension_loaded") and bool(manager.call("is_extension_loaded", EXTENSION_PATH)):
				report["explicitLoadStatus"] = 2
			elif manager.has_method("load_extension"):
				report["explicitLoadStatus"] = int(manager.call("load_extension", EXTENSION_PATH))
			if manager.has_method("get_loaded_extensions"):
				report["loadedExtensions"] = manager.call("get_loaded_extensions")
	report["classExists"] = ClassDB.class_exists(BACKEND_CLASS)
	report["singletonExists"] = Engine.has_singleton(BACKEND_CLASS)
	if bool(report["classExists"]):
		var instance = ClassDB.instantiate(BACKEND_CLASS)
		report["instantiated"] = instance != null
		if instance != null and instance.has_method("backend_summary"):
			var summary_value = instance.call("backend_summary")
			if summary_value is Dictionary:
				report["backendSummary"] = summary_value
				report["status"] = "passed" if bool(summary_value.get("ready", false)) else "failed"
			else:
				report["status"] = "passed"
	var service = TerrainMeshingServiceScript.new()
	if service != null:
		service.setup(null)
		if service.has_method("backend_summary"):
			var service_summary_value = service.backend_summary()
			if service_summary_value is Dictionary:
				report["serviceSummary"] = service_summary_value
	var backend_summary: Dictionary = report["backendSummary"] if report["backendSummary"] is Dictionary else {}
	var service_summary: Dictionary = report["serviceSummary"] if report["serviceSummary"] is Dictionary else {}
	var backend_ready := bool(backend_summary.get("ready", false))
	var service_async := bool(service_summary.get("async", false))
	report["status"] = "passed" if backend_ready and service_async else "failed"
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
	quit(0 if String(report["status"]) == "passed" else 1)
