extends RefCounted
class_name CaveInteriorBuilder

var main
var support_material: StandardMaterial3D
var formation_material: StandardMaterial3D

func setup(main_node) -> void:
	main = main_node

func build(_plan: Dictionary, _rng: RandomNumberGenerator, _metadata: Dictionary = {}) -> Node3D:
	return null

func build_formation_mesh(_plan: Dictionary, _rng: RandomNumberGenerator) -> ArrayMesh:
	return ArrayMesh.new()

func add_support_frames(_root: Node3D, _plan: Dictionary) -> void:
	return

func wall_mount_sample(_plan: Dictionary, walk_cell: Vector2i, wall_normal: Vector2i) -> Dictionary:
	var cell_size := float(main.CELL) if main != null else 1.35
	var center := Vector2(float(walk_cell.x) * cell_size, float(walk_cell.y) * cell_size)
	var normal := Vector2(float(wall_normal.x), float(wall_normal.y))
	if normal.length_squared() <= 0.001:
		normal = Vector2(1.0, 0.0)
	normal = normal.normalized()
	return {
		"valid": false,
		"surface": center,
		"normalWorld": normal
	}

func cave_formation_material() -> StandardMaterial3D:
	if formation_material != null:
		return formation_material
	formation_material = StandardMaterial3D.new()
	formation_material.vertex_color_use_as_albedo = true
	formation_material.albedo_color = Color(0.32, 0.35, 0.33)
	formation_material.roughness = 0.96
	return formation_material

func cave_support_material() -> StandardMaterial3D:
	if support_material != null:
		return support_material
	support_material = StandardMaterial3D.new()
	support_material.albedo_color = Color(0.34, 0.21, 0.12)
	support_material.roughness = 0.88
	return support_material
