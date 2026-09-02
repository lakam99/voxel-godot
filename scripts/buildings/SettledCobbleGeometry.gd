extends RefCounted

## Original settled-cobble construction, expressed as value descriptors.
## No scene nodes, materials, clipping, RNG or alternate surface-history sampler.
## Caller supplies the same source part and configured authoritative history.
## Row/column identities accompany the existing ordered batch payloads.
## Publication and source construction consume this same generator.

static func describe_source(part, surface_history, source_blueprint_id: String) -> Dictionary:
	return describe(part, surface_history, family_for(part), runs_along_x(part), region_phase(part, source_blueprint_id))

static func family_for(part) -> String:
	var explicit_family := String(part.recipe.get("pavingFamily", ""))
	if not explicit_family.is_empty():
		return explicit_family
	var semantic := String(part.semantic)
	if semantic in ["citadel_market_plaza", "citadel_civic_quarter_paving", "castle_courtyard_paving"]:
		return "civic_setts"
	if semantic.contains("route") or semantic.contains("lane") or semantic.contains("alley") or semantic.contains("street"):
		return "lane_cobbles"
	return "irregular_cobbles"

static func runs_along_x(part) -> bool:
	var heading := String(part.recipe.get("pavingHeading", ""))
	if heading == "x":
		return true
	if heading == "z":
		return false
	return part.size.x >= part.size.z

static func region_phase(part, source_blueprint_id: String) -> float:
	var region := String(part.recipe.get("pavingRegion", ""))
	if region.is_empty():
		region = "%s:%s" % [source_blueprint_id, String(part.semantic)]
	return float(posmod(region.hash(), 1009)) / 1009.0

static func describe(part, surface_history, paving_family: String, runs_along_x: bool, region_phase: float) -> Dictionary:
	var size: Vector3 = part.size
	var civic_setts := paving_family == "civic_setts" or paving_family == "courtyard_setts"
	var bed_height := maxf(0.045, size.y * 0.48)
	var joint_material_id := "stone_foundation" if civic_setts else "ground_soil"
	var bed := {"size": Vector3(size.x, bed_height, size.z), "position": Vector3(0.0, -size.y * 0.5 + bed_height * 0.5, 0.0), "materialId": joint_material_id}
	var along_span: float = size.x if runs_along_x else size.z
	var cross_span: float = size.z if runs_along_x else size.x
	var along_origin: float = part.position.x if runs_along_x else part.position.z
	var cross_origin: float = part.position.z if runs_along_x else part.position.x
	var target_along := 0.94 if civic_setts else 1.02
	var target_cross := 0.62 if civic_setts else 0.76
	var desired_count := maxi(1, ceili(along_span / target_along)) * maxi(1, ceili(cross_span / target_cross))
	if desired_count > 6000:
		var expansion := sqrt(float(desired_count) / 6000.0)
		target_along *= expansion
		target_cross *= expansion
	var regular_ids: Array[Vector2i] = []
	var worn_ids: Array[Vector2i] = []
	var regular_transforms: Array[Transform3D] = []
	var regular_custom_data: Array[Color] = []
	var worn_transforms: Array[Transform3D] = []
	var worn_custom_data: Array[Color] = []
	var cross_min := cross_origin - cross_span * 0.5
	var row_index := floori(cross_min / target_cross) - 1
	var cross_cursor := float(row_index) * target_cross - cross_origin
	while cross_cursor < cross_span * 0.5 - 0.01:
		var row_phase := fposmod(sin(float(row_index + 1) * 19.193 + region_phase * 71.713) * 15731.743, 1.0)
		# Hand-laid paving cannot inherit an invisible perfect grid from the
		# recipe bounds.  Courses, like real setts, advance by their own stable
		# widths and only meet the border where a mason had to cut a stone.
		var nominal_cross := target_cross * lerpf(0.78 if civic_setts else 0.70, 1.22 if civic_setts else 1.30, row_phase)
		var cross_start := maxf(-cross_span * 0.5, cross_cursor)
		var cross_end := minf(cross_span * 0.5, cross_cursor + nominal_cross)
		if cross_end - cross_start < 0.10:
			cross_cursor += nominal_cross
			row_index += 1
			continue
		var cross_center := (cross_start + cross_end) * 0.5
		var row_offset := target_along * lerpf(0.26, 0.72, row_phase) if posmod(row_index, 2) == 1 else target_along * lerpf(-0.22, 0.18, row_phase)
		row_offset += (row_phase - 0.5) * (target_along * (0.20 if civic_setts else 0.42))
		var along_min := along_origin - along_span * 0.5
		var column_index := floori((along_min + row_offset) / target_along) - 1
		var along_cursor := float(column_index) * target_along - row_offset - along_origin
		while along_cursor < along_span * 0.5 - 0.01:
			var stable := fposmod(sin(float(column_index + 1) * 12.9898 + float(row_index + 1) * 78.233 + region_phase * 37.719) * 43758.5453, 1.0)
			var secondary := fposmod(sin(float(column_index + 1) * 41.173 + float(row_index + 1) * 19.317 + region_phase * 91.37) * 23171.31, 1.0)
			var nominal_along := target_along * lerpf(0.76 if civic_setts else 0.66, 1.28 if civic_setts else 1.38, stable)
			var along_start := maxf(-along_span * 0.5, along_cursor)
			var along_end := minf(along_span * 0.5, along_cursor + nominal_along)
			if along_end - along_start < 0.10:
				along_cursor += nominal_along
				column_index += 1
				continue
			var joint := 0.028 if civic_setts else 0.052
			# The course generator owns the shared boundaries. Each sett fills its
			# irregular slot except for one narrow mortar joint, so the joint bed
			# cannot read as a broad rectangular backing plane.
			var stone_along := maxf(0.12, along_end - along_start - joint)
			var stone_cross := maxf(0.12, cross_end - cross_start - joint)
			var stone_height := maxf(0.07, size.y * lerpf(0.54, 0.78, secondary) if civic_setts else size.y * lerpf(0.50, 0.82, secondary))
			var along_center := (along_start + along_end) * 0.5
			var along_jitter := 0.0
			var cross_jitter := 0.0
			var x := along_center + along_jitter if runs_along_x else cross_center + cross_jitter
			var z := cross_center + cross_jitter if runs_along_x else along_center + along_jitter
			var world_position: Vector3 = part.position + Vector3(x, 0.0, z)
			var conditions: Dictionary = surface_history.conditions_at(world_position)
			var wear_contact: Dictionary = surface_history.wear_contact_at(world_position)
			var route_wear := float(wear_contact.get("influence", 0.0))
			var footprint_extent := Vector2(stone_along, stone_cross) * 0.5 if runs_along_x else Vector2(stone_cross, stone_along) * 0.5
			var root_contact: Dictionary = surface_history.root_buttress_contact(world_position, footprint_extent)
			var root_disturbance := float(root_contact.get("influence", 0.0))
			var root_direction: Vector3 = root_contact.get("direction", Vector3.ZERO) as Vector3
			var settlement := (stable - 0.5) * (0.012 if civic_setts else 0.040)
			settlement -= route_wear * 0.024
			settlement += root_disturbance * lerpf(0.055, 0.115, secondary)
			var y := size.y * 0.5 - stone_height * 0.48 + settlement
			var yaw := (secondary - 0.5) * deg_to_rad(3.0 if civic_setts else 7.0)
			if root_direction.length_squared() > 0.001:
				var root_yaw := atan2(-root_direction.z, root_direction.x) if runs_along_x else atan2(root_direction.x, root_direction.z)
				yaw = lerp_angle(yaw, root_yaw, root_disturbance * 0.68)
			var tilt := (stable - 0.5) * deg_to_rad(3.0 if civic_setts else 8.0)
			var stone_size := Vector3(stone_along, stone_height, stone_cross) if runs_along_x else Vector3(stone_cross, stone_height, stone_along)
			var basis := (Basis(Vector3.UP, yaw) * Basis(Vector3.FORWARD, tilt)).scaled(stone_size)
			var root_shift := Vector3.ZERO
			if root_direction.length_squared() > 0.001:
				var root_normal := Vector3(-root_direction.z, 0.0, root_direction.x).normalized()
				var side := 1.0 if float(root_contact.get("lateral", 0.0)) >= 0.0 else -1.0
				root_shift = root_normal * side * root_disturbance * lerpf(0.035, 0.095, secondary)
			var local_position := Vector3(x, y, z) + root_shift
			var transform := Transform3D(basis, local_position)
			var root_moisture := root_disturbance * (0.54 + secondary * 0.36)
			var canopy_deposit := float(conditions.get("canopyDeposit", 0.0))
			# INSTANCE_CUSTOM carries only typed surface-history facts: runoff,
			# route/threshold use, root disturbance and tree-canopy deposition.
			var route_lateral := float(wear_contact.get("lateral", 1.0))
			var custom := Color(0.0, pack_route_history(route_wear, route_lateral), clampf(root_moisture, 0.0, 1.0), clampf(canopy_deposit, 0.0, 1.0))
			if root_disturbance > 0.30 or route_wear > 0.58:
				worn_ids.append(Vector2i(row_index, column_index))
				worn_transforms.append(transform)
				worn_custom_data.append(custom)
			else:
				regular_ids.append(Vector2i(row_index, column_index))
				regular_transforms.append(transform)
				regular_custom_data.append(custom)
			along_cursor += nominal_along
			column_index += 1
		cross_cursor += nominal_cross
		row_index += 1
	return {"ready": true, "bed": bed,
		"regularTransforms": regular_transforms, "regularCustomData": regular_custom_data, "regularIds": regular_ids,
		"wornTransforms": worn_transforms, "wornCustomData": worn_custom_data, "wornIds": worn_ids}


static func pack_route_history(influence: float, lateral: float) -> float:
	var packed_strength := clampi(roundi(clampf(influence, 0.0, 1.0) * 15.0), 0, 15)
	var packed_lateral := clampi(roundi(clampf(lateral, 0.0, 1.0) * 15.0), 0, 15)
	return float(packed_strength * 16 + packed_lateral) / 255.0
