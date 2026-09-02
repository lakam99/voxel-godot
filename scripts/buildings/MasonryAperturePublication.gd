extends RefCounted

## Private, resumable renderer preparation. Mesh resources never enter recipes.
const Aperture = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const Cuts = preload("res://scripts/buildings/MasonryApertureGeometry.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Materials = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const MAX_PARTS := 512
const MAX_BRICKS := 8192
const MAX_VERTICES := 262144
const MAX_FRAGMENTS := 32768
const MAX_WORK := 16000000
var state := "pending_budget"
var reason := ""
var _blueprint
var _source_count := 0
var _source_order: Array = []
var _requests: Array = []
var _by_id: Dictionary = {}
var _marked: Dictionary = {}
var _declarations: Dictionary = {}
var _artifacts: Dictionary = {}
var _context := PackedByteArray()
var _part_cursor := 0
var _brick_cursor := 0
var _solids: Array = []
var _current: Dictionary = {}
var _unit_snapshot
var _unit_owner: WeakRef
var _unit_binding := PackedByteArray()
var metrics := {"parts": 0, "bricks": 0, "changedBricks": 0, "turns": 0, "maxSliceUsec": 0, "maxUnitUsec": 0, "preparationUsec": 0,
	"beginUsec": 0, "maxDeclarationUsec": 0, "declarationsValidated": 0, "maxDescriptorUsec": 0, "finalValidationUsec": 0, "vertices": 0, "fragments": 0, "work": 0, "sliceOverruns": 0}

func begin(b, publisher) -> bool:
	var started := Time.get_ticks_usec()
	_blueprint = b
	_unit_owner = weakref(publisher)
	_context = context_binding(publisher)
	if b == null: return _fail("missing_source")
	_source_count = b.parts.size()
	if not b.parts.any(func(part): return part != null and part.recipe.has("masonryApertureSource")):
		state = "ready"
		return true
	if b.parts.size() > 10000: return _fail("source_limit")
	_unit_binding = Cuts.UnitSnapshot.source_binding(publisher.unit_box)
	if _unit_binding.is_empty(): return _fail("invalid_unit_box_source")
	_source_order = b.parts.duplicate()
	var marked_parts: Array = []
	for part in b.parts:
		if part == null or part.id.is_empty() or _by_id.has(part.id): return _fail("invalid_source_ids")
		_by_id[part.id] = part
		if part.recipe.has("masonryApertureSource"): marked_parts.append(part)
	for part in marked_parts:
		if _requests.size() >= MAX_PARTS: return _fail("part_limit")
		var key: Variant = part.recipe.masonryApertureSource
		if not key is String or key.is_empty() or part.kind != "wall" or not Materials.is_masonry_material(part.material_id) or part.recipe.get("visual", true) != true:
			return _fail("invalid_masonry_declaration")
		if not b.recipe.get("facadeApertures") is Dictionary: return _fail("invalid_aperture_collection")
		var record: Variant = b.recipe.facadeApertures.get(key)
		if not record is Dictionary or not record.get("partIds") is Array or not record.partIds.has(part.id) or record.get("producerPrefix") != key or not record.get("openings") is Array or record.openings.is_empty() or record.openings.size() > 16:
			return _fail("unbound_masonry_apertures")
		if not _declarations.has(key):
			var volumes: Array[AABB] = []
			for opening in record.openings:
				if not opening is Dictionary or not opening.get("fullVolume") is AABB: return _fail("invalid_aperture")
				var volume: AABB = opening.fullVolume
				if not volume.position.is_finite() or not volume.end.is_finite() or volume.size.x <= 0 or volume.size.y <= 0 or volume.size.z <= 0: return _fail("invalid_aperture")
				volumes.append(volume)
			_declarations[key] = {"record": var_to_bytes(record), "volumes": volumes, "validated": false, "geometry": {}}
		var snapshot: Dictionary = part.snapshot()
		_requests.append({"part": part, "snapshot": snapshot, "source": var_to_bytes(snapshot),
			"key": key, "record": _declarations[key].record, "volumes": _declarations[key].volumes})
		_marked[part.id] = part
	metrics.parts = _requests.size()
	if _requests.is_empty(): state = "ready"
	metrics.beginUsec = Time.get_ticks_usec() - started
	return true

func advance(publisher, budget_usec: int = 2500) -> String:
	if state != "pending_budget": return state
	if budget_usec < 1 or budget_usec > 4000:
		_fail("invalid_slice_budget")
		return state
	var started := Time.get_ticks_usec()
	metrics.turns += 1
	if context_binding(publisher) != _context: _fail("stale_masonry_context")
	var units := 0
	# A very small budget must still make progress after context validation.
	# Units and overruns remain measured; the requested duration is not hidden.
	while state == "pending_budget" and (units == 0 or Time.get_ticks_usec() - started < budget_usec):
		units += 1
		var unit_started := Time.get_ticks_usec()
		if _unit_snapshot == null and not _requests.is_empty():
			_unit_snapshot = Cuts.UnitSnapshot.new()
			if not unit_source_pending_matches(publisher) or not _unit_snapshot.capture(publisher.unit_box, metrics): _fail("invalid_unit_box_snapshot")
		elif _part_cursor == _requests.size():
			if _validate_all(publisher): state = "ready"
			metrics.finalValidationUsec = Time.get_ticks_usec() - unit_started
		elif _current.is_empty():
			var request: Dictionary = _requests[_part_cursor]
			if not _request_valid(request): break
			if not _declarations[request.key].validated:
				_validate_declaration(request.key)
				var declaration_usec := Time.get_ticks_usec() - unit_started
				metrics.maxDeclarationUsec = maxi(metrics.maxDeclarationUsec, declaration_usec)
				metrics.maxUnitUsec = maxi(metrics.maxUnitUsec, declaration_usec)
				continue
			var source_part := Part.new(request.snapshot)
			var geometry: Dictionary = publisher.describe_masonry(source_part)
			_solids = publisher.masonry_brick_solids(source_part, geometry)
			metrics.maxDescriptorUsec = maxi(metrics.maxDescriptorUsec, Time.get_ticks_usec() - unit_started)
			if _solids.size() + metrics.bricks > MAX_BRICKS:
				_fail("aggregate_brick_limit")
				break
			_current = {"geometry": geometry, "entries": [], "preparedMeshes": {}, "provenance": []}
			_brick_cursor = 0
		elif _brick_cursor < _solids.size():
			var request: Dictionary = _requests[_part_cursor]
			var result := Cuts.prepare([_solids[_brick_cursor]], request.volumes, publisher.unit_box, metrics, _unit_snapshot)
			if not result.ready:
				_fail("masonry_cut:" + result.reason)
				break
			var fragment_count: int = result.entries.reduce(func(total, entry): return total + entry.cells.size(), 0)
			metrics.vertices += result.vertexCount
			metrics.fragments += fragment_count
			metrics.work += result.clippingWork + result.verificationWork
			if metrics.vertices > MAX_VERTICES or metrics.fragments > MAX_FRAGMENTS or metrics.work > MAX_WORK:
				_fail("aggregate_resource_limit")
				break
			_current.entries.append_array(result.entries)
			_current.preparedMeshes.merge(result.preparedMeshes)
			_current.provenance.append_array(result.provenance)
			metrics.bricks += 1
			metrics.changedBricks += result.preparedMeshes.size()
			_brick_cursor += 1
		else:
			_artifacts[_requests[_part_cursor].part.id] = _current
			_current = {}
			_solids = []
			_part_cursor += 1
		metrics.maxUnitUsec = maxi(metrics.maxUnitUsec, Time.get_ticks_usec() - unit_started)
	var elapsed := Time.get_ticks_usec() - started
	metrics.maxSliceUsec = maxi(metrics.maxSliceUsec, elapsed)
	if elapsed > budget_usec: metrics.sliceOverruns += 1
	metrics.preparationUsec += elapsed
	return state

func ready_for(part, publisher) -> bool:
	if state != "ready": return _fail("masonry_not_prepared")
	if not validate_unit_source(publisher): return false
	if context_binding(publisher) != _context: return _fail("stale_masonry_context")
	var matches := _requests.filter(func(request): return request.part == part)
	if matches.size() != 1 or not _artifacts.has(part.id): return _fail("unprepared_masonry_part")
	return validate_publication_binding(part)

func owns(part) -> bool:
	return _marked.has(part.id) or _marked.find_key(part) != null

func accepts_source_member(part) -> bool:
	if _requests.is_empty(): return true
	if _blueprint.parts.size() != _source_count or _by_id.get(part.id) != part or not _blueprint.parts.has(part): return _fail("stale_source_membership")
	return true

func artifact(part) -> Dictionary:
	return _artifacts.get(part.id, {}) if state == "ready" else {}

func _validate_all(publisher) -> bool:
	if _requests.is_empty(): return true
	if not validate_unit_source(publisher): return false
	if context_binding(publisher) != _context: return _fail("stale_masonry_context")
	if _blueprint.parts.size() != _source_count: return _fail("stale_source_membership")
	# Native array equality compares the retained object sequence without
	# rebuilding a whole-world dictionary at every validation boundary.
	if _blueprint.parts != _source_order: return _fail("stale_source_ids_or_order")
	var current: Dictionary = _by_id
	var validated: Dictionary = {}
	for request in _requests:
		if current.get(request.part.id) != request.part or var_to_bytes(request.part.snapshot()) != request.source: return _fail("stale_masonry_source")
		if not validated.has(request.key):
			if not _blueprint.recipe.get("facadeApertures") is Dictionary: return _fail("stale_aperture_geometry")
			var record: Variant = _blueprint.recipe.facadeApertures.get(request.key)
			if var_to_bytes(record) != request.record or not _same_validated_geometry(request.key): return _fail("stale_aperture_geometry")
			validated[request.key] = true
	return true

func _validate_declaration(key: String) -> bool:
	var cached: Dictionary = _declarations[key]
	var record: Variant = _blueprint.recipe.get("facadeApertures", {}).get(key)
	if var_to_bytes(record) != cached.record or not Aperture.validate(record, _by_id): return _fail("unbound_masonry_apertures")
	# The seal is proved once. Later guards compare every exact geometry field
	# it hashes, plus the complete declaration bytes, rather than hashing again.
	for id in record.partIds: cached.geometry[id] = Aperture._geometry(_by_id[id])
	cached.validated = true
	metrics.declarationsValidated += 1
	return true

func _same_validated_geometry(key: String) -> bool:
	var cached: Dictionary = _declarations[key]
	if not cached.validated: return false
	for id in cached.geometry:
		var peer: Variant = _by_id.get(id)
		# Membership is checked once by the caller: full source sequence at
		# finalization, or each declaration peer at the emission boundary.
		if peer == null or peer.id != id or Aperture._geometry(peer) != cached.geometry[id]: return false
	return true

func _request_valid(request: Dictionary) -> bool:
	if not accepts_source_member(request.part): return false
	if not _blueprint.parts.has(request.part) or not _blueprint.recipe.get("facadeApertures") is Dictionary: return _fail("stale_masonry_source")
	if var_to_bytes(request.part.snapshot()) != request.source or var_to_bytes(_blueprint.recipe.facadeApertures.get(request.key)) != request.record:
		return _fail("stale_masonry_source")
	return true

func validate_publication_binding(part) -> bool:
	var matches := _requests.filter(func(request): return request.part == part)
	if matches.size() != 1 or not _request_valid(matches[0]): return _fail("stale_masonry_source")
	var record: Dictionary = _blueprint.recipe.facadeApertures[matches[0].key]
	var current: Dictionary = {}
	for id in record.partIds:
		var peer: Variant = _by_id.get(id)
		if peer == null or peer.id != id or not _blueprint.parts.has(peer): return _fail("stale_aperture_peer")
		current[id] = peer
	if not _same_validated_geometry(matches[0].key): return _fail("stale_aperture_geometry")
	return true

func unit_source_pending_matches(publisher) -> bool:
	if _requests.is_empty(): return true
	return _unit_owner != null and _unit_owner.get_ref() == publisher and not _unit_binding.is_empty() and Cuts.UnitSnapshot.source_binding(publisher.unit_box) == _unit_binding

func validate_unit_source(publisher) -> bool:
	if _requests.is_empty(): return true
	var owner: Variant = _unit_owner.get_ref() if _unit_owner != null else null
	if owner == null or _unit_snapshot == null or not _unit_snapshot.matches(owner.unit_box): return _fail("stale_unit_box_snapshot")
	# Collision collectors may consume the same artifacts with a distinct native
	# box resource. Its complete parameters must still match the bound owner.
	if publisher != owner and Cuts.UnitSnapshot.source_binding(publisher.unit_box, false) != Cuts.UnitSnapshot.source_binding(owner.unit_box, false): return _fail("incompatible_unit_box_consumer")
	return true

static func context_binding(publisher) -> PackedByteArray:
	var history = publisher.surface_history
	return var_to_bytes([publisher.source_blueprint_id, history.route_corridors, history.tree_placements, history.history_events, history.history_event_cells])

func _fail(message: String) -> bool:
	if reason.is_empty(): reason = message
	state = "failed"
	_artifacts.clear()
	_current.clear()
	_solids.clear()
	return false
