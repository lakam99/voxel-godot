extends Node3D
class_name MotionContactResolutionRenderer

## Presentation-only adapter for passive geometry and pure resolution facts.
## It never owns collision, damage, target state, or gameplay consequences.

const CLEAR_GEOMETRY_COLOR := Color(0.22, 0.58, 1.0, 0.36)
const RESOLVED_GEOMETRY_COLOR := Color(1.0, 0.28, 0.12, 0.58)
const CONTACT_POINT_COLOR := Color(1.0, 0.96, 0.72, 0.94)
const CONTACT_NORMAL_COLOR := Color(1.0, 0.58, 0.30, 0.72)

var geometry_mesh: SphereMesh
var point_mesh: SphereMesh
var normal_mesh: CylinderMesh


func _ready() -> void:
	geometry_mesh = SphereMesh.new()
	geometry_mesh.radius = 1.0
	geometry_mesh.height = 2.0
	geometry_mesh.radial_segments = 20
	geometry_mesh.rings = 12
	point_mesh = SphereMesh.new()
	point_mesh.radius = 1.0
	point_mesh.height = 2.0
	point_mesh.radial_segments = 12
	point_mesh.rings = 8
	normal_mesh = CylinderMesh.new()
	normal_mesh.top_radius = 0.026
	normal_mesh.bottom_radius = 0.026
	normal_mesh.height = 1.0
	normal_mesh.radial_segments = 6


func render_geometries(passive_geometries: Array, resolutions: Array) -> void:
	clear_visuals()
	var resolved_by_geometry: Dictionary = {}
	for resolution in resolutions:
		if resolution != null and resolution.resolved:
			resolved_by_geometry[resolution.geometry_id] = resolution
	for passive_geometry in passive_geometries:
		if passive_geometry == null:
			continue
		var resolution = resolved_by_geometry.get(passive_geometry.geometry_id, null)
		add_geometry(passive_geometry, resolution)
		if resolution != null:
			add_contact_marker(resolution)


func clear_visuals() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()


func add_geometry(passive_geometry, resolution) -> void:
	var instance := MeshInstance3D.new()
	instance.name = "PassiveContactGeometry"
	instance.mesh = geometry_mesh
	instance.position = passive_geometry.center
	instance.scale = Vector3.ONE * float(passive_geometry.radius)
	instance.material_override = make_material(RESOLVED_GEOMETRY_COLOR if resolution != null else CLEAR_GEOMETRY_COLOR, 2)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


func add_contact_marker(resolution) -> void:
	var point := MeshInstance3D.new()
	point.name = "MotionContactPoint"
	point.mesh = point_mesh
	point.position = resolution.contact_point
	point.scale = Vector3.ONE * 0.085
	point.material_override = make_material(CONTACT_POINT_COLOR, 4)
	point.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(point)
	var normal: Vector3 = (resolution.contact_normal as Vector3).normalized()
	if normal.length_squared() <= 0.0001:
		return
	var line := MeshInstance3D.new()
	line.name = "MotionContactNormal"
	line.mesh = normal_mesh
	line.position = resolution.contact_point + normal * 0.24
	line.basis = Basis(Quaternion(Vector3.UP, normal))
	line.scale = Vector3(1.0, 0.48, 1.0)
	line.material_override = make_material(CONTACT_NORMAL_COLOR, 3)
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(line)


func make_material(color: Color, priority: int) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b) * 0.46
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	material.render_priority = priority
	return material
