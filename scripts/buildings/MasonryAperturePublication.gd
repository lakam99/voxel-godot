extends RefCounted

## Private, resumable renderer preparation. Mesh resources never enter recipes.
const Aperture = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const Cuts = preload("res://scripts/buildings/MasonryApertureGeometry.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Materials = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const Descriptor = preload("res://scripts/buildings/MasonryDescriptorGeometry.gd")
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
var _prepared_history_context
var _part_cursor := 0
var _brick_cursor := 0
var _solids: Array = []
var _current: Dictionary = {}
var _unit_snapshot
var _unit_owner: WeakRef
var _unit_binding := PackedByteArray()
var _begin_stage := "done"
var _begin_cursor := 0
var _begin_marked: Array = []
var _descriptor_cursor
var _descriptor_part
var _solids_group := 0
var _solids_index := 0
var _solids_frame: Transform3D
var _solids_material_key := ""
var _building_solids := false
var metrics := {"parts": 0, "bricks": 0, "changedBricks": 0, "turns": 0, "maxSliceUsec": 0, "maxUnitUsec": 0, "preparationUsec": 0,
	"beginUsec": 0, "maxDeclarationUsec": 0, "declarationsValidated": 0, "maxDescriptorUsec": 0, "finalValidationUsec": 0, "vertices": 0, "fragments": 0, "work": 0, "sliceOverruns": 0}

func begin(b, publisher) -> bool:
	var started:=Time.get_ticks_usec()
	if not begin_incremental(b,publisher): return false
	while _begin_stage!="done" and state=="pending_budget": _advance_begin()
	metrics.beginUsec=Time.get_ticks_usec()-started
	return state!="failed"

func begin_incremental(b, publisher) -> bool:
	# Exclusive-owned runtime input: the owner must not mutate/reuse this blueprint
	# until completion or cancellation retirement. Membership/order bind now;
	# individual geometry binds when each request is captured. Mutable callers
	# requiring begin-time snapshots must use the synchronous begin() adapter.
	var started:=Time.get_ticks_usec()
	_blueprint=b
	_unit_owner=weakref(publisher)
	_context=context_binding(publisher)
	_prepared_history_context=publisher._prepared_history
	if b==null: return _fail("missing_source")
	_source_count=b.parts.size()
	if not b.parts.any(func(part): return part!=null and part.recipe.has("masonryApertureSource")):
		state="ready"; _begin_stage="done"; return true
	if b.parts.size()>10000: return _fail("source_limit")
	_unit_binding=Cuts.UnitSnapshot.source_binding(publisher.unit_box)
	if _unit_binding.is_empty(): return _fail("invalid_unit_box_source")
	_source_order=b.parts.duplicate()
	_begin_stage="inventory"
	metrics.beginUsec=Time.get_ticks_usec()-started
	return true

func _advance_begin() -> void:
	if _begin_stage=="inventory":
		if _begin_cursor==_source_order.size():
			_begin_cursor=0; _begin_stage="requests"; return
		var part=_source_order[_begin_cursor]
		_begin_cursor+=1
		if part==null or part.id.is_empty() or _by_id.has(part.id):
			_fail("invalid_source_ids"); return
		_by_id[part.id]=part
		if part.recipe.has("masonryApertureSource"): _begin_marked.append(part)
	elif _begin_stage=="requests":
		if _begin_cursor==_begin_marked.size():
			metrics.parts=_requests.size()
			_begin_stage="done"
			if _requests.is_empty(): state="ready"
			return
		var part=_begin_marked[_begin_cursor]
		_begin_cursor+=1
		_prepare_request(part)

func _prepare_request(part) -> bool:
	if _requests.size()>=MAX_PARTS: return _fail("part_limit")
	var key: Variant=part.recipe.get("masonryApertureSource")
	if not key is String or key.is_empty() or part.kind!="wall" or not Materials.is_masonry_material(part.material_id) or part.recipe.get("visual",true)!=true:
		return _fail("invalid_masonry_declaration")
	if not _blueprint.recipe.get("facadeApertures") is Dictionary: return _fail("invalid_aperture_collection")
	var record: Variant=_blueprint.recipe.facadeApertures.get(key)
	if not record is Dictionary or not record.get("partIds") is Array or not record.partIds.has(part.id) or record.get("producerPrefix")!=key or not record.get("openings") is Array or record.openings.is_empty() or record.openings.size()>16:
		return _fail("unbound_masonry_apertures")
	if not _declarations.has(key):
		var volumes: Array[AABB]=[]
		for opening in record.openings:
			if not opening is Dictionary or not opening.get("fullVolume") is AABB: return _fail("invalid_aperture")
			var volume: AABB=opening.fullVolume
			if not volume.position.is_finite() or not volume.end.is_finite() or volume.size.x<=0 or volume.size.y<=0 or volume.size.z<=0: return _fail("invalid_aperture")
			volumes.append(volume)
		_declarations[key]={"record":var_to_bytes(record),"volumes":volumes,"validated":false,"geometry":{}}
	var snapshot: Dictionary=part.snapshot()
	_requests.append({"part":part,"snapshot":snapshot,"source":var_to_bytes(snapshot),
		"key":key,"record":_declarations[key].record,"volumes":_declarations[key].volumes})
	_marked[part.id]=part
	return true

func advance(publisher, budget_usec: int = 2500) -> String:
	if state != "pending_budget": return state
	if budget_usec < 1 or budget_usec > 4000:
		_fail("invalid_slice_budget")
		return state
	var started := Time.get_ticks_usec()
	metrics.turns += 1
	if not _context_matches(publisher): _fail("stale_masonry_context")
	if _begin_stage!="done" and _blueprint.parts!=_source_order: _fail("stale_source_membership")
	var units := 0
	# A very small budget must still make progress after context validation.
	# Units and overruns remain measured; the requested duration is not hidden.
	while state == "pending_budget" and (units == 0 or Time.get_ticks_usec() - started < budget_usec):
		units += 1
		var unit_started := Time.get_ticks_usec()
		if _begin_stage!="done":
			_advance_begin()
		elif _unit_snapshot == null and not _requests.is_empty():
			_unit_snapshot = Cuts.UnitSnapshot.new()
			if not unit_source_pending_matches(publisher) or not _unit_snapshot.capture(publisher.unit_box, metrics): _fail("invalid_unit_box_snapshot")
		elif _part_cursor == _requests.size():
			if _validate_all(publisher): state = "ready"
			metrics.finalValidationUsec = Time.get_ticks_usec() - unit_started
		elif _descriptor_cursor!=null:
			var result: Dictionary=_descriptor_cursor.advance(maxi(1,budget_usec-int(Time.get_ticks_usec()-started)))
			if result.status=="ready":
				_begin_solids(_descriptor_cursor.take_result())
				_descriptor_cursor=null
			elif result.status!="pending_budget": _fail("masonry_descriptor:"+String(result.get("reason",result.status)))
			metrics.maxDescriptorUsec=maxi(metrics.maxDescriptorUsec,Time.get_ticks_usec()-unit_started)
		elif _building_solids:
			_advance_solids(publisher)
		elif _current.is_empty():
			var request: Dictionary = _requests[_part_cursor]
			if not _request_valid(request): break
			if not _declarations[request.key].validated:
				_validate_declaration(request.key)
				var declaration_usec := Time.get_ticks_usec() - unit_started
				metrics.maxDeclarationUsec = maxi(metrics.maxDeclarationUsec, declaration_usec)
				metrics.maxUnitUsec = maxi(metrics.maxUnitUsec, declaration_usec)
				continue
			_descriptor_part=Part.new(request.snapshot)
			var prepared: Dictionary=publisher.prepared_masonry_geometry(request.part)
			if publisher._publication_failed():
				_fail("stale_prepared_masonry"); break
			if not prepared.is_empty(): _begin_solids(prepared)
			else: _descriptor_cursor=Descriptor.begin_source(_descriptor_part,publisher.surface_history,publisher.source_blueprint_id)
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

func _begin_solids(geometry: Dictionary) -> void:
	_current={"geometry":geometry,"entries":[],"preparedMeshes":{},"provenance":[]}
	_building_solids=true; _solids_group=0; _solids_index=0; _solids=[]
	_solids_frame=Transform3D(Basis.from_euler(_descriptor_part.rotation),_descriptor_part.position)

func _advance_solids(publisher) -> void:
	if _solids_group==2:
		_building_solids=false; _brick_cursor=0; return
	var group: String="regular" if _solids_group==0 else "repair"
	var geometry: Dictionary=_current.geometry
	var transforms: Array=geometry[group+"Transforms"]
	var custom: Array=geometry[group+"CustomData"]
	if _solids_index==0:
		_solids_material_key="%s:%0.3f" % [geometry.surfaceMaterialId,publisher.masonry_family_variation(_descriptor_part)]
		if group=="repair": _solids_material_key="masonry_repair:"+_solids_material_key
	if _solids_index==transforms.size():
		_solids_group+=1; _solids_index=0; return
	if _solids.size()+metrics.bricks>=MAX_BRICKS:
		_fail("aggregate_brick_limit"); return
	_solids.append({"id":"%s:%s:%d" % [_descriptor_part.id,group,_solids_index],"group":group,"ordinal":_solids_index,
		"materialKey":_solids_material_key,"surfaceMaterialId":geometry.surfaceMaterialId,"customData":custom[_solids_index],
		"localTransform":transforms[_solids_index],"transform":_solids_frame*transforms[_solids_index]})
	_solids_index+=1

func ready_for(part, publisher) -> bool:
	if state != "ready": return _fail("masonry_not_prepared")
	if not validate_unit_source(publisher): return false
	if not _context_matches(publisher): return _fail("stale_masonry_context")
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
	if not _context_matches(publisher): return _fail("stale_masonry_context")
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

func _context_matches(publisher) -> bool:
	if _prepared_history_context!=null:
		return is_same(publisher._prepared_history,_prepared_history_context) and publisher.validate_paving_history_source()
	return publisher._prepared_history==null and context_binding(publisher)==_context

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
