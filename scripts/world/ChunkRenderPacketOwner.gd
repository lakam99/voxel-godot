extends RefCounted
class_name ChunkRenderPacketOwner

const BACKEND_CLASS := "ChunkRenderPacketBackend"
const BACKEND_NODE := "ChunkRenderPacketBackend"


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
	var attached := attach_to_chunk(chunk)
	if attached.get("status") != "ready":
		attached["ownerCell"] = owner_cell
		return attached
	return {"status":"ready","backend":attached.backend,"chunk":chunk,"ownerCell":owner_cell}
