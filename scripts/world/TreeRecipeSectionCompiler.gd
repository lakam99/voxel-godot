extends RefCounted
class_name TreeRecipeSectionCompiler

## Resumable recipe-to-section value compiler. Recipe/LOD and gameplay remain
## owned by TreeSpawnService and the tree body; this type only builds renderer
## resources and assigns their exact instances to static render sections.

const SpawnService := preload("res://scripts/environment/TreeSpawnService.gd")
const FactoryScript := preload("res://scripts/visual/ProceduralTreeVisualFactory.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Adapter := preload("res://scripts/world/TreeSectionValueAdapter.gd")
const RemovedProps := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")

const SCHEMA := "tree-recipe-section-compiler/v1"
const MAX_WORK_UNITS_PER_ADVANCE := 64
const ROLES := ["bole", "branches", "foliage"]

var _job: Dictionary = {}


func begin(main: Object, world_id: String, records: Array,
		removed_snapshot: Dictionary) -> Dictionary:
	if _job.get("status", "") == "pending":
		return _pending("compiler_job_already_active")
	if not is_instance_valid(main) or world_id.is_empty() or records.is_empty():
		return _pending("tree_recipe_input_missing")
	if not bool(removed_snapshot.get("ok", false)):
		return _pending("tree_removed_props_snapshot_missing")
	var copied_records: Array = []
	var ids: Array[String] = []
	for value: Variant in records:
		if not value is Dictionary or not value.is_read_only():
			return _pending("tree_recipe_input_unsealed")
		var record: Dictionary = value
		var validated := _validate_record(main, world_id, record, removed_snapshot)
		if validated.get("status") != "ready":
			return validated
		var id := String(record.get("propId", ""))
		if id in ids:
			return _pending("duplicate_tree_source")
		ids.append(id)
		copied_records.append(record)
	_job = {"status":"pending", "main":weakref(main), "mainInstanceId":main.get_instance_id(),
		"worldId":world_id, "records":copied_records, "recordIndex":0,
		"roleIndex":0, "factory":FactoryScript.new(), "buildState":{},
		"compileState":{}, "roleValues":{}, "sectionBatches":{}, "bindings":{}, "manifest":[],
		"currentSourceSections":{}, "currentSourceOwnedSections":{},
		"currentSourceGeometryOwnership":[],
		"workUnits":0, "removedSnapshot":removed_snapshot,
		"sourceIdentities":_source_identities(copied_records)}
	return {"status":"pending", "reason":"tree_section_compile_started", "retryable":true}


func advance(work_units := 1) -> Dictionary:
	if _job.is_empty() or _job.get("status", "") != "pending":
		return _pending("tree_section_compile_not_active")
	var budget := clampi(work_units, 1, MAX_WORK_UNITS_PER_ADVANCE)
	var performed := 0
	while performed < budget and int(_job.recordIndex) < _job.records.size():
		var record: Dictionary = _job.records[_job.recordIndex]
		if not _current(record):
			return _discard("tree_recipe_input_became_stale")
		var role_index := int(_job.roleIndex)
		var role := String(ROLES[role_index])
		if not _job.compileState.is_empty():
			var append_result := _append_role_instance(record, _job.compileState)
			if append_result.get("status") != "ready":
				return _discard(String(append_result.get("reason", "tree_instance_compile_failed")))
			performed += 1
			_job.workUnits = int(_job.workUnits) + 1
			if int(_job.compileState.nextIndex) >= int(_job.compileState.instanceCount):
				_job.roleValues[role] = _job.compileState.values
				_job.compileState = {}
				_job.roleIndex = role_index + 1
				if int(_job.roleIndex) >= ROLES.size():
					var source_manifest := _seal_source(record)
					if source_manifest.get("status") != "ready":
						return _discard(String(source_manifest.get("reason", "tree_source_manifest_failed")))
					_job.manifest.append(source_manifest.value)
					_job.recordIndex = int(_job.recordIndex) + 1
					_job.roleIndex = 0
					_job.roleValues = {}
			continue
		if _job.buildState.is_empty():
			var prepared := _begin_role(record, role)
			if prepared.get("status") != "ready":
				return _discard(String(prepared.get("reason", "tree_role_begin_failed")))
			_job.buildState = prepared.get("state", {})
			performed += 1
			_job.workUnits = int(_job.workUnits) + 1
			continue
		var factory: Object = _job.factory
		var complete := _advance_role(factory, role, _job.buildState)
		performed += 1
		_job.workUnits = int(_job.workUnits) + 1
		if not complete:
			continue
		var values := _finish_role(factory, record, role, _job.buildState)
		_job.buildState = {}
		if values.is_empty():
			return _discard("tree_role_values_unavailable")
		var compiled := _prepare_role_compile(record, role, values)
		if compiled.get("status") != "ready":
			return _discard(String(compiled.get("reason", "tree_role_compile_failed")))
		_job.compileState = compiled.state
	if int(_job.recordIndex) < _job.records.size():
		return {"status":"pending", "reason":"tree_section_compile_in_progress",
			"retryable":true, "workUnits":int(_job.workUnits),
			"recordIndex":int(_job.recordIndex), "roleIndex":int(_job.roleIndex)}
	return _seal_candidate()


func cancel() -> void:
	_job.clear()


func _begin_role(record: Dictionary, role: String) -> Dictionary:
	var recipe: Dictionary = record.recipeSnapshot
	var branches: Array[Dictionary] = _typed_dictionary_array(recipe.get("branches", []))
	var foliage: Array = recipe.get("foliage", [])
	var factory: Object = _job.factory
	var state: Dictionary
	match role:
		"bole": state = factory.begin_runtime_bole_build(branches)
		"branches": state = factory.begin_runtime_distal_build(recipe, branches,
			String(record.request.get("biome", "forest")), String(record.propId))
		"foliage": state = factory.begin_runtime_foliage_build(recipe, foliage,
			String(record.request.get("biome", "forest")), String(record.propId))
	if state.is_empty():
		return {"status":"pending", "reason":"tree_recipe_role_has_no_render_values"}
	return {"status":"ready", "state":state}


func _advance_role(factory: Object, role: String, state: Dictionary) -> bool:
	match role:
		"bole": return bool(factory.advance_runtime_bole_build(state, 1))
		"branches": return bool(factory.advance_runtime_distal_build(state, 1))
		"foliage": return bool(factory.advance_runtime_foliage_build(state, 1))
	return false


func _finish_role(factory: Object, record: Dictionary, role: String,
		state: Dictionary) -> Dictionary:
	var recipe: Dictionary = record.recipeSnapshot
	var biome := String(record.request.get("biome", "forest"))
	match role:
		"bole": return factory.finish_runtime_bole_values(recipe, state, biome)
		"branches": return factory.finish_runtime_distal_build_values(state, recipe, biome)
		"foliage": return factory.finish_runtime_foliage_build_values(state, recipe, biome)
	return {}


func _prepare_role_compile(record: Dictionary, role: String, values: Dictionary) -> Dictionary:
	var mesh: Mesh
	var multi: MultiMesh
	var instance_count := 1
	var material: Material = values.get("material", null)
	if role == "bole":
		mesh = values.get("mesh", null) as Mesh
	else:
		multi = values.get("multiMesh", null) as MultiMesh
		if multi == null:
			return _pending("tree_multimesh_value_missing")
		mesh = multi.mesh
		instance_count = multi.instance_count
	if not is_instance_valid(mesh) or not is_instance_valid(material) or instance_count <= 0:
		return _pending("tree_render_resource_or_instance_missing")
	var layer := Adapter._supported_opaque_layer(material, role)
	if layer.is_empty(): return _pending("tree_render_layer_unsupported")
	var mesh_report := MeshFingerprint.inspect(mesh)
	var mesh_digest := String(mesh_report.get("contentDigest", ""))
	var material_digest := Adapter._material_digest(material)
	if mesh_report.get("status") != "ready" or mesh_digest.is_empty() or material_digest.is_empty():
		return _pending("tree_resource_fingerprint_unavailable")
	var bounds := mesh.get_aabb()
	if not Adapter._valid_bounds(bounds): return _pending("tree_mesh_bounds_invalid")
	var resource_key := "tree.runtime.%s:%s/v1" % [role, mesh_digest]
	var material_key := "tree.material.%s:%s" % [role, material_digest]
	var policy: Dictionary = values.get("renderPolicy", {})
	var compatibility := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":material_key, "renderTier":"detail" if role == "foliage" else "structural",
		"meshResourceKey":resource_key, "meshContentDigest":mesh_digest,
		"meshKey":"%s|pipeline=%s|layer=%s|sort=none" % [resource_key, Adapter.PIPELINE_REVISION, layer],
		"pipelineRevision":Adapter.PIPELINE_REVISION, "renderLayer":layer,
		"translucentSortPolicy":"none", "meshLocalBounds":bounds,
		"castShadows":int(policy.get("castShadow", GeometryInstance3D.SHADOW_CASTING_SETTING_ON)) != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"visibilityRangeEnd":float(policy.get("visibilityRangeEnd", 0.0)),
		"fadeMargin":float(policy.get("visibilityRangeEndMargin", 0.0))}
	var batch_key := SnapshotBuilder.batch_compatibility_key(compatibility)
	if batch_key.is_empty(): return _pending("tree_batch_compatibility_invalid")
	compatibility["batchKey"] = batch_key
	compatibility["compatibilityKey"] = batch_key
	compatibility.make_read_only()
	_job.bindings[resource_key] = mesh
	_job.bindings[material_key] = material
	return {"status":"ready", "state":{"role":role, "values":values, "mesh":mesh,
		"multiMesh":multi, "bounds":bounds, "compatibility":compatibility,
		"batchKey":batch_key, "resourceKey":resource_key, "materialKey":material_key,
		"meshDigest":mesh_digest, "materialDigest":material_digest,
		"ownerCell":record.logicalOwnerCell, "instanceCount":instance_count, "nextIndex":0}}


func _append_role_instance(record: Dictionary, state: Dictionary) -> Dictionary:
	var index := int(state.nextIndex)
	var role := String(state.role)
	var multi: MultiMesh = state.multiMesh
	var local_transform := Transform3D.IDENTITY if role == "bole" else multi.get_instance_transform(index)
	var color := Color.WHITE if role == "bole" or not multi.use_colors else multi.get_instance_color(index)
	var custom := Color.TRANSPARENT if role == "bole" else multi.get_instance_custom_data(index)
	var world_transform: Transform3D = record.bodyGlobalTransform * local_transform
	if not Adapter._valid_transform(world_transform) or not Attributes.is_finite_color(color) \
			or not Attributes.is_finite_color(custom):
		return _pending("tree_instance_value_invalid")
	var world_bounds: AABB = state.bounds * world_transform
	if not Adapter._valid_bounds(world_bounds): return _pending("tree_instance_bounds_invalid")
	var section_key := Grid.key_for_world_position(world_bounds.get_center())
	_job.currentSourceOwnedSections[section_key] = true
	var support_keys := Grid.keys_intersecting_bounds(world_bounds)
	if support_keys.is_empty(): return _pending("tree_instance_support_sections_missing")
	for support_key: Vector3i in support_keys:
		_job.currentSourceSections[support_key] = true
	_job.currentSourceGeometryOwnership.append({"role":role,
		"instanceIndex":index, "ownedSectionKey":section_key,
		"supportSectionKeys":support_keys.duplicate()})
	var section_origin := Grid.origin_for_key(section_key)
	var section_transform := Transform3D(Basis.IDENTITY, -section_origin) * world_transform
	var batch_key := String(state.batchKey)
	var key := "%s|%s" % [section_key, batch_key]
	if not _job.sectionBatches.has(key):
		_job.sectionBatches[key] = {"sectionKey":section_key, "batchKey":batch_key,
			"role":role, "compatibilityKey":state.compatibility, "meshKey":state.resourceKey,
			"materialKey":state.materialKey, "meshDigest":state.meshDigest,
			"materialDigest":state.materialDigest, "sectionOrigin":section_origin,
			"ownerCell":state.ownerCell,
			"streamChunkDependencies":Grid.stream_chunk_keys_intersecting_section(section_key),
			"instanceAttributes":[], "contributors":{}}
	var batch: Dictionary = _job.sectionBatches[key]
	var packed := Attributes.encode(section_transform, custom, color)
	batch.instanceAttributes.append_array(packed)
	var contributors: Dictionary = batch.contributors
	var source_id := String(record.sourceId)
	if not contributors.has(source_id): contributors[source_id] = []
	(contributors[source_id] as Array).append_array(packed)
	state.nextIndex = index + 1
	return {"status":"ready"}


func _seal_source(record: Dictionary) -> Dictionary:
	if not _current(record):
		return _pending("tree_recipe_input_stale_before_source_seal")
	var digest_context := HashingContext.new()
	if digest_context.start(HashingContext.HASH_SHA256) != OK:
		return _pending("tree_source_digest_begin_failed")
	var source_id := String(record.sourceId)
	for key: Variant in _job.sectionBatches.keys():
		var batch: Dictionary = _job.sectionBatches[key]
		if String(batch.role) not in ROLES or not batch.contributors.has(source_id):
			continue
		var packed := var_to_bytes([key, batch.meshDigest, batch.materialDigest,
			batch.contributors[source_id]])
		if digest_context.update(packed) != OK:
			return _pending("tree_source_digest_update_failed")
	var compiled_digest := digest_context.finish().hex_encode()
	var revision_context := HashingContext.new()
	if revision_context.start(HashingContext.HASH_SHA256) != OK \
			or revision_context.update(var_to_bytes([SCHEMA,
				String(record.contentRevision), compiled_digest])) != OK:
		return _pending("tree_source_revision_digest_failed")
	var values := {"schema":SCHEMA, "sourceId":String(record.sourceId),
		"sourceRevision":revision_context.finish().hex_encode(),
		"recipeArtifactRevision":String(record.contentRevision),
		"recipeSignature":String(record.recipeSignature),
		"bodyInstanceId":int(record.bodyInstanceId),
		"bodyGlobalTransform":record.bodyGlobalTransform,
		"sectionKeys":_source_section_keys(_job.currentSourceSections),
		"ownedSectionKeys":_source_section_keys(_job.currentSourceOwnedSections),
		"geometryOwnership":_freeze_ownership(_job.currentSourceGeometryOwnership),
		"compiledAttributeDigest":compiled_digest}
	_deep_freeze(values)
	_job.currentSourceSections.clear()
	_job.currentSourceOwnedSections.clear()
	_job.currentSourceGeometryOwnership.clear()
	return {"status":"ready", "value":values}


func _seal_candidate() -> Dictionary:
	var main_ref := _job.main as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	if not is_instance_valid(main) or main.get_instance_id() != int(_job.mainInstanceId) \
			or not RemovedProps.is_current_for_ids(main, _job.removedSnapshot, _source_prop_ids()) :
		return _discard("tree_removed_props_or_main_stale_before_seal")
	for record: Dictionary in _job.records:
		if not _current(record):
			return _discard("tree_recipe_input_stale_before_candidate_seal")
	if not _resources_current():
		return _discard("tree_render_resource_fingerprint_changed_before_candidate_seal")
	var batches: Array[Dictionary] = []
	var manifest: Array = _job.manifest.duplicate(true)
	for key: Variant in _job.sectionBatches.keys():
		var batch: Dictionary = _job.sectionBatches[key]
		var attrs: Array = batch.instanceAttributes
		if attrs.is_empty() or attrs.size() % Attributes.FLOATS_PER_INSTANCE != 0:
			return _discard("tree_instance_attribute_buffer_invalid")
		attrs.make_read_only()
		var row := {"sectionKey":batch.sectionKey, "batchKey":batch.batchKey,
			"role":batch.role, "renderLayer":"opaque", "compatibilityKey":batch.compatibilityKey,
			"meshKey":batch.meshKey, "materialKey":batch.materialKey,
			"meshContentDigest":batch.meshDigest, "materialContentDigest":batch.materialDigest,
			"sectionOrigin":batch.sectionOrigin, "ownerCell":batch.ownerCell,
			"streamChunkDependencies":batch.streamChunkDependencies,
			"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"instanceCount":attrs.size() / Attributes.FLOATS_PER_INSTANCE,
			"contributors":_freeze_contributors(batch.contributors, manifest),
			"instanceAttributes":attrs}
		_deep_freeze(row)
		batches.append(row)
	batches.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ak: Vector3i = a.sectionKey
		var bk: Vector3i = b.sectionKey
		if ak.x != bk.x: return ak.x < bk.x
		if ak.y != bk.y: return ak.y < bk.y
		if ak.z != bk.z: return ak.z < bk.z
		return String(a.batchKey) < String(b.batchKey))
	batches.make_read_only()
	manifest.make_read_only()
	var bindings: Dictionary = _job.bindings.duplicate()
	bindings.make_read_only()
	var output := {"status":"ready", "schema":SCHEMA, "worldId":_job.worldId,
		"sources":manifest, "batches":batches, "resourceBindings":bindings,
		"workUnits":int(_job.workUnits), "oldRepresentationRetention":"caller_owned_until_receipt"}
	output.make_read_only()
	_job.status = "complete"
	return output


func _validate_record(main: Object, world_id: String, record: Dictionary,
		removed_snapshot: Dictionary) -> Dictionary:
	if String(record.get("schema", "")) != "tree-section-recipe-input/v1" \
			or int(record.get("worldOwnerInstanceId", 0)) != main.get_instance_id():
		return _pending("tree_recipe_artifact_identity_invalid")
	var check := _record_currentness(main, world_id, record, removed_snapshot)
	return {"status":"ready"} if check else _pending("tree_recipe_artifact_stale")


func _current(record: Dictionary) -> bool:
	var main_ref := _job.main as WeakRef
	var main: Object = main_ref.get_ref() if main_ref != null else null
	return is_instance_valid(main) and main.get_instance_id() == int(_job.mainInstanceId) \
		and _record_currentness(main, String(_job.worldId), record, _job.removedSnapshot)


func _record_currentness(main: Object, world_id: String, record: Dictionary,
		removed_snapshot: Dictionary) -> bool:
	var body_ref := record.get("body") as WeakRef
	var body := body_ref.get_ref() as StaticBody3D if body_ref != null else null
	if not is_instance_valid(body) or not body.is_inside_tree() or body.is_queued_for_deletion() \
			or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
			or int(record.get("worldOwnerInstanceId", 0)) != main.get_instance_id() \
			or not (record.get("bodyGlobalTransform") as Transform3D).is_equal_approx(body.global_transform) \
			or String(body.get_meta("prop_id", "")) != String(record.get("propId", "")) \
			or bool(body.get_meta("tree_publication_cancelled", false)):
		return false
	var expected_generation := int(body.get_meta("tree_section_recipe_input_expected_generation", 0))
	if expected_generation > 0 and expected_generation != int(record.get("producerGeneration", 0)):
		return false
	if String(record.get("worldSeed", "")) != String(main.get("seed_text")) \
			or not RemovedProps.is_current_for_ids(main, removed_snapshot, [String(record.propId)]) \
			or (removed_snapshot.get("ids", []) as Array).has(String(record.propId)):
		return false
	var service := SpawnService.new()
	var normalized: Dictionary = service.normalize_request(record.get("request", {}))
	var recipe: Dictionary = record.get("recipeSnapshot", {})
	if normalized.is_empty() or normalized != record.get("request", {}) \
			or String(service.runtime_recipe_signature(recipe, normalized)) != String(record.get("recipeSignature", "")):
		return false
	var context := HashingContext.new()
	var content := [String(record.get("schema", "")), "tree-recipe-section-compiler/v1",
		String(record.get("worldSeed", "")), String(record.get("propId", "")),
		String(record.get("renderLodTier", "")), String(record.get("recipeSignature", "")),
		record.get("request", {}), recipe]
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(var_to_bytes(content)) != OK:
		return false
	return context.finish().hex_encode() == String(record.get("contentRevision", "")) \
		and String(record.get("renderLodTier", "")) == String(recipe.get("renderLod", {}).get("tier", "")) \
		and not bool(recipe.get("runtimeImpostor", false))


func _source_identities(records: Array) -> Array:
	var ids: Array = []
	for record: Dictionary in records:
		ids.append([String(record.get("sourceId", "")), String(record.get("contentRevision", "")),
			int(record.get("bodyInstanceId", 0)), int(record.get("producerGeneration", 0))])
	_deep_freeze(ids)
	return ids


func _typed_dictionary_array(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not value is Array:
		return result
	for item: Variant in value:
		if item is Dictionary:
			result.append(item)
	return result


func _source_prop_ids() -> Array:
	var ids: Array = []
	for record: Dictionary in _job.records:
		ids.append(String(record.get("propId", "")))
	return ids


func _source_section_keys(source_sections: Dictionary) -> Array:
	var keys: Array[Vector3i] = []
	for key: Variant in source_sections.keys():
		if key is Vector3i: keys.append(key)
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	_deep_freeze(keys)
	return keys


func _freeze_ownership(rows: Array) -> Array:
	var frozen: Array = rows.duplicate(true)
	_deep_freeze(frozen)
	return frozen


func _resources_current() -> bool:
	for key_value: Variant in _job.bindings.keys():
		var key := String(key_value)
		var resource: Variant = _job.bindings[key_value]
		if key.begins_with("tree.runtime."):
			if not resource is Mesh: return false
			var current_mesh := MeshFingerprint.inspect(resource as Mesh)
			if current_mesh.get("status") != "ready" \
					or not key.contains(String(current_mesh.get("contentDigest", ""))):
				return false
		elif key.begins_with("tree.material."):
			if not resource is Material: return false
			var digest := Adapter._material_digest(resource as Material)
			if digest.is_empty() or not key.ends_with(digest): return false
		else:
			return false
	return true


func _freeze_contributors(contributors: Dictionary, manifest: Array) -> Dictionary:
	var copy := {}
	for source_id: Variant in contributors:
		var attributes: Array = contributors[source_id].duplicate()
		attributes.make_read_only()
		var source_revision := ""
		for source_value: Variant in manifest:
			if source_value is Dictionary and String(source_value.get("sourceId", "")) == String(source_id):
				source_revision = String(source_value.get("sourceRevision", ""))
				break
		if source_revision.is_empty():
			return {}
		copy[String(source_id)] = {"sourceId":String(source_id),
			"sourcePartId":String(source_id), "sourceRevision":source_revision,
			"instanceCount":attributes.size() / Attributes.FLOATS_PER_INSTANCE,
			"instanceAttributes":attributes}
	_deep_freeze(copy)
	return copy


func _deep_freeze(value: Variant) -> void:
	if value is Dictionary:
		for nested: Variant in value.values(): _deep_freeze(nested)
		(value as Dictionary).make_read_only()
	elif value is Array:
		for nested: Variant in value: _deep_freeze(nested)
		(value as Array).make_read_only()


func _discard(reason: String) -> Dictionary:
	_job.clear()
	return _pending(reason)


func _pending(reason: String) -> Dictionary:
	return {"status":"pending", "reason":reason, "retryable":true}
