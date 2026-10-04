extends RefCounted
class_name ChunkRenderPacketOwner

const BACKEND_CLASS := "ChunkRenderPacketBackend"
const BACKEND_NODE := "ChunkRenderPacketBackend"
const SectionInstallSession = preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const SectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")


static func attach_to_chunk(chunk: Node3D) -> Dictionary:
	if not is_instance_valid(chunk) or not chunk.name.begins_with("Chunk_"):
		return {"status":"failed","reason":"invalid_chunk_owner"}
	if not ClassDB.class_exists(BACKEND_CLASS):
		return {"status":"unavailable","reason":"native_chunk_render_packet_backend_missing"}
	var existing := chunk.get_node_or_null(BACKEND_NODE) as Node3D
	if existing != null:
		return {"status":"ready","backend":existing}
	var backend := ClassDB.instantiate(BACKEND_CLASS) as Node3D
	if backend == null:
		return {"status":"failed","reason":"native_chunk_render_packet_backend_create_failed"}
	backend.name = BACKEND_NODE
	chunk.add_child(backend)
	return {"status":"ready","backend":backend}


static func resolve_current_scene_backend(owner_cell: Vector2i) -> Dictionary:
	var chunk_result := _resolve_current_scene_chunk(owner_cell)
	if chunk_result.get("status") != "ready": return chunk_result
	var chunk: Node3D = chunk_result.chunk
	var attached := attach_to_chunk(chunk)
	if attached.get("status") != "ready":
		attached["ownerCell"] = owner_cell
		return attached
	return {"status":"ready","backend":attached.backend,"chunk":chunk,"ownerCell":owner_cell}


static func resolve_existing_scene_backend(owner_cell: Vector2i) -> Dictionary:
	var chunk_result := _resolve_current_scene_chunk(owner_cell)
	if chunk_result.get("status") != "ready": return chunk_result
	var chunk: Node3D = chunk_result.chunk
	var backend := chunk.get_node_or_null(BACKEND_NODE) as Node3D
	if backend == null: return {"status":"pending","reason":"chunk_packet_backend_not_attached","ownerCell":owner_cell}
	return {"status":"ready","backend":backend,"chunk":chunk,"ownerCell":owner_cell}


## Section slots use a render owner whose lifetime follows render demand, not
## the gameplay chunk dictionary. Captured candidate values remain valid after
## source chunks unload; the canonical owner still gates slot installation and
## native receipt identity.
static func resolve_current_static_section_backend(owner_cell: Vector2i) -> Dictionary:
	var owner_result := _resolve_static_section_owner(owner_cell, true)
	if owner_result.get("status") != "ready":
		return owner_result
	var owner: Node3D = owner_result.owner as Node3D
	var backend: Node3D = owner.get_node_or_null(BACKEND_NODE) as Node3D
	if backend == null:
		var attached := attach_to_chunk(owner)
		if attached.get("status") != "ready":
			return attached
		backend = attached.backend as Node3D
	return {"status":"ready","backend":backend,"chunk":owner,"ownerCell":owner_cell}


static func resolve_existing_static_section_backend(owner_cell: Vector2i) -> Dictionary:
	var owner_result := _resolve_static_section_owner(owner_cell, false)
	if owner_result.get("status") != "ready":
		return owner_result
	var owner: Node3D = owner_result.owner as Node3D
	var backend := owner.get_node_or_null(BACKEND_NODE) as Node3D
	if backend == null:
		return {"status":"pending","reason":"section_owner_backend_not_attached",
			"ownerCell":owner_cell}
	return {"status":"ready","backend":backend,"chunk":owner,"ownerCell":owner_cell}


static func begin_static_section_install(candidate: Dictionary,
		material_bindings: Dictionary, mesh_bindings: Dictionary) -> Dictionary:
	if not candidate.is_read_only() or not candidate.get("sectionKey") is Vector3i:
		return {"status":"failed", "reason":"invalid_section_candidate_header"}
	var owner_cell: Vector2i = SectionGrid.chunk_key_for_section(candidate.sectionKey)
	var owner := resolve_current_static_section_backend(owner_cell)
	if owner.get("status") != "ready":
		return owner
	var session = SectionInstallSession.new()
	var begun: Dictionary = session.begin(owner.backend, owner.chunk, candidate,
		material_bindings, mesh_bindings)
	if begun.get("status") != "begun":
		return begun
	return {"status":"ready", "session":session,
		"backend":owner.backend, "chunk":owner.chunk, "ownerCell":owner_cell,
		"candidate":begun}


static func _resolve_current_scene_chunk(owner_cell: Vector2i) -> Dictionary:
	var scene := Engine.get_main_loop() as SceneTree
	if scene == null or scene.current_scene == null:
		return {"status":"pending","reason":"current_world_scene_unavailable"}
	var has_chunks := false
	for property: Dictionary in scene.current_scene.get_property_list():
		if String(property.get("name","")) == "chunks":
			has_chunks = true
			break
	if not has_chunks:
		return {"status":"failed","reason":"current_world_chunk_registry_missing"}
	var chunks: Variant = scene.current_scene.get("chunks")
	if not chunks is Dictionary:
		return {"status":"failed","reason":"current_world_chunk_registry_invalid"}
	var chunk: Variant = chunks.get(owner_cell)
	if not chunk is Node3D or not is_instance_valid(chunk) or not chunk.is_inside_tree():
		return {"status":"pending","reason":"owner_chunk_not_loaded","ownerCell":owner_cell}
	if String(chunk.name) != "Chunk_%d_%d" % [owner_cell.x,owner_cell.y]:
		return {"status":"failed","reason":"owner_chunk_identity_mismatch"}
	return {"status":"ready","chunk":chunk,"ownerCell":owner_cell}


static func _resolve_static_section_owner(owner_cell: Vector2i, create_if_missing: bool) -> Dictionary:
	var scene := Engine.get_main_loop() as SceneTree
	if scene == null or scene.current_scene == null:
		return {"status":"pending","reason":"current_world_scene_unavailable"}
	if not scene.current_scene.has_method("get_static_section_render_owner"):
		return {"status":"failed","reason":"static_section_owner_registry_missing"}
	var resolved: Variant = scene.current_scene.call("get_static_section_render_owner",
		owner_cell, create_if_missing)
	if not resolved is Dictionary:
		return {"status":"failed","reason":"static_section_owner_registry_invalid"}
	if resolved.get("status") != "ready":
		return resolved
	var owner: Variant = resolved.get("owner")
	var backend: Variant = resolved.get("backend")
	if not owner is Node3D or not is_instance_valid(owner) or not owner.is_inside_tree() \
			or String(owner.name) != "Chunk_%d_%d" % [owner_cell.x, owner_cell.y] \
			or not backend is Node3D or not is_instance_valid(backend) \
			or backend.get_parent() != owner:
		return {"status":"failed","reason":"static_section_owner_identity_mismatch",
			"ownerCell":owner_cell}
	return {"status":"ready","owner":owner,"backend":backend,"ownerCell":owner_cell}
