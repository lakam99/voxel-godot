extends RefCounted

## Single geometry owner for sacks, baskets and pottery. Descriptions contain
## only values: ordered primitive properties, local poses and material requests.
## Preserve the original publisher's scalar expression order before Vector3
## rounding. Material evaluation stays lazy and ordered in the publisher.
## Resource construction is separate, shared by publication and bounds queries;
## only the original explicit properties are assigned (other defaults survive).

static func describe(kind: String, size: Vector3) -> Array:
	match kind:
		"sack":
			return [
				_piece("cylinder", _cylinder(0.34, 0.48, 0.72, 10), Vector3(size.x, size.y, size.z), Vector3(0.0, -size.y * 0.08, 0.0), "ClothSackBody"),
				_piece("cylinder", _cylinder(0.22, 0.38, 0.28, 10), Vector3(size.x * 0.86, size.y * 0.42, size.z * 0.86), Vector3(0.0, size.y * 0.31, 0.0), "ClothSackShoulder"),
				_piece("box", {}, Vector3(size.x * 0.28, size.y * 0.08, size.z * 0.28), Vector3(0.0, size.y * 0.47, 0.0), "SackTie", {"mode": "id", "id": "timber_board", "subtract": 0.04}),
				_piece("box", {}, Vector3(size.x * 0.82, size.y * 0.08, size.z * 0.76), Vector3(0.0, -size.y * 0.45, 0.0), "SackSettledBase")
			]
		"pottery":
			return [
				_piece("cylinder", _cylinder(0.34, 0.47, 0.78, 12), Vector3(size.x, size.y, size.z), Vector3(0.0, -size.y * 0.06, 0.0), "PotteryBody"),
				_piece("cylinder", _cylinder(0.32, 0.38, 0.24, 12), Vector3(size.x * 0.72, size.y * 0.34, size.z * 0.72), Vector3(0.0, size.y * 0.38, 0.0), "PotteryNeck")
			]
		"basket":
			var pieces: Array = [
				_piece("cylinder", _cylinder(0.50, 0.40, 0.62, 12), Vector3(size.x, size.y, size.z), Vector3(0.0, -size.y * 0.10, 0.0), "WovenBasketBody"),
				_piece("torus", {"inner_radius": 0.37, "outer_radius": 0.50, "rings": 12, "ring_segments": 6}, Vector3(size.x, size.y * 0.24, size.z), Vector3(0.0, size.y * 0.30, 0.0), "BasketRim", {"mode": "id", "id": "timber_beam", "subtract": 0.02})
			]
			for side in [-1.0, 1.0]:
				pieces.append(_piece("box", {}, Vector3(size.x * 0.10, size.y * 0.72, size.z * 0.10), Vector3(side * size.x * 0.34, size.y * 0.28, 0.0), "BasketHandlePost", {"mode": "id", "id": "timber_beam"}))
			pieces.append(_piece("box", {}, Vector3(size.x * 0.78, size.y * 0.10, size.z * 0.10), Vector3(0.0, size.y * 0.62, 0.0), "BasketHandle", {"mode": "id", "id": "timber_beam"}))
			return pieces
	return []

static func create_mesh(piece: Dictionary) -> Mesh:
	var mesh: Mesh
	match piece.get("primitive", ""):
		"cylinder": mesh = CylinderMesh.new()
		"torus": mesh = TorusMesh.new()
		"box":
			# Publisher boxes still use its inherited unit_box. This factory
			# exposes the same unit primitive to other geometry consumers.
			var box := BoxMesh.new()
			box.size = Vector3.ONE
			mesh = box
		_: return null
	for property in piece.properties:
		mesh.set(property, piece.properties[property])
	return mesh

static func local_bounds(pieces: Array) -> Array:
	var boxes: Array = []
	for piece in pieces:
		var size: Vector3 = piece.size
		var position: Vector3 = piece.position
		if piece.primitive == "box":
			# Preserve the former placement probe's exact box arithmetic.
			boxes.append(AABB(position - size * 0.5, size))
		else:
			var mesh := create_mesh(piece)
			if mesh == null: return []
			boxes.append(Transform3D(Basis.from_scale(size), position) * mesh.get_aabb())
	return boxes

static func _cylinder(top: float, bottom: float, height: float, segments: int) -> Dictionary:
	# Dictionary insertion order preserves the original setter order.
	return {"top_radius": top, "bottom_radius": bottom, "height": height, "radial_segments": segments}

static func _piece(primitive: String, properties: Dictionary, size: Vector3, position: Vector3, node_name: String, material: Dictionary = {"mode": "part"}) -> Dictionary:
	return {"primitive": primitive, "properties": properties, "size": size, "position": position, "nodeName": node_name, "material": material}
