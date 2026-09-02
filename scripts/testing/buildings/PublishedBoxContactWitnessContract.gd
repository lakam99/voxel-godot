extends SceneTree

## Synthetic CPU geometry contract, not actual publication or visual acceptance.
const Witness = preload("res://scripts/testing/buildings/PublishedBoxContactWitness.gd")
const MINIMUM := 0.002 # Explicit two-millimetre nominal joint radius, not epsilon.
var _checks: Dictionary = {}
var _witnesses: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_BOX_CONTACT_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var identity := Transform3D.IDENTITY
	var rotation := Basis.from_euler(Vector3(0.37, -0.61, 0.23))
	var cases := {"identity": identity, "tilted_rotated": Transform3D(rotation, Vector3(2, -3, 4)), "nonuniform": Transform3D(rotation.scaled(Vector3(1.4, 0.8, 2.1)), Vector3(-4, 2, 1)), "mirrored": Transform3D(rotation.scaled(Vector3(-1.2, 0.7, 1.8)), Vector3(1, 3, -2))}
	for name in cases:
		for end in ["rear", "front"]:
			var first: Transform3D = cases[name]
			var peer := first * Transform3D(Basis.IDENTITY, Vector3(0, -0.5 if end == "rear" else 0.5, 0))
			var seconds: Array = [Transform3D(Basis.IDENTITY, Vector3(100, 100, 100)), peer]
			var before := var_to_bytes([first, seconds])
			var found := Witness.find_contact(first, seconds, end, MINIMUM)
			var key: String = name + ":" + end
			_checks[key] = _verify(first, peer, end, found) and found.get("peerIndex") == 1
			_checks[key + ":deterministic_immutable"] = var_to_bytes(found) == var_to_bytes(Witness.find_contact(first, seconds, end, MINIMUM)) and before == var_to_bytes([first, seconds])
			_witnesses[key] = found
	for name in ["separated", "tangent", "moved_peer"]:
		var y := -1.0 if name == "tangent" else -3.0
		_no_contact(name, identity, [Transform3D(Basis.IDENTITY, Vector3(0, y, 0))], "rear", MINIMUM, true)
	_no_contact("empty", identity, [], "rear", MINIMUM, true)
	_no_contact("oversized_radius", identity, [identity], "rear", 1.0, true)
	for value in [0.0, -MINIMUM, INF, NAN]:
		_no_contact("invalid_radius:" + str(value), identity, [identity], "rear", value, false)
	_no_contact("invalid_end", identity, [identity], "bottom", MINIMUM, false)
	_no_contact("malformed_peer_after_valid", identity, [identity, {}], "rear", MINIMUM, false)
	var singular := Transform3D(Basis(Vector3.ZERO, Vector3.UP, Vector3.BACK), Vector3.ZERO)
	var nonfinite := Transform3D(Basis.IDENTITY, Vector3(INF, 0, 0))
	var bad_basis := Transform3D(Basis(Vector3(NAN, 0, 0), Vector3.UP, Vector3.BACK), Vector3.ZERO)
	for bad in [singular, nonfinite, bad_basis]:
		_no_contact("invalid_first:" + str(bad), bad, [identity], "rear", MINIMUM, false)
		_no_contact("invalid_peer:" + str(bad), identity, [identity, bad], "rear", MINIMUM, false)
	var bounded: Array = []
	bounded.resize(4096)
	bounded.fill(identity)
	_checks["4096_peers_allowed"] = Witness.find_contact(identity, bounded, "rear", MINIMUM).get("found") == true
	bounded.append(identity)
	_no_contact("4097_peers_rejected", identity, bounded, "rear", MINIMUM, false)
	var passed: bool = _checks.values().all(func(value): return value == true)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify({"passed": passed, "checks": _checks, "witnesses": _witnesses, "minimumRadius": MINIMUM, "evidenceScope": "synthetic_transform_plane_proof_only", "doesNotProve": "No GPU readback, actual published joints, visuals, gameplay, or completeness of contact search."}, "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if passed and written else 1)

func _no_contact(name: String, first: Transform3D, peers: Array, end: String, radius: float, valid: bool) -> void:
	var result := Witness.find_contact(first, peers, end, radius)
	_checks[name] = result.get("found") == false and result.get("valid") == valid and not result.has("point") and int(result.get("samplecount", -1)) >= 0 and int(result.get("samplecount", 126)) <= 125

func _verify(first: Transform3D, peer: Transform3D, end: String, result: Dictionary) -> bool:
	if result.get("found") != true or result.get("valid") != true or not result.get("point") is Vector3: return false
	var point: Vector3 = result.point
	var radius: float = result.get("radius", -1.0)
	if not point.is_finite() or not is_finite(radius) or radius < MINIMUM or result.samplecount < 1 or result.samplecount > 125: return false
	var local := first.affine_inverse() * point
	if absf(local.x) >= 0.5 or absf(local.z) >= 0.5: return false
	if end == "rear" and (local.y <= -0.5 or local.y >= -0.2): return false
	if end == "front" and (local.y <= 0.2 or local.y >= 0.5): return false
	# Independent world-space face construction: cross products, not inverse rows.
	var proof := INF
	for box in [first, peer]:
		for axis in range(3):
			var edge: Vector3 = box.basis[axis]
			var normal: Vector3 = box.basis[(axis + 1) % 3].cross(box.basis[(axis + 2) % 3]).normalized()
			if normal.dot(edge) < 0.0: normal = -normal
			for side in [-1.0, 1.0]:
				var outward: Vector3 = normal * side
				var face: Vector3 = box.origin + edge * (side * 0.5)
				var clearance: float = outward.dot(face - point)
				if clearance < MINIMUM: return false
				proof = minf(proof, clearance)
	# Numerical agreement only; both independent eligibility thresholds above are strict.
	return is_equal_approx(radius, proof)
