extends RefCounted

## Conservative construction admission for represented affine source boxes.
## This does not replace collision publication or certify rendered mesh clearance.
static func measure(first: Transform3D, second: Transform3D) -> Dictionary:
	if not _valid(first) or not _valid(second): return {"valid": false, "clear": false, "reason": "invalid_box"}
	var a := [first.basis.x, first.basis.y, first.basis.z]
	var b := [second.basis.x, second.basis.y, second.basis.z]
	var axes: Array = []
	for index in range(3):
		axes.append(_cross(a[index], a[(index + 1) % 3]))
		axes.append(_cross(b[index], b[(index + 1) % 3]))
		for other in range(3): axes.append(_cross(a[index], b[other]))
	var gap := -INF
	for axis: Array in axes:
		var length := sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2])
		# Omitting a degenerate candidate axis can only prevent admission.
		if length <= 1.0e-12: continue
		for component in range(3): axis[component] /= length
		var radius := 0.0
		for index in range(3): radius += 0.5 * (absf(_dot(axis, a[index])) + absf(_dot(axis, b[index])))
		var distance := 0.0
		for component in range(3): distance += axis[component] * (float(first.origin[component]) - float(second.origin[component]))
		gap = maxf(gap, absf(distance) - radius)
	if not is_finite(gap): return {"valid": false, "clear": false, "reason": "invalid_projection"}
	var cardinal := _cardinal(first.basis) and _cardinal(second.basis)
	var magnitude := 1.0
	for pose: Transform3D in [first, second]:
		for component in range(3): magnitude = maxf(magnitude, absf(float(pose.origin[component])))
	var guard := magnitude * 1.0e-10
	# Exact cardinal face contact has no positive-volume intersection. Rotated
	# uncertain contact is not treated as clear, and no solids are shrunk.
	var clear := gap >= 0.0 if cardinal else gap > guard
	return {"valid": true, "clear": clear, "greatestAxisGap": gap, "cardinal": cardinal,
		"roundingGuard": 0.0 if cardinal else guard, "reason": "" if clear else ("overlap" if gap < -guard else "unresolved_contact")}

static func _valid(pose: Transform3D) -> bool:
	if not pose.origin.is_finite(): return false
	var product := 1.0
	for axis in range(3):
		if absf(pose.origin[axis]) > 100000.0 or not pose.basis[axis].is_finite(): return false
		var length := pose.basis[axis].length()
		if length < 0.0001 or length > 10000.0: return false
		product *= length
	var determinant := pose.basis.determinant()
	return is_finite(determinant) and absf(determinant) > product * 1.0e-10

static func _cardinal(basis: Basis) -> bool:
	var used: Dictionary = {}
	for axis in range(3):
		var row := -1
		for component in range(3):
			if basis[axis][component] == 0.0: continue
			if row != -1: return false
			row = component
		if row == -1 or used.has(row): return false
		used[row] = true
	return true

static func _cross(a: Vector3, b: Vector3) -> Array:
	return [float(a.y) * float(b.z) - float(a.z) * float(b.y), float(a.z) * float(b.x) - float(a.x) * float(b.z), float(a.x) * float(b.y) - float(a.y) * float(b.x)]

static func _dot(a: Array, b: Vector3) -> float:
	return a[0] * float(b.x) + a[1] * float(b.y) + a[2] * float(b.z)
