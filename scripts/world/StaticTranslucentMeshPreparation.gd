extends RefCounted
## Derived mesh data only. Source recipes/revisions remain independent of POV.
## One source instance remains one geometry owner; its faces are sorted in
## world-metric coordinates, including nonuniform source scale.
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Fingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
# Completed derived artifacts only, never source readiness or pending work.
# Resources are Main-owned; no Node, RID, WeakRef, or callback is retained.
const MAX_CACHE_ENTRIES := 64
const MAX_CACHE_BYTES := 8 * 1024 * 1024
const MAX_ENTRY_BYTES := 512 * 1024
const MAX_SORT_VARIANTS := 2
static var _cache: Dictionary = {}
static var _cache_order: Array[String] = []
static var _cache_bytes := 0

static func clear_cache() -> void:
	_cache.clear()
	_cache_order.clear()
	_cache_bytes = 0

static func cache_diagnostics() -> Dictionary:
	return {"entryCount":_cache.size(), "estimatedBytes":_cache_bytes,
		"entryLimit":MAX_CACHE_ENTRIES, "byteLimit":MAX_CACHE_BYTES}

static func _retain(key: String, entry: Dictionary) -> void:
	var bytes := int(entry.get("bytes",0))
	if bytes <= 0 or bytes > MAX_ENTRY_BYTES: return
	if _cache.has(key): _cache_bytes -= int(_cache[key].bytes)
	_cache_order.erase(key)
	_cache[key] = entry
	_cache_order.append(key)
	_cache_bytes += bytes
	while _cache.size() > MAX_CACHE_ENTRIES or _cache_bytes > MAX_CACHE_BYTES:
		var oldest: String = _cache_order.pop_front()
		_cache_bytes -= int(_cache[oldest].bytes)
		_cache.erase(oldest)

static func prepare(group: Dictionary, pov: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	var metrics := {"canonicalUsec":0,"sortUsec":0,"materializeUsec":0,"fingerprintUsec":0,
		"canonicalHits":0,"sortedHits":0}
	if pov.get("status") != "ready" or not pov.get("cameraPosition") is Vector3 \
			or not pov.cameraPosition.is_finite() or not pov.get("revision") is int \
			or int(pov.revision) <= 0:
		return {"status":"pending", "reason":"citadel_translucent_pov_unavailable"}
	if group.has("compoundAnchor") or not String(group.get("attachmentKey", "")).is_empty():
		return {"status":"pending", "reason":"citadel_translucent_moving_attachment_unsupported"}
	var source_mesh: Mesh = group.resourceBindings.mesh
	var prepared: Array[Dictionary] = []
	for segment: Dictionary in group.segments:
		for instance_index: int in range(int(segment.instanceCount)):
			var offset := instance_index * Attributes.FLOATS_PER_INSTANCE
			var world_transform: Transform3D = group.sourceToWorld * Attributes.decode_transform(segment.buffer, offset)
			if absf(world_transform.basis.determinant()) < 0.000001:
				return {"status":"failed", "reason":"citadel_translucent_singular_transform"}
			var world_bounds: AABB = world_transform * source_mesh.get_aabb()
			var origin := world_bounds.get_center()
			var section := Grid.key_for_world_position(origin)
			var camera: Vector3 = pov.cameraPosition - origin
			var cache_key := String(group.contentDigest) + ":" + String(segment.segmentId) + ":" + str(instance_index)
			var cached: Dictionary = _cache.get(cache_key,{})
			var camera_section := Grid.key_for_world_position(pov.cameraPosition)
			var relative := Vector3i(clampi(camera_section.x-section.x,-1,1),
				clampi(camera_section.y-section.y,-1,1),clampi(camera_section.z-section.z,-1,1))
			var sort_key := relative.x+1+(relative.y+1)*3+(relative.z+1)*9+1
			var cached_variant: Dictionary = cached.get("variants",{}).get(sort_key,{})
			if not cached_variant.is_empty():
				var accepted := cached_variant.duplicate(false)
				var descriptor: Dictionary = accepted.descriptor.duplicate(false)
				descriptor["povRevision"] = pov.revision
				descriptor.make_read_only()
				accepted["descriptor"] = descriptor
				prepared.append(accepted)
				metrics.sortedHits += 1
				_cache_order.erase(cache_key)
				_cache_order.append(cache_key)
				continue
			var canonical_surfaces: Array = cached.get("surfaces",[]).duplicate()
			var canonical_bytes := int(cached.get("canonicalBytes",0))
			var mesh := ArrayMesh.new()
			var surfaces: Array[Dictionary] = []
			for surface_index: int in range(source_mesh.get_surface_count()):
				# BoxMesh is the production window primitive and always emits triangles.
				# PrimitiveMesh exposes neither this ArrayMesh method nor a primitive_type property.
				var primitive := Mesh.PRIMITIVE_TRIANGLES if source_mesh is BoxMesh else -1
				if source_mesh is ArrayMesh: primitive = source_mesh.surface_get_primitive_type(surface_index)
				if primitive != Mesh.PRIMITIVE_TRIANGLES:
					return {"status":"failed", "reason":"citadel_translucent_nontriangle_mesh"}
				var phase_start := Time.get_ticks_usec()
				var arrays: Array
				var faces: Array[Dictionary]
				if surface_index < canonical_surfaces.size():
					arrays = canonical_surfaces[surface_index].arrays.duplicate(false)
					faces.assign(canonical_surfaces[surface_index].faces)
					metrics.canonicalHits += 1
				else:
					arrays = source_mesh.surface_get_arrays(surface_index).duplicate(true)
					var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
					for index: int in range(vertices.size()): vertices[index] = world_transform * vertices[index] - origin
					arrays[Mesh.ARRAY_VERTEX] = vertices
					if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
						var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
						var normal_basis := world_transform.basis.inverse().transposed()
						for index: int in range(normals.size()): normals[index] = (normal_basis * normals[index]).normalized()
						arrays[Mesh.ARRAY_NORMAL] = normals
					if arrays[Mesh.ARRAY_TANGENT] is PackedFloat32Array:
						var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
						for index: int in range(0, tangents.size(), 4):
							var tangent := (world_transform.basis * Vector3(tangents[index], tangents[index+1], tangents[index+2])).normalized()
							tangents[index] = tangent.x
							tangents[index+1] = tangent.y
							tangents[index+2] = tangent.z
							tangents[index+3] *= signf(world_transform.basis.determinant())
						arrays[Mesh.ARRAY_TANGENT] = tangents
					var indices := PackedInt32Array()
					if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array: indices = arrays[Mesh.ARRAY_INDEX]
					if indices.is_empty():
						for index: int in range(vertices.size()): indices.append(index)
					if indices.is_empty() or indices.size() % 6 != 0:
						return {"status":"failed", "reason":"citadel_translucent_quad_topology_required"}
					faces = []
					for first: int in range(0, indices.size(), 6):
						var unique: Dictionary = {}
						var face_indices := PackedInt32Array()
						for index: int in range(first, first+6):
							var vertex_index := indices[index]
							if vertex_index < 0 or vertex_index >= vertices.size():
								return {"status":"failed", "reason":"citadel_translucent_index_out_of_bounds"}
							unique[vertex_index] = true
							face_indices.append(vertex_index)
						var centroid := Vector3.ZERO
						for vertex_index: int in unique: centroid += vertices[vertex_index]
						centroid /= float(unique.size())
						faces.append({"groupId":"face:%08d" % (first/6), "centroid":centroid, "indices":face_indices})
					# Packed array lanes use copy-on-write. The retained canonical arrays
					# are never mutated; sorting replaces only the index lane of a copy.
					var canonical_arrays := arrays.duplicate(false)
					canonical_arrays.make_read_only()
					var canonical_faces := faces.duplicate()
					for face: Dictionary in canonical_faces: face.make_read_only()
					canonical_faces.make_read_only()
					var canonical := {"arrays":canonical_arrays, "faces":canonical_faces}
					canonical.make_read_only()
					canonical_surfaces.append(canonical)
					for lane: Variant in arrays:
						var lane_bytes := Fingerprint._packed_array_bytes(lane)
						if lane_bytes < 0: return {"status":"failed", "reason":"citadel_glass_cache_unmeasurable_lane"}
						canonical_bytes += lane_bytes
					canonical_bytes += indices.size()*4 + faces.size()*256 + 512
				metrics.canonicalUsec += Time.get_ticks_usec()-phase_start
				phase_start = Time.get_ticks_usec()
				faces.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
					var ad: float = a.centroid.distance_squared_to(camera)
					var bd: float = b.centroid.distance_squared_to(camera)
					return String(a.groupId) < String(b.groupId) if is_equal_approx(ad, bd) else ad > bd)
				var sorted_indices := PackedInt32Array()
				var face_groups: Array[Dictionary] = []
				for face: Dictionary in faces:
					var row := {"groupId":face.groupId, "centroid":face.centroid,
						"firstIndex":sorted_indices.size(), "indexCount":6}
					row.make_read_only()
					face_groups.append(row)
					sorted_indices.append_array(face.indices)
				arrays[Mesh.ARRAY_INDEX] = sorted_indices
				metrics.sortUsec += Time.get_ticks_usec()-phase_start
				phase_start = Time.get_ticks_usec()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				mesh.surface_set_material(surface_index, source_mesh.surface_get_material(surface_index))
				metrics.materializeUsec += Time.get_ticks_usec()-phase_start
				face_groups.make_read_only()
				var surface := {"surfaceIndex":surface_index, "faceGroups":face_groups}
				surface.make_read_only()
				surfaces.append(surface)
			var fingerprint_start := Time.get_ticks_usec()
			var fingerprint := Fingerprint.inspect(mesh)
			metrics.fingerprintUsec += Time.get_ticks_usec()-fingerprint_start
			if fingerprint.get("status") != "ready": return fingerprint
			surfaces.make_read_only()
			var descriptor := {"schema":"section-translucent-face-groups/v1", "sectionKey":section,
				"sectionGeneration":-1, "povRevision":pov.revision, "cameraPosition":camera,
				"meshContentDigest":fingerprint.contentDigest, "surfaces":surfaces}
			descriptor.make_read_only()
			var color := Color(float(segment.buffer[offset+12]), float(segment.buffer[offset+13]),
				float(segment.buffer[offset+14]), float(segment.buffer[offset+15]))
			var buffer: Array[float] = Attributes.encode_transform(Transform3D.IDENTITY, segment.buffer, offset, color)
			buffer.make_read_only()
			var prepared_row := {"mesh":mesh, "meshContentDigest":fingerprint.contentDigest,
				"sourceToWorld":Transform3D(Basis.IDENTITY, origin), "buffer":buffer,
				"segmentId":"%s:glass:%06d" % [String(segment.segmentId), instance_index],
				"descriptor":descriptor}
			prepared_row.make_read_only()
			prepared.append(prepared_row)
			var variants: Dictionary = cached.get("variants",{}).duplicate()
			var variant_order: Array = cached.get("variantOrder",[]).duplicate()
			variants[sort_key] = prepared_row
			variant_order.erase(sort_key)
			variant_order.append(sort_key)
			while variant_order.size() > MAX_SORT_VARIANTS:
				variants.erase(variant_order.pop_front())
			_retain(cache_key,{"surfaces":canonical_surfaces,"canonicalBytes":canonical_bytes,
				"variants":variants,"variantOrder":variant_order,
				"bytes":canonical_bytes*(1+variants.size())})
	return {"status":"ready", "groups":prepared, "bakeUsec":Time.get_ticks_usec()-started,"phases":metrics,"cache":cache_diagnostics()}
