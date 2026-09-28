extends RefCounted
class_name BuildingPublicationPreparation

## CPU-only preparation. prepare_source runs on an owned worker with immutable
## source snapshots; no Nodes, rendering resources or scene publication here.
const Source = preload("res://scripts/buildings/BuildingPublicationSource.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const History = preload("res://scripts/buildings/SurfaceHistoryField.gd")
const MasonryGeometry = preload("res://scripts/buildings/MasonryDescriptorGeometry.gd")
const Materials = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const MasonryPacket = preload("res://scripts/buildings/BuildingMasonryRenderPacket.gd")
const MasonryAperturePacket = preload("res://scripts/buildings/BuildingMasonryAperturePacket.gd")
const CobbleGeometry = preload("res://scripts/buildings/SettledCobbleGeometry.gd")
const RoofGeometry = preload("res://scripts/buildings/BuildingRoofGeometry.gd")
const SurfacePacket = preload("res://scripts/buildings/BuildingSurfaceRenderPacket.gd")
const PartRecord = preload("res://scripts/buildings/BuildingPart.gd")
const SpatialDependencies = preload("res://scripts/buildings/BuildingSpatialDependencies.gd")
const CitadelPlan = preload("res://scripts/world/CitadelPublicationPlan.gd")
const NavigationProducer = preload("res://scripts/buildings/BuildingNavigationTileProducer.gd")
const PavingAssembly = preload("res://scripts/buildings/PavingFootingAssemblyRecipe.gd")
const UnitBoxArrays = preload("res://scripts/buildings/UnitBoxSurfaceArrays.gd")
const METADATA_MAX_DEPTH := 128

class Continuation extends RefCounted:
	var callback: Callable
	var cancelled := false
	func advance(stage: String) -> bool:
		if cancelled: return false
		cancelled = callback.is_valid() and callback.call(stage) != true
		return not cancelled

class PreparedSource extends RefCounted:
	# Kept private until the publisher consumes this exact holder. Runtime owns
	# its lifetime and must retire stale, unconsumed payloads off the main thread.
	var _binding: Dictionary = {}
	var _payload: Dictionary = {}
	var _consumed := false
	func describe(expected_binding: Dictionary):
		if _consumed or _binding != expected_binding: return null
		var description = _payload.get("spatialDependencies")
		return description if description != null and description.binding == expected_binding else null
	func take(expected_binding: Dictionary) -> Dictionary:
		if _consumed or _payload.is_empty() or _binding != expected_binding: return {}
		_consumed = true
		var result := _payload
		_payload = {}
		return result

## Immutable worker-produced source prerequisite for demand-bound physical
## packets. This is deliberately not a PreparedSource and has no scene or
## publication-ready meaning. It retains only admitted value source plus the
## shared, fully prepared facts that a per-group compiler may validate against.
class PreparedPublicationBase extends RefCounted:
	var binding: Dictionary = {}
	var profile: Dictionary = {}
	var building_source: Dictionary = {}
	var furnishing_source: Dictionary = {}
	var description = null
	var static_records: Dictionary = {}
	var static_record_bindings: Dictionary = {}
	var prepared_history = null
	var packet_eligibility: Dictionary = {}
	var publication_plan: CitadelPlan
	var source_id := ""
	var _scene_blueprint = null
	var _scene_furnishing_plan = null
	var _scene_source_consumed := false
	func matches(expected_binding: Dictionary) -> bool:
		return binding == expected_binding and binding.is_read_only() and profile.is_read_only() \
			and building_source.is_read_only() and furnishing_source.is_read_only() \
			and description != null and description.binding == binding and not source_id.is_empty() \
			and publication_plan != null and publication_plan.matches(binding,description.publication_groups.groups)
	func take_scene_source(expected_binding: Dictionary) -> Dictionary:
		if _scene_source_consumed or expected_binding!=binding or _scene_blueprint==null or _scene_furnishing_plan==null:
			return {}
		_scene_source_consumed=true
		var result := {"blueprint":_scene_blueprint,"furnishingPlan":_scene_furnishing_plan,"sourceId":source_id}
		_scene_blueprint=null
		_scene_furnishing_plan=null
		return result

## Value-keyed group artifact. It contains no restored BuildingPart aliases:
## callers must validate its binding/member records before constructing Nodes.
class PreparedPhysicalGroupPacket extends RefCounted:
	var binding: Dictionary = {}
	var source_id := ""
	var group_ids: Array[String] = []
	var building_entries: Dictionary = {}
	## Immutable furnishing records are carried separately from structural
	## geometry. FurnishingPublisher remains the only visual/collision builder;
	## the packet merely binds its selected source records to this closure.
	var furnishing_entries: Dictionary = {}
	var static_records: Dictionary = {}
	var history_source_id := ""
	var preparation_usec := 0
	func matches(base: PreparedPublicationBase, expected_groups: Array[String]) -> bool:
		return base != null and binding == base.binding and source_id == base.source_id \
			and history_source_id == base.source_id and group_ids == expected_groups \
			and binding.is_read_only() and building_entries.is_read_only() and furnishing_entries.is_read_only() \
			and static_records.is_read_only()

class PreparedHistory extends RefCounted:
	# Only the compiler constructs this certificate, after isolating and freezing
	# every container. Retain it with the publisher until worker retirement.
	var history
	var _identity: Dictionary = {}
	func _init(field, source_id: String) -> void:
		history = field
		_identity = {"history":field, "sourceId":source_id,
			"routes":field.route_corridors, "trees":field.tree_placements,
			"events":field.history_events, "cells":field.history_event_cells}
		_identity.make_read_only()
	func matches(field, source_id: String) -> bool:
		# No scans, encoding, equality of containers, or caller-recipe ownership.
		return field != null and field == _identity.history and history == field \
			and source_id == _identity.sourceId \
			and is_same(field.route_corridors, _identity.routes) \
			and is_same(field.tree_placements, _identity.trees) \
			and is_same(field.history_events, _identity.events) \
			and is_same(field.history_event_cells, _identity.cells)

class RecordBinding extends RefCounted:
	static func encode(record: Dictionary) -> String:
		var encoded := var_to_bytes(record)
		encoded.fill(0)
		if encoded.encode_var(0, record) != encoded.size(): return ""
		return encoded.hex_encode()

class MasonrySelection extends RefCounted:
	static func selected(part) -> bool:
		if part == null or not bool(part.recipe.get("visual", true)): return false
		var kind := String(part.kind)
		return kind in ["wall", "foundation"] and Materials.is_masonry_material(String(part.material_id)) \
			and not (kind == "foundation" and Materials.is_cobble_material(String(part.material_id)))

class GeometrySelection extends RefCounted:
	static func selected(part, family: String) -> bool:
		if family=="masonry": return MasonrySelection.selected(part)
		if part==null or not bool(part.recipe.get("visual",true)): return false
		if family=="paving":
			return String(part.kind)=="foundation" and Materials.is_cobble_material(String(part.material_id)) and not part.recipe.has("pavingFootingJoints")
		return family=="roof" and String(part.kind)=="roof"

class PreparedGeometry extends RefCounted:
	# Object keys deliberately retain source parts through worker retirement and
	# recognize a changed ID. Geometry/entry/maps are otherwise deeply readonly.
	var _entries: Dictionary
	var _ids: Dictionary = {}
	var _omitted: Dictionary
	var _omitted_ids: Dictionary = {}
	var _history: PreparedHistory
	var _source_id: String
	var family: String
	func _init(entries: Dictionary, history_artifact: PreparedHistory, source_id: String, omitted: Dictionary, geometry_family := "masonry") -> void:
		family = geometry_family
		_entries = entries
		_history = history_artifact
		_source_id = source_id
		for part in entries: _ids[entries[part].id] = part
		_ids.make_read_only()
		_omitted = omitted
		for part in omitted: _omitted_ids[omitted[part]] = part
		_omitted_ids.make_read_only()
	func matches_history(history_artifact, field, source_id: String) -> bool:
		return history_artifact == _history and source_id == _source_id \
			and _history != null and _history.matches(field, source_id)
	func has_part(part) -> bool:
		if part == null: return false
		if _entries.has(part) or _ids.has(String(part.id)): return true
		if _omitted.has(part): return String(part.id) != _omitted[part]
		if _omitted_ids.has(String(part.id)): return true
		# A newly inserted eligible object is missing, not an intentional fallback.
		return GeometrySelection.selected(part,family)
	func validate_part(part) -> bool:
		if part == null or not _entries.has(part) or not matches_history(_history, _history.history, _source_id): return false
		var entry: Dictionary = _entries[part]
		if entry.sealedRevision >= 0:
			return part.get_script()==PartRecord and part._publication_sealed \
				and part._publication_revision==entry.sealedRevision and is_same(part.recipe,entry.sealedRecipe)
		# A caller can introduce cycles/Objects after preparation. Reject before
		# snapshot() deep-copies; do not feed unsupported graphs to the encoder.
		var graph := MetadataGraph.new()
		graph.guard = Continuation.new()
		graph.walk(part.recipe, [], false)
		if not graph.eligible: return false
		var snapshot: Dictionary = part.snapshot()
		graph.walk(snapshot, [], false)
		return graph.eligible and RecordBinding.encode(snapshot) == _entries[part].binding
	func geometry_for(part) -> Dictionary:
		return _entries[part].geometry if validate_part(part) else {}
	func packet_for(part):
		return _entries[part].packet if validate_part(part) else null
	func count() -> int:
		return _entries.size()

class MetadataGraph extends RefCounted:
	# Only isolated Array/Dictionary copies are frozen. Never freeze a caller's
	# recipe, trust packed-array COW, or retain Objects through typed containers.
	var guard: Continuation
	var eligible := true
	var visits := 0
	var walk_stage := "publication_metadata_walk"
	func walk(value: Variant, ancestors: Array, copy: bool, depth := 0) -> Variant:
		visits += 1
		var kind := typeof(value)
		if visits % 128 == 0 or kind == TYPE_ARRAY or kind == TYPE_DICTIONARY:
			if not guard.advance(walk_stage): return null
		if kind <= TYPE_NODE_PATH: return value
		if kind != TYPE_ARRAY and kind != TYPE_DICTIONARY:
			eligible = false
			return null
		if depth >= METADATA_MAX_DEPTH:
			eligible = false
			return null
		for ancestor in ancestors:
			if is_same(value, ancestor):
				eligible = false
				return null
		if kind == TYPE_ARRAY:
			if not container_type_supported(value.get_typed_builtin()):
				eligible = false
				return null
		else:
			if value.get_typed_key_builtin() > TYPE_NODE_PATH or not container_type_supported(value.get_typed_value_builtin()):
				eligible = false
				return null
		ancestors.append(value)
		# A shallow duplicate preserves typed container declarations and key order;
		# every nested value is replaced before this isolated copy is frozen.
		var result: Variant = value.duplicate(false) if copy else null
		if kind == TYPE_DICTIONARY:
			for key in value:
				if typeof(key) > TYPE_NODE_PATH:
					eligible = false
					break
				var item: Variant = walk(value[key], ancestors, copy, depth + 1)
				if not eligible or guard.cancelled: break
				if copy: result[key] = item
		else:
			for index in value.size():
				var item: Variant = walk(value[index], ancestors, copy, depth + 1)
				if not eligible or guard.cancelled: break
				if copy: result[index] = item
		ancestors.pop_back()
		if not eligible or guard.cancelled: return null
		if copy: result.make_read_only()
		return result
	func container_type_supported(kind: int) -> bool:
		return kind <= TYPE_NODE_PATH or kind == TYPE_ARRAY or kind == TYPE_DICTIONARY

static func valid_binding(binding: Dictionary) -> bool:
	return binding.size() == 3 and binding.get("siteId") is String and not binding.siteId.is_empty() \
		and binding.get("sourceKey") is String and not binding.sourceKey.is_empty() \
		and binding.get("generation") is int and binding.generation > 0

## Build the immutable prerequisite for future demand-bound group packets.
## This is intentionally a separate API from prepare_source: callers cannot
## treat it as scene input or publication readiness.
static func prepare_publication_base(building: Dictionary, furniture: Dictionary, binding: Dictionary, profile: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	if not valid_binding(binding) or not profile is Dictionary: return _failed("invalid_publication_base_request")
	var source_binding := binding.duplicate()
	source_binding.make_read_only()
	var source_profile := profile.duplicate(true)
	source_profile.make_read_only()
	var guard := Continuation.new()
	guard.callback = continuation
	var restored := Source.restore(building, furniture, guard.advance)
	if not restored.ready: return _failed(restored.reason)
	var diagnostics := evaluate(restored.blueprint, {}, guard.advance)
	if not diagnostics.ready: return _failed(diagnostics.reason)
	# Physical resolution can rewrite derived part facts. Capture that resolved
	# source once in the base; a demanded packet must never replay evaluation on
	# the entire citadel merely to reach the same member bindings.
	var graph := MetadataGraph.new()
	graph.guard = guard
	var resolved_building: Variant = graph.walk(restored.blueprint.snapshot(), [], true)
	if guard.cancelled: return _failed("cancelled")
	if not graph.eligible or not resolved_building is Dictionary:
		return _failed("resolved_publication_base_snapshot_invalid")
	var description = SpatialDependencies.compile_description(restored.blueprint,restored.furnishingPlan,source_binding,source_profile.get("origin",Vector3.ZERO),guard.advance)
	if description == null: return _failed("cancelled" if guard.cancelled else "spatial_dependency_compilation_failed")
	var metadata := _compile_static_records(restored.blueprint, guard.advance)
	if not metadata.ready: return _failed(metadata.reason)
	var history_result := _compile_history(restored.blueprint, guard.advance)
	if not history_result.ready: return _failed(history_result.reason)
	if not building.is_read_only() or not furniture.is_read_only(): return _failed("mutable_publication_base_source")
	var base := PreparedPublicationBase.new()
	base.binding = source_binding
	base.profile = source_profile
	base.building_source = resolved_building
	base.furnishing_source = furniture
	base.description = description
	base.static_records = metadata.staticRecords
	base.static_record_bindings = metadata.staticRecordBindings
	base.prepared_history = history_result.preparedHistory
	base.source_id = String(restored.blueprint.recipe.get("sourceBlueprintId", restored.blueprint.id))
	base._scene_blueprint = restored.blueprint
	base._scene_furnishing_plan = restored.furnishingPlan
	var eligibility := classify_physical_group_packet_eligibility(description.publication_groups,resolved_building,furniture)
	if not eligibility.get("ready",false): return eligibility
	eligibility.make_read_only()
	base.packet_eligibility=eligibility
	var plan_result := CitadelPlan.build(description,resolved_building,furniture,eligibility,guard.advance)
	if not plan_result.get("ready",false): return _failed(String(plan_result.get("reason","publication_plan_failed")))
	base.publication_plan=plan_result.plan
	if not base.matches(source_binding): return _failed("invalid_publication_base")
	return {"ready":true,"reason":"","base":base,"diagnostics":diagnostics,
		"metadataPreparationUsec":metadata.metadataPreparationUsec,"historyPreparationUsec":history_result.historyPreparationUsec,
		"publicationPlanPreparationUsec":plan_result.preparationUsec,"publicationPlanSignature":plan_result.outputSignature}

## Main-thread scene source reconstruction for a validated base. This creates a
## fresh private object graph; it neither prepares geometry nor consumes a
## group packet. The scene job may own this graph while packet workers rebuild
## their own separate graphs from the same frozen admitted values.
static func restore_publication_scene_source(base: PreparedPublicationBase, expected_binding: Dictionary) -> Dictionary:
	if base == null or not base.matches(expected_binding): return _failed("invalid_publication_base_scene_request")
	# The base worker already restored and round-trip validated this exact private
	# graph. Transfer it once instead of repeating the multi-megabyte decode and
	# serialization check in a gameplay frame.
	var restored := base.take_scene_source(expected_binding)
	if restored.is_empty(): return _failed("publication_base_scene_source_unavailable")
	if restored.sourceId != base.source_id or restored.blueprint.parts.size()+restored.furnishingPlan.parts.size()!=base.description.parts.size():
		return _failed("stale_publication_base_scene_source")
	return {"ready":true,"reason":"","blueprint":restored.blueprint,"furnishingPlan":restored.furnishingPlan,
		"sourceId":restored.sourceId}

## Compile an isolated, value-keyed packet for an already dependency-closed
## group set. It reconstructs a private source so no main-thread or base
## BuildingPart object is sealed, mutated, or retained by this worker result.
static func compile_physical_group_packet(base: PreparedPublicationBase, group_ids: Array[String], continuation: Callable = Callable()) -> Dictionary:
	if base == null or not base.matches(base.binding) or group_ids.is_empty(): return _failed("invalid_physical_group_packet_request")
	var ordered: Array[String] = group_ids.duplicate()
	ordered.sort()
	var seen: Dictionary = {}
	for id: String in ordered:
		if id.is_empty() or seen.has(id): return _failed("invalid_physical_group_ids")
		seen[id] = true
	if ordered != group_ids: return _failed("invalid_physical_group_ids")
	var groups: Dictionary = base.description.publication_groups.get("groups",{})
	var eligibility := base.packet_eligibility
	if eligibility.is_empty(): eligibility=classify_physical_group_packet_eligibility(base.description.publication_groups,base.building_source,base.furnishing_source)
	if not eligibility.ready: return _failed(String(eligibility.reason))
	var selected_indices: Dictionary = {}
	var selected_furnishing_indices: Dictionary = {}
	for id: String in ordered:
		if not groups.has(id): return _failed("unknown_physical_group")
		var group_eligibility: Variant = eligibility.groups.get(id)
		if not group_eligibility is Dictionary: return _failed("invalid_physical_group_eligibility")
		if not group_eligibility.eligible:
			var reason := String(group_eligibility.reasons[0]) if not group_eligibility.reasons.is_empty() else "unsupported"
			return _failed("physical_packet_aperture_artifact_required" if reason=="aperture" else "physical_packet_"+reason+"_unsupported")
		for index: int in groups[id].buildingIndices: selected_indices[index] = true
		for index: int in groups[id].furnitureIndices: selected_furnishing_indices[index] = true
	var guard := Continuation.new()
	guard.callback = continuation
	var started := Time.get_ticks_usec()
	# Restore the immutable group partition, not the complete city. Group
	# compilation previously decoded and round-trip encoded all 4k+ source parts
	# for every one- or few-group packet. The publication plan already supplies a
	# dependency-closed, source-indexed selection; preserve the complete recipe
	# and room metadata needed by the existing geometry compilers while narrowing
	# only their part arrays. The worker still owns a fresh private object graph.
	var packet_building_source := base.building_source.duplicate(false)
	var packet_building_parts: Array = []
	var source_indices: Array = selected_indices.keys()
	source_indices.sort()
	for raw_index in source_indices:
		if not guard.advance("publication_packet_partition"): return _failed("cancelled")
		var building_source_index := int(raw_index)
		if building_source_index < 0 or building_source_index >= base.building_source.parts.size():
			return _failed("invalid_physical_group_member_index")
		packet_building_parts.append(base.building_source.parts[building_source_index])
	packet_building_source["parts"] = packet_building_parts
	var packet_furnishing_source := base.furnishing_source.duplicate(false)
	var packet_furnishing_parts: Array = []
	var source_furnishing_indices: Array = selected_furnishing_indices.keys()
	source_furnishing_indices.sort()
	for raw_index in source_furnishing_indices:
		if not guard.advance("publication_packet_partition"): return _failed("cancelled")
		var furnishing_source_index := int(raw_index)
		if furnishing_source_index < 0 or furnishing_source_index >= base.furnishing_source.parts.size():
			return _failed("invalid_physical_group_furnishing_index")
		packet_furnishing_parts.append(base.furnishing_source.parts[furnishing_source_index])
	packet_furnishing_source["parts"] = packet_furnishing_parts
	var restored := Source.restore(packet_building_source, packet_furnishing_source, guard.advance)
	if not restored.ready: return _failed(restored.reason)
	var source_id := String(restored.blueprint.recipe.get("sourceBlueprintId", restored.blueprint.id))
	if source_id != base.source_id: return _failed("stale_physical_group_source")
	if base.prepared_history == null or not base.prepared_history.matches(base.prepared_history.history,source_id):
		return _failed("stale_physical_group_history")
	var artifacts: Dictionary = {}
	var jointed_families: Dictionary = {}
	var selected_ids: Dictionary = {}
	for selected_part in restored.blueprint.parts:
		if selected_part.recipe.has("pavingFootingJoints"):
			var jointed := _compile_jointed_paving_family(restored.blueprint, selected_part, UnitBoxArrays.canonical())
			if not jointed.ready: return _failed(jointed.reason)
			jointed_families[String(selected_part.id)] = jointed.family
		selected_ids[String(selected_part.id)] = true
	for family: String in ["masonry","paving","roof"]:
		var compiled := _compile_geometry(restored.blueprint,base.prepared_history,guard.advance,false,family,selected_ids)
		if not compiled.ready: return _failed(compiled.reason)
		artifacts[family] = compiled.artifact
	var entries: Dictionary = {}
	var furnishing_entries: Dictionary = {}
	var records: Dictionary = {}
	for index: int in restored.blueprint.parts.size():
		var part = restored.blueprint.parts[index]
		var id := String(part.id)
		var source_binding := static_record_binding(part.snapshot())
		if source_binding.is_empty(): return _failed("physical_group_record_encoding_failed")
		if base.static_record_bindings.has(id) and base.static_record_bindings[id] != source_binding:
			return _failed("stale_physical_group_member")
		if base.static_records.has(id): records[id] = base.static_records[id]
		var families: Dictionary = {}
		for family: String in artifacts:
			if not geometry_selected(part,family): continue
			var artifact = artifacts[family]
			if artifact == null: return _failed("missing_physical_group_artifact")
			var geometry: Dictionary = artifact.geometry_for(part)
			var packet = artifact.packet_for(part)
			if family=="masonry" and part.recipe.has("masonryApertureSource"):
				packet = MasonryAperturePacket.compile(part,geometry,restored.blueprint)
			if geometry.is_empty() or packet == null or (packet is Dictionary and packet.is_empty()): return _failed("incomplete_physical_group_artifact")
			families[family] = {"binding":source_binding,"geometry":geometry,"packet":packet}
		if jointed_families.has(id):
			var jointed_family: Dictionary = jointed_families[id]
			if jointed_family.get("binding") != source_binding: return _failed("stale_jointed_paving_member")
			families["jointed_paving"] = jointed_family
		families.make_read_only()
		var entry := {"id":id,"binding":source_binding,"families":families}
		entry.make_read_only()
		entries[id] = entry
	for index: int in restored.furnishingPlan.parts.size():
		var furnishing_part = restored.furnishingPlan.parts[index]
		if furnishing_part == null: return _failed("invalid_physical_group_furnishing")
		var furnishing_id := String(furnishing_part.id)
		if furnishing_id.is_empty() or furnishing_entries.has(furnishing_id): return _failed("duplicate_physical_group_furnishing")
		var furnishing_snapshot: Dictionary = furnishing_part.snapshot()
		var frozen_furnishing: Variant = _freeze_value(furnishing_snapshot)
		if not frozen_furnishing is Dictionary: return _failed("physical_group_furnishing_freeze_failed")
		var furnishing_binding := static_record_binding(frozen_furnishing)
		if furnishing_binding.is_empty(): return _failed("physical_group_furnishing_record_encoding_failed")
		var furnishing_entry := {"id":furnishing_id,"binding":furnishing_binding,"record":frozen_furnishing}
		furnishing_entry.make_read_only()
		furnishing_entries[furnishing_id] = furnishing_entry
	entries.make_read_only()
	furnishing_entries.make_read_only()
	records.make_read_only()
	var packet := PreparedPhysicalGroupPacket.new()
	packet.binding = base.binding
	packet.source_id = source_id
	packet.group_ids = ordered
	packet.group_ids.make_read_only()
	packet.building_entries = entries
	packet.furnishing_entries = furnishing_entries
	packet.static_records = records
	packet.history_source_id = source_id
	packet.preparation_usec = Time.get_ticks_usec()-started
	if not packet.matches(base,ordered): return _failed("invalid_physical_group_packet")
	return {"ready":true,"reason":"","packet":packet}


## Classifies frozen source snapshots without restoring BuildingPart or scene
## objects. This is the admission census for demand-bound physical packets.
static func classify_physical_group_packet_eligibility(publication_groups: Dictionary, building_source: Dictionary, furnishing_source: Dictionary = {}) -> Dictionary:
	var groups: Variant = publication_groups.get("groups")
	var building_parts: Variant = building_source.get("parts")
	var furnishing_parts: Variant = furnishing_source.get("parts",[])
	var tree_records: Variant = publication_groups.get("treeRecords",[])
	if not groups is Dictionary or not building_parts is Array or not furnishing_parts is Array or not tree_records is Array:
		return _failed("invalid_packet_eligibility_source")
	var jointed_feet: Dictionary = {}
	for snapshot_value in building_parts:
		if not snapshot_value is Dictionary: continue
		var recipe: Variant = snapshot_value.get("recipe",{})
		if not recipe is Dictionary or not recipe.has("pavingFootingJoints"): continue
		var declaration: Variant = recipe.pavingFootingJoints
		if not declaration is Dictionary or not declaration.get("footPartIds") is Array: continue
		for foot_id in declaration.footPartIds: jointed_feet[String(foot_id)] = true
	var results: Dictionary = {}
	var ids: Array = groups.keys()
	ids.sort()
	for id_value in ids:
		var id := String(id_value)
		var group: Variant = groups[id]
		var reasons: Array[String] = []
		var families: Array[String] = []
		if not group is Dictionary:
			reasons.append("unsupported")
		else:
			var building_indices: Variant = group.get("buildingIndices",[])
			var furniture_indices: Variant = group.get("furnitureIndices",[])
			var tree_indices: Variant = group.get("treeIndices",[])
			if not building_indices is Array or not furniture_indices is Array or not tree_indices is Array:
				reasons.append("unsupported")
			else:
				# Furniture is packet-capable through the frozen furnishing record
				# entries below. It has no structural geometry compiler and remains
				# published solely by FurnishingPublisher on the scene owner.
				for index_value in furniture_indices:
					var furnishing_index := int(index_value)
					if furnishing_index < 0 or furnishing_index >= furnishing_parts.size() or not furnishing_parts[furnishing_index] is Dictionary:
						if not reasons.has("unsupported"): reasons.append("unsupported")
				# Trees do not need worker-built mesh artifacts: their immutable
				# publication-group record is already bound to this exact base and the
				# scene owner registers it through the existing tree callback. Validate
				# that record here so a tree-only packet can authorize that normal path.
				for index_value in tree_indices:
					var tree_index := int(index_value)
					if tree_index < 0 or tree_index >= tree_records.size() or not tree_records[tree_index] is Dictionary:
						if not reasons.has("unsupported"): reasons.append("unsupported")
				# Door geometry is already published through the ordinary individual
				# body path. Packet admission only permits it when the scene job later
				# proves the same body was registered with its existing portal owner
				# before committing a group receipt. That owner-side gate cannot live in
				# this frozen worker census.
				if not (group.get("doorPartIds",[]) is Array): reasons.append("unsupported")
				for index_value in building_indices:
					var index := int(index_value)
					if index < 0 or index >= building_parts.size() or not building_parts[index] is Dictionary:
						if not reasons.has("unsupported"): reasons.append("unsupported")
						continue
					var part: Dictionary = building_parts[index]
					var recipe: Variant = part.get("recipe",{})
					if not recipe is Dictionary:
						if not reasons.has("unsupported"): reasons.append("unsupported")
						continue
					# Aperture geometry is admitted only through its dedicated value-only
					# cut instruction.  The worker does not build Mesh resources; the
					# restored scene owner hydrates it through the existing cutter.
					if recipe.has("pavingFootingJoints"):
						if not families.has("jointed_paving"): families.append("jointed_paving")
					elif not _snapshot_geometry_family(part).is_empty() and not families.has("normal"):
						families.append("normal")
		reasons.sort()
		families.sort()
		var entry := {"eligible":reasons.is_empty(),"reasons":reasons,"families":families}
		entry.make_read_only()
		results[id] = entry
	results.make_read_only()
	return {"ready":true,"reason":"","groups":results}


static func _snapshot_geometry_family(part: Dictionary) -> String:
	var recipe: Variant = part.get("recipe",{})
	if not recipe is Dictionary or not bool(recipe.get("visual",true)): return ""
	var kind := String(part.get("kind",""))
	var material := String(part.get("material",part.get("materialId","")))
	if kind in ["wall","foundation"] and Materials.is_masonry_material(material) and not (kind=="foundation" and Materials.is_cobble_material(material)):
		return "masonry"
	if kind=="foundation" and Materials.is_cobble_material(material): return "paving"
	if kind=="roof": return "roof"
	return ""


static func _compile_jointed_paving_family(blueprint, finish, unit_surface_arrays: Array) -> Dictionary:
	var declaration: Variant = finish.recipe.get("pavingFootingJoints")
	if not declaration is Dictionary or declaration.size() != 4 or not declaration.get("footPartIds") is Array \
			or not (declaration.get("nominalJoint") is float or declaration.get("nominalJoint") is int):
		return _failed("invalid_jointed_paving_declaration")
	var foot_ids: Array = declaration.footPartIds
	if foot_ids.is_empty() or foot_ids.size() > PavingAssembly.FootCuts.MAX_FEET:
		return _failed("invalid_jointed_paving_feet")
	var by_id: Dictionary = {}
	for part in blueprint.parts:
		if part == null or by_id.has(String(part.id)): return _failed("invalid_jointed_paving_source")
		by_id[String(part.id)] = part
	var feet: Array = []
	var foot_bindings: Dictionary = {}
	for foot_id_value in foot_ids:
		var foot_id := String(foot_id_value)
		if foot_id.is_empty() or foot_bindings.has(foot_id) or not by_id.has(foot_id): return _failed("invalid_jointed_paving_feet")
		var foot = by_id[foot_id]
		var binding := static_record_binding(foot.snapshot())
		if binding.is_empty(): return _failed("jointed_paving_foot_binding_failed")
		foot_bindings[foot_id] = binding
		feet.append(foot)
	var result: Dictionary = PavingAssembly.prepare_value(blueprint, [String(finish.id)], feet, float(declaration.nominalJoint), unit_surface_arrays)
	if not result.ready: return _failed("jointed_paving_prepare:" + String(result.reason))
	var joint: Variant = result.joints.get(String(finish.id))
	var artifact: Variant = result.artifacts.get(String(finish.id))
	if not joint is Dictionary or not artifact is Dictionary or var_to_bytes(joint) != var_to_bytes(declaration):
		return _failed("jointed_paving_declaration_mismatch")
	if artifact.get("geometryDigest") != declaration.get("geometryDigest") or artifact.get("constructionDigest") != declaration.get("constructionDigest"):
		return _failed("jointed_paving_digest_mismatch")
	if not _value_graph_safe(artifact): return _failed("jointed_paving_resource_in_value")
	var family: Variant = _freeze_value({"binding":static_record_binding(finish.snapshot()),"kind":"jointed_paving",
		"joint":joint,"footBindings":foot_bindings,"artifact":artifact})
	if not family is Dictionary: return _failed("jointed_paving_freeze_failed")
	return {"ready":true,"reason":"","family":family}


static func _value_graph_safe(value: Variant) -> bool:
	if value is Object: return false
	if value is Dictionary:
		for key in value:
			if not _value_graph_safe(key) or not _value_graph_safe(value[key]): return false
	elif value is Array:
		for item in value:
			if not _value_graph_safe(item): return false
	return true


static func _freeze_value(value: Variant) -> Variant:
	if value is Object: return null
	if value is Dictionary:
		var copied: Dictionary = {}
		for key in value:
			var frozen_key: Variant = _freeze_value(key)
			var frozen_value: Variant = _freeze_value(value[key])
			if (key != null and frozen_key == null) or (value[key] != null and frozen_value == null): return null
			copied[frozen_key] = frozen_value
		copied.make_read_only()
		return copied
	if value is Array:
		var copied: Array = []
		for item in value:
			var frozen: Variant = _freeze_value(item)
			if item != null and frozen == null: return null
			copied.append(frozen)
		copied.make_read_only()
		return copied
	return value


## Build the exclusive navigation cursor from the same frozen compact
## description as a packet base. It deliberately does not restore source
## parts or compile physical render geometry.
static func prepare_navigation_source(base: PreparedPublicationBase, expected_binding: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	if base == null or not base.matches(expected_binding): return _failed("invalid_publication_base_navigation_request")
	var guard := Continuation.new()
	guard.callback = continuation
	var producer := NavigationProducer.new()
	var progress := producer.begin(base.description.navigation,base.description.furnishing_navigation,guard.advance,base.description.solid_records)
	if progress.get("status","failed") in ["failed","cancelled"]:
		return _failed("cancelled" if guard.cancelled else "navigation_producer_initialization_failed")
	if not guard.advance("publication_navigation_source_ready"): return _failed("cancelled")
	var source := {"producer":producer,"binding":base.binding,"domain":producer.domain()}
	source.make_read_only()
	return {"ready":true,"reason":"","navigationSource":source}

static func prepare_source(building: Dictionary, furniture: Dictionary, binding: Dictionary, continuation: Callable = Callable(), world_origin := Vector3.ZERO, description_callback: Callable = Callable(), demanded_navigation := false) -> Dictionary:
	if not valid_binding(binding): return _failed("invalid_publication_binding")
	# Freeze identity before invoking any caller callback or expensive work.
	var source_binding := binding.duplicate()
	source_binding.make_read_only()
	var guard := Continuation.new()
	guard.callback = continuation
	var restored := Source.restore(building, furniture, guard.advance)
	if not restored.ready: return _failed(restored.reason)
	var diagnostics := evaluate(restored.blueprint, {}, guard.advance)
	if not diagnostics.ready: return _failed(diagnostics.reason)
	var description = SpatialDependencies.compile_description(restored.blueprint,restored.furnishingPlan,source_binding,world_origin,guard.advance)
	if description == null: return _failed("cancelled" if guard.cancelled else "spatial_dependency_compilation_failed")
	if description_callback.is_valid() and description_callback.call(description) != true: return _failed("cancelled")
	var metadata := _compile_static_records(restored.blueprint, guard.advance)
	if not metadata.ready: return _failed(metadata.reason)
	var history_result := _compile_history(restored.blueprint, guard.advance)
	if not history_result.ready: return _failed(history_result.reason)
	var masonry := _compile_masonry(restored.blueprint, history_result.preparedHistory, guard.advance, true)
	if not masonry.ready: return _failed(masonry.reason)
	var surfaces: Dictionary = {}
	var surface_timings: Dictionary = {}
	for family: String in ["paving","roof"]:
		var compiled := _compile_geometry(restored.blueprint,history_result.preparedHistory,guard.advance,true,family)
		if not compiled.ready: return _failed(compiled.reason)
		surfaces[family]=compiled.artifact
		surface_timings[family]=compiled.preparationUsec
	surfaces.make_read_only()
	surface_timings.make_read_only()
	var spatial = description
	var navigation_source: Dictionary = {}
	if demanded_navigation:
		# The worker returns exclusive producer ownership separately from scene
		# data. The scene may borrow the frozen description, never this cursor.
		var producer := NavigationProducer.new()
		var progress := producer.begin(description.navigation, description.furnishing_navigation, guard.advance, description.solid_records)
		if progress.get("status", "failed") in ["failed", "cancelled"]:
			return _failed("cancelled" if guard.cancelled else "navigation_producer_initialization_failed")
		# The frozen inventory is independent of the exclusively owned cursor.
		# Consumers may retain it while the worker compiles demanded tile outputs.
		navigation_source = {"producer":producer, "binding":source_binding, "domain":producer.domain()}
		navigation_source.make_read_only()
	else:
		spatial = description.compile_navigation(guard.advance)
		if spatial == null: return _failed("cancelled" if guard.cancelled else "spatial_dependency_compilation_failed")
	if not guard.advance("publication_preparation_ready"): return _failed("cancelled")
	var prepared := PreparedSource.new()
	prepared._binding = source_binding
	prepared._payload = {"blueprint":restored.blueprint, "furnishingPlan":restored.furnishingPlan,
		"raisedRouteCoverage":diagnostics.raisedRouteCoverage, "physicalIntegrity":diagnostics.physicalIntegrity,
		"preparationUsec":diagnostics.preparationUsec, "routeUsec":diagnostics.routeUsec,
		"physicalUsec":diagnostics.physicalUsec, "workerThreadId":OS.get_thread_caller_id(),
		"staticRecords":metadata.staticRecords, "staticRecordBindings":metadata.staticRecordBindings,
		"metadataPreparationUsec":metadata.metadataPreparationUsec,
		"preparedHistory":history_result.preparedHistory,
		"historyPreparationUsec":history_result.historyPreparationUsec,
		"preparedMasonry":masonry.preparedMasonry, "masonryPreparationUsec":masonry.masonryPreparationUsec,
		"preparedSurfaces":surfaces,"surfacePreparationUsec":surface_timings,
		"spatialDependencies":spatial}
	return {"ready":true, "reason":"", "prepared":prepared, "description":description, "navigationSource":navigation_source}

## Same visible wall/foundation dispatch as the publisher, including tagged
## aperture walls. No cuts, Nodes, Resources, uploads or geometry alternatives.
static func _compile_masonry(blueprint, prepared_history: PreparedHistory, continuation: Callable = Callable(), seal_owned_parts := false) -> Dictionary:
	var result := _compile_geometry(blueprint,prepared_history,continuation,seal_owned_parts,"masonry")
	if not result.ready: return result
	return {"ready":true,"reason":"","preparedMasonry":result.artifact,"masonryPreparationUsec":result.preparationUsec}

static func _compile_geometry(blueprint, prepared_history: PreparedHistory, continuation: Callable = Callable(), seal_owned_parts := false, family := "masonry", selected_ids: Dictionary = {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var guard := Continuation.new()
	guard.callback = continuation
	if not guard.advance("publication_"+family+"_started"): return _failed("cancelled")
	var result := {"ready":true, "reason":"", "artifact":null, "preparationUsec":0}
	if prepared_history != null:
		if blueprint == null: return _failed("missing_blueprint")
		var source_id := String(blueprint.recipe.get("sourceBlueprintId", blueprint.id))
		if not prepared_history.matches(prepared_history.history, source_id): return _failed("stale_prepared_history")
		var entries: Dictionary = {}
		var omitted: Dictionary = {}
		var seen: Dictionary = {}
		for part in blueprint.parts:
			if not guard.advance("publication_"+family+"_part"): return _failed("cancelled")
			if not selected_ids.is_empty() and not selected_ids.has(String(part.id)): continue
			if not geometry_selected(part,family): continue
			var id := String(part.id)
			if seen.has(id): return _failed("duplicate_"+family+"_part_id")
			seen[id] = true # Unsupported selected records still reserve their ID.
			var graph := MetadataGraph.new()
			graph.guard = guard
			graph.walk_stage = "publication_"+family+"_walk"
			graph.walk(part.recipe, [], false)
			if guard.cancelled: return _failed("cancelled")
			if not graph.eligible:
				omitted[part] = id
				continue
			var snapshot: Dictionary = part.snapshot()
			graph.walk(snapshot, [], false)
			if guard.cancelled: return _failed("cancelled")
			if not graph.eligible:
				omitted[part] = id
				continue
			var binding := static_record_binding(snapshot)
			if binding.is_empty(): return _failed(family+"_record_encoding_failed")
			var cursor = _geometry_cursor(part,prepared_history.history,source_id,family)
			while true:
				if not guard.advance("publication_"+family+"_cursor"):
					cursor.cancel()
					return _failed("cancelled")
				var progress: Dictionary = cursor.advance(2500)
				if progress.status == "ready": break
				if progress.status != "pending_budget": return _failed(family+"_descriptor_failed")
			if not guard.advance("publication_"+family+"_freeze"): return _failed("cancelled")
			var geometry: Variant = graph.walk(cursor.take_result(), [], true)
			if guard.cancelled: return _failed("cancelled")
			if not graph.eligible: return _failed("unsupported_"+family+"_descriptor")
			var packet = MasonryPacket.compile(part,geometry,source_id,guard.advance) if family=="masonry" else SurfacePacket.compile(part,geometry,family,guard.advance)
			if guard.cancelled: return _failed("cancelled")
			var sealed_revision := -1
			var sealed_recipe: Dictionary = {}
			if seal_owned_parts:
				if part.get_script()!=PartRecord: return _failed("unsupported_owned_part")
				sealed_recipe = graph.walk(snapshot.recipe,[],true)
				if guard.cancelled: return _failed("cancelled")
				if not graph.eligible: return _failed("unsupported_owned_recipe")
				# Validate after callbacks and before replacing any owned recipe.
				graph.walk(part.recipe,[],false)
				if guard.cancelled: return _failed("cancelled")
				if not graph.eligible: return _failed("stale_prepared_"+family+"_part")
				if static_record_binding(part.snapshot())!=binding: return _failed("stale_prepared_"+family+"_part")
				sealed_revision = part.seal_for_publication(sealed_recipe)
				if sealed_revision<0: return _failed("already_sealed_owned_part")
			var entry := {"id":id, "part":part, "binding":binding, "geometry":geometry,"packet":packet,
				"sealedRevision":sealed_revision,"sealedRecipe":sealed_recipe}
			entry.make_read_only()
			entries[part] = entry
			if not guard.advance("publication_"+family+"_record"): return _failed("cancelled")
		entries.make_read_only()
		omitted.make_read_only()
		var artifact := PreparedGeometry.new(entries, prepared_history, source_id, omitted, family)
		# Callbacks may reject or change earlier inputs. Never commit partial/stale
		# descriptors; validation remains worker work and independently cancellable.
		for part in entries:
			if not guard.advance("publication_"+family+"_validate"): return _failed("cancelled")
			if not artifact.validate_part(part): return _failed("stale_prepared_"+family+"_part")
		if not artifact.matches_history(prepared_history, prepared_history.history, source_id): return _failed("stale_prepared_history")
		result.artifact = artifact
	if not guard.advance("publication_"+family+"_completed"): return _failed("cancelled")
	result.preparationUsec = Time.get_ticks_usec() - started
	return result

static func geometry_selected(part, family: String) -> bool:
	return GeometrySelection.selected(part,family)

static func _geometry_cursor(part, history, source_id: String, family: String):
	if family=="masonry": return MasonryGeometry.begin_source(part,history,source_id)
	if family=="roof": return RoofGeometry.begin_source(part,history,source_id)
	# Match the existing paving publisher's authoring-normalized private copy.
	return CobbleGeometry.begin_source(PartRecord.new(part.snapshot()),history,source_id)

static func _masonry_selected(part) -> bool:
	return MasonrySelection.selected(part)

## Optional optimization only: unsupported input stays on mutable compatibility.
## Configure uses the original history algorithm, then replaces ALL four roots
## with isolated copies. In particular, never freeze configure's recipe alias.
static func _compile_history(blueprint, continuation: Callable = Callable()) -> Dictionary:
	var started := Time.get_ticks_usec()
	var guard := Continuation.new()
	guard.callback = continuation
	if not guard.advance("publication_history_started"): return _failed("cancelled")
	if blueprint == null: return _failed("missing_blueprint")
	var result := {"ready":true, "reason":"", "preparedHistory":null, "historyPreparationUsec":0}
	var graph := MetadataGraph.new()
	graph.guard = guard
	graph.walk_stage = "publication_history_walk"
	# Preflight before configure's tree duplicate(true): cycles/Objects/packed
	# values must not enter that operation. Conservative omission is intentional.
	graph.walk(blueprint.recipe, [], false)
	if guard.cancelled: return _failed("cancelled")
	var shape_valid: bool = blueprint.recipe is Dictionary
	if shape_valid:
		shape_valid = blueprint.recipe.get("routeCorridors", blueprint.recipe.get("pavingTreatments", [])) is Array \
			and blueprint.recipe.get("landscapeTrees", []) is Array
		if shape_valid and blueprint.recipe.get("landscapeTrees", []).is_empty():
			var urban: Variant = blueprint.recipe.get("urbanPoc", {})
			shape_valid = urban is Dictionary and urban.get("treePlacements", []) is Array
	if graph.eligible and shape_valid:
		if not guard.advance("publication_history_configure"): return _failed("cancelled")
		var field := History.new()
		# Atomic legacy configure runs on the owned worker, never the frame thread.
		field.configure(blueprint.recipe, blueprint.parts)
		if not guard.advance("publication_history_configured"): return _failed("cancelled")
		var frozen: Variant = graph.walk([field.route_corridors, field.tree_placements,
			field.history_events, field.history_event_cells], [], true)
		if guard.cancelled: return _failed("cancelled")
		if graph.eligible:
			field.route_corridors = frozen[0]
			field.tree_placements = frozen[1]
			field.history_events = frozen[2]
			field.history_event_cells = frozen[3]
			var source_id := String(blueprint.recipe.get("sourceBlueprintId", blueprint.id))
			result.preparedHistory = PreparedHistory.new(field, source_id)
	if not guard.advance("publication_history_completed"): return _failed("cancelled")
	result.historyPreparationUsec = Time.get_ticks_usec() - started
	return result

## Post-diagnostic snapshots only. Unsupported graphs are absent from BOTH maps
## so the publisher retains its ordinary unfrozen fallback. Exact bindings are
## immutable hexadecimal Strings of the typed encoding, not hashes/packed aliases.
static func _compile_static_records(blueprint, continuation: Callable = Callable()) -> Dictionary:
	var started := Time.get_ticks_usec()
	var guard := Continuation.new()
	guard.callback = continuation
	if not guard.advance("publication_metadata_started"): return _failed("cancelled")
	var records: Dictionary = {}
	var bindings: Dictionary = {}
	var seen: Dictionary = {}
	for part in blueprint.parts:
		if not guard.advance("publication_metadata_part"): return _failed("cancelled")
		if part == null or not part.collision_enabled or String(part.kind) == "door": continue
		var id := String(part.id)
		if seen.has(id): return _failed("duplicate_static_record_id")
		seen[id] = true # Includes unsupported records: never silently overwrite.
		var graph := MetadataGraph.new()
		graph.guard = guard
		# snapshot() itself deep-duplicates recipes. Reject cycles/unsupported
		# graphs BEFORE that legacy operation; do not trigger recursion errors.
		graph.walk(part.recipe, [], false)
		if guard.cancelled: return _failed("cancelled")
		if not graph.eligible: continue
		var snapshot: Dictionary = part.snapshot()
		var frozen: Variant = graph.walk(snapshot, [], true)
		if guard.cancelled: return _failed("cancelled")
		if not graph.eligible: continue
		var encoded := static_record_binding(frozen)
		if encoded.is_empty(): return _failed("static_record_encoding_failed")
		if not guard.advance("publication_metadata_record_encoded"): return _failed("cancelled")
		records[id] = frozen
		bindings[id] = encoded
	if not guard.advance("publication_metadata_completed"): return _failed("cancelled")
	records.make_read_only()
	bindings.make_read_only()
	return {"ready":true, "reason":"", "staticRecords":records, "staticRecordBindings":bindings,
		"metadataPreparationUsec":Time.get_ticks_usec()-started}

## Call only for supported, acyclic metadata. Godot 4.6.1's NodePath encoder
## advances over component alignment padding without writing it (marshalls.cpp).
## Re-encode into zeroed storage: identical Variant types/order/format and every
## represented byte, with deterministic padding instead of allocator contents.
## Consumers comparing these bindings must use this same encoding contract.
static func static_record_binding(record: Dictionary) -> String:
	return RecordBinding.encode(record)

## Shared sequence for the legacy synchronous entry and background preparation.
## Preserve BOTH resolutions: the second changes derived classification facts.
## Empty continuation retains existing virtual validation/resolve dispatch.
static func evaluate(blueprint, options: Dictionary = {}, continuation: Callable = Callable()) -> Dictionary:
	if blueprint == null: return _failed("missing_blueprint")
	var guard := Continuation.new()
	guard.callback = continuation
	var callback := guard.advance if continuation.is_valid() else Callable()
	var started := Time.get_ticks_usec()
	if not guard.advance("publication_route_started"): return _failed("cancelled")
	var route: Dictionary = Castle.validate_raised_route_coverage(blueprint, callback)
	if bool(route.get("cancelled", false)) or not guard.advance("publication_route_completed"): return _failed("cancelled")
	var route_finished := Time.get_ticks_usec()
	var authority = options.get("structuralAuthorityBlueprint", blueprint)
	var physical: Dictionary
	if authority != null and authority.has_method("validate_physical_integrity"):
		if continuation.is_valid():
			if not authority.has_method("validate_physical_integrity_cancellable"):
				return _failed("structural_authority_not_cancellable")
			physical = authority.validate_physical_integrity_cancellable(callback)
		else:
			physical = authority.validate_physical_integrity()
	else:
		physical = {"passed":true, "checkedPartCount":0, "checks":[], "violations":[]}
	if bool(physical.get("cancelled", false)) or not guard.advance("publication_physical_completed"): return _failed("cancelled")
	var finished := Time.get_ticks_usec()
	return {"ready":true, "reason":"", "raisedRouteCoverage":route, "physicalIntegrity":physical,
		"preparationUsec":finished-started, "routeUsec":route_finished-started, "physicalUsec":finished-route_finished}

static func _failed(reason: String) -> Dictionary:
	return {"ready":false, "reason":reason}
