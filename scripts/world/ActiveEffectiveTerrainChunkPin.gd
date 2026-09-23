extends RefCounted
class_name ActiveEffectiveTerrainChunkPin

## Read-only N3 pin admission for one 28-cell surface-prop chunk. The native
## backend owns source/delta/shaping facts; this wrapper never samples terrain.
const SCHEMA_VERSION := 1
const CHUNKS_PER_PAGE := 10

static func capture(backend: Object, seed: String, chunk: Vector2i) -> Dictionary:
	if backend == null or not is_instance_valid(backend) \
			or not backend.has_method("status") or not backend.has_method("pin_effective_page"):
		return _failed("backend_missing")
	var before: Dictionary = backend.status()
	if not _owner_ready(before, seed):
		return _failed("backend_source_not_ready")
	var page_key := Vector2i(floori(float(chunk.x) / CHUNKS_PER_PAGE),
		floori(float(chunk.y) / CHUNKS_PER_PAGE))
	var pin: Dictionary = backend.pin_effective_page(page_key)
	if pin.get("status") != "ready" or not pin.get("page") is Object:
		return _failed("effective_page_not_ready")
	var page: Object = pin.page
	if not is_instance_valid(page) or not page.has_method("status"):
		return _failed("effective_page_invalid")
	var page_status: Dictionary = page.status()
	var after: Dictionary = backend.status()
	if before != after or not _page_matches_owner(page_status, after, page_key):
		return _failed("effective_page_changed_during_capture")
	return {"ok":true, "schemaVersion":SCHEMA_VERSION,
		"scope":"native_effective_terrain_chunk_pin_only", "backendInstanceId":backend.get_instance_id(),
		"seed":seed, "chunk":chunk, "primaryPage":page_key,
		"ownerStatus":after.duplicate(true), "pageStatus":page_status.duplicate(true), "page":page}

static func is_current(backend: Object, seed: String, snapshot: Dictionary) -> bool:
	if backend == null or not is_instance_valid(backend) or not snapshot.get("ok", false) \
			or snapshot.get("schemaVersion") != SCHEMA_VERSION \
			or snapshot.get("scope") != "native_effective_terrain_chunk_pin_only" \
			or snapshot.get("backendInstanceId") != backend.get_instance_id() \
			or snapshot.get("seed") != seed or not snapshot.get("chunk") is Vector2i \
			or not snapshot.get("primaryPage") is Vector2i \
			or not snapshot.get("page") is Object \
			or not snapshot.get("ownerStatus") is Dictionary \
			or not snapshot.get("pageStatus") is Dictionary:
		return false
	var page: Object = snapshot.page
	if not is_instance_valid(page) or not page.has_method("status") \
			or not backend.has_method("status"):
		return false
	var expected_page := Vector2i(floori(float(snapshot.chunk.x) / CHUNKS_PER_PAGE),
		floori(float(snapshot.chunk.y) / CHUNKS_PER_PAGE))
	var owner: Dictionary = backend.status()
	return expected_page == snapshot.primaryPage and _owner_ready(owner, seed) \
		and owner == snapshot.ownerStatus \
		and page.status() == snapshot.pageStatus \
		and _page_matches_owner(snapshot.pageStatus, owner, expected_page)

static func _owner_ready(status: Dictionary, seed: String) -> bool:
	return status.get("status") == "ready" and status.get("sourceSeedText") == seed \
		and not seed.is_empty() and _valid_identity(status.get("sourceIdentity")) \
		and _valid_identity(status.get("shapingRegistryIdentity")) \
		and status.get("terrainDeltaRevision") is int \
		and status.get("shapingRegistryRevision") is int

static func _page_matches_owner(page: Dictionary, owner: Dictionary, key: Vector2i) -> bool:
	return page.get("status") == "ready" and page.get("primaryPage") == key \
		and page.get("sourceIdentity") == owner.get("sourceIdentity") \
		and page.get("terrainDeltaRevision") == owner.get("terrainDeltaRevision") \
		and page.get("shapingRegistryRevision") == owner.get("shapingRegistryRevision") \
		and page.get("shapingRegistryIdentity") == owner.get("shapingRegistryIdentity") \
		and _valid_identity(page.get("pinIdentity"))

static func _valid_identity(value: Variant) -> bool:
	if not value is Dictionary or value.get("algorithm") != "sha256":
		return false
	var hex: Variant = value.get("hex")
	return hex is String and hex.length() == 64 and hex == hex.to_lower() \
		and hex.is_valid_hex_number(false)

static func _failed(reason: String) -> Dictionary:
	return {"ok":false, "reason":reason}
