extends SceneTree

## Direct engine transform oracle for MainRuntimeTools' chunk.position and
## MainPlaytestTools' local prop position. No terrain/classification is mocked
## or claimed here; this isolates the two Vector3 float32 storage boundaries.

const CELL := 1.35
const CHUNK_SIZE := 28
const CASES := [
	{"chunkX": 1, "chunkZ": 1, "localX": 2, "localZ": 26},
	{"chunkX": 1, "chunkZ": 1, "localX": 26, "localZ": 2},
	{"chunkX": -1, "chunkZ": -1, "localX": 2, "localZ": 26},
	{"chunkX": -1, "chunkZ": -1, "localX": 26, "localZ": 2},
	{"chunkX": 127, "chunkZ": -127, "localX": 26, "localZ": 2},
	{"chunkX": 1000000, "chunkZ": -1000000, "localX": 2, "localZ": 26},
]

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var report_path := OS.get_environment("VOXEL_SURFACE_PROP_CHUNK_TRANSFORM_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/native-world-backend/surface-prop-chunk-transform-oracle.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var results: Array[Dictionary] = []
	for candidate in CASES:
		var cx: int = candidate["chunkX"]
		var cz: int = candidate["chunkZ"]
		var lx: int = candidate["localX"]
		var lz: int = candidate["localZ"]
		var chunk := Node3D.new()
		root.add_child(chunk)
		chunk.position = Vector3(cx * CHUNK_SIZE * CELL, 0.0, cz * CHUNK_SIZE * CELL)
		var prop := Node3D.new()
		chunk.add_child(prop)
		prop.position = Vector3(lx * CELL, 17.125, lz * CELL)
		var world := prop.global_position
		var direct := Vector3((cx * CHUNK_SIZE + lx) * CELL, 17.125, (cz * CHUNK_SIZE + lz) * CELL)
		results.append({
			"chunkX": cx, "chunkZ": cz, "localX": lx, "localZ": lz,
			"cellX": cx * CHUNK_SIZE + lx, "cellZ": cz * CHUNK_SIZE + lz,
			"originBits": [bits32(chunk.position.x), bits32(chunk.position.z)],
			"localBits": [bits32(prop.position.x), bits32(prop.position.z)],
			"worldBits": [bits32(world.x), bits32(world.z)],
			"directBits": [bits32(direct.x), bits32(direct.z)],
		})
		chunk.free()
	var report := {
		"schemaVersion": 1,
		"runnerId": "surface_prop_chunk_transform_contract",
		"finished": true,
		"passed": results.size() == CASES.size(),
		"evidenceLevel": "contract",
		"scope": "Direct Godot Node3D chunk-local transform float32 bits; does not prove terrain sampling, native parity, or live feature publication.",
		"results": results,
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	quit(0 if report["passed"] else 1)

func bits32(value: float) -> int:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, value)
	return bytes.decode_u32(0)
