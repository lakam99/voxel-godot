extends SceneTree

## Direct source oracle for unedited surface-prop heights. This executes the
## current WorldGenerationSystem interpolation, not a copied native formula.

const EffectiveOracle := preload("res://scripts/testing/native_world/N3EffectiveTerrainOracle.gd")
const COLUMNS := [Vector2i(0, 0), Vector2i(1, 2), Vector2i(-20, 13), Vector2i(47, -6)]
const EXPECTED_ANCHOR_Y_BITS := [1102070153, 1102310801, 1103514043, 1100866912]

var report_path := ""

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_SURFACE_PROP_SPAWN_PROJECTION_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/native-world-backend/surface-prop-spawn-projection-oracle.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var bundle: Dictionary = EffectiveOracle.build_world("atlas-1492")
	if not bool(bundle.get("ok", false)):
		finish(false, [], String(bundle.get("reason", "world_build_failed")))
		return
	var world = bundle.get("world")
	var rows: Array[Dictionary] = []
	var passed := true
	for index in range(COLUMNS.size()):
		var column: Vector2i = COLUMNS[index]
		var cell := Vector3i(column.x, 0, column.y)
		var height := float(world.volume_surface_y_for_cell(cell))
		var biome := String(world.surface_biome_for_cell3(cell))
		var anchor_bits := bits32(height)
		passed = passed and anchor_bits == EXPECTED_ANCHOR_Y_BITS[index]
		rows.append({
			"x": column.x, "z": column.y, "height": height,
			"anchorYBits": anchor_bits, "expectedAnchorYBits": EXPECTED_ANCHOR_Y_BITS[index], "biome": biome,
		})
	finish(passed, rows, "" if passed else "source_height_regression")

func bits32(value: float) -> int:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, value)
	return bytes.decode_u32(0)

func finish(passed: bool, rows: Array[Dictionary], reason: String) -> void:
	var report := {
		"schemaVersion": 1,
		"runnerId": "surface_prop_spawn_projection_oracle",
		"finished": true,
		"passed": passed,
		"evidenceLevel": "contract",
		"scope": "Direct Godot source heights and biomes for unedited columns; no native parity, edited projection, publication, collision, or live gameplay claim.",
		"seed": "atlas-1492", "columns": rows, "reason": reason,
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	quit(0 if passed else 1)
