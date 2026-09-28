extends RefCounted

## Diagnostic walk itinerary, never a production route or layout authority.
## One courtyard aisle plus perpendicular visits. A blocked itinerary fails;
## this helper never searches alternate routes or moves generated geometry.
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const RADIUS := 0.32 # unchanged CottagePocPlayer capsule
const HEIGHT := 1.72

static func prepare(b, plans: Array) -> Dictionary:
	if b == null or plans.is_empty() or plans.size() > 8 or b.parts.size() > 10000:
		return {"ready": false, "reason": "invalid_walk_source"}
	var courtyards: Array = b.rooms.filter(func(room): return room.get("role") == "courtyard")
	if courtyards.size() != 1 or not courtyards[0].get("bounds") is AABB:
		return {"ready": false, "reason": "missing_common_courtyard"}
	var courtyard: AABB = courtyards[0].bounds
	var standing_y := float(plans[0].standingY)
	var aisle_z := INF
	for plan in plans:
		if not plan.get("approach") is Rect2 or float(plan.standingY) != standing_y:
			return {"ready": false, "reason": "requires_same_level_approaches"}
		# Use the frontmost reserved approach centre, not its outermost edge:
		# this keeps the itinerary within the public approach depth.
		aisle_z = minf(aisle_z, (plan.approach as Rect2).get_center().y)
	# The local market's public paving defines the start, not the global
	# courtyard centre (the real street houses divide that wider courtyard).
	var entry_surface = b.find_part(String(plans[0].supportId))
	if entry_surface == null or not Urban.is_primary_tree_paving(entry_surface):
		return {"ready": false, "reason": "missing_public_market_start"}
	var start := Vector3(entry_surface.position.x, standing_y, aisle_z)
	if not Rect2(Vector2(courtyard.position.x, courtyard.position.z), Vector2(courtyard.size.x, courtyard.size.z)).has_point(Vector2(start.x, start.z)):
		return {"ready": false, "reason": "market_start_outside_courtyard"}
	var waypoints: Array = []
	for i in range(plans.size()):
		var approach: Rect2 = plans[i].approach
		var target := Vector3(approach.get_center().x, standing_y, approach.get_center().y)
		var junction := Vector3(target.x, standing_y, aisle_z)
		waypoints.append({"id": "market_%02d_aisle" % i, "position": junction, "standingY": standing_y, "capture": false})
		waypoints.append({"id": "market_%02d_front" % i, "position": target, "standingY": standing_y, "capture": true, "faceDirection": -plans[i].frontAfter})
		if i + 1 < plans.size():
			waypoints.append({"id": "market_%02d_return" % i, "position": junction, "standingY": standing_y, "capture": false})
	var compact: Array = []
	for waypoint in waypoints:
		if not compact.is_empty() and compact.back().position == waypoint.position:
			if waypoint.capture: compact[compact.size() - 1] = waypoint
		else:
			compact.append(waypoint)
	waypoints = compact
	return _check_itinerary(b, start, waypoints, standing_y)


static func extend_to_terminal_fronts(b, market_plan: Dictionary, terminals: Dictionary, furnishing_obstacles: Array) -> Dictionary:
	# Diagnostic itinerary only: continue the SAME actor from the market act.
	# Continue along the aisle parallel to the new frontage before entering it;
	# no alternate route search, authored waypoint coordinates or new placement.
	if not market_plan.get("ready", false) or not terminals.get("ready", false):
		return {"ready": false, "reason": "walk_sources_not_ready"}
	if b == null or b.parts.size() > 10000 or furnishing_obstacles.size() > 4096 or not market_plan.get("waypoints") is Array or market_plan.waypoints.size() > 32 or not market_plan.get("start") is Vector3 or not terminals.get("elevation") is Dictionary or not terminals.elevation.get("publicPavingPlan") is Dictionary or not terminals.get("front") is Vector3 or not terminals.get("setups") is Array or terminals.setups.is_empty() or terminals.setups.size() > 8:
		return {"ready": false, "reason": "invalid_terminal_walk_source"}
	var waypoints: Array = market_plan.waypoints.duplicate(true)
	var layouts: Dictionary = terminals.elevation.publicPavingPlan
	if not layouts.get("approach") is Rect2 or not Urban.RigidHouseholdLayoutRecipeScript._valid_rect(layouts.approach) or not layouts.has("standingY") or not market_plan.has("standingY"):
		return {"ready": false, "reason": "invalid_terminal_walk_frontage"}
	var approach: Rect2 = layouts.approach
	var front: Vector3 = terminals.front
	var cardinal_front := Vector3(roundf(front.x), 0, roundf(front.z))
	var standing_y := float(layouts.standingY)
	if waypoints.is_empty() or standing_y != float(market_plan.standingY) or not front.is_finite() or cardinal_front.length_squared() != 1.0 or front.distance_to(cardinal_front) > 0.00001:
		return {"ready": false, "reason": "terminal_walk_requires_same_level_cardinal_frontage"}
	front = cardinal_front
	var end: Vector3 = waypoints.back().position
	var centre := Vector3(approach.get_center().x, standing_y, approach.get_center().y)
	var seen_bays: Dictionary = {}
	for setup in terminals.setups:
		if not setup is Dictionary or not setup.get("prefix") is String:
			return {"ready": false, "reason": "invalid_terminal_walk_bay"}
		if seen_bays.has(setup.prefix):
			return {"ready": false, "reason": "duplicate_terminal_walk_bay"}
		seen_bays[setup.prefix] = true
		var counter = b.find_part(String(setup.prefix) + "_counter")
		if counter == null:
			return {"ready": false, "reason": "terminal_walk_missing_counter"}
		if not b.has_finite_positive_bounds(counter) or (b.part_transform(counter).basis * Vector3.FORWARD).distance_to(front) > 0.00001:
			return {"ready": false, "reason": "terminal_counter_orientation_mismatch"}
		var frontage_inner := INF
		for xz in [approach.position, approach.end, Vector2(approach.position.x, approach.end.y), Vector2(approach.end.x, approach.position.y)]:
			frontage_inner = minf(frontage_inner, Vector3(xz.x, 0, xz.y).dot(front))
		var counter_feet := Vector3(counter.position.x, standing_y, counter.position.z)
		var target_coordinate := maxf(counter_feet.dot(front) + counter.size.z * 0.5, frontage_inner) + RADIUS + 0.10
		var at_front: Vector3 = counter_feet + front * (target_coordinate - counter_feet.dot(front))
		var aisle: Vector3 = at_front + front * (centre - at_front).dot(front)
		for point in [at_front, aisle]:
			if not approach.encloses(Rect2(Vector2(point.x, point.z) - Vector2.ONE * RADIUS, Vector2.ONE * RADIUS * 2.0)):
				return {"ready": false, "reason": "terminal_target_outside_reserved_frontage", "partId": counter.id}
		var id := String(setup.prefix)
		if seen_bays.size() == 1:
			# Stay on the incoming aisle until aligned with the first counter.
			# Turning toward a stall before that point can cross its own seating.
			var junction := aisle + front * (end - aisle).dot(front)
			waypoints.append({"id": "terminal_frontage_connection", "position": junction, "standingY": standing_y, "capture": false})
		waypoints.append({"id": id + "_aisle", "position": aisle, "standingY": standing_y, "capture": false})
		waypoints.append({"id": id + "_front", "position": at_front, "standingY": standing_y, "capture": true, "faceDirection": -front})
		if setup != terminals.setups.back():
			waypoints.append({"id": id + "_return", "position": aisle, "standingY": standing_y, "capture": false})
	var compact: Array = waypoints.slice(0, market_plan.waypoints.size())
	for waypoint in waypoints.slice(market_plan.waypoints.size()):
		# The witness may stop within0.35m. Distinct targets need enough space
		# for a subsequent observed approach; never omit a required front visit.
		if (compact.back().position as Vector3).distance_to(waypoint.position) <= 0.70:
			if waypoint.capture:
				return {"ready": false, "reason": "terminal_capture_lacks_observable_approach"}
			continue
		compact.append(waypoint)
	waypoints = compact
	var checked := _check_itinerary(b, market_plan.start, waypoints, standing_y, furnishing_obstacles, true)
	checked["scope"] = "one continuous local walk from market courtyard through three markets and three terminal fronts"
	return checked


static func _check_itinerary(b, start: Vector3, waypoints: Array, standing_y: float, furnishing_obstacles: Array = [], include_visible_obstacles := false) -> Dictionary:
	if not start.is_finite() or not is_finite(standing_y) or waypoints.is_empty() or waypoints.size() > 64:
		return {"ready": false, "reason": "invalid_walk_itinerary"}
	for waypoint in waypoints:
		if not waypoint is Dictionary or not waypoint.get("position") is Vector3 or not waypoint.position.is_finite() or waypoint.position.y != standing_y or waypoint.get("standingY") != standing_y:
			return {"ready": false, "reason": "invalid_walk_waypoint"}
	var surfaces: Array[Rect2] = []
	var blockers: Array = []
	for part in b.parts:
		if part == null or not b.has_finite_positive_bounds(part):
			return {"ready": false, "reason": "invalid_walk_source_bounds"}
		var bounds: AABB = b.transformed_part_bounds(part)
		if Urban.is_primary_tree_paving(part) and part.collision_enabled and part.rotation == Vector3.ZERO and bounds.end.y == standing_y:
			surfaces.append(Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z)))
		var ground_detail: bool = Urban.RigidHouseholdLayoutRecipeScript._surface_detail(part) and bounds.end.y <= standing_y + 0.02
		var visible_obstacle: bool = include_visible_obstacles and not ground_detail
		if (part.collision_enabled or visible_obstacle) and bounds.end.y > standing_y + 0.02 and bounds.position.y < standing_y + HEIGHT:
			blockers.append({"id": part.id, "bounds": bounds})
	for obstacle in furnishing_obstacles:
		if not obstacle is Dictionary or not obstacle.get("bounds") is AABB or not Urban.RigidHouseholdLayoutRecipeScript._valid_bounds(obstacle.bounds):
			return {"ready": false, "reason": "invalid_walk_furnishing_obstacle"}
		blockers.append(obstacle)
	var points: Array = [start]
	for waypoint in waypoints: points.append(waypoint.position)
	var distance := 0.0
	for i in range(1, points.size()):
		var from: Vector3 = points[i - 1]
		var to: Vector3 = points[i]
		distance += from.distance_to(to)
		# A full-body swept box is conservative even for a short diagonal join.
		var sweep := AABB(from.min(to) + Vector3(-RADIUS, 0.02, -RADIUS), (to - from).abs() + Vector3(RADIUS * 2, HEIGHT - 0.02, RADIUS * 2))
		for blocker in blockers:
			if sweep.intersects(blocker.bounds):
				return {"ready": false, "reason": "diagnostic_aisle_blocked", "segment": i, "partId": blocker.id, "bounds": blocker.bounds, "start": start, "waypoints": waypoints}
		var samples := maxi(1, ceili(from.distance_to(to) / RADIUS))
		if samples > 1024:
			return {"ready": false, "reason": "walk_extent_limit"}
		for sample in range(samples + 1):
			var p := from.lerp(to, float(sample) / samples)
			for offset in [Vector2.ZERO, Vector2(-RADIUS, -RADIUS), Vector2(-RADIUS, RADIUS), Vector2(RADIUS, -RADIUS), Vector2(RADIUS, RADIUS)]:
				var xz: Vector2 = Vector2(p.x, p.z) + offset
				if not surfaces.any(func(surface): return surface.has_point(xz)):
					return {"ready": false, "reason": "diagnostic_aisle_lacks_public_paving", "segment": i, "point": p, "start": start, "waypoints": waypoints}
	return {"ready": true, "start": start, "standingY": standing_y, "waypoints": waypoints, "distance": distance,
		"observationObstacles": blockers if include_visible_obstacles else [],
		"doesNotProve": "Conservative source-only itinerary precheck; no publisher/tree/furniture/live collision or access proof. No alternative route search."}
