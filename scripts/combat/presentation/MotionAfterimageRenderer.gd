extends Node3D

## Shared presentation adapter for pure motion samples. Every motion trail
## becomes one continuous translucent ribbon. This node owns no collision,
## damage, anatomy, input, or gameplay state.

const AFTERIMAGE_COLOR := Color(1.0, 1.0, 1.0, 0.34)

## Every live arc uses exactly the same immutable material. Creating a
## StandardMaterial3D while a hostile is striking can force renderer resource
## work into a gameplay frame, even though the visual state has not changed.
static var shared_afterimage_material: StandardMaterial3D

var stack
var ribbons_by_trail_id: Dictionary = {}


func set_stack(next_stack) -> void:
	stack = next_stack


func render_at(global_time: float, trail_samples := 15) -> void:
	if stack == null or not stack.has_method("trails_until"):
		clear_visuals()
		return
	render_trails(stack.trails_until(global_time, trail_samples))


## This is the shared runtime/PoC contract. Callers may supply samples in
## local, camera, or world space, but every ribbon derives from those samples
## without creating a second animation path.
func render_trails(trails: Array) -> void:
	var used_trail_ids: Dictionary = {}
	for index in range(trails.size()):
		var trail = trails[index]
		if not (trail is Dictionary):
			continue
		var trail_id := String(trail.get("instanceId", "trail_%d" % index))
		if trail_id == "":
			trail_id = "trail_%d" % index
		used_trail_ids[trail_id] = true
		var samples: Array = trail.get("samples", [])
		var forward_motion_samples: Array = []
		for sample in samples:
			if sample != null and sample.phase != "recovery":
				forward_motion_samples.append(sample)
		# A ribbon represents the continuous forward motion, not a series of tiny
		# instantaneous phase fragments. Keep wind-up joined to the active arc;
		# only omit recovery so the trail cannot fold back over itself.
		var ribbon := ribbon_for_trail(trail_id)
		if not update_afterimage_mesh(ribbon, forward_motion_samples if not forward_motion_samples.is_empty() else samples):
			ribbon.visible = false
			continue
		ribbon.visible = true
	prune_unused_ribbons(used_trail_ids)


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
	ribbon.name = "MotionAfterimageRibbon_%s" % trail_id.validate_filename()
	ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Dynamic vertex data lives on this one mesh for the life of the independent
	# motion. Do not allocate an ArrayMesh every physics frame.
	ribbon.mesh = ImmediateMesh.new()
	add_child(ribbon)
	ribbons_by_trail_id[trail_id] = ribbon
	return ribbon


func prune_unused_ribbons(used_trail_ids: Dictionary) -> void:
	for trail_id_value in ribbons_by_trail_id.keys().duplicate():
		var trail_id := String(trail_id_value)
		if used_trail_ids.has(trail_id):
			continue
		var ribbon := ribbons_by_trail_id.get(trail_id) as MeshInstance3D
		if ribbon != null and is_instance_valid(ribbon):
			remove_child(ribbon)
			ribbon.queue_free()
		ribbons_by_trail_id.erase(trail_id)


func update_afterimage_mesh(ribbon: MeshInstance3D, samples: Array) -> bool:
	if ribbon == null or not is_instance_valid(ribbon):
		return false
	var mesh := ribbon.mesh as ImmediateMesh
	if mesh == null:
		mesh = ImmediateMesh.new()
		ribbon.mesh = mesh
	mesh.clear_surfaces()
	if samples.size() < 2:
		return false
	# ImmediateMesh rejects surface_end() when no vertices were supplied. A
	# just-started wind-up can legitimately have repeated samples, so establish
	# that there is a drawable segment before opening the surface.
	var has_drawable_segment := false
	for index in range(samples.size() - 1):
		if not trajectory_edges(samples, index).is_empty() and not trajectory_edges(samples, index + 1).is_empty():
			has_drawable_segment = true
			break
	if not has_drawable_segment:
		return false
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, afterimage_material())
	var segment_count := 0
	for index in range(samples.size() - 1):
		var previous_edge := trajectory_edges(samples, index)
		var current_edge := trajectory_edges(samples, index + 1)
		if previous_edge.is_empty() or current_edge.is_empty():
			continue
		var inner_previous: Vector3 = previous_edge["inner"]
		var outer_previous: Vector3 = previous_edge["outer"]
		var inner_current: Vector3 = current_edge["inner"]
		var outer_current: Vector3 = current_edge["outer"]
		# Adjacent segments share an exact boundary, producing one continuous
		# shape rather than a sequence of independently rendered afterimages.
		mesh.surface_add_vertex(inner_previous)
		mesh.surface_add_vertex(outer_previous)
		mesh.surface_add_vertex(outer_current)
		mesh.surface_add_vertex(inner_previous)
		mesh.surface_add_vertex(outer_current)
		mesh.surface_add_vertex(inner_current)
		segment_count += 1
	mesh.surface_end()
	return segment_count > 0


func trajectory_edges(samples: Array, index: int) -> Dictionary:
	if index < 0 or index >= samples.size():
		return {}
	var sample = samples[index]
	if sample == null:
		return {}
	var tip: Vector3 = sample.tip
	var radial: Vector3 = tip - sample.origin
	var reach: float = radial.length()
	if reach <= 0.001:
		return {}
	var previous_sample = samples[maxi(0, index - 1)]
	var next_sample = samples[mini(samples.size() - 1, index + 1)]
	if previous_sample == null or next_sample == null:
		return {}
	var tangent: Vector3 = next_sample.tip - previous_sample.tip
	if tangent.length_squared() <= 0.000001:
		return {}
	var width_axis: Vector3 = tangent.normalized().cross(radial.normalized())
	if width_axis.length_squared() <= 0.000001:
		width_axis = radial.normalized().cross(Vector3.UP)
	if width_axis.length_squared() <= 0.000001:
		width_axis = Vector3.RIGHT
	var half_width := clampf(reach * 0.055, 0.10, 0.22)
	var direction := width_axis.normalized()
	return {
		"inner": tip - direction * half_width,
		"outer": tip + direction * half_width
	}


func afterimage_material() -> StandardMaterial3D:
	if shared_afterimage_material != null:
		return shared_afterimage_material
	var material := StandardMaterial3D.new()
	material.albedo_color = AFTERIMAGE_COLOR
	material.emission_enabled = true
	material.emission = Color.WHITE * 0.32
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	material.render_priority = 1
	shared_afterimage_material = material
	return shared_afterimage_material
