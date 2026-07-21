extends Node3D
class_name MotionTelegraphRenderer

## Presentation-only wind-up cue. It reads the same recipe timeline as the
## white motion ribbon and deliberately knows nothing about enemy types,
## weapons, collision, targets, or damage.

const TELEGRAPH_COLOR := Color(1.0, 0.70, 0.24, 0.38)
static var shared_ring_mesh: CylinderMesh
static var shared_telegraph_material: StandardMaterial3D

var ring: MeshInstance3D


func _ready() -> void:
	ring = MeshInstance3D.new()
	ring.name = "MotionWindupTelegraph"
	ring.mesh = ring_mesh()
	ring.material_override = telegraph_material()
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.visible = false
	add_child(ring)


func render_for(source: Node3D, recipe, normalized_time: float) -> void:
	if ring == null or source == null or not is_instance_valid(source) or recipe == null:
		set_telegraph_visible(false)
		return
	var parameters: Dictionary = recipe.parameters
	var windup := clampf(float(parameters.get("windupFraction", 0.25)), 0.02, 0.80)
	var visible := normalized_time >= 0.0 and normalized_time < windup
	set_telegraph_visible(visible)
	if not visible:
		return
	var progress := clampf(normalized_time / windup, 0.0, 1.0)
	var reach := clampf(float(parameters.get("reach", 3.0)), 0.5, 8.0)
	global_position = source.global_position + Vector3.UP * 0.035
	var scale_factor := lerpf(0.34, clampf(reach * 0.28, 0.62, 1.35), progress)
	ring.scale = Vector3(scale_factor, 1.0, scale_factor)


func set_telegraph_visible(value: bool) -> void:
	if ring != null and is_instance_valid(ring):
		ring.visible = value


static func ring_mesh() -> CylinderMesh:
	if shared_ring_mesh != null:
		return shared_ring_mesh
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.0
	mesh.bottom_radius = 1.0
	mesh.height = 0.026
	mesh.radial_segments = 24
	mesh.rings = 1
	shared_ring_mesh = mesh
	return shared_ring_mesh


static func telegraph_material() -> StandardMaterial3D:
	if shared_telegraph_material != null:
		return shared_telegraph_material
	var material := StandardMaterial3D.new()
	material.albedo_color = TELEGRAPH_COLOR
	material.emission_enabled = true
	material.emission = Color(1.0, 0.42, 0.08) * 0.75
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	material.render_priority = 0
	shared_telegraph_material = material
	return shared_telegraph_material
