extends RefCounted
class_name GeneratedContentViewPriority

## Shared, scheduling-only view intent for generated content owners.  Values are
## deliberately quantized so camera jitter never rebuilds retained world demand.
## Geometry, collision, generation order and acceptance remain at their owners.
const POSITION_QUANTUM := 4.0
const DIRECTION_SECTORS := 16
const DEFAULT_FAR_DISTANCE := 180.0
const NEAR_RING_DISTANCE := 42.0
const PREDICTED_CORRIDOR_RADIUS := 24.0
const PORTAL_LOOK_THROUGH_DISTANCE := 52.0
const PORTAL_LOOK_THROUGH_HALF_WIDTH := 18.0

static func normalize(value: Variant) -> Dictionary:
	if value == null or not value is Dictionary or value.is_empty(): return {}
	if not value.get("origin") is Vector3 or not value.get("forward") is Vector3 \
			or not value.get("predictedOrigin") is Vector3:
		return {}
	var origin: Vector3 = value.origin
	var predicted: Vector3 = value.predictedOrigin
	var forward: Vector3 = value.forward
	if not origin.is_finite() or not predicted.is_finite() or not forward.is_finite(): return {}
	forward.y = 0.0
	if forward.length_squared() < 0.0001: return {}
	forward = forward.normalized()
	var angle := atan2(forward.z,forward.x)
	var step := TAU/float(DIRECTION_SECTORS)
	angle = roundf(angle/step)*step
	forward = Vector3(cos(angle),0.0,sin(angle))
	origin = _quantized_position(origin)
	predicted = _quantized_position(predicted)
	var fov_value: Variant = value.get("horizontalFovDegrees",72.0)
	var far_value: Variant = value.get("farDistance",DEFAULT_FAR_DISTANCE)
	if not (fov_value is float or fov_value is int) or not (far_value is float or far_value is int): return {}
	var fov := snappedf(clampf(float(fov_value),45.0,120.0),5.0)
	var far_distance := snappedf(clampf(float(far_value),64.0,256.0),16.0)
	return {"origin":origin,"forward":forward,"predictedOrigin":predicted,
		"horizontalFovDegrees":fov,"farDistance":far_distance}

static func ranked_groups(groups: Dictionary, view_intent: Dictionary) -> Array[Dictionary]:
	var view := normalize(view_intent)
	var result: Array[Dictionary] = []
	if view.is_empty():
		for id: String in groups:
			result.append({"id":id,"priority":4,"distanceSquared":INF,"portal":false,"throughPortal":false})
		result.sort_custom(_rank_precedes)
		return result
	var origin: Vector3 = view.origin
	var forward: Vector3 = view.forward
	var predicted: Vector3 = view.predictedOrigin
	var far_distance: float = view.farDistance
	var cone_cos := cos(deg_to_rad(float(view.horizontalFovDegrees)*0.5))
	var portal_id := ""
	var portal_score := INF
	for id: String in groups:
		var group: Dictionary = groups[id]
		if group.get("doorPartIds",[]).is_empty(): continue
		var center := _horizontal_center(group.get("bounds",AABB()))
		if not center.is_finite(): continue
		var delta := center-origin
		var distance := Vector2(delta.x,delta.z).length()
		var facing := 1.0 if distance<=0.001 else Vector3(delta.x,0.0,delta.z).normalized().dot(forward)
		if facing < cone_cos or distance > far_distance: continue
		var score := distance*(2.0-facing)
		if score<portal_score or is_equal_approx(score,portal_score) and id<portal_id:
			portal_score=score
			portal_id=id
	var portal_center := _horizontal_center(groups.get(portal_id,{}).get("bounds",AABB())) if not portal_id.is_empty() else Vector3.INF
	for id: String in groups:
		var group: Dictionary = groups[id]
		var center := _horizontal_center(group.get("bounds",AABB()))
		if not center.is_finite(): continue
		var delta := center-origin
		var horizontal := Vector2(delta.x,delta.z)
		var distance_squared := horizontal.length_squared()
		var distance := sqrt(distance_squared)
		var facing := 1.0 if distance<=0.001 else Vector3(delta.x,0.0,delta.z).normalized().dot(forward)
		var visible := distance<=NEAR_RING_DISTANCE*0.35 or (facing>=cone_cos and distance<=far_distance)
		var predicted_delta := Vector2(center.x-predicted.x,center.z-predicted.z)
		var predicted_near := predicted_delta.length_squared()<=PREDICTED_CORRIDOR_RADIUS*PREDICTED_CORRIDOR_RADIUS
		var through_portal := false
		if portal_center.is_finite() and id!=portal_id:
			var behind := center-portal_center
			var depth := Vector3(behind.x,0.0,behind.z).dot(forward)
			var lateral_vector := Vector3(behind.x,0.0,behind.z)-forward*depth
			through_portal = depth>=0.0 and depth<=PORTAL_LOOK_THROUGH_DISTANCE \
				and lateral_vector.length()<=PORTAL_LOOK_THROUGH_HALF_WIDTH+depth*0.18
		var priority := 4
		if id==portal_id or through_portal: priority=1
		elif visible or predicted_near: priority=2
		elif distance<=NEAR_RING_DISTANCE: priority=3
		result.append({"id":id,"priority":priority,"distanceSquared":distance_squared,
			"portal":id==portal_id,"throughPortal":through_portal})
	result.sort_custom(_rank_precedes)
	return result

static func _quantized_position(value: Vector3) -> Vector3:
	return Vector3(snappedf(value.x,POSITION_QUANTUM),snappedf(value.y,POSITION_QUANTUM),snappedf(value.z,POSITION_QUANTUM))

static func _horizontal_center(bounds: AABB) -> Vector3:
	if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.x<=0.0 or bounds.size.z<=0.0:
		return Vector3.INF
	var center := bounds.get_center()
	return Vector3(center.x,0.0,center.z)

static func _rank_precedes(a: Dictionary,b: Dictionary) -> bool:
	if int(a.priority)!=int(b.priority): return int(a.priority)<int(b.priority)
	if not is_equal_approx(float(a.distanceSquared),float(b.distanceSquared)):
		return float(a.distanceSquared)<float(b.distanceSquared)
	return String(a.id)<String(b.id)
