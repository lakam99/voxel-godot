extends Node3D
class_name MotionVolumeRenderer

## Presentation-only inspection adapter for pure MotionVolumeSample geometry.
## It renders no collision shape and never resolves contact; every visible
## capsule and sweep sheet is reconstructed from the shared motion output.

const VOLUME_COLOR := Color(1.0, 0.66, 0.20, 0.42)
const PREVIEW_VOLUME_COLOR := Color(1.0, 0.66, 0.20, 0.34)
const SWEEP_COLOR := Color(1.0, 0.78, 0.36, 0.15)

const MotionVolumeSamplerScript := preload("res://scripts/combat/contact/MotionVolumeSampler.gd")

var stack
var volume_recipe
var capsule_mesh: CylinderMesh
var cap_mesh: SphereMesh


func _ready() -> void:
	capsule_mesh = CylinderMesh.new()
	capsule_mesh.top_radius = 1.0
	capsule_mesh.bottom_radius = 1.0
	capsule_mesh.height = 1.0
	capsule_mesh.radial_segments = 12
	cap_mesh = SphereMesh.new()
	cap_mesh.radius = 1.0
	cap_mesh.height = 2.0
	cap_mesh.radial_segments = 12
	cap_mesh.rings = 6


func set_stack(next_stack) -> void:
	stack = next_stack


func set_volume_recipe(next_volume_recipe) -> void:
	volume_recipe = next_volume_recipe


func render_at(global_time: float) -> void:
	clear_visuals()
	if stack == null or volume_recipe == null:
		return
	# The capsule previews the full motion, including wind-up and recovery. The
	# active flag still controls the sweep sheet, preserving the declared arc-only
	# contact window for a later resolver.
	var current_samples: Array = MotionVolumeSamplerScript.geometry_samples_for_stack(stack, volume_recipe, global_time)
	var previous_samples: Array = MotionVolumeSamplerScript.geometry_samples_for_stack(stack, volume_recipe, maxf(0.0, global_time - 0.045))
	var previous_by_instance: Dictionary = {}
	for previous_sample in previous_samples:
		previous_by_instance[previous_sample.instance_id] = previous_sample
	for current_sample in current_samples:
		var previous_sample = previous_by_instance.get(current_sample.instance_id, null)
		if current_sample.active:
			add_sweep_sheet(MotionVolumeSamplerScript.sweep(previous_sample, current_sample))
		add_capsule(current_sample)


func clear_visuals() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()


func add_capsule(volume_sample) -> void:
	if volume_sample == null:
		return
	var start: Vector3 = volume_sample.segment_start
	var finish: Vector3 = volume_sample.segment_end
	var axis: Vector3 = finish - start
	var length: float = axis.length()
	if length <= 0.001:
		return
	var material := make_material(VOLUME_COLOR if volume_sample.active else PREVIEW_VOLUME_COLOR, 2)
	var cylinder := MeshInstance3D.new()
	cylinder.name = "MotionContactVolumeCapsule"
	cylinder.mesh = capsule_mesh
	cylinder.material_override = material
	cylinder.position = start.lerp(finish, 0.5)
	cylinder.basis = Basis(Quaternion(Vector3.UP, axis / length))
	cylinder.scale = Vector3(volume_sample.radius, length, volume_sample.radius)
	cylinder.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(cylinder)
	for endpoint in [start, finish]:
		var cap := MeshInstance3D.new()
		cap.name = "MotionContactVolumeCap"
		cap.mesh = cap_mesh
		cap.material_override = material
		cap.position = endpoint
		cap.scale = Vector3.ONE * volume_sample.radius
		cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(cap)


func add_sweep_sheet(sweep_sample) -> void:
	if sweep_sample == null or not sweep_sample.active:
		return
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface_tool.set_material(make_material(SWEEP_COLOR, 1))
	var from_start: Vector3 = sweep_sample.from_segment_start
	var from_end: Vector3 = sweep_sample.from_segment_end
	var to_start: Vector3 = sweep_sample.to_segment_start
	var to_end: Vector3 = sweep_sample.to_segment_end
	surface_tool.add_vertex(from_start)
	surface_tool.add_vertex(from_end)
	surface_tool.add_vertex(to_end)
	surface_tool.add_vertex(from_start)
	surface_tool.add_vertex(to_end)
	surface_tool.add_vertex(to_start)
	var sheet := MeshInstance3D.new()
	sheet.name = "MotionContactVolumeSweep"
	sheet.mesh = surface_tool.commit()
	sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sheet)


func make_material(color: Color, priority: int) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b) * 0.34
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	material.render_priority = priority
	return material
