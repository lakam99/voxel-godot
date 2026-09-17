extends SceneTree

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var report_path := OS.get_environment("VWB_ADAPTER_SMOKE_REPORT")
	var engine_version := Engine.get_version_info()
	var report := {
		"schema": "native-world-backend-adapter-smoke-report/v1",
		"engineVersion": engine_version,
		"classExists": ClassDB.class_exists("TerrainMeshingBackend"),
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
				report["passed"] = (
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
	await process_frame
	if report_path != "":
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if bool(report["passed"]) else 1)
