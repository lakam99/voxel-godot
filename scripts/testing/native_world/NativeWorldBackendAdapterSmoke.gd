extends SceneTree

const EXTENSION_PATH := "res://addons/terrain_meshing_backend/terrain_meshing_backend.gdextension"
const EXTENSION_LOAD_STATUS_OK := 0
const EXTENSION_LOAD_STATUS_ALREADY_LOADED := 2

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var report_path := OS.get_environment("VWB_ADAPTER_SMOKE_REPORT")
	var engine_version := Engine.get_version_info()
	var resource_exists := ResourceLoader.exists(EXTENSION_PATH)
	var extension_manager_exists := Engine.has_singleton("GDExtensionManager")
	var explicit_load_status := -1
	var loaded_extensions := PackedStringArray()
	if extension_manager_exists:
		var manager = Engine.get_singleton("GDExtensionManager")
		if manager != null:
			if manager.has_method("is_extension_loaded") and bool(manager.call("is_extension_loaded", EXTENSION_PATH)):
				explicit_load_status = EXTENSION_LOAD_STATUS_ALREADY_LOADED
			elif manager.has_method("load_extension"):
				explicit_load_status = int(manager.call("load_extension", EXTENSION_PATH))
			if manager.has_method("get_loaded_extensions"):
				loaded_extensions = manager.call("get_loaded_extensions")
	var extension_admitted := (
		resource_exists
		and extension_manager_exists
		and explicit_load_status in [EXTENSION_LOAD_STATUS_OK, EXTENSION_LOAD_STATUS_ALREADY_LOADED]
		and EXTENSION_PATH in loaded_extensions
	)
	var report := {
		"schema": "native-world-backend-adapter-smoke-report/v1",
		"engineVersion": engine_version,
		"extensionPath": EXTENSION_PATH,
		"resourceExists": resource_exists,
		"extensionManagerSingleton": extension_manager_exists,
		"explicitLoadStatus": explicit_load_status,
		"loadedExtensions": loaded_extensions,
		"classExists": ClassDB.class_exists("TerrainMeshingBackend"),
		"n3OwnerClassExists": ClassDB.class_exists("NativeWorldBackend"),
		"n3PageClassExists": ClassDB.class_exists("NativeEffectiveTerrainPage"),
		"n3OwnerStatus": {},
		"instantiated": false,
		"core": {},
		"passed": false
	}
	if bool(report["classExists"]):
		var backend = ClassDB.instantiate("TerrainMeshingBackend")
		report["instantiated"] = backend != null
		if backend != null and backend.has_method("world_backend_core_smoke"):
			var value = backend.call("world_backend_core_smoke")
			if value is Dictionary:
				report["core"] = value
				report["passed"] = extension_admitted and (
					String(value.get("schema", "")) == "native-world-backend-adapter-smoke/v1"
					and int(value.get("floorDivide", 0)) == -2
					and int(value.get("euclideanModulo", 0)) == 15
					and int(value.get("emptySeedHash", 0)) == 2166136261
					and String(value.get("sourceDigest", "")) == "abbd66bd21010fe6f0a4b9406264fdefefa05bc793ed8a27ce2c7c59424736bf"
					and bool(value.get("coreLinked", false))
					and int(engine_version.get("major", -1)) == 4
					and int(engine_version.get("minor", -1)) == 6
					and int(engine_version.get("patch", -1)) == 1
					and String(engine_version.get("status", "")) == "stable"
					and String(engine_version.get("hash", "")) == "14d19694e0c88a3f9e82d899a0400f27a24c176e"
				)
		backend = null
	var n3_owner = ClassDB.instantiate("NativeWorldBackend") if bool(report.n3OwnerClassExists) else null
	if n3_owner != null and n3_owner.has_method("status"):
		report.n3OwnerStatus = n3_owner.status()
		report.passed = bool(report.passed) \
			and bool(report.n3PageClassExists) \
			and String(report.n3OwnerStatus.get("schema", "")) == "n3-native-world-backend-adapter/v1" \
			and String(report.n3OwnerStatus.get("status", "")) == "uninitialized" \
			and bool(report.n3OwnerStatus.get("shadowOnly", false)) \
			and not bool(report.n3OwnerStatus.get("productionCutover", true))
	else:
		report.passed = false
	n3_owner = null
	await process_frame
	if report_path != "":
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if bool(report["passed"]) else 1)
