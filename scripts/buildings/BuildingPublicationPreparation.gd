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
const PartRecord = preload("res://scripts/buildings/BuildingPart.gd")
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
	func take(expected_binding: Dictionary) -> Dictionary:
		if _consumed or _payload.is_empty() or _binding != expected_binding: return {}
		_consumed = true
		var result := _payload
		_payload = {}
		return result

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

class PreparedMasonry extends RefCounted:
	# Object keys deliberately retain source parts through worker retirement and
	# recognize a changed ID. Geometry/entry/maps are otherwise deeply readonly.
	var _entries: Dictionary
	var _ids: Dictionary = {}
	var _omitted: Dictionary
	var _omitted_ids: Dictionary = {}
	var _history: PreparedHistory
	var _source_id: String
	func _init(entries: Dictionary, history_artifact: PreparedHistory, source_id: String, omitted: Dictionary) -> void:
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
		return MasonrySelection.selected(part)
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

static func prepare_source(building: Dictionary, furniture: Dictionary, binding: Dictionary, continuation: Callable = Callable()) -> Dictionary:
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
	var metadata := _compile_static_records(restored.blueprint, guard.advance)
	if not metadata.ready: return _failed(metadata.reason)
	var history_result := _compile_history(restored.blueprint, guard.advance)
	if not history_result.ready: return _failed(history_result.reason)
	var masonry := _compile_masonry(restored.blueprint, history_result.preparedHistory, guard.advance, true)
	if not masonry.ready: return _failed(masonry.reason)
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
		"preparedMasonry":masonry.preparedMasonry, "masonryPreparationUsec":masonry.masonryPreparationUsec}
	return {"ready":true, "reason":"", "prepared":prepared}

## Same visible wall/foundation dispatch as the publisher, including tagged
## aperture walls. No cuts, Nodes, Resources, uploads or geometry alternatives.
static func _compile_masonry(blueprint, prepared_history: PreparedHistory, continuation: Callable = Callable(), seal_owned_parts := false) -> Dictionary:
	var started := Time.get_ticks_usec()
	var guard := Continuation.new()
	guard.callback = continuation
	if not guard.advance("publication_masonry_started"): return _failed("cancelled")
	var result := {"ready":true, "reason":"", "preparedMasonry":null, "masonryPreparationUsec":0}
	if prepared_history != null:
		if blueprint == null: return _failed("missing_blueprint")
		var source_id := String(blueprint.recipe.get("sourceBlueprintId", blueprint.id))
		if not prepared_history.matches(prepared_history.history, source_id): return _failed("stale_prepared_history")
		var entries: Dictionary = {}
		var omitted: Dictionary = {}
		var seen: Dictionary = {}
		for part in blueprint.parts:
			if not guard.advance("publication_masonry_part"): return _failed("cancelled")
			if not _masonry_selected(part): continue
			var id := String(part.id)
			if seen.has(id): return _failed("duplicate_masonry_part_id")
			seen[id] = true # Unsupported selected records still reserve their ID.
			var graph := MetadataGraph.new()
			graph.guard = guard
			graph.walk_stage = "publication_masonry_walk"
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
			if binding.is_empty(): return _failed("masonry_record_encoding_failed")
			var cursor = MasonryGeometry.begin_source(part, prepared_history.history, source_id)
			while true:
				if not guard.advance("publication_masonry_cursor"):
					cursor.cancel()
					return _failed("cancelled")
				var progress: Dictionary = cursor.advance(2500)
				if progress.status == "ready": break
				if progress.status != "pending_budget": return _failed("masonry_descriptor_failed")
			if not guard.advance("publication_masonry_freeze"): return _failed("cancelled")
			var geometry: Variant = graph.walk(cursor.take_result(), [], true)
			if guard.cancelled: return _failed("cancelled")
			if not graph.eligible: return _failed("unsupported_masonry_descriptor")
			var packet = MasonryPacket.compile(part,geometry,source_id,guard.advance)
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
				if not graph.eligible: return _failed("stale_prepared_masonry_part")
				if static_record_binding(part.snapshot())!=binding: return _failed("stale_prepared_masonry_part")
				sealed_revision = part.seal_for_publication(sealed_recipe)
				if sealed_revision<0: return _failed("already_sealed_owned_part")
			var entry := {"id":id, "part":part, "binding":binding, "geometry":geometry,"packet":packet,
				"sealedRevision":sealed_revision,"sealedRecipe":sealed_recipe}
			entry.make_read_only()
			entries[part] = entry
			if not guard.advance("publication_masonry_record"): return _failed("cancelled")
		entries.make_read_only()
		omitted.make_read_only()
		var artifact := PreparedMasonry.new(entries, prepared_history, source_id, omitted)
		# Callbacks may reject or change earlier inputs. Never commit partial/stale
		# descriptors; validation remains worker work and independently cancellable.
		for part in entries:
			if not guard.advance("publication_masonry_validate"): return _failed("cancelled")
			if not artifact.validate_part(part): return _failed("stale_prepared_masonry_part")
		if not artifact.matches_history(prepared_history, prepared_history.history, source_id): return _failed("stale_prepared_history")
		result.preparedMasonry = artifact
	if not guard.advance("publication_masonry_completed"): return _failed("cancelled")
	result.masonryPreparationUsec = Time.get_ticks_usec() - started
	return result

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
