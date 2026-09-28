extends RefCounted

## Pure CPU evidence for supplied rendered unit-box transforms; no GPU readback.
## A failed bounded search does not prove absence of a contact elsewhere.
static func find_contact(first: Transform3D, seconds: Array, end: String, minimum_radius: float) -> Dictionary:
	var result := {"found": false, "valid": false, "radius": 0.0, "peerIndex": -1, "samplecount": 0, "reason": "invalid_input"}
	if end not in ["rear", "front"] or not is_finite(minimum_radius) or minimum_radius <= 0.0 or seconds.size() > 4096:
		return result
	var owner := _planes(first)
	if owner.is_empty(): return result
	var peers: Array = []
	for value in seconds:
		if not value is Transform3D: return result
		var peer := _planes(value)
		if peer.is_empty(): return result
		peers.append(peer)
	result.valid = true
	result.reason = "no_sampled_witness_not_proof_of_absence"
	if peers.is_empty(): return result
	# Five cell centers in each dimension, strictly inside the selected cap.
	# The requested radius is a physical length, never a numerical tolerance.
	var cap_start := -0.5 if end == "rear" else 0.2
	for y in range(5):
		for x in range(5):
			for z in range(5):
				var local := Vector3(-0.5 + (x + 0.5) / 5.0, cap_start + (y + 0.5) * 0.3 / 5.0, -0.5 + (z + 0.5) / 5.0)
				var point := first * local
				result.samplecount += 1
				if not point.is_finite():
					result.valid = false
					result.reason = "nonfinite_sample"
					return result
				var own_radius := _radius(owner, point)
				if own_radius < minimum_radius: continue
				for index in range(peers.size()):
					var radius := minf(own_radius, _radius(peers[index], point))
					if radius >= minimum_radius:
						result.merge({"found": true, "point": point, "radius": radius, "peerIndex": index, "reason": "sampled_interior_ball"}, true)
						return result
	return result

static func _planes(transform: Transform3D) -> Dictionary:
	if not transform.origin.is_finite() or not transform.basis.is_finite(): return {}
	var determinant := transform.basis.determinant()
	if not is_finite(determinant) or determinant == 0.0: return {}
	var inverse := transform.affine_inverse()
	if not inverse.origin.is_finite() or not inverse.basis.is_finite(): return {}
	var rows := inverse.basis.transposed()
	var norms := Vector3(rows.x.length(), rows.y.length(), rows.z.length())
	if not norms.is_finite() or norms.x <= 0.0 or norms.y <= 0.0 or norms.z <= 0.0: return {}
	return {"inverse": inverse, "norms": norms}

static func _radius(planes: Dictionary, point: Vector3) -> float:
	var local: Vector3 = planes.inverse * point
	if not local.is_finite(): return -INF
	var distances: Vector3 = (Vector3.ONE * 0.5 - local.abs()) / planes.norms
	return minf(distances.x, minf(distances.y, distances.z))
