extends Node3D
class_name MotionSegmentSweepRenderer

## Presentation-only ribbon for an item segment. It joins consecutive grip-to-
## tip samples into one continuous translucent swept surface; physics samples
## the same segment independently through the contact adapter.

const AFTERIMAGE_COLOR := Color(1.0, 1.0, 1.0, 0.34)

static var shared_afterimage_material: StandardMaterial3D
static var shared_overlay_afterimage_material: StandardMaterial3D

var ribbons_by_trail_id: Dictionary = {}
var draw_over_depth := false


func set_draw_over_depth(enabled: bool) -> void:
	draw_over_depth = enabled


func render_segment_trails(trails: Array) -> void:
	var used: Dictionary = {}
	for index in range(trails.size()):
		var trail = trails[index] as Dictionary
		if trail.is_empty():
			continue
		var trail_id := String(trail.get("instanceId", "segment_%d" % index))
		used[trail_id] = true
		var samples: Array = []
		for sample in trail.get("samples", []):
			if sample != null and String(sample.phase) != "recovery":
				samples.append(sample)
		var ribbon := ribbon_for_trail(trail_id)
		ribbon.visible = update_sweep_mesh(ribbon, samples)
	prune_unused_ribbons(used)


func clear_visuals() -> void:
	for ribbon_value in ribbons_by_trail_id.values():
		var ribbon := ribbon_value as MeshInstance3D
		if ribbon != null and is_instance_valid(ribbon):
			remove_child(ribbon)
			ribbon.queue_free()
	ribbons_by_trail_id.clear()


func ribbon_for_trail(trail_id: String) -> MeshInstance3D:
	var existing := ribbons_by_trail_id.get(trail_id, null) as MeshInstance3D
	if existing != null and is_instance_valid(existing):
		return existing
	var ribbon := MeshInstance3D.new()
	ribbon.name = "MotionEquipmentSweep_%s" % trail_id.validate_filename()
	ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ribbon.mesh = ImmediateMesh.new()
	add_child(ribbon)
	ribbons_by_trail_id[trail_id] = ribbon
	return ribbon


func prune_unused_ribbons(used: Dictionary) -> void:
	for trail_id_value in ribbons_by_trail_id.keys().duplicate():
		var trail_id := String(trail_id_value)
		if used.has(trail_id):
			continue
		var ribbon := ribbons_by_trail_id.get(trail_id) as MeshInstance3D
		if ribbon != null and is_instance_valid(ribbon):
			remove_child(ribbon)
			ribbon.queue_free()
		ribbons_by_trail_id.erase(trail_id)


func update_sweep_mesh(ribbon: MeshInstance3D, samples: Array) -> bool:
	if ribbon == null or not is_instance_valid(ribbon):
		return false
	var mesh := ribbon.mesh as ImmediateMesh
	if mesh == null:
		mesh = ImmediateMesh.new()
		ribbon.mesh = mesh
	mesh.clear_surfaces()
	if samples.size() < 2:
		return false
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, afterimage_material())
	var segment_count := 0
	for index in range(samples.size() - 1):
		var previous = samples[index]
		var current = samples[index + 1]
		if previous == null or current == null:
			continue
		var previous_start: Vector3 = previous.segment_start
		var previous_end: Vector3 = previous.segment_end
		var current_start: Vector3 = current.segment_start
		var current_end: Vector3 = current.segment_end
		if previous_end.distance_squared_to(previous_start) <= 0.000001 or current_end.distance_squared_to(current_start) <= 0.000001:
			continue
		mesh.surface_add_vertex(previous_start)
		mesh.surface_add_vertex(previous_end)
		mesh.surface_add_vertex(current_end)
		mesh.surface_add_vertex(previous_start)
		mesh.surface_add_vertex(current_end)
		mesh.surface_add_vertex(current_start)
		segment_count += 1
	mesh.surface_end()
	return segment_count > 0


func afterimage_material() -> StandardMaterial3D:
	if draw_over_depth and shared_overlay_afterimage_material != null:
		return shared_overlay_afterimage_material
	if not draw_over_depth and shared_afterimage_material != null:
		return shared_afterimage_material
	var material := StandardMaterial3D.new()
	material.albedo_color = AFTERIMAGE_COLOR
	material.emission_enabled = true
	material.emission = Color.WHITE * 0.32
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = draw_over_depth
	material.render_priority = 2 if draw_over_depth else 1
	if draw_over_depth:
		shared_overlay_afterimage_material = material
		return shared_overlay_afterimage_material
	shared_afterimage_material = material
	return shared_afterimage_material
