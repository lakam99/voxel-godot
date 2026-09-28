extends SceneTree

## Directly invokes the production six-draw rock recipe.  The fixed-vector
## assertion is populated from the live method so a native port cannot silently
## translate its draw order or float arithmetic.

const RockRecipeBuilderScript := preload("res://scripts/environment/RockRecipeBuilder.gd")

const EXPECTED := {
	0: [1.27091150917139, 0.637751580774784, 1.03686468601227, 1.25131964683533, 1.1986848115921, 1.23602616786957],
	1: [2.07068081801902, 0.743616393208504, 1.15784769058228, 1.59521305561066, 0.957186698913574, 1.02372682094574],
	123456789: [1.97829742427985, 0.726121687889099, 1.41469855308533, 1.68217313289642, 0.753812313079834, 1.40172040462494],
	4294967295: [1.89681461935967, 0.775791820883751, 1.06554148197174, 1.3989052772522, 0.789948582649231, 1.05209577083588],
}

const EXPECTED_SINK_BITS := {
	0: [0x3fa2ad3a, 0x3f2b6d79, 0x3e892461],
	1: [0x40048609, 0x3f47e253, 0x3e9fe843],
	123456789: [0x3ffd38da, 0x3f432e77, 0x3e9c252c],
	4294967295: [0x3ff2cad2, 0x3f508868, 0x3ea6d387],
}

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_SURFACE_ROCK_RECIPE_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/surface-rock-recipe-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	for seed in [0, 1, 123456789, 4294967295]:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		var spec: Dictionary = RockRecipeBuilderScript.build_visual_spec(rng)
		var finite := true
		for value in [spec.get("rotation", NAN), spec.get("radius", NAN), spec.get("height_factor", NAN)]:
			finite = finite and is_finite(float(value))
		var scale: Vector3 = spec.get("scale", Vector3(NAN, NAN, NAN))
		finite = finite and is_finite(scale.x) and is_finite(scale.y) and is_finite(scale.z)
		var actual := [float(spec.get("rotation", NAN)), float(spec.get("radius", NAN)), float(spec.get("height_factor", NAN)), scale.x, scale.y, scale.z]
		var expected: Array = EXPECTED.get(seed, [])
		var matches := expected.size() == actual.size()
		for index in range(actual.size()):
			matches = matches and absf(float(actual[index]) - float(expected[index])) < 0.00000000000001
		var body := Node3D.new()
		body.rotation.y = float(spec.get("rotation", 0.0))
		var sphere := SphereShape3D.new()
		sphere.radius = float(spec.get("radius", 0.0)) * 1.05
		var collider := CollisionShape3D.new()
		collider.position.y = float(spec.get("radius", 0.0)) * 0.42
		var sink_bits := [bits32(body.rotation.y), bits32(sphere.radius), bits32(collider.position.y)]
		body.free()
		collider.free()
		if EXPECTED_SINK_BITS.has(seed):
			matches = matches and sink_bits == EXPECTED_SINK_BITS[seed]
		add_result("surface_rock_recipe_seed_%d" % seed, finite and matches, {
			"seed": seed,
			"expected": expected,
			"actual": actual,
			"sinkBits": sink_bits,
			"finalState": rng.state,
		})
	finish()

func bits32(value: float) -> int:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, value)
	return bytes.decode_u32(0)

func add_result(name: String, passed: bool, details: Dictionary) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func finish() -> void:
	var failure_count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failure_count += 1
	var report := {
		"schemaVersion": 1,
		"runnerId": "surface_rock_recipe_contract",
		"finished": true,
		"passed": failure_count == 0,
		"evidenceLevel": "contract",
		"scope": "Direct Godot execution of the production RockRecipeBuilder and the current MainPlaytestTools numeric property assignments. It proves source recipe and float32 sink arithmetic; it does not prove native parity, collision installation, or gameplay.",
		"resultCount": results.size(),
		"failureCount": failure_count,
		"results": results,
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	quit(0 if failure_count == 0 else 1)
