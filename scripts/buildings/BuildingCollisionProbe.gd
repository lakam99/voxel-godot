extends RefCounted
class_name BuildingCollisionProbe

const BuildingSurfaceFallProbeScript := preload("res://scripts/testing/buildings/BuildingSurfaceFallProbe.gd")

const SUPPORT_SEMANTICS := {
	"castle_keep_palace_entry_forecourt": true
}
const PLAYER_SETTLE_FRAMES := 42
const PLAYER_SWEEP_FRAMES := 210
const PLAYER_SURFACE_TOLERANCE := 0.28
const PLAYER_DOOR_INTERACTION_DISTANCE := 2.20
const CITADEL_WALKABLE_SURFACE_TOLERANCE := 0.02
const MAX_CITADEL_OVERLAY_SAMPLES_PER_REGION := 3
const CITADEL_WALKABLE_OVERLAY_SEMANTICS := {
	"castle_route_cobbled_module": true,
	"castle_route_pedestrian_margin": true,
	"castle_route_constructed_gutter": true
}
const CITADEL_SELF_COLLISION_SEMANTICS := {}
const CITADEL_OVERLAY_SUPPORT_SEMANTICS := {
	"castle_courtyard_foundation": true,
	"castle_courtyard_paving": true,
	"castle_route_terrace_walkway": true,
	"castle_route_junction": true
}
const CITADEL_FOUNDATION_SUPPORT_SEMANTICS := {
	"castle_courtyard_foundation": true,
	"castle_inhabited_terrace_block": true,
	"castle_residence_structural_plinth": true
}


static func audit_citadel_residence_foundation_supports(root: Node3D, parts: Array) -> Dictionary:
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	if root == null or root.get_world_3d() == null:
		return {"passed": false, "checkedFoundationCount": 0, "checkedSampleCount": 0, "checks": checks, "violations": ["missing_collision_world"]}
	var support_colliders := _citadel_foundation_support_colliders(root)
	for part in parts:
		if part == null or not bool(part.collision_enabled):
			continue
		var source_part_id := String(part.recipe.get("castleResidenceSourcePart", ""))
		if String(part.kind) != "foundation" or not String(part.semantic).begins_with("castle_courtyard_residence_"):
			continue
		var samples := _citadel_foundation_footprint_samples(root, part)
		var sample_checks: Array[Dictionary] = []
		for sample_value in samples:
			var sample: Dictionary = sample_value as Dictionary
			var support := _published_citadel_foundation_support_at(sample.get("position", Vector3.ZERO) as Vector3, support_colliders)
			sample_checks.append({
				"id": String(sample.get("id", "sample")),
				"position": sample.get("position", Vector3.ZERO),
				"support": support,
				"passed": not support.is_empty()
			})
		var check := {
			"partId": String(part.id),
			"sourcePartId": source_part_id,
			"publishedCollision": _has_published_part_collision(root, String(part.id)),
			"foundationBottomY": part.position.y - part.size.y * 0.5,
			"samples": sample_checks,
			"passed": _has_published_part_collision(root, String(part.id)) and sample_checks.all(func(sample: Dictionary) -> bool: return bool(sample.get("passed", false)))
		}
		if not bool(check.get("passed", false)):
			violations.append("%s has an uncovered published foundation footprint sample" % String(part.id))
		checks.append(check)
	return {
		"passed": not checks.is_empty() and violations.is_empty(),
		"checkedFoundationCount": checks.size(),
		"checkedSampleCount": checks.size() * 9,
		"checks": checks,
		"violations": violations
	}


static func audit_citadel_walkable_surface_collision(context: Node, player: CharacterBody3D, root: Node3D, parts: Array) -> Dictionary:
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	if context == null or player == null or root == null or root.get_world_3d() == null:
		return {"passed": false, "checkedSurfaceCount": 0, "checks": checks, "violations": ["missing_player_collision_world"]}
	var candidates: Array = []
	var sampled_overlay_counts: Dictionary = {}
	for part in parts:
		if part == null:
			continue
		var semantic := String(part.semantic)
		var overlay_surface := CITADEL_WALKABLE_OVERLAY_SEMANTICS.has(semantic)
		if overlay_surface:
			var overlay_region := String(part.recipe.get("pavingRegion", semantic))
			var overlay_key := "%s:%s" % [semantic, overlay_region]
			var sampled_count := int(sampled_overlay_counts.get(overlay_key, 0))
			if sampled_count >= MAX_CITADEL_OVERLAY_SAMPLES_PER_REGION:
				continue
			sampled_overlay_counts[overlay_key] = sampled_count + 1
		if overlay_surface or CITADEL_SELF_COLLISION_SEMANTICS.has(semantic) or bool(part.recipe.get("playerSurfaceAudit", false)):
			candidates.append(part)
	for part in candidates:
		var semantic := String(part.semantic)
		var surface := _top_surface_for_part(root, part)
		var query := PhysicsRayQueryParameters3D.create(surface + Vector3.UP * 0.20, surface - Vector3.UP * 0.62, 1)
		query.collide_with_areas = false
		var hit: Dictionary = root.get_world_3d().direct_space_state.intersect_ray(query)
		var hit_position: Vector3 = hit.get("position", Vector3.INF) as Vector3
		var hit_source := _part_collision_source_for_ray(hit)
		var source_part_id := String(hit_source.get("partId", ""))
		var source_semantic := String(hit_source.get("semantic", ""))
		var requires_self_collision := CITADEL_SELF_COLLISION_SEMANTICS.has(semantic) or bool(part.recipe.get("playerSurfaceAudit", false))
		var source_is_valid := source_part_id == String(part.id) if requires_self_collision else CITADEL_OVERLAY_SUPPORT_SEMANTICS.has(source_semantic)
		var ray_hits_surface := not hit.is_empty() and absf(hit_position.y - surface.y) <= CITADEL_WALKABLE_SURFACE_TOLERANCE
		var check := {
			"partId": String(part.id),
			"semantic": semantic,
			"sourceCollisionEnabled": bool(part.collision_enabled),
			"expectedSurfaceY": surface.y,
			"raySurfaceY": hit_position.y if not hit.is_empty() else INF,
			"rayShapeSource": hit_source,
			"requiresSelfCollision": requires_self_collision,
			"sourceIsValid": source_is_valid,
			"rayHitsSurface": ray_hits_surface,
			"playerProof": {},
			"passed": ray_hits_surface and source_is_valid
		}
		if requires_self_collision:
			var player_proof := await _settle_real_player_on_surface(context, player, root, surface, String(part.id), [String(part.id)])
			check["playerProof"] = player_proof
			check["passed"] = bool(check.get("passed", false)) and bool(player_proof.get("passed", false))
		if not bool(check.get("passed", false)):
			violations.append("%s has no attributable collision at its visible walkable surface" % String(part.id))
		checks.append(check)
	return {
		"passed": not checks.is_empty() and violations.is_empty(),
		"checkedSurfaceCount": checks.size(),
		"sampledOverlayCounts": sampled_overlay_counts,
		"overlaySampleLimitPerRegion": MAX_CITADEL_OVERLAY_SAMPLES_PER_REGION,
		"checks": checks,
		"violations": violations
	}


static func audit_keep_entry_supports(context: Node, root: Node3D, parts: Array) -> Dictionary:
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	if context == null or root == null or root.get_world_3d() == null:
		return {"passed": false, "checkedPartCount": 0, "checks": checks, "violations": ["missing_collision_world"]}
	var probes: Array[Dictionary] = []
	for part in parts:
		if part == null or not SUPPORT_SEMANTICS.has(String(part.semantic)):
			continue
		var expected_surface := _top_surface_for_part(root, part)
		var check := {
			"partId": String(part.id),
			"semantic": String(part.semantic),
			"sourceCollisionEnabled": bool(part.collision_enabled),
			"expectedSurfaceY": expected_surface.y,
			"rayHit": false,
			"raySurfaceY": INF,
			"motorBlocked": false
		}
		if not bool(part.collision_enabled):
			violations.append("%s has no source collision" % String(part.id))
			checks.append(check)
			continue
		var probe := CharacterBody3D.new()
		probe.collision_layer = 0
		probe.collision_mask = 1
		var collision := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.30
		capsule.height = 1.70
		collision.shape = capsule
		collision.position.y = capsule.height * 0.5
		probe.add_child(collision)
		root.add_child(probe)
		probe.global_position = expected_surface + Vector3.UP * 0.48
		probes.append({"probe": probe, "check": check, "expectedSurface": expected_surface})
	await context.get_tree().physics_frame
	for probe_record_value in probes:
		var probe_record: Dictionary = probe_record_value as Dictionary
		var probe := probe_record.get("probe") as CharacterBody3D
		var check: Dictionary = probe_record.get("check", {}) as Dictionary
		var expected_surface: Vector3 = probe_record.get("expectedSurface", Vector3.ZERO) as Vector3
		var query := PhysicsRayQueryParameters3D.create(expected_surface + Vector3.UP * 0.22, expected_surface - Vector3.UP * 0.55, 1)
		query.collide_with_areas = false
		var hit: Dictionary = root.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			var hit_position: Vector3 = hit.get("position", Vector3.ZERO) as Vector3
			var source_candidates := _part_collision_candidates_at_contact(root, hit_position)
			var hit_source := _part_collision_source_for_ray(hit)
			var source_matched := String(hit_source.get("partId", "")) == String(check.get("partId", ""))
			check["rayHit"] = absf(hit_position.y - expected_surface.y) <= 0.08 and source_matched
			check["raySurfaceY"] = hit_position.y
			check["rayCollider"] = String((hit.get("collider") as Node).name) if hit.get("collider") is Node else ""
			check["rayShapeSource"] = hit_source
			check["sourceCandidates"] = source_candidates
			check["sourceMatched"] = source_matched
		if probe != null and is_instance_valid(probe):
			check["motorBlocked"] = probe.test_move(probe.global_transform, Vector3.DOWN * 0.72)
			probe.queue_free()
		if not bool(check.get("rayHit", false)):
			violations.append("%s has no collision at its visible top surface" % String(check.get("partId", "support")))
		if not bool(check.get("motorBlocked", false)):
			violations.append("%s does not block a descending CharacterBody3D" % String(check.get("partId", "support")))
		checks.append(check)
	return {
		"passed": not checks.is_empty() and violations.is_empty(),
		"checkedPartCount": checks.size(),
		"checks": checks,
		"violations": violations
	}


static func audit_citadel_raised_route_roadbeds(context: Node, root: Node3D, parts: Array, route_coverage_records: Array = []) -> Dictionary:
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	if context == null or root == null or root.get_world_3d() == null:
		return {"passed": false, "checkedRoadbedCount": 0, "checks": checks, "violations": ["missing_collision_world"]}
	var courtyard_foundations: Array = []
	var roadbeds: Array = []
	for part in parts:
		if part == null:
			continue
		if String(part.semantic) == "castle_courtyard_foundation":
			courtyard_foundations.append(part)
		elif String(part.semantic) in ["castle_route_terrace_walkway", "castle_route_junction"]:
			roadbeds.append(part)
	if courtyard_foundations.is_empty():
		return {"passed": false, "checkedRoadbedCount": roadbeds.size(), "checks": checks, "violations": ["missing_castle_courtyard_foundation"]}
	if roadbeds.is_empty():
		return {"passed": false, "checkedRoadbedCount": 0, "checks": checks, "violations": ["missing_raised_route_roadbeds"]}
	for roadbed in roadbeds:
		var bottom := root.to_global(roadbed.position - Vector3.UP * roadbed.size.y * 0.5)
		var surface := _top_surface_for_part(root, roadbed)
		var underside_support_samples: Array[Dictionary] = []
		for x_fraction in [-0.5, 0.0, 0.5]:
			for z_fraction in [-0.5, 0.0, 0.5]:
				var sample_bottom := root.to_global(roadbed.position + Vector3(roadbed.size.x * float(x_fraction), -roadbed.size.y * 0.5, roadbed.size.z * float(z_fraction)))
				var sample_support := _courtyard_foundation_support_at(root, sample_bottom, courtyard_foundations)
				var sample_surface: Vector3 = sample_support.get("surface", Vector3.INF) as Vector3
				underside_support_samples.append({"position": sample_bottom, "courtyardSupport": sample_support, "continuous": not sample_support.is_empty() and absf(sample_bottom.y - sample_surface.y) <= 0.04})
		var courtyard_support := _courtyard_foundation_support_at(root, bottom, courtyard_foundations)
		var courtyard_top: Vector3 = courtyard_support.get("surface", Vector3.INF) as Vector3
		var check := {
			"partId": String(roadbed.id),
			"semantic": String(roadbed.semantic),
			"collisionEnabled": bool(roadbed.collision_enabled),
			"courtyardTopY": courtyard_top.y,
			"roadbedBottomY": bottom.y,
			"expectedSurfaceY": surface.y,
			"courtyardSupport": courtyard_support,
			"undersideSupportSamples": underside_support_samples,
			"continuousFromCourtyard": underside_support_samples.all(func(sample: Dictionary) -> bool: return bool(sample.get("continuous", false))),
			"rayHit": false,
			"motorBlocked": false
		}
		if not bool(roadbed.collision_enabled):
			violations.append("%s has no source collision" % String(roadbed.id))
			checks.append(check)
			continue
		var probe := CharacterBody3D.new()
		probe.collision_layer = 0
		probe.collision_mask = 1
		var collision := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.30
		capsule.height = 1.70
		collision.shape = capsule
		collision.position.y = capsule.height * 0.5
		probe.add_child(collision)
		root.add_child(probe)
		probe.global_position = surface + Vector3.UP * 0.48
		await context.get_tree().physics_frame
		var query := PhysicsRayQueryParameters3D.create(surface + Vector3.UP * 0.22, surface - Vector3.UP * 0.55, 1)
		query.collide_with_areas = false
		var hit: Dictionary = root.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			var hit_position: Vector3 = hit.get("position", Vector3.ZERO) as Vector3
			var hit_source := _part_collision_source_for_ray(hit)
			var source_is_route_roadbed := String(hit_source.get("semantic", "")) in ["castle_route_terrace_walkway", "castle_route_junction"]
			check["rayHit"] = absf(hit_position.y - surface.y) <= 0.08 and source_is_route_roadbed
			check["raySurfaceY"] = hit_position.y
			check["rayShapeSource"] = hit_source
			check["sourceIsRouteRoadbed"] = source_is_route_roadbed
		check["motorBlocked"] = probe.test_move(probe.global_transform, Vector3.DOWN * 0.72)
		probe.queue_free()
		if not bool(check.get("continuousFromCourtyard", false)):
			violations.append("%s does not meet the courtyard foundation" % String(roadbed.id))
		if not bool(check.get("rayHit", false)):
			violations.append("%s has no attributable collision at its top surface" % String(roadbed.id))
		if not bool(check.get("motorBlocked", false)):
			violations.append("%s does not block a descending CharacterBody3D" % String(roadbed.id))
		checks.append(check)
	var route_record_coverage := await audit_raised_route_record_collision(context, root, route_coverage_records)
	if not bool(route_record_coverage.get("passed", false)):
		violations.append_array(route_record_coverage.get("violations", []) as Array)
	return {
		"passed": violations.is_empty(),
		"checkedRoadbedCount": checks.size(),
		"checks": checks,
		"routeRecordCoverage": route_record_coverage,
		"violations": violations
	}


static func audit_raised_route_record_collision(context: Node, root: Node3D, route_coverage_records: Array) -> Dictionary:
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	if route_coverage_records.is_empty():
		return {"passed": false, "checkedSampleCount": 0, "checks": checks, "violations": ["missing_source_raised_route_coverage"]}
	if context == null or root == null or root.get_world_3d() == null:
		return {"passed": false, "checkedSampleCount": 0, "checks": checks, "violations": ["missing_collision_world"]}
	for coverage_value in route_coverage_records:
		if not coverage_value is Dictionary:
			violations.append("invalid_source_raised_route_coverage_record")
			continue
		var coverage: Dictionary = coverage_value as Dictionary
		var street_id := String(coverage.get("streetId", ""))
		if not bool(coverage.get("passed", false)):
			violations.append("%s source raised-route coverage is incomplete" % street_id)
			continue
		var roadbed_sample_id := String(coverage.get("handoffRoadbedSampleId", ""))
		var transition_sample_id := String(coverage.get("handoffTransitionSampleId", ""))
		for sample_value in coverage.get("samples", []) as Array:
			if not sample_value is Dictionary:
				violations.append("%s has an invalid source sample" % street_id)
				continue
			var sample: Dictionary = sample_value as Dictionary
			var local_position: Vector3 = sample.get("position", Vector3.ZERO) as Vector3
			var expected_surface := root.to_global(Vector3(local_position.x, float(sample.get("ownerTopY", local_position.y)), local_position.z))
			var owner_id := String(sample.get("ownerId", ""))
			var boundary_contact := bool(sample.get("boundaryContact", false))
			var boundary_owner_ids: Array = sample.get("boundaryOwnerIds", []) as Array
			var foundation_support_id := String(sample.get("foundationSupportId", ""))
			var root_support_id := String(sample.get("rootSupportId", ""))
			var owner_collision := published_collision_shape_state(root, owner_id)
			var support_collision := published_collision_shape_state(root, root_support_id)
			var check := {
				"streetId": street_id,
				"sampleId": String(sample.get("id", "")),
				"ownerId": owner_id,
				"ownerSemantic": String(sample.get("ownerSemantic", "")),
				"boundaryContact": boundary_contact,
				"boundaryOwnerIds": boundary_owner_ids,
				"foundationSupportId": foundation_support_id,
				"rootSupportId": root_support_id,
				"expectedSurface": expected_surface,
				"seamHeight": float(sample.get("seamHeight", 0.0)),
				"ownerCollision": owner_collision,
				"foundationCollision": support_collision,
				"rayHit": false,
				"motorBlocked": false
			}
			var probe := CharacterBody3D.new()
			probe.collision_layer = 0
			probe.collision_mask = 1
			var probe_collision := CollisionShape3D.new()
			var capsule := CapsuleShape3D.new()
			capsule.radius = 0.30
			capsule.height = 1.70
			probe_collision.shape = capsule
			probe_collision.position.y = capsule.height * 0.5
			probe.add_child(probe_collision)
			root.add_child(probe)
			probe.global_position = expected_surface + Vector3.UP * 0.48
			await context.get_tree().physics_frame
			var query := PhysicsRayQueryParameters3D.create(expected_surface + Vector3.UP * 0.24, expected_surface - Vector3.UP * 0.55, 1)
			query.collide_with_areas = false
			var hit: Dictionary = root.get_world_3d().direct_space_state.intersect_ray(query)
			if not hit.is_empty():
				var hit_position: Vector3 = hit.get("position", Vector3.INF) as Vector3
				var hit_source := _part_collision_source_for_ray(hit)
				var hit_owner_id := String(hit_source.get("partId", ""))
				var matching_owner := boundary_owner_ids.has(hit_owner_id) if boundary_contact else hit_owner_id == owner_id
				check["rayHit"] = absf(hit_position.y - expected_surface.y) <= 0.08 and matching_owner
				check["raySurface"] = hit_position
				check["rayShapeSource"] = hit_source
			check["motorBlocked"] = probe.test_move(probe.global_transform, Vector3.DOWN * 0.72)
			probe.queue_free()
			var passed := bool(sample.get("passed", false)) and bool(owner_collision.get("enabled", false)) and bool(support_collision.get("enabled", false)) and bool(check.get("rayHit", false)) and bool(check.get("motorBlocked", false))
			check["passed"] = passed
			if not passed:
				violations.append("%s/%s lacks its named published route collision chain" % [street_id, String(sample.get("id", ""))])
			checks.append(check)
		var junction_seams: Dictionary = coverage.get("junctionSeams", {}) as Dictionary
		var seam_collision := await audit_raised_route_junction_seam_collision(context, root, street_id, junction_seams)
		checks.append_array(seam_collision.get("checks", []) as Array)
		violations.append_array(seam_collision.get("violations", []) as Array)
		var handoff_collision := await audit_raised_route_handoff_collision(context, root, street_id, coverage.get("handoffSeam", {}) as Dictionary)
		checks.append_array(handoff_collision.get("checks", []) as Array)
		violations.append_array(handoff_collision.get("violations", []) as Array)
	return {"passed": not checks.is_empty() and violations.is_empty(), "checkedSampleCount": checks.size(), "checks": checks, "violations": violations}


static func audit_raised_route_junction_seam_collision(context: Node, root: Node3D, street_id: String, junction_seams: Dictionary) -> Dictionary:
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	if junction_seams.is_empty():
		return {"passed": true, "checks": checks, "violations": violations}
	if not bool(junction_seams.get("passed", false)):
		return {"passed": false, "checks": checks, "violations": ["%s source junction seams are incomplete" % street_id]}
	for pair_value in junction_seams.get("pairs", []) as Array:
		if not pair_value is Dictionary:
			violations.append("%s has an invalid declared junction seam pair" % street_id)
			continue
		var pair: Dictionary = pair_value as Dictionary
		var pair_id := String(pair.get("id", ""))
		for side_name in ["roadbed", "junction"]:
			var side: Dictionary = pair.get(side_name, {}) as Dictionary
			var check := await audit_raised_route_handoff_side_collision(context, root, street_id, "%s_%s" % [pair_id, side_name], 0.0, side)
			check["junctionSeamId"] = pair_id
			check["junctionSeamSide"] = side_name
			if not bool(check.get("passed", false)):
				violations.append("%s/%s lacks exact named published collision evidence" % [pair_id, side_name])
			checks.append(check)
		var gap_valid := float(pair.get("gap", INF)) <= float(pair.get("gapLimit", 0.01)) and float(pair.get("heightDelta", INF)) <= float(pair.get("heightLimit", 0.01))
		if not gap_valid:
			violations.append("%s exceeds the declared roadbed-to-junction seam tolerance" % pair_id)
	return {"passed": violations.is_empty(), "checks": checks, "violations": violations}


static func audit_raised_route_handoff_collision(context: Node, root: Node3D, street_id: String, handoff: Dictionary) -> Dictionary:
	if not bool(handoff.get("declared", false)):
		return {"passed": true, "checks": [], "violations": []}
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	var lane_records: Array = handoff.get("lanes", []) as Array
	if lane_records.is_empty():
		lane_records.append({"offset": 0.0, "roadbed": handoff.get("roadbed", {}), "transition": handoff.get("transition", {})})
	for lane_index in range(lane_records.size()):
		var lane: Dictionary = lane_records[lane_index] as Dictionary
		for side_name in ["roadbed", "transition"]:
			var side: Dictionary = lane.get(side_name, {}) as Dictionary
			var sample_id := "%s_handoff_%s" % [street_id, side_name] if absf(float(lane.get("offset", 0.0))) <= 0.001 else "%s_handoff_%s_lane_%d" % [street_id, side_name, lane_index]
			var check := await audit_raised_route_handoff_side_collision(context, root, street_id, sample_id, float(lane.get("offset", 0.0)), side)
			if not bool(check.get("passed", false)):
				violations.append("%s/%s lacks collision-backed published handoff evidence" % [street_id, side_name])
			checks.append(check)
	return {"passed": violations.is_empty(), "checks": checks, "violations": violations}


static func audit_raised_route_handoff_side_collision(context: Node, root: Node3D, street_id: String, sample_id: String, lane_offset: float, side: Dictionary) -> Dictionary:
	var local_position: Vector3 = side.get("position", Vector3.ZERO) as Vector3
	var expected_surface := root.to_global(Vector3(local_position.x, float(side.get("topY", local_position.y)), local_position.z))
	var owner_id := String(side.get("ownerId", ""))
	var root_id := String(side.get("rootSupportId", ""))
	var check := {"streetId": street_id, "sampleId": sample_id, "laneOffset": lane_offset, "ownerId": owner_id, "rootSupportId": root_id, "expectedSurface": expected_surface, "ownerCollision": published_collision_shape_state(root, owner_id), "rootCollision": published_collision_shape_state(root, root_id), "rayHit": false, "motorBlocked": false}
	var probe := CharacterBody3D.new()
	probe.collision_layer = 0
	probe.collision_mask = 1
	var probe_collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.30
	capsule.height = 1.70
	probe_collision.shape = capsule
	probe_collision.position.y = capsule.height * 0.5
	probe.add_child(probe_collision)
	root.add_child(probe)
	probe.global_position = expected_surface + Vector3.UP * 0.48
	await context.get_tree().physics_frame
	var query := PhysicsRayQueryParameters3D.create(expected_surface + Vector3.UP * 0.24, expected_surface - Vector3.UP * 0.55, 1)
	query.collide_with_areas = false
	var hit: Dictionary = root.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var hit_position: Vector3 = hit.get("position", Vector3.INF) as Vector3
		var hit_source := _part_collision_source_for_ray(hit)
		check["rayHit"] = absf(hit_position.y - expected_surface.y) <= 0.08 and String(hit_source.get("partId", "")) == owner_id
		check["rayShapeSource"] = hit_source
	check["motorBlocked"] = probe.test_move(probe.global_transform, Vector3.DOWN * 0.72)
	probe.queue_free()
	check["passed"] = bool(side.get("passed", false)) and bool((check.get("ownerCollision", {}) as Dictionary).get("enabled", false)) and bool((check.get("rootCollision", {}) as Dictionary).get("enabled", false)) and bool(check.get("rayHit", false)) and bool(check.get("motorBlocked", false))
	return check


static func published_collision_shape_state(root: Node3D, part_id: String) -> Dictionary:
	if root == null or part_id.is_empty():
		return {"partId": part_id, "enabled": false, "shapeCount": 0}
	var shape_count := 0
	var enabled_count := 0
	for collision_node_value in root.find_children("*", "CollisionShape3D", true, false):
		var collision_node := collision_node_value as CollisionShape3D
		if collision_node == null or String(collision_node.get_meta("building_part_id", "")) != part_id:
			continue
		shape_count += 1
		if not collision_node.disabled:
			enabled_count += 1
	return {"partId": part_id, "enabled": enabled_count > 0, "shapeCount": shape_count, "enabledShapeCount": enabled_count}


static func audit_raised_route_collision_negative_controls(context: Node, player: CharacterBody3D, root: Node3D, parts: Array, route_coverage_records: Array) -> Dictionary:
	var route_sample: Dictionary = {}
	var transition_sample: Dictionary = {}
	for coverage_value in route_coverage_records:
		if not coverage_value is Dictionary:
			continue
		var coverage: Dictionary = coverage_value as Dictionary
		if not String(coverage.get("streetId", "")).contains("processional_04b"):
			continue
		var handoff: Dictionary = coverage.get("handoffSeam", {}) as Dictionary
		var roadbed: Dictionary = handoff.get("roadbed", {}) as Dictionary
		var transition: Dictionary = handoff.get("transition", {}) as Dictionary
		if bool(roadbed.get("passed", false)):
			route_sample = roadbed.duplicate(true)
			route_sample["streetId"] = String(coverage.get("streetId", ""))
			route_sample["id"] = "%s_handoff_roadbed" % String(coverage.get("streetId", ""))
		if bool(transition.get("passed", false)):
			transition_sample = transition.duplicate(true)
			transition_sample["streetId"] = String(coverage.get("streetId", ""))
			transition_sample["id"] = "%s_handoff_transition" % String(coverage.get("streetId", ""))
		break
	var route_support_id := String(route_sample.get("foundationSupportId", ""))
	if route_support_id.is_empty():
		route_support_id = String(route_sample.get("rootSupportId", ""))
	var foundation_control := await audit_disabled_route_collision_shape(context, root, route_coverage_records, route_sample, route_support_id, "processional_04b_named_root")
	var transition_control := await audit_disabled_route_collision_shape(context, root, route_coverage_records, transition_sample, String(transition_sample.get("rootSupportId", "")), "keep_entry_transition_root")
	var player_transition_failure := {}
	if bool(transition_control.get("disabledAuditFailedExactSample", false)):
		var transition_shapes := collision_shapes_for_part(root, String(transition_sample.get("ownerId", "")))
		var prior_disabled: Array[bool] = []
		for shape in transition_shapes:
			prior_disabled.append(shape.disabled)
			shape.disabled = true
		await context.get_tree().physics_frame
		player_transition_failure = await audit_player_raised_route_transition_handoff(context, player, root, route_coverage_records)
		for index in range(transition_shapes.size()):
			transition_shapes[index].disabled = prior_disabled[index]
		await context.get_tree().physics_frame
	var player_sweep_failed := not bool(player_transition_failure.get("passed", true))
	transition_control["playerSweep"] = player_transition_failure
	transition_control["playerSweepFailed"] = player_sweep_failed
	transition_control["passed"] = bool(transition_control.get("passed", false)) and player_sweep_failed
	return {
		"passed": bool(foundation_control.get("passed", false)) and bool(transition_control.get("passed", false)),
		"foundationSupportDisabled": foundation_control,
		"keepEntryTransitionDisabled": transition_control
	}


static func audit_disabled_route_collision_shape(context: Node, root: Node3D, route_coverage_records: Array, sample: Dictionary, part_id: String, control_name: String) -> Dictionary:
	if sample.is_empty() or part_id.is_empty():
		return {"passed": false, "control": control_name, "reason": "missing_target_source_sample", "sample": sample, "partId": part_id}
	var shapes := collision_shapes_for_part(root, part_id)
	if shapes.is_empty():
		return {"passed": false, "control": control_name, "reason": "missing_published_collision_shape", "sample": sample, "partId": part_id}
	var prior_disabled: Array[bool] = []
	for shape in shapes:
		prior_disabled.append(shape.disabled)
		shape.disabled = true
	await context.get_tree().physics_frame
	var corrupted := await audit_raised_route_record_collision(context, root, route_coverage_records)
	for index in range(shapes.size()):
		shapes[index].disabled = prior_disabled[index]
	await context.get_tree().physics_frame
	var exact_sample_failed := false
	var street_id := String(sample.get("streetId", ""))
	var sample_id := String(sample.get("id", ""))
	for check_value in corrupted.get("checks", []) as Array:
		var check: Dictionary = check_value as Dictionary
		if String(check.get("streetId", "")) == street_id and String(check.get("sampleId", "")) == sample_id:
			exact_sample_failed = not bool(check.get("passed", true))
			break
	return {
		"passed": not bool(corrupted.get("passed", true)) and exact_sample_failed,
		"control": control_name,
		"partId": part_id,
		"streetId": street_id,
		"sampleId": sample_id,
		"disabledAudit": corrupted,
		"disabledAuditFailedExactSample": exact_sample_failed
	}


static func collision_shapes_for_part(root: Node3D, part_id: String) -> Array[CollisionShape3D]:
	var shapes: Array[CollisionShape3D] = []
	if root == null or part_id.is_empty():
		return shapes
	for collision_node_value in root.find_children("*", "CollisionShape3D", true, false):
		var collision_node := collision_node_value as CollisionShape3D
		if collision_node != null and String(collision_node.get_meta("building_part_id", "")) == part_id:
			shapes.append(collision_node)
	return shapes


static func _courtyard_foundation_support_at(root: Node3D, position: Vector3, foundations: Array) -> Dictionary:
	for foundation in foundations:
		if foundation == null:
			continue
		var transform := Transform3D(Basis.from_euler(foundation.rotation), foundation.position)
		var local := transform.affine_inverse() * root.to_local(position)
		var half: Vector3 = foundation.size * 0.5
		if absf(local.x) > half.x - 0.015 or absf(local.z) > half.z - 0.015:
			continue
		var surface := root.to_global(transform * Vector3(local.x, half.y, local.z))
		return {"partId": String(foundation.id), "semantic": String(foundation.semantic), "surface": surface}
	return {}


static func audit_player_keep_entry_sweep(context: Node, player: CharacterBody3D, root: Node3D, parts: Array) -> Dictionary:
	for part in parts:
		if part != null and String(part.semantic) == "castle_keep_palace_entry_forecourt":
			return await audit_player_keep_entry_forecourt_sweep(context, player, root, part, parts)
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	if context == null or player == null or root == null or root.get_world_3d() == null:
		return {"passed": false, "checks": checks, "violations": ["missing_player_collision_world"]}
	var steps: Array[Dictionary] = []
	var ramp = null
	for part in parts:
		if part == null:
			continue
		if String(part.semantic) == "castle_keep_palace_entry_ramp":
			ramp = part
		if String(part.semantic) != "castle_keep_palace_axial_entry_step":
			continue
		steps.append({
			"id": String(part.id),
			"position": root.to_global(part.position),
			"surface": root.to_global(part.position + Vector3.UP * part.size.y * 0.5),
			"width": part.size.x,
			"depth": part.size.z
		})
	steps.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return (left.get("position", Vector3.ZERO) as Vector3).z < (right.get("position", Vector3.ZERO) as Vector3).z
	)
	if steps.size() < 2 or ramp == null:
		return {"passed": false, "checks": checks, "violations": ["missing_axial_keep_entry_steps"]}
	var ramp_transform := Transform3D(Basis.from_euler(ramp.rotation), ramp.position)
	var ramp_start := root.to_global(ramp_transform * Vector3(0.0, ramp.size.y * 0.5, -ramp.size.z * 0.44))
	var ramp_center := root.to_global(ramp_transform * Vector3(0.0, ramp.size.y * 0.5, 0.0))
	var ramp_finish := root.to_global(ramp_transform * Vector3(0.0, ramp.size.y * 0.5, ramp.size.z * 0.44))
	var first: Dictionary = steps.front() as Dictionary
	var side_offset := minf(ramp.size.x * 0.32, 0.55)
	var sample_specs := player_surface_samples(root, parts, ramp_center, ramp_finish, side_offset)
	var surface_probe_result := await audit_surface_fall_probes(context, player, root, sample_specs)
	checks.append_array(surface_probe_result.get("checks", []) as Array)
	violations.append_array(surface_probe_result.get("violations", []) as Array)
	var exposed_expected := int(surface_probe_result.get("exposedExpected", 0))
	var exposed_verified := int(surface_probe_result.get("exposedVerified", 0))
	var not_exposed: Array = surface_probe_result.get("notExposed", []) as Array
	var probe_interference_count := int(surface_probe_result.get("probeInterferenceCount", 0))
	if sample_specs.size() != exposed_expected + not_exposed.size() + checks.filter(func(check_value) -> bool: return String((check_value as Dictionary).get("failureReason", "")) == "missing_or_ambiguous_top_collision").size():
		violations.append("keep entry surface accounting did not cover every requested sample")
	if exposed_verified != exposed_expected:
		violations.append("keep entry exposed surface probes did not all verify")
	if not not_exposed.is_empty():
		violations.append("keep entry samples were covered by undeclared collision")
	if probe_interference_count != 0:
		violations.append("keep entry fall probes interfered with one another")
	var sweep_start: Vector3 = ramp_start
	var sweep_finish: Vector3 = ramp_finish
	var sweep_direction := sweep_finish - sweep_start
	sweep_direction.y = 0.0
	if sweep_direction.length_squared() <= 0.01:
		violations.append("keep_entry_step_axis_is_degenerate")
	else:
		player.global_position = sweep_start + Vector3.UP * 2.20
		player.velocity = Vector3.ZERO
		player.set("automated_input", true)
		player.set("automated_sprint", false)
		player.set("automated_move", Vector3.ZERO)
		for _frame in range(PLAYER_SETTLE_FRAMES):
			await context.get_tree().physics_frame
		var settled_position := player.global_position
		player.set("automated_move", sweep_direction.normalized())
		var grounded_frames := 0
		var minimum_y := INF
		var maximum_progress := 0.0
		var seam_crossings: Array[Dictionary] = []
		var last_slide_contact: Dictionary = {}
		var seam_indices := {}
		for step_index in range(1, steps.size()):
			var threshold: Vector3 = (steps[step_index] as Dictionary).get("surface", Vector3.ZERO) as Vector3
			seam_indices[step_index] = threshold.z
		for frame in range(PLAYER_SWEEP_FRAMES):
			await context.get_tree().physics_frame
			var current := player.global_position
			minimum_y = minf(minimum_y, current.y)
			if player.is_on_floor():
				grounded_frames += 1
			var progress := (current - settled_position).dot(sweep_direction.normalized())
			maximum_progress = maxf(maximum_progress, progress)
			if player.get_slide_collision_count() > 0:
				var collision := player.get_slide_collision(0)
				var collider = collision.get_collider() if collision != null else null
				var contact_position := collision.get_position() if collision != null else Vector3.ZERO
				last_slide_contact = {
					"frame": frame,
					"collider": String((collider as Node).name) if collider is Node else str(collider),
					"normal": collision.get_normal() if collision != null else Vector3.ZERO,
					"position": contact_position,
					"partCandidates": _part_collision_candidates_at_contact(root, contact_position)
				}
			for seam_index_value in seam_indices.keys():
				var seam_index := int(seam_index_value)
				if seam_crossings.any(func(entry: Dictionary) -> bool: return int(entry.get("index", -1)) == seam_index):
					continue
				if current.z >= float(seam_indices.get(seam_index, INF)) - 0.08:
					seam_crossings.append({"index": seam_index, "frame": frame, "position": current, "grounded": player.is_on_floor()})
			if maximum_progress >= sweep_direction.length() + 0.20:
				break
		player.set("automated_move", Vector3.ZERO)
		player.set("automated_input", false)
		var sweep := {
			"id": "entry_step_continuous_sweep",
			"start": settled_position,
			"finish": player.global_position,
			"requiredDistance": sweep_direction.length(),
			"maximumProgress": maximum_progress,
			"groundedFrames": grounded_frames,
				"minimumY": minimum_y,
				"seamCrossings": seam_crossings,
				"lastSlideContact": last_slide_contact,
				"playerVelocity": player.velocity,
				"playerTerrainGrounded": bool(player.get("terrain_grounded")),
			"terrainCollisionHold": bool(player.get_meta("terrain_collision_hold", false)),
			"terrainCollisionHoldReason": String(player.get_meta("terrain_collision_hold_reason", "")),
			"terrainCollisionHoldFrames": int(player.get("terrain_collision_hold_frames")),
			"lastTerrainCollisionProof": (player.get("last_terrain_collision_proof") as Dictionary).duplicate(true) if player.get("last_terrain_collision_proof") is Dictionary else {},
			"passed": maximum_progress >= sweep_direction.length() - 0.20 and grounded_frames >= 18 and seam_crossings.size() == steps.size() - 1
		}
		checks.append(sweep)
		if not bool(sweep.get("passed", false)):
			violations.append("player did not complete a grounded crossing of the keep entry steps")
	var edge_sweeps := await _audit_player_keep_entry_side_sweeps(context, player, root, ramp_transform, ramp, steps)
	checks.append(edge_sweeps)
	if not bool(edge_sweeps.get("passed", false)):
		violations.append("player did not complete grounded side-lane crossings of the keep entry steps")
	var apron_seams := await _audit_player_keep_entry_apron_seams(context, player, root, parts)
	checks.append(apron_seams)
	if not bool(apron_seams.get("passed", false)):
		violations.append("player did not remain grounded across the keep entry step-apron seams")
	return {
		"passed": violations.is_empty(),
		"checks": checks,
		"violations": violations,
		"sampleCount": sample_specs.size(),
		"exposedExpected": exposed_expected,
		"exposedVerified": exposed_verified,
		"notExposed": not_exposed,
		"probeInterferenceCount": probe_interference_count,
		"residualProbeCount": int(surface_probe_result.get("residualProbeCount", 0))
	}


static func audit_player_keep_entry_forecourt_sweep(context: Node, player: CharacterBody3D, root: Node3D, forecourt, parts: Array) -> Dictionary:
	if context == null or player == null or root == null or root.get_world_3d() == null:
		return {"passed": false, "checks": [], "violations": ["missing_player_collision_world"]}
	var threshold_id := String(forecourt.recipe.get("interiorTransitionPartId", ""))
	var door_part_id := String(forecourt.recipe.get("interiorDoorPartId", ""))
	var threshold = null
	for part in parts:
		if part != null and String(part.id) == threshold_id:
			threshold = part
			break
	if threshold == null:
		return {"passed": false, "checks": [], "violations": ["missing_keep_entry_interior_transition"]}
	var door := _published_part_body(root, door_part_id)
	if door == null:
		return {"passed": false, "checks": [], "violations": ["missing_published_keep_entry_door"]}
	var transform := Transform3D(Basis.from_euler(forecourt.rotation), forecourt.position)
	var threshold_transform := Transform3D(Basis.from_euler(threshold.rotation), threshold.position)
	var traversal_half_width := float(forecourt.recipe.get("playerTraversalHalfWidth", forecourt.size.x * 0.34))
	var lateral_offset := minf(traversal_half_width, minf(forecourt.size.x * 0.5 - 0.40, threshold.size.x * 0.5 - 0.36))
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	var surface_probes := await audit_surface_fall_probes(context, player, root, player_surface_samples(root, parts, root.to_global(transform * Vector3(0.0, forecourt.size.y * 0.5, 0.0)), root.to_global(transform * Vector3(0.0, forecourt.size.y * 0.5, forecourt.size.z * 0.40)), lateral_offset))
	checks.append_array(surface_probes.get("checks", []) as Array)
	violations.append_array(surface_probes.get("violations", []) as Array)
	var lanes: Array[Dictionary] = []
	for lane_offset in [-lateral_offset, 0.0, lateral_offset]:
		var start := root.to_global(transform * Vector3(lane_offset, forecourt.size.y * 0.5, forecourt.size.z * 0.28))
		var finish := root.to_global(threshold_transform * Vector3(lane_offset, threshold.size.y * 0.5, 0.0))
		var start_evidence := await _settle_real_player_on_surface(context, player, root, start, "keep_forecourt_lane_start", [String(forecourt.id)])
		var settled := player.global_position
		var direction := finish - settled
		direction.y = 0.0
		if direction.length_squared() <= 0.01:
			lanes.append({"laneOffset": lane_offset, "passed": false, "violations": ["degenerate_forecourt_lane"]})
			continue
		var required_distance := direction.length()
		var normalized_direction := direction.normalized()
		var sweep_frame_budget := maxi(PLAYER_SWEEP_FRAMES, ceili((required_distance + 0.20) / 0.025))
		player.set("automated_input", true)
		player.set("automated_sprint", true)
		player.set("automated_move", normalized_direction)
		var grounded_frames := 0
		var airborne_frames := 0
		var maximum_progress := 0.0
		var door_interaction := {"passed": bool(door.get_meta("open", false)), "reason": "already_open" if bool(door.get_meta("open", false)) else "pending"}
		for _frame in range(sweep_frame_budget):
			await context.get_tree().physics_frame
			if player.is_on_floor():
				grounded_frames += 1
			else:
				airborne_frames += 1
			maximum_progress = maxf(maximum_progress, (player.global_position - settled).dot(normalized_direction))
			if not bool(door_interaction.get("passed", false)) and flat_distance(player.global_position, door.global_position) <= PLAYER_DOOR_INTERACTION_DISTANCE:
				player.set("automated_move", Vector3.ZERO)
				await _settle_player_after_automated_move(context)
				door_interaction = await _open_door_with_live_player_input(context, player, door)
				if not bool(door_interaction.get("passed", false)):
					break
				player.set("automated_move", normalized_direction)
			if maximum_progress >= required_distance + 0.12:
				break
		player.set("automated_move", Vector3.ZERO)
		player.set("automated_input", false)
		await _settle_player_after_automated_move(context)
		var end_source := _surface_exposure(root, player.global_position, String(threshold.id), player)
		var end_contained := player_is_within_part_inset(root, player, threshold, 0.32)
		var passed := bool(start_evidence.get("passed", false)) and bool(door_interaction.get("passed", false)) and maximum_progress >= required_distance - 0.14 and grounded_frames >= 12 and airborne_frames == 0 and end_contained and bool(end_source.get("exposed", false))
		lanes.append({"laneOffset": lane_offset, "start": start_evidence, "finish": player.global_position, "expectedTransitionPartId": String(threshold.id), "requiredDistance": required_distance, "maximumProgress": maximum_progress, "groundedFrames": grounded_frames, "airborneFrames": airborne_frames, "doorInteraction": door_interaction, "endContained": end_contained, "endSource": end_source, "passed": passed})
	var passed := lanes.size() == 3 and lanes.all(func(lane: Dictionary) -> bool: return bool(lane.get("passed", false))) and violations.is_empty()
	return {"passed": passed, "checks": checks, "lanes": lanes, "violations": violations if not passed else [], "sampleCount": int(surface_probes.get("checks", []).size())}


static func audit_player_raised_route_transition_handoff(context: Node, player: CharacterBody3D, root: Node3D, route_coverage_records: Array) -> Dictionary:
	var lanes: Array = []
	for coverage_value in route_coverage_records:
		if not coverage_value is Dictionary or not String((coverage_value as Dictionary).get("streetId", "")).contains("processional_04b"):
			continue
		var coverage: Dictionary = coverage_value as Dictionary
		var handoff: Dictionary = coverage.get("handoffSeam", {}) as Dictionary
		lanes = handoff.get("lanes", []) as Array
		if lanes.is_empty():
			lanes.append({"offset": 0.0, "roadbed": handoff.get("roadbed", {}), "transition": handoff.get("transition", {})})
		break
	if lanes.is_empty() or context == null or player == null or root == null or root.get_world_3d() == null:
		return {"passed": false, "violations": ["missing_declared_processional_04b_roadbed_to_ramp_handoff"], "lanes": lanes}
	var lane_checks: Array[Dictionary] = []
	for lane_value in lanes:
		var lane: Dictionary = lane_value as Dictionary
		lane_checks.append(await audit_player_raised_route_transition_lane(context, player, root, lane.get("roadbed", {}) as Dictionary, lane.get("transition", {}) as Dictionary, float(lane.get("offset", 0.0))))
	var passed := lane_checks.size() == 3 and lane_checks.all(func(check: Dictionary) -> bool: return bool(check.get("passed", false)))
	return {"passed": passed, "streetId": "processional_04b", "lanes": lane_checks, "violations": [] if passed else ["player did not continuously complete every declared processional_04b roadbed-to-ramp handoff lane"]}


static func audit_player_raised_route_transition_lane(context: Node, player: CharacterBody3D, root: Node3D, roadbed: Dictionary, transition: Dictionary, lane_offset: float) -> Dictionary:
	if roadbed.is_empty() or transition.is_empty():
		return {"passed": false, "laneOffset": lane_offset, "violations": ["missing_declared_handoff_lane"]}
	var roadbed_local: Vector3 = roadbed.get("position", Vector3.ZERO) as Vector3
	var roadbed_start := root.to_global(Vector3(roadbed_local.x, float(roadbed.get("topY", roadbed_local.y)), roadbed_local.z))
	var transition_local: Vector3 = transition.get("position", Vector3.ZERO) as Vector3
	var transition_finish := root.to_global(Vector3(transition_local.x, float(transition.get("topY", transition_local.y)), transition_local.z))
	var roadbed_owner_id := String(roadbed.get("ownerId", ""))
	var transition_owner_id := String(transition.get("ownerId", ""))
	var seam_axis := transition_finish - roadbed_start
	seam_axis.y = 0.0
	if seam_axis.length_squared() <= 0.000001:
		return {"passed": false, "laneOffset": lane_offset, "violations": ["missing_processional_04b_handoff_axis"], "roadbed": roadbed, "transition": transition}
	seam_axis = seam_axis.normalized()
	# Coverage samples intentionally straddle the seam by a few centimetres. A
	# motor test needs endpoints inside their respective collision owners, not a
	# near-zero vector between the two semantic probe positions.
	roadbed_start -= seam_axis * 0.16
	transition_finish += seam_axis * 0.70
	var start_evidence := await _settle_real_player_on_surface(context, player, root, roadbed_start, "processional_04b_roadbed_start", [roadbed_owner_id])
	var settled := player.global_position
	var direction := transition_finish - settled
	direction.y = 0.0
	if direction.length_squared() <= 0.01:
		return {"passed": false, "laneOffset": lane_offset, "violations": ["degenerate_processional_04b_handoff_axis"], "roadbed": roadbed, "transition": transition}
	var required_distance := direction.length()
	direction = direction.normalized()
	player.set("automated_input", true)
	player.set("automated_sprint", false)
	player.set("automated_move", direction)
	var grounded_frames := 0
	var airborne_frames := 0
	var maximum_progress := 0.0
	for _frame in range(PLAYER_SWEEP_FRAMES):
		await context.get_tree().physics_frame
		if player.is_on_floor():
			grounded_frames += 1
		else:
			airborne_frames += 1
		maximum_progress = maxf(maximum_progress, (player.global_position - settled).dot(direction))
		if _frame >= 11 and maximum_progress >= required_distance + 0.15:
			break
	player.set("automated_move", Vector3.ZERO)
	player.set("automated_input", false)
	await _settle_player_after_automated_move(context)
	var end_source := _surface_exposure(root, player.global_position, transition_owner_id, player)
	var end_contained := player_is_within_published_part_inset(root, player, transition_owner_id, 0.30)
	var start_source: Dictionary = start_evidence.get("rayShapeSource", {}) as Dictionary
	var passed := bool(start_evidence.get("passed", false)) and String(start_source.get("partId", "")) == roadbed_owner_id and maximum_progress >= required_distance - 0.14 and grounded_frames >= 12 and airborne_frames == 0 and end_contained and bool(end_source.get("exposed", false))
	return {"passed": passed, "laneOffset": lane_offset, "roadbedOwnerId": roadbed_owner_id, "transitionOwnerId": transition_owner_id, "seamAxis": seam_axis, "start": start_evidence, "finish": player.global_position, "requiredDistance": required_distance, "maximumProgress": maximum_progress, "groundedFrames": grounded_frames, "airborneFrames": airborne_frames, "endContained": end_contained, "endSource": end_source, "violations": [] if passed else ["player did not continuously complete the declared processional_04b roadbed-to-ramp handoff lane"]}


static func audit_player_raised_route_junction_traversals(context: Node, player: CharacterBody3D, root: Node3D, route_coverage_records: Array) -> Dictionary:
	if context == null or player == null or root == null or root.get_world_3d() == null:
		return {"passed": false, "junctions": [], "violations": ["missing_player_collision_world"]}
	var pairs_by_junction: Dictionary = {}
	var transition_handoffs_by_junction: Dictionary = {}
	for coverage_value in route_coverage_records:
		if not coverage_value is Dictionary:
			continue
		var coverage: Dictionary = coverage_value as Dictionary
		var seams: Dictionary = coverage.get("junctionSeams", {}) as Dictionary
		for pair_value in seams.get("pairs", []) as Array:
			if not pair_value is Dictionary:
				continue
			var pair: Dictionary = pair_value as Dictionary
			if not bool(pair.get("passed", false)):
				continue
			var junction_id := String(pair.get("junctionId", ""))
			if junction_id.is_empty():
				continue
			var pairs: Array = pairs_by_junction.get(junction_id, []) as Array
			pairs.append(pair)
			pairs_by_junction[junction_id] = pairs
		var handoff: Dictionary = coverage.get("handoffSeam", {}) as Dictionary
		var handoff_roadbed: Dictionary = handoff.get("roadbed", {}) as Dictionary
		if bool(handoff.get("declared", false)) and String(handoff_roadbed.get("ownerSemantic", "")) == "castle_route_junction":
			for sample_value in coverage.get("samples", []) as Array:
				if not sample_value is Dictionary:
					continue
				var sample: Dictionary = sample_value as Dictionary
				var sample_junction_id := String(sample.get("ownerId", ""))
				if String(sample.get("ownerSemantic", "")) != "castle_route_junction" or sample_junction_id != String(handoff_roadbed.get("ownerId", "")):
					continue
				var handoffs: Array = transition_handoffs_by_junction.get(sample_junction_id, []) as Array
				handoffs.append({"streetId": String(coverage.get("streetId", "")), "handoff": handoff})
				transition_handoffs_by_junction[sample_junction_id] = handoffs
				break
	if pairs_by_junction.is_empty():
		return {"passed": false, "junctions": [], "violations": ["missing_declared_raised_route_junction_seams"]}
	var junction_checks: Array[Dictionary] = []
	var violations: Array[String] = []
	for junction_id_value in pairs_by_junction:
		var junction_id := String(junction_id_value)
		var pairs: Array = pairs_by_junction.get(junction_id, []) as Array
		var unique_roadbeds: Dictionary = {}
		for pair_value in pairs:
			var pair: Dictionary = pair_value as Dictionary
			unique_roadbeds[String((pair.get("roadbed", {}) as Dictionary).get("ownerId", ""))] = pair
		var approaches: Array = unique_roadbeds.values()
		if approaches.size() < 2:
			var transition_handoffs: Array = transition_handoffs_by_junction.get(junction_id, []) as Array
			if approaches.size() == 1 and transition_handoffs.size() == 1:
				var transition_check := await audit_player_raised_route_junction_to_transition(context, player, root, junction_id, approaches[0] as Dictionary, transition_handoffs[0] as Dictionary)
				junction_checks.append(transition_check)
				if not bool(transition_check.get("passed", false)):
					violations.append("%s did not complete every player roadbed-to-junction-to-transition lane" % junction_id)
				continue
			var incomplete_reason := "junction has fewer than two declared roadbed approaches"
			if approaches.size() == 1 and transition_handoffs.size() > 1:
				incomplete_reason = "junction has ambiguous declared transition handoffs"
			var incomplete := {"junctionId": junction_id, "passed": false, "lanes": [], "violations": [incomplete_reason]}
			junction_checks.append(incomplete)
			violations.append("%s %s" % [junction_id, incomplete_reason])
			continue
		var junction_check := await audit_player_raised_route_junction(context, player, root, junction_id, approaches[0] as Dictionary, approaches[1] as Dictionary)
		junction_checks.append(junction_check)
		if not bool(junction_check.get("passed", false)):
			violations.append("%s did not complete every player ingress-to-egress lane" % junction_id)
	var passed := not junction_checks.is_empty() and violations.is_empty()
	return {"passed": passed, "junctions": junction_checks, "violations": violations}


static func audit_player_raised_route_junction(context: Node, player: CharacterBody3D, root: Node3D, junction_id: String, ingress_pair: Dictionary, egress_pair: Dictionary) -> Dictionary:
	var ingress: Dictionary = ingress_pair.get("roadbed", {}) as Dictionary
	var egress: Dictionary = egress_pair.get("roadbed", {}) as Dictionary
	var ingress_direction: Vector3 = ingress_pair.get("direction", Vector3.ZERO) as Vector3
	var egress_direction: Vector3 = egress_pair.get("direction", Vector3.ZERO) as Vector3
	if ingress.is_empty() or egress.is_empty() or ingress_direction.length_squared() <= 0.001 or egress_direction.length_squared() <= 0.001:
		return {"junctionId": junction_id, "passed": false, "lanes": [], "violations": ["missing_non_degenerate_junction_ingress_or_egress"]}
	var ingress_local: Vector3 = ingress.get("position", Vector3.ZERO) as Vector3
	var egress_local: Vector3 = egress.get("position", Vector3.ZERO) as Vector3
	var ingress_surface := root.to_global(Vector3(ingress_local.x, float(ingress.get("topY", ingress_local.y)), ingress_local.z)) - ingress_direction.normalized() * 0.62
	var egress_surface := root.to_global(Vector3(egress_local.x, float(egress.get("topY", egress_local.y)), egress_local.z)) - egress_direction.normalized() * 0.62
	var traverse_axis := egress_surface - ingress_surface
	traverse_axis.y = 0.0
	if traverse_axis.length_squared() <= 0.01:
		return {"junctionId": junction_id, "passed": false, "lanes": [], "violations": ["degenerate_junction_traverse_axis"]}
	traverse_axis = traverse_axis.normalized()
	var lateral_axis := Vector3(-traverse_axis.z, 0.0, traverse_axis.x)
	var lane_checks: Array[Dictionary] = []
	for lane_offset in [-0.30, 0.0, 0.30]:
		lane_checks.append(await audit_player_raised_route_junction_lane(context, player, root, junction_id, ingress_surface + lateral_axis * lane_offset, egress_surface + lateral_axis * lane_offset, String(ingress.get("ownerId", "")), String(egress.get("ownerId", "")), lane_offset))
	var passed := lane_checks.size() == 3 and lane_checks.all(func(check: Dictionary) -> bool: return bool(check.get("passed", false)))
	return {"junctionId": junction_id, "ingressPairId": String(ingress_pair.get("id", "")), "egressPairId": String(egress_pair.get("id", "")), "lanes": lane_checks, "passed": passed, "violations": [] if passed else ["one or more player lanes did not cross the named junction"]}


static func audit_player_raised_route_junction_to_transition(context: Node, player: CharacterBody3D, root: Node3D, junction_id: String, ingress_pair: Dictionary, transition_record: Dictionary) -> Dictionary:
	var ingress: Dictionary = ingress_pair.get("roadbed", {}) as Dictionary
	var ingress_direction: Vector3 = ingress_pair.get("direction", Vector3.ZERO) as Vector3
	var handoff: Dictionary = transition_record.get("handoff", {}) as Dictionary
	var lanes: Array = handoff.get("lanes", []) as Array
	if ingress.is_empty() or ingress_direction.length_squared() <= 0.001 or lanes.size() != 3:
		return {"junctionId": junction_id, "passed": false, "lanes": [], "violations": ["missing_declared_three_lane_junction_transition_handoff"]}
	var ingress_local: Vector3 = ingress.get("position", Vector3.ZERO) as Vector3
	var ingress_surface := root.to_global(Vector3(ingress_local.x, float(ingress.get("topY", ingress_local.y)), ingress_local.z)) - ingress_direction.normalized() * 0.62
	var lateral_axis := Vector3(-ingress_direction.z, 0.0, ingress_direction.x).normalized()
	var lane_checks: Array[Dictionary] = []
	for lane_value in lanes:
		var lane: Dictionary = lane_value as Dictionary
		var transition: Dictionary = lane.get("transition", {}) as Dictionary
		var transition_local: Vector3 = transition.get("position", Vector3.ZERO) as Vector3
		var transition_surface := root.to_global(Vector3(transition_local.x, float(transition.get("topY", transition_local.y)), transition_local.z))
		var lane_offset := float(lane.get("offset", 0.0))
		lane_checks.append(await audit_player_raised_route_junction_lane(context, player, root, junction_id, ingress_surface - lateral_axis * lane_offset, transition_surface, String(ingress.get("ownerId", "")), String(transition.get("ownerId", "")), lane_offset, true, 0.04))
	var passed := lane_checks.size() == 3 and lane_checks.all(func(check: Dictionary) -> bool: return bool(check.get("passed", false)))
	return {"junctionId": junction_id, "ingressPairId": String(ingress_pair.get("id", "")), "transitionStreetId": String(transition_record.get("streetId", "")), "transitionOwnerId": String(((lanes[0] as Dictionary).get("transition", {}) as Dictionary).get("ownerId", "")), "lanes": lane_checks, "passed": passed, "violations": [] if passed else ["one or more player lanes did not cross the named junction into its declared transition"]}


static func audit_player_raised_route_junction_lane(context: Node, player: CharacterBody3D, root: Node3D, junction_id: String, start_surface: Vector3, finish_surface: Vector3, ingress_owner_id: String, egress_owner_id: String, lane_offset: float, stop_at_egress := false, egress_inset := 0.28) -> Dictionary:
	var start_evidence := await _settle_real_player_on_surface(context, player, root, start_surface, "%s_ingress" % junction_id, [ingress_owner_id])
	var settled := player.global_position
	var direction := finish_surface - settled
	direction.y = 0.0
	if direction.length_squared() <= 0.01:
		return {"laneOffset": lane_offset, "passed": false, "violations": ["degenerate_player_junction_lane_axis"]}
	var required_distance := direction.length()
	direction = direction.normalized()
	player.set("automated_input", true)
	player.set("automated_sprint", false)
	player.set("automated_move", direction)
	var grounded_frames := 0
	var airborne_frames := 0
	var maximum_progress := 0.0
	var observed_junction := false
	var observed_egress := false
	for frame in range(PLAYER_SWEEP_FRAMES):
		await context.get_tree().physics_frame
		if player.is_on_floor():
			grounded_frames += 1
		else:
			airborne_frames += 1
		maximum_progress = maxf(maximum_progress, (player.global_position - settled).dot(direction))
		var current_source := _surface_exposure(root, player.global_position, junction_id, player)
		observed_junction = observed_junction or bool(current_source.get("exposed", false))
		var egress_source := _surface_exposure(root, player.global_position, egress_owner_id, player)
		observed_egress = observed_egress or bool(egress_source.get("exposed", false))
		if stop_at_egress and observed_egress and maximum_progress >= required_distance - 0.20:
			break
		if not stop_at_egress and frame >= 11 and maximum_progress >= required_distance + 0.12:
			break
	player.set("automated_move", Vector3.ZERO)
	player.set("automated_input", false)
	await _settle_player_after_automated_move(context)
	var end_source := _surface_exposure(root, player.global_position, egress_owner_id, player)
	var end_contained := player_is_within_published_part_inset(root, player, egress_owner_id, egress_inset)
	var start_source: Dictionary = start_evidence.get("rayShapeSource", {}) as Dictionary
	var passed := bool(start_evidence.get("passed", false)) and String(start_source.get("partId", "")) == ingress_owner_id and observed_junction and observed_egress and maximum_progress >= required_distance - 0.14 and grounded_frames >= 12 and airborne_frames == 0 and end_contained and bool(end_source.get("exposed", false))
	return {"laneOffset": lane_offset, "ingressOwnerId": ingress_owner_id, "junctionId": junction_id, "egressOwnerId": egress_owner_id, "start": start_evidence, "finish": player.global_position, "requiredDistance": required_distance, "maximumProgress": maximum_progress, "groundedFrames": grounded_frames, "airborneFrames": airborne_frames, "observedJunction": observed_junction, "observedEgress": observed_egress, "stopAtEgress": stop_at_egress, "egressInset": egress_inset, "endContained": end_contained, "endSource": end_source, "passed": passed, "violations": [] if passed else ["player did not remain grounded from named ingress through junction to named egress"]}


static func audit_player_keep_entry_apron_seams(context: Node, player: CharacterBody3D, root: Node3D, parts: Array) -> Dictionary:
	if context == null or player == null or root == null or root.get_world_3d() == null:
		return {"passed": false, "checks": [], "violations": ["missing_player_collision_world"]}
	return await _audit_player_keep_entry_apron_seams(context, player, root, parts)


static func _audit_player_keep_entry_side_sweeps(context: Node, player: CharacterBody3D, root: Node3D, ramp_transform: Transform3D, ramp, steps: Array[Dictionary]) -> Dictionary:
	var lane_offset := minf(maxf(0.0, ramp.size.x * 0.5 - 0.48), 0.55)
	if lane_offset <= 0.12:
		return {"id": "entry_step_side_lane_sweeps", "passed": true, "skipped": true, "reason": "ramp_too_narrow_for_side_lanes"}
	var lanes: Array[Dictionary] = []
	for lane_name in ["left", "right"]:
		var lane_sign := -1.0 if lane_name == "left" else 1.0
		var start := root.to_global(ramp_transform * Vector3(lane_offset * lane_sign, ramp.size.y * 0.5, -ramp.size.z * 0.44))
		var finish := root.to_global(ramp_transform * Vector3(lane_offset * lane_sign, ramp.size.y * 0.5, ramp.size.z * 0.44))
		var direction := finish - start
		direction.y = 0.0
		if direction.length_squared() <= 0.01:
			lanes.append({"lane": lane_name, "passed": false, "reason": "degenerate_sweep_axis"})
			continue
		player.global_position = start + Vector3.UP * 2.20
		player.velocity = Vector3.ZERO
		player.set("automated_input", true)
		player.set("automated_sprint", false)
		player.set("automated_move", Vector3.ZERO)
		for _frame in range(PLAYER_SETTLE_FRAMES):
			await context.get_tree().physics_frame
		var settled := player.global_position
		var normalized_direction := direction.normalized()
		var seam_progresses: Array[float] = []
		for step_index in range(1, steps.size()):
			var threshold: Vector3 = (steps[step_index] as Dictionary).get("surface", Vector3.ZERO) as Vector3
			seam_progresses.append((threshold - settled).dot(normalized_direction))
		player.set("automated_move", normalized_direction)
		var grounded_frames := 0
		var maximum_progress := 0.0
		var seam_count := 0
		for _frame in range(PLAYER_SWEEP_FRAMES):
			await context.get_tree().physics_frame
			var current := player.global_position
			if player.is_on_floor():
				grounded_frames += 1
			maximum_progress = maxf(maximum_progress, (current - settled).dot(normalized_direction))
			while seam_count < seam_progresses.size() and maximum_progress >= float(seam_progresses[seam_count]) - 0.08:
				seam_count += 1
			if maximum_progress >= direction.length() + 0.20:
				break
		player.set("automated_move", Vector3.ZERO)
		player.set("automated_input", false)
		lanes.append({
			"lane": lane_name,
			"start": settled,
			"finish": player.global_position,
			"requiredDistance": direction.length(),
			"maximumProgress": maximum_progress,
			"groundedFrames": grounded_frames,
			"seamCrossingCount": seam_count,
			"passed": maximum_progress >= direction.length() - 0.20 and grounded_frames >= 18 and seam_count == steps.size() - 1
		})
	var passed := lanes.size() == 2 and lanes.all(func(lane: Dictionary) -> bool: return bool(lane.get("passed", false)))
	return {"id": "entry_step_side_lane_sweeps", "passed": passed, "lanes": lanes}


static func _audit_player_keep_entry_apron_seams(context: Node, player: CharacterBody3D, root: Node3D, parts: Array) -> Dictionary:
	var steps_by_side := {}
	var aprons_by_side := {}
	for part in parts:
		if part == null:
			continue
		var semantic := String(part.semantic)
		if semantic == "castle_keep_palace_axial_entry_step":
			var step_side := 1 if part.position.x >= 0.0 else -1
			if not steps_by_side.has(step_side):
				steps_by_side[step_side] = []
			(steps_by_side[step_side] as Array).append(part)
		elif semantic == "castle_keep_palace_entry_apron":
			var apron_side := 1 if part.position.x >= 0.0 else -1
			aprons_by_side[apron_side] = part
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	for side_value in [-1, 1]:
		var apron = aprons_by_side.get(side_value)
		var side_steps: Array = steps_by_side.get(side_value, []) as Array
		if apron == null or side_steps.is_empty():
			violations.append("missing_step_or_apron_for_side_%d" % side_value)
			continue
		for step in side_steps:
			var side := float(side_value)
			var step_outer_x: float = float(step.position.x) + side * float(step.size.x) * 0.5
			var apron_inner_x: float = float(apron.position.x) - side * float(apron.size.x) * 0.5
			var signed_overlap := side * (step_outer_x - apron_inner_x)
			var seam_x: float = (step_outer_x + apron_inner_x) * 0.5
			var seam_surface := root.to_global(Vector3(seam_x, step.position.y + step.size.y * 0.5, step.position.z))
			var covering_support := _higher_published_support_at(root, seam_surface, String(step.id))
			if not covering_support.is_empty():
				checks.append({
					"id": "%s_to_%s_seam" % [String(step.id), String(apron.id)],
					"passed": true,
					"exposed": false,
					"skippedReason": "covered_by_higher_published_support",
					"coveringSupport": covering_support
				})
				continue
			var step_exclusive_surface := root.to_global(Vector3(step_outer_x - side * 0.12, step.position.y + step.size.y * 0.5, step.position.z))
			var apron_exclusive_surface := root.to_global(Vector3(apron_inner_x + side * 0.12, apron.position.y + apron.size.y * 0.5, step.position.z))
			var step_source := _surface_exposure(root, step_exclusive_surface, String(step.id))
			var apron_source := _surface_exposure(root, apron_exclusive_surface, String(apron.id))
			var step_covering_support := _higher_published_support_at(root, step_exclusive_surface, String(step.id))
			var apron_covering_support := _higher_published_support_at(root, apron_exclusive_surface, String(apron.id))
			var check := await _settle_real_player_on_surface(
				context,
				player,
				root,
				seam_surface,
				"%s_to_%s_seam" % [String(step.id), String(apron.id)],
				[String(step.id), String(apron.id)]
			)
			check["stepOuterX"] = step_outer_x
			check["apronInnerX"] = apron_inner_x
			check["signedOverlap"] = signed_overlap
			check["geometryOverlapPassed"] = signed_overlap >= 0.04 - 0.001
			check["stepExclusiveSource"] = step_source
			check["apronExclusiveSource"] = apron_source
			check["stepCoveringSupport"] = step_covering_support
			check["apronCoveringSupport"] = apron_covering_support
			check["sourceCoveragePassed"] = (bool(step_source.get("exposed", false)) or not step_covering_support.is_empty()) \
				and (bool(apron_source.get("exposed", false)) or not apron_covering_support.is_empty())
			check["passed"] = bool(check.get("passed", false)) and bool(check.get("geometryOverlapPassed", false)) and bool(check.get("sourceCoveragePassed", false))
			checks.append(check)
			if not bool(check.get("passed", false)):
				violations.append("%s has no grounded collision at the step-apron seam" % String(step.id))
	return {"id": "entry_step_apron_seams", "passed": violations.is_empty() and not checks.is_empty(), "checks": checks, "violations": violations}


static func _citadel_foundation_footprint_samples(root: Node3D, foundation) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	var transform := Transform3D(Basis.from_euler(foundation.rotation), foundation.position)
	for x_index in range(3):
		for z_index in range(3):
			var x := lerpf(-foundation.size.x * 0.40, foundation.size.x * 0.40, float(x_index) / 2.0)
			var z := lerpf(-foundation.size.z * 0.40, foundation.size.z * 0.40, float(z_index) / 2.0)
			samples.append({
				"id": "%d_%d" % [x_index, z_index],
				"position": root.to_global(transform * Vector3(x, -foundation.size.y * 0.5, z))
			})
	return samples


static func _citadel_foundation_support_colliders(root: Node3D) -> Array[CollisionShape3D]:
	var colliders: Array[CollisionShape3D] = []
	for collision_value in root.find_children("*", "CollisionShape3D", true, false):
		var collision := collision_value as CollisionShape3D
		if collision == null or collision.disabled or not collision.has_meta("building_semantic"):
			continue
		if CITADEL_FOUNDATION_SUPPORT_SEMANTICS.has(String(collision.get_meta("building_semantic", ""))):
			colliders.append(collision)
	return colliders


static func _published_citadel_foundation_support_at(position: Vector3, colliders: Array[CollisionShape3D]) -> Dictionary:
	for collision in colliders:
		if collision == null or not is_instance_valid(collision):
			continue
		var box := collision.shape as BoxShape3D
		if box == null:
			continue
		var local := collision.global_transform.affine_inverse() * position
		var half_size := box.size * 0.5
		if absf(local.x) > half_size.x - 0.015 or absf(local.z) > half_size.z - 0.015:
			continue
		if absf(local.y) > half_size.y + 0.04:
			continue
		return {
			"partId": String(collision.get_meta("building_part_id", "")),
			"semantic": String(collision.get_meta("building_semantic", "")),
			"localPosition": local,
			"shapeSize": box.size
		}
	return {}


static func _has_published_part_collision(root: Node3D, part_id: String) -> bool:
	for collision_value in root.find_children("*", "CollisionShape3D", true, false):
		var collision := collision_value as CollisionShape3D
		if collision != null and not collision.disabled and String(collision.get_meta("building_part_id", "")) == part_id:
			return true
	return false


static func _top_surface_for_part(root: Node3D, part) -> Vector3:
	var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
	return root.to_global(transform * Vector3(0.0, part.size.y * 0.5, 0.0))


static func audit_surface_fall_probes(context: Node, player: CharacterBody3D, root: Node3D, sample_specs: Array[Dictionary]) -> Dictionary:
	const BATCH_SIZE := 16
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	var exposed: Array[Dictionary] = []
	var not_exposed: Array[Dictionary] = []
	for sample in sample_specs:
		var surface: Vector3 = sample.get("surface", Vector3.ZERO) as Vector3
		var part_id := String(sample.get("partId", ""))
		var exposure := _surface_exposure(root, surface, part_id)
		var covering := _higher_published_support_at(root, surface, part_id)
		if not covering.is_empty():
			not_exposed.append({"id": String(sample.get("id", "")), "expectedPartId": part_id, "coveringSupport": covering})
		elif bool(exposure.get("exposed", false)):
			exposed.append(sample)
		else:
			checks.append({"id": String(sample.get("id", "")), "expectedPartId": part_id, "passed": false, "failureReason": "missing_or_ambiguous_top_collision", "exposure": exposure})
			violations.append("expected support has no attributable collision at %s" % String(sample.get("id", "")))
	var source_shape: CollisionShape3D
	for child_value in player.find_children("*", "CollisionShape3D", true, false):
		var candidate := child_value as CollisionShape3D
		if candidate != null and candidate.shape is CapsuleShape3D:
			source_shape = candidate
			break
	if source_shape == null or source_shape.shape == null:
		return {"checks": checks, "violations": ["missing_production_player_capsule"], "exposedExpected": exposed.size(), "notExposed": not_exposed, "probeInterferenceCount": 0}
	var probe_interference_count := 0
	var residual_probe_count := 0
	for first_index in range(0, exposed.size(), BATCH_SIZE):
		var batch: Array = exposed.slice(first_index, mini(first_index + BATCH_SIZE, exposed.size()))
		var probes: Array[Dictionary] = []
		for sample_value in batch:
			var sample: Dictionary = sample_value as Dictionary
			var probe := BuildingSurfaceFallProbeScript.new() as CharacterBody3D
			probe.collision_layer = player.collision_layer
			probe.collision_mask = player.collision_mask
			probe.floor_max_angle = player.floor_max_angle
			probe.floor_snap_length = player.floor_snap_length
			probe.safe_margin = player.safe_margin
			probe.up_direction = player.up_direction
			probe.set_meta("building_surface_fall_probe", true)
			var collider := CollisionShape3D.new()
			collider.shape = source_shape.shape.duplicate()
			collider.transform = source_shape.transform
			probe.add_child(collider)
			root.add_child(probe)
			for existing_value in probes:
				var existing_probe := (existing_value as Dictionary).get("probe") as CharacterBody3D
				if existing_probe != null:
					probe.add_collision_exception_with(existing_probe)
					existing_probe.add_collision_exception_with(probe)
			probe.global_position = (sample.get("surface", Vector3.ZERO) as Vector3) + Vector3.UP * 2.20
			probes.append({"sample": sample, "probe": probe})
		for _frame in range(PLAYER_SETTLE_FRAMES):
			await context.get_tree().physics_frame
		for entry_value in probes:
			var entry: Dictionary = entry_value as Dictionary
			var sample: Dictionary = entry.get("sample", {}) as Dictionary
			var probe := entry.get("probe") as CharacterBody3D
			var surface: Vector3 = sample.get("surface", Vector3.ZERO) as Vector3
			var query := PhysicsRayQueryParameters3D.create(surface + Vector3.UP * 0.32, surface - Vector3.UP * 0.60, 1)
			for probe_value in probes:
				var batch_probe := (probe_value as Dictionary).get("probe") as CharacterBody3D
				if batch_probe != null:
					query.exclude.append(batch_probe.get_rid())
			var hit := probe.get_world_3d().direct_space_state.intersect_ray(query)
			var hit_position: Vector3 = hit.get("position", Vector3.INF) as Vector3
			var source := _part_collision_source_for_ray(hit)
			var body_contacts: Array[Dictionary] = _part_collision_candidates_at_contact(root, probe.global_position)
			var slide_contact := {}
			if probe.get_slide_collision_count() > 0:
				var collision := probe.get_slide_collision(0)
				if collision != null:
					var contact_position := collision.get_position()
					var collider_body := collision.get_collider() as Node
					if collider_body != null and bool(collider_body.get_meta("building_surface_fall_probe", false)):
						probe_interference_count += 1
					slide_contact = {"position": contact_position, "normal": collision.get_normal(), "partCandidates": _part_collision_candidates_at_contact(root, contact_position)}
			var passed := probe.is_on_floor() and absf(probe.global_position.y - surface.y) <= PLAYER_SURFACE_TOLERANCE and not hit.is_empty() and absf(hit_position.y - surface.y) <= 0.08 and String(source.get("partId", "")) == String(sample.get("partId", ""))
			checks.append({"id": String(sample.get("id", "")), "expectedPartId": String(sample.get("partId", "")), "exposed": true, "playerGrounded": probe.is_on_floor(), "playerPosition": probe.global_position, "bodyContacts": body_contacts, "slideContact": slide_contact, "raySurface": hit_position, "rayShapeSource": source, "passed": passed})
			if not passed:
				violations.append("surface fall probe failed at %s" % String(sample.get("id", "")))
			probe.queue_free()
		await context.get_tree().physics_frame
		for child_value in root.find_children("*", "CharacterBody3D", true, false):
			var child := child_value as CharacterBody3D
			if child != null and bool(child.get_meta("building_surface_fall_probe", false)):
				residual_probe_count += 1
		if context.has_method("report_collision_probe_progress"):
			context.call("report_collision_probe_progress", "keep_entry_surface_batch", mini(first_index + batch.size(), exposed.size()), exposed.size())
	var exposed_verified := 0
	for check_value in checks:
		var check: Dictionary = check_value as Dictionary
		if bool(check.get("exposed", false)) and bool(check.get("passed", false)):
			exposed_verified += 1
	if residual_probe_count != 0:
		violations.append("surface fall probes remained after batch cleanup")
	return {"checks": checks, "violations": violations, "exposedExpected": exposed.size(), "exposedVerified": exposed_verified, "notExposed": not_exposed, "probeInterferenceCount": probe_interference_count, "residualProbeCount": residual_probe_count}


static func player_surface_samples(root: Node3D, parts: Array, ramp_center: Vector3, ramp_finish: Vector3, ramp_side_offset: float) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	for part in parts:
		if part == null or not SUPPORT_SEMANTICS.has(String(part.semantic)):
			continue
		var part_id := String(part.id)
		var center := _top_surface_for_part(root, part)
		var lateral_limit := maxf(0.0, part.size.x * 0.5 - 0.48)
		var lateral_offset := minf(0.55, lateral_limit)
		var longitudinal_limit := maxf(0.0, part.size.z * 0.5 - 0.48)
		var longitudinal_offset := minf(0.55, longitudinal_limit)
		samples.append({"id": "%s_center" % part_id, "partId": part_id, "surface": center})
		var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
		if lateral_offset > 0.12:
			var left := root.to_global(transform * Vector3(-lateral_offset, part.size.y * 0.5, 0.0))
			var right := root.to_global(transform * Vector3(lateral_offset, part.size.y * 0.5, 0.0))
			samples.append({"id": "%s_left_edge" % part_id, "partId": part_id, "surface": left})
			samples.append({"id": "%s_right_edge" % part_id, "partId": part_id, "surface": right})
		if lateral_offset > 0.12 and longitudinal_offset > 0.12:
			for x_sign in [-1.0, 1.0]:
				for z_sign in [-1.0, 1.0]:
					var corner := root.to_global(transform * Vector3(lateral_offset * x_sign, part.size.y * 0.5, longitudinal_offset * z_sign))
					samples.append({"id": "%s_corner_%s_%s" % [part_id, "left" if x_sign < 0.0 else "right", "front" if z_sign < 0.0 else "back"], "partId": part_id, "surface": corner})
	# The ramp's longitudinal upper surface is distinct from its centre and must
	# remain grounded after recipe transforms and static-batch publication.
	samples.append({"id": "castle_keep_palace_entry_ramp_upper", "partId": "castle_keep_palace_entry_ramp", "surface": ramp_finish})
	return samples


static func _surface_exposure(root: Node3D, surface: Vector3, expected_part_id: String, excluded_body: CollisionObject3D = null) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(surface + Vector3.UP * 8.0, surface - Vector3.UP * 0.30, 1)
	query.collide_with_areas = false
	if excluded_body != null:
		query.exclude = [excluded_body.get_rid()]
	var hit: Dictionary = root.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {"exposed": false, "topmostSurface": Vector3.INF, "topmostCandidates": []}
	var topmost_surface: Vector3 = hit.get("position", Vector3.INF) as Vector3
	var topmost_candidates := _part_collision_candidates_at_contact(root, topmost_surface)
	var hit_source := _part_collision_source_for_ray(hit)
	var expected_is_topmost := String(hit_source.get("partId", "")) == expected_part_id
	return {
		"exposed": expected_is_topmost and absf(topmost_surface.y - surface.y) <= 0.08,
		"topmostSurface": topmost_surface,
		"topmostCandidates": topmost_candidates,
		"topmostShapeSource": hit_source
	}


static func _settle_player_after_automated_move(context: Node, frames := 6) -> void:
	for _frame in range(frames):
		await context.get_tree().physics_frame


static func _published_part_body(root: Node3D, part_id: String) -> StaticBody3D:
	if root == null or part_id.is_empty():
		return null
	for node_value in root.find_children("*", "StaticBody3D", true, false):
		var body := node_value as StaticBody3D
		if body != null and String(body.get_meta("building_part_id", "")) == part_id:
			return body
	return null


static func flat_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x - second.x, first.z - second.z).length()


static func _open_door_with_live_player_input(context: Node, player: CharacterBody3D, door: StaticBody3D) -> Dictionary:
	if context == null or player == null or door == null:
		return {"passed": false, "reason": "missing_live_door_interaction_context"}
	if bool(door.get_meta("open", false)):
		return {"passed": true, "reason": "already_open", "doorPartId": String(door.get_meta("building_part_id", ""))}
	var aim_target := door.global_position
	aim_target.y = player.global_position.y
	player.look_at(aim_target, Vector3.UP)
	var camera = player.get("camera") as Camera3D
	if camera != null:
		camera.rotation.x = 0.0
	await context.get_tree().physics_frame
	var hit: Dictionary = player.view_ray(4.20, true)
	var collider := hit.get("collider") as Node
	if not _interaction_hit_belongs_to_door(collider, door):
		return {"passed": false, "reason": "door_not_targeted_by_real_player_ray", "doorPartId": String(door.get_meta("building_part_id", "")), "hitCollider": collider.name if collider != null else ""}
	var game_main := context.get("main") as Node
	var focused_hit: Dictionary = game_main.call("focused_interaction_hit") as Dictionary if game_main != null and game_main.has_method("focused_interaction_hit") else {}
	var focused_collider := focused_hit.get("collider") as Node
	var focused_matches_door := _interaction_hit_belongs_to_door(focused_collider, door)
	if not focused_matches_door:
		return {"passed": false, "reason": "door_not_targeted_by_production_interaction", "doorPartId": String(door.get_meta("building_part_id", "")), "focusedCollider": focused_collider.name if focused_collider != null else ""}
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	var center := context.get_viewport().get_visible_rect().size * 0.5
	click.position = center
	click.global_position = center
	context.get_viewport().push_input(click)
	click = click.duplicate() as InputEventMouseButton
	click.pressed = false
	context.get_viewport().push_input(click)
	for _frame in range(12):
		await context.get_tree().physics_frame
	var opened := bool(door.get_meta("open", false))
	return {"passed": opened and door.collision_layer == 0, "reason": "opened_by_right_click" if opened else "door_did_not_open_from_right_click", "doorPartId": String(door.get_meta("building_part_id", "")), "focusedCollider": focused_collider.name if focused_collider != null else "", "collisionLayer": door.collision_layer}


static func _interaction_hit_belongs_to_door(collider: Node, door: StaticBody3D) -> bool:
	var current := collider
	while current != null:
		if current == door:
			return true
		if current.has_meta("interaction_parent") and current.get_meta("interaction_parent") == door:
			return true
		current = current.get_parent()
	return false


static func player_is_within_part_inset(root: Node3D, player: CharacterBody3D, part, inset: float) -> bool:
	if root == null or player == null or part == null:
		return false
	var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
	var local_position := transform.affine_inverse() * root.to_local(player.global_position)
	return absf(local_position.x) <= maxf(0.0, part.size.x * 0.5 - inset) and absf(local_position.z) <= maxf(0.0, part.size.z * 0.5 - inset)


static func player_is_within_published_part_inset(root: Node3D, player: CharacterBody3D, part_id: String, inset: float) -> bool:
	if root == null or player == null or part_id.is_empty():
		return false
	for collision_value in root.find_children("*", "CollisionShape3D", true, false):
		var collision := collision_value as CollisionShape3D
		if collision == null or collision.disabled or String(collision.get_meta("building_part_id", "")) != part_id:
			continue
		var box := collision.shape as BoxShape3D
		if box == null:
			continue
		var local_position := collision.global_transform.affine_inverse() * player.global_position
		if absf(local_position.x) <= maxf(0.0, box.size.x * 0.5 - inset) and absf(local_position.z) <= maxf(0.0, box.size.z * 0.5 - inset):
			return true
	return false


static func _higher_published_support_at(root: Node3D, surface: Vector3, expected_part_id: String) -> Dictionary:
	var highest: Dictionary = {}
	var highest_y := surface.y + PLAYER_SURFACE_TOLERANCE
	for collision_node_value in root.find_children("*", "CollisionShape3D", true, false):
		var collision_node := collision_node_value as CollisionShape3D
		if collision_node == null or collision_node.disabled or not collision_node.has_meta("building_part_id"):
			continue
		var part_id := String(collision_node.get_meta("building_part_id", ""))
		if part_id == expected_part_id:
			continue
		var box := collision_node.shape as BoxShape3D
		if box == null:
			continue
		var local_surface := collision_node.global_transform.affine_inverse() * surface
		var half_size := box.size * 0.5
		if absf(local_surface.x) > half_size.x + 0.08 or absf(local_surface.z) > half_size.z + 0.08:
			continue
		var top_surface := collision_node.global_transform * Vector3(local_surface.x, half_size.y, local_surface.z)
		if top_surface.y <= highest_y:
			continue
		highest_y = top_surface.y
		highest = {
			"partId": part_id,
			"kind": String(collision_node.get_meta("building_part_kind", "")),
			"semantic": String(collision_node.get_meta("building_semantic", "")),
			"surface": top_surface,
			"sourceSurface": surface
		}
	return highest


static func audit_explicit_walkable_surfaces(context: Node, player: CharacterBody3D, root: Node3D, parts: Array) -> Dictionary:
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	var exposed_surface_count := 0
	if context == null or player == null or root == null or root.get_world_3d() == null:
		return {"passed": false, "checkedSurfaceCount": 0, "checks": checks, "violations": ["missing_player_collision_world"]}
	for part in parts:
		if part == null or not bool(part.recipe.get("playerSurfaceAudit", false)):
			continue
		var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
		var local_samples := [
			Vector3.ZERO,
			Vector3(part.size.x * 0.27, 0.0, 0.0),
			Vector3(-part.size.x * 0.27, 0.0, 0.0),
			Vector3(0.0, 0.0, part.size.z * 0.27),
			Vector3(0.0, 0.0, -part.size.z * 0.27)
		]
		for sample_index in range(local_samples.size()):
			var local_sample: Vector3 = local_samples[sample_index] as Vector3
			var surface := root.to_global(transform * Vector3(local_sample.x, part.size.y * 0.5, local_sample.z))
			var exposure := _surface_exposure(root, surface, String(part.id))
			if not bool(exposure.get("exposed", false)):
				checks.append({
					"id": "%s_surface_%02d" % [String(part.id), sample_index],
					"partId": String(part.id),
					"semantic": String(part.semantic),
					"expectedSurface": surface,
					"passed": false,
					"exposed": false,
					"failureReason": "source_surface_not_exposed_or_not_attributed",
					"topmostSurface": exposure.get("topmostSurface", Vector3.INF),
					"topmostCandidates": exposure.get("topmostCandidates", [])
				})
				violations.append("%s has no exposed, attributable player surface at sample %d" % [String(part.id), sample_index])
				continue
			exposed_surface_count += 1
			var check := await _settle_real_player_on_surface(context, player, root, surface, "%s_surface_%02d" % [String(part.id), sample_index], [String(part.id)])
			check["partId"] = String(part.id)
			check["semantic"] = String(part.semantic)
			check["exposed"] = true
			checks.append(check)
			if not bool(check.get("passed", false)):
				violations.append("%s has no player-proven collision at sample %d" % [String(part.id), sample_index])
	return {
		"passed": not checks.is_empty() and exposed_surface_count > 0 and violations.is_empty(),
		"checkedSurfaceCount": checks.size(),
		"exposedSurfaceCount": exposed_surface_count,
		"checks": checks,
		"violations": violations
	}


static func _settle_real_player_on_surface(context: Node, player: CharacterBody3D, root: Node3D, surface: Vector3, sample_id: String, expected_part_ids: Array[String] = []) -> Dictionary:
	player.global_position = surface + Vector3.UP * 2.20
	player.velocity = Vector3.ZERO
	player.set("automated_input", true)
	player.set("automated_sprint", false)
	player.set("automated_move", Vector3.ZERO)
	for _frame in range(PLAYER_SETTLE_FRAMES):
		await context.get_tree().physics_frame
	player.set("automated_input", false)
	var query := PhysicsRayQueryParameters3D.create(surface + Vector3.UP * 0.32, surface - Vector3.UP * 0.60, 1)
	query.collide_with_areas = false
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(query)
	var hit_position: Vector3 = hit.get("position", Vector3.INF) as Vector3
	var source_candidates: Array = _part_collision_candidates_at_contact(root, hit_position) if not hit.is_empty() else []
	var hit_source := _part_collision_source_for_ray(hit)
	var approved_source_support := String(hit_source.get("partId", "")) in expected_part_ids
	var standing_delta := absf(player.global_position.y - surface.y)
	var grounded := player.is_on_floor()
	return {
		"id": sample_id,
		"expectedSurface": surface,
		"rayHit": not hit.is_empty() and absf(hit_position.y - surface.y) <= 0.08,
		"rayCollider": String((hit.get("collider") as Node).name) if hit.get("collider") is Node else "",
		"raySurface": hit_position if not hit.is_empty() else Vector3.INF,
		"rayNormal": hit.get("normal", Vector3.ZERO) if not hit.is_empty() else Vector3.ZERO,
		"rayShapeSource": hit_source,
		"sourceSupportCandidates": source_candidates,
		"approvedSourceSupport": approved_source_support,
		"playerPosition": player.global_position,
		"playerGrounded": grounded,
		"standingDelta": standing_delta,
		"passed": grounded and standing_delta <= PLAYER_SURFACE_TOLERANCE and not hit.is_empty() and absf(hit_position.y - surface.y) <= 0.08 and approved_source_support
	}


static func _part_collision_candidates_at_contact(root: Node3D, contact_position: Vector3) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	if root == null or not is_instance_valid(root):
		return candidates
	for collision_node_value in root.find_children("*", "CollisionShape3D", true, false):
		var collision_node := collision_node_value as CollisionShape3D
		if collision_node == null or collision_node.disabled or not collision_node.has_meta("building_part_id"):
			continue
		var box := collision_node.shape as BoxShape3D
		if box == null:
			continue
		var local_contact := collision_node.global_transform.affine_inverse() * contact_position
		var half_size := box.size * 0.5
		var tolerance := 0.08
		if absf(local_contact.x) > half_size.x + tolerance:
			continue
		if absf(local_contact.y) > half_size.y + tolerance:
			continue
		if absf(local_contact.z) > half_size.z + tolerance:
			continue
		candidates.append({
			"partId": String(collision_node.get_meta("building_part_id")),
			"kind": String(collision_node.get_meta("building_part_kind", "")),
			"semantic": String(collision_node.get_meta("building_semantic", "")),
			"localContact": local_contact,
			"shapeSize": box.size
		})
	return candidates


static func _part_collision_source_for_ray(hit: Dictionary) -> Dictionary:
	var collider := hit.get("collider") as CollisionObject3D
	if collider == null:
		return {}
	var shape_index := int(hit.get("shape", -1))
	if shape_index < 0:
		return {"collider": collider.name, "reason": "missing_shape_index"}
	var owner_id := collider.shape_find_owner(shape_index)
	if owner_id < 0:
		return {"collider": collider.name, "shapeIndex": shape_index, "reason": "missing_shape_owner"}
	var owner := collider.shape_owner_get_owner(owner_id)
	var collision_node := owner as CollisionShape3D
	if collision_node == null:
		return {"collider": collider.name, "shapeIndex": shape_index, "reason": "shape_owner_is_not_collision_shape"}
	if collision_node.disabled:
		return {"collider": collider.name, "shapeIndex": shape_index, "reason": "disabled_collision_shape"}
	return {
		"collider": collider.name,
		"shapeIndex": shape_index,
		"shapeOwner": collision_node.name,
		"partId": String(collision_node.get_meta("building_part_id", "")),
		"kind": String(collision_node.get_meta("building_part_kind", "")),
		"semantic": String(collision_node.get_meta("building_semantic", ""))
	}
