extends "res://scripts/testing/buildings/CitadelMarketPublishedOverlapContract.gd"

## CPU publication diagnostic, not a headed or physical acceptance runner.
## Uses the immutable reviewed source. Every viable source proposal is measured;
## contact candidates remain reported, never exempted by ownership alone.
const Chimney = preload("res://scripts/buildings/ChimneyBearingRecipe.gd")
const Shops = preload("res://scripts/buildings/CitadelShopRecipe.gd")
const Furnisher = preload("res://scripts/buildings/FurnishingPublisher.gd")
const FurnishingPlanScript = preload("res://scripts/buildings/FurnishingPlan.gd")
const REVIEW_SHA := "e43b972eface80bbcbc015ef55ac0c21a5cb99083dcfa9aabbb5a407f9832038"
const MAX_MATERIAL_OBJECTS := 32768
const MAX_COLLECTED_NODES := 1000000
const MAX_COLLECT_DEPTH := 64
const MAX_PART_PRIMITIVES := 32768
var _materials: Dictionary = {} # Material OBJECT keys retain lifetime; no reused instance IDs.
var _work := {"nodes": 0, "buildingVisualPrimitives": 0, "furnitureVisualPrimitives": 0,
	"collisionShapes": 0, "blockingShapes": 0, "nonblockingShapes": 0,
	"collisionPublications": 0, "furniturePublications": 0,
	"materialSnapshots": 0, "materialCacheHits": 0, "jointPrimitiveTests": 0}
var _nonbox_depth := 0

class ColliderPublisher:
	extends "res://scripts/buildings/BuildingPartPublisher.gd"
	# Collision extraction uses the real publish_part path; rendering is measured
	# separately through the unchanged CPU visual publisher collector above.
	func publish_visual(_part, _parent: Node3D) -> void: pass

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var path := OS.get_environment("VOXEL_CHIMNEY_PUBLISHED_REPORT")
	var input := OS.get_environment("VOXEL_CHIMNEY_REVIEWED_BASELINE")
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or not DirAccess.dir_exists_absolute(path.get_base_dir()) or FileAccess.file_exists(path) or FileAccess.get_sha256(input) != REVIEW_SHA:
		quit(2)
		return
	var controls := _collector_controls()
	if not controls.passed or OS.get_environment("VOXEL_CHIMNEY_PUBLISH_COLLECTOR_ONLY") == "1":
		var control_file := FileAccess.open(path, FileAccess.WRITE)
		if control_file == null:
			quit(2)
			return
		control_file.store_string(JSON.stringify(controls, "\t"))
		control_file.close()
		quit(0 if controls.passed else 1)
		return
	# Synthetic negative controls deliberately set stop reasons. None leak into
	# the real diagnostic, and their work is reported separately below.
	_stop_reason = ""
	for key in _counts: _counts[key] = 0
	for key in _work: _work[key] = 0
	_materials.clear()
	var file := FileAccess.open(input, FileAccess.READ)
	var archive: Dictionary = file.get_var(false)
	file.close()
	var before = Shops.copy_source(archive.sourceSnapshot)
	var candidate = Shops.copy_source(archive.sourceSnapshot)
	if candidate.parts.size() > MAX_SOURCE_PARTS or archive.furnitureSnapshot.parts.size() > Chimney.MAX_OBSTACLES:
		quit(2)
		return
	var furniture: Dictionary = Shops.furnishing_obstacles(archive.furnitureSnapshot, archive.protectedReservations)
	var constructed: Array = []
	var blocked: Array = []
	for part in before.parts:
		if part.semantic != "citadel_urban_chimney": continue
		var prefix: String = part.id.trim_suffix("_chimney")
		var gables := [prefix + "_upper_shell_side_-1", prefix + "_upper_shell_side_1"]
		var upstream := [prefix + "_foundation", prefix + "_stone_shell_side_-1", prefix + "_stone_shell_side_1"]
		var proposal: Dictionary = Chimney.apply(candidate, part.id, gables, upstream, furniture.obstacles)
		if proposal.ready:
			constructed.append({"chimneyId": part.id, "bearerId": proposal.partIds[0], "gableIds": gables})
		else:
			blocked.append({"chimneyId": part.id, "reason": proposal.reason})
	var old_publisher = _configured_publisher(before)
	var new_publisher = _configured_publisher(candidate)
	var colliders := ColliderPublisher.new()
	var payloads: Dictionary = {}
	var originals_exact := true
	var spatial_exact := true
	var appearance_exact := true
	var original_comparisons: Array = []
	for part in candidate.parts:
		if not _within_budget(): break
		var visual := _extract_overlap_payload(new_publisher, candidate, part, "candidate")
		var collision := _collision_payload(colliders, part)
		if not _valid_payload(visual) or not _valid_payload(collision):
			_stop_reason = "invalid_building_payload_bounds"
			break
		payloads[part.id] = {"visual": visual, "collision": collision}
		var old = before.find_part(part.id)
		if old != null:
			var old_visual := _extract_overlap_payload(old_publisher, before, old, "original")
			var old_collision := _collision_payload(colliders, old)
			var comparison := _compare_channels({"visual": old_visual, "collision": old_collision}, payloads[part.id])
			comparison["partId"] = part.id
			original_comparisons.append(comparison)
			originals_exact = originals_exact and comparison.exact
			spatial_exact = spatial_exact and comparison.spatialExact
			appearance_exact = appearance_exact and comparison.appearanceExact
	var furnishing = FurnishingPlanScript.new(archive.furnitureSnapshot.id, int(archive.furnitureSnapshot.seed), archive.furnitureSnapshot.sourceBlueprintId)
	for record in archive.furnitureSnapshot.parts: furnishing.add_part(record)
	var furnishing_publisher := Furnisher.new()
	var original_furnishing_publisher := Furnisher.new()
	var furnishing_comparisons: Array = []
	for part in furnishing.parts:
		if not _within_budget(): break
		var published := _furnishing_payload(furnishing_publisher, part)
		var original_published := _furnishing_payload(original_furnishing_publisher, part)
		payloads["furnishing:" + part.id] = published
		var comparison := _compare_channels(original_published, published)
		comparison["partId"] = part.id
		comparison["generatedNodeNameEvidence"] = {"original": original_published.get("generatedNodeNames", []), "candidate": published.get("generatedNodeNames", [])}
		comparison["onlyGeneratedNodeNamesDiffer"] = comparison.exact and var_to_bytes(original_published.get("generatedNodeNames", [])) != var_to_bytes(published.get("generatedNodeNames", []))
		furnishing_comparisons.append(comparison)
		originals_exact = originals_exact and comparison.exact
		spatial_exact = spatial_exact and comparison.spatialExact
		appearance_exact = appearance_exact and comparison.appearanceExact
	var contacts: Array = []
	var joints: Array = []
	var relevant: Dictionary = {}
	var pair_count := 0
	for construction in constructed:
		if not payloads.has(construction.bearerId): continue
		relevant[construction.bearerId] = true
		for counterpart in construction.gableIds + [construction.chimneyId]:
			relevant[counterpart] = true
			for channel in ["visual", "collision"]:
				if not _within_budget(): break
				if not payloads.has(counterpart):
					_stop_reason = "missing_expected_joint_payload"
					break
				joints.append({"bearerId": construction.bearerId, "otherId": counterpart, "channel": channel,
					"seatId": construction.bearerId if counterpart == construction.chimneyId else counterpart,
					"measurement": _joint_measurement(payloads[construction.bearerId][channel], payloads[counterpart][channel], counterpart == construction.chimneyId)})
		for id in payloads:
			if id == construction.bearerId: continue
			if not _within_budget(): break
			for channel in ["visual", "collision"]:
				# Every retained payload was fully checked at extraction. No mutation
				# follows. Avoid rescanning every surrounding primitive on every pair;
				# direct/untrusted helper calls still use _classify_overlap below.
				var result: Dictionary = _classify_validated_overlap(payloads[construction.bearerId][channel], payloads[id][channel])
				pair_count += 1
				_counts.partPairs += 1
				if result.status != "certified_separated" and result.status != "no_collision":
					relevant[id] = true
					contacts.append({"bearerId": construction.bearerId, "otherId": id, "channel": channel, "declaredBearingCounterpart": id == construction.chimneyId or construction.gableIds.has(id), "measurement": result})
	var inventory: Array = []
	var relevant_payloads: Dictionary = {}
	for id in payloads:
		if not _within_budget(): break
		var row := {"partId": id}
		for channel in ["visual", "collision"]:
			var payload: Dictionary = payloads[id][channel]
			row[channel] = {"status": payload.status, "primitiveCount": payload.primitives.size(), "bounds": payload.bounds,
				"digest": _stable_digest(payload), "shapeCount": payload.get("shapes", []).size()}
			if channel == "collision": row[channel]["shapes"] = payload.get("shapes", [])
		inventory.append(row)
		if relevant.has(id): relevant_payloads[id] = payloads[id]
	var complete: bool = _within_budget() and constructed.size() == 11 and joints.size() == 66 and inventory.size() == payloads.size() and original_comparisons.size() == before.parts.size() and furnishing_comparisons.size() == furnishing.parts.size() and payloads.size() == candidate.parts.size() + furnishing.parts.size() and pair_count == constructed.size() * (payloads.size() - 1) * 2
	var report := {"diagnosticCompleted": complete, "passed": false, "status": "contact_review_required" if complete else _stop_reason,
		"collectorControls": controls,
		"constructed": constructed, "blocked": blocked, "originalSpatialVisualAndCollisionPayloadsExact": spatial_exact,
		"originalMaterialAndCustomDataPayloadsExact": appearance_exact, "allOriginalPayloadsExact": originals_exact, "originalComparisons": original_comparisons,
		"furnishingComparisons": furnishing_comparisons,
		"expectedJointCount": 66, "jointMatrix": joints, "payloadInventory": inventory, "relevantPayloads": relevant_payloads,
		"payloadCount": payloads.size(), "pairCount": pair_count, "contacts": contacts, "counts": _counts, "extractionWork": _work,
		"limits": {"softMsec": SOFT_LIMIT_MSEC, "totalPrimitivesIncludingAllChannelsAndReplays": MAX_PUBLISHED_PRIMITIVES,
			"primitiveTestsIncludingJointMatrix": MAX_PRIMITIVE_TESTS, "materialObjects": MAX_MATERIAL_OBJECTS,
			"nodes": MAX_COLLECTED_NODES, "depth": MAX_COLLECT_DEPTH, "partPrimitives": MAX_PART_PRIMITIVES},
		"elapsedMsec": Time.get_ticks_msec() - _started_msec, "immutableInputUnchanged": FileAccess.get_sha256(input) == REVIEW_SHA,
		"evidenceLevel": "actual_CPU_visual_and_collision_publication_diagnostic",
		"doesNotProve": "No automatic contact exemption, triangle test for nonboxes, external texture pixel equivalence, GPU appearance, PhysicsServer contact/actor-mask behavior, physics movement, accessible attic, engineering capacity, or full physical gate. Material parity is stored properties/shader parameters and per-primitive custom data. Collision extraction reports enabled body shapes separately from disabled/layer-zero/Area interaction shapes."}
	file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_overlap_json(report), "\t"))
	file.flush()
	var write_error := file.get_error()
	file.close()
	quit(1 if complete and originals_exact and write_error == OK else 2)

func _collision_payload(publisher, part) -> Dictionary:
	if not _within_budget(): return {"status": "invalid", "primitives": [], "shapes": [], "bounds": []}
	_work.collisionPublications += 1
	var parent := Node3D.new()
	# Real door publication resolves global transforms; keep its documented
	# scene-tree precondition even in this CPU diagnostic, without actors.
	root.add_child(parent)
	publisher.publish_part(part, parent)
	var result := _collect_collision_payload(parent)
	parent.free()
	publisher.published_nodes.clear()
	return result

func _furnishing_payload(publisher, part) -> Dictionary:
	if not _within_budget():
		return {"visual": {"status": "invalid", "primitives": [], "bounds": []}, "collision": {"status": "invalid", "primitives": [], "shapes": [], "bounds": []}}
	_work.furniturePublications += 1
	var parent := Node3D.new()
	publisher.publish_part(part, parent)
	var captured := {"primitives": [], "materialCounts": {}, "boxCount": 0, "nonBoxCount": 0, "errors": []}
	_collect_nonboxes(parent, Transform3D.IDENTITY, "", captured)
	var identities: Dictionary = {}
	var generated_names: Array = []
	_mesh_identities(parent, "", "", [], identities, generated_names, 0)
	for primitive in captured.primitives:
		if not identities.has(primitive.id):
			captured.errors.append("missing_furnishing_mesh_identity:" + str(primitive.id))
			continue
		var identity: Dictionary = identities[primitive.id]
		primitive["id"] = identity.id
		primitive["publisherNodeIdentity"] = identity.nodes
	var result := {"visual": _visual_payload(captured, "furnitureVisualPrimitives"), "collision": _collect_collision_payload(parent), "generatedNodeNames": generated_names}
	if not _valid_payload(result.visual) or not _valid_payload(result.collision): _stop_reason = "invalid_furnishing_payload_bounds"
	parent.free()
	publisher.published_parts.clear()
	return result

func _mesh_identities(parent: Node, raw_prefix: String, index_prefix: String, ancestors: Array, identities: Dictionary, generated_names: Array, depth: int) -> void:
	if depth > MAX_COLLECT_DEPTH:
		_stop_reason = "mesh_identity_depth_limit"
		return
	for index in range(parent.get_child_count()):
		_work.nodes += 1
		if not _within_budget(): return
		var child := parent.get_child(index)
		var raw_name := String(child.name)
		var raw_path := raw_prefix + "/" + raw_name
		var index_path := index_prefix + "/%d" % index
		# Normalize ONLY Godot's generated @Class@integer names. Authored names,
		# sibling order, hierarchy and node classes remain part of exact parity.
		var generated_prefix := "@" + child.get_class() + "@"
		var generated: bool = raw_name.begins_with(generated_prefix) and raw_name.trim_prefix(generated_prefix).is_valid_int()
		var nodes: Array = ancestors.duplicate()
		nodes.append({"index": index, "class": child.get_class(), "name": "<engine-generated>" if generated else raw_name})
		if generated: generated_names.append({"indexPath": index_path, "class": child.get_class(), "rawName": raw_name})
		if child is MeshInstance3D:
			if identities.size() >= MAX_PART_PRIMITIVES:
				_stop_reason = "mesh_identity_part_limit"
				return
			identities["mesh:" + raw_path] = {"id": "mesh:" + index_path, "nodes": nodes}
		_mesh_identities(child, raw_path, index_path, nodes, identities, generated_names, depth + 1)

func _visual_projections(payload: Dictionary) -> Dictionary:
	var spatial := {"status": payload.status, "bounds": payload.bounds, "primitives": [], "sourceVisualFalse": payload.get("sourceVisualFalse", false)}
	var appearance := {"status": payload.status, "primitives": []}
	for primitive in payload.primitives:
		var geometry: Dictionary = primitive.duplicate()
		for key in ["materialDigests", "customData", "castShadow"]: geometry.erase(key)
		spatial.primitives.append(geometry)
		appearance.primitives.append({"id": primitive.id, "publisherNodeIdentity": primitive.get("publisherNodeIdentity", []),
			"materialDigests": primitive.get("materialDigests", []), "customData": primitive.get("customData"), "castShadow": primitive.get("castShadow")})
	return {"spatial": spatial, "appearance": appearance}

func _compare_channels(original: Dictionary, candidate: Dictionary) -> Dictionary:
	var old := _visual_projections(original.visual)
	var current := _visual_projections(candidate.visual)
	var visual_valid: bool = _valid_payload(original.visual) and _valid_payload(candidate.visual)
	var collision_valid: bool = _valid_payload(original.collision) and _valid_payload(candidate.collision)
	var visual_spatial: bool = visual_valid and var_to_bytes(old.spatial) == var_to_bytes(current.spatial)
	var collision_exact: bool = collision_valid and var_to_bytes(original.collision) == var_to_bytes(candidate.collision)
	var appearance: bool = visual_valid and var_to_bytes(old.appearance) == var_to_bytes(current.appearance)
	var details: Array = []
	for index in range(mini(original.visual.primitives.size(), candidate.visual.primitives.size())):
		if visual_spatial and appearance: break
		if details.size() >= 8: break
		var before_primitive: Dictionary = original.visual.primitives[index]
		var after_primitive: Dictionary = candidate.visual.primitives[index]
		var changed: Array = []
		var keys: Array = before_primitive.keys()
		for key in after_primitive:
			if not keys.has(key): keys.append(key)
		for key in keys:
			if before_primitive.has(key) != after_primitive.has(key) or var_to_bytes(before_primitive.get(key)) != var_to_bytes(after_primitive.get(key)): changed.append(key)
		if not changed.is_empty():
			var old_values: Dictionary = {}
			var new_values: Dictionary = {}
			for key in changed:
				old_values[key] = before_primitive.get(key)
				new_values[key] = after_primitive.get(key)
			details.append({"index": index, "originalId": before_primitive.id, "candidateId": after_primitive.id, "changedFields": changed, "originalValues": old_values, "candidateValues": new_values})
	return {"exact": visual_spatial and collision_exact and appearance, "spatialExact": visual_spatial and collision_exact,
		"visualSpatialExact": visual_spatial, "collisionExact": collision_exact, "appearanceExact": appearance,
		"originalVisualSpatialDigest": _stable_digest(old.spatial), "candidateVisualSpatialDigest": _stable_digest(current.spatial),
		"originalAppearanceDigest": _stable_digest(old.appearance), "candidateAppearanceDigest": _stable_digest(current.appearance),
		"originalCollisionDigest": _stable_digest(original.collision), "candidateCollisionDigest": _stable_digest(candidate.collision),
		"originalPrimitiveCount": original.visual.primitives.size(), "candidatePrimitiveCount": candidate.visual.primitives.size(),
		"firstVisualMismatches": details}

func _valid_payload(payload: Dictionary) -> bool:
	if not payload.get("primitives") is Array or not payload.get("bounds") is Array: return false
	if payload.primitives.size() > MAX_PART_PRIMITIVES: return false
	var ids: Dictionary = {}
	for primitive in payload.primitives:
		if not _valid_primitive(primitive) or ids.has(primitive.id): return false
		ids[primitive.id] = true
		if not _contains_intervals(payload.bounds, primitive.bounds): return false
	var shape_ids: Dictionary = {}
	var blocking_ids: Array = []
	if not payload.get("shapes", []) is Array: return false
	if payload.get("shapes", []).size() > MAX_PART_PRIMITIVES: return false
	for shape in payload.get("shapes", []):
		if not _valid_primitive(shape) or shape_ids.has(shape.id) or not shape.get("state") is Dictionary: return false
		shape_ids[shape.id] = true
		if not shape.state.get("blocking") is bool: return false
		if shape.state.blocking:
			blocking_ids.append(shape.id)
			if not ids.has(shape.id): return false
	if payload.has("shapes") and blocking_ids.size() != ids.size(): return false
	if payload.get("status") == "no_collision": return payload.primitives.is_empty() and payload.bounds.is_empty()
	return payload.get("status") == "published" and _valid_intervals(payload.bounds) and not payload.primitives.is_empty()

func _valid_intervals(bounds: Variant) -> bool:
	if not bounds is Array or bounds.size() != 6: return false
	for value in bounds:
		if not (value is float or value is int) or not is_finite(float(value)): return false
	for axis in range(3):
		if bounds[axis] >= bounds[axis + 3]: return false
	return true

func _contains_intervals(outer: Variant, inner: Variant) -> bool:
	if not _valid_intervals(outer) or not _valid_intervals(inner): return false
	for axis in range(3):
		if outer[axis] > inner[axis] or outer[axis + 3] < inner[axis + 3]: return false
	return true

func _valid_primitive(primitive: Variant) -> bool:
	if not primitive is Dictionary or not primitive.get("id") is String or primitive.id.is_empty() or not primitive.get("transform") is Transform3D: return false
	if primitive.get("type") not in ["box", "mesh"] or not _valid_box(primitive.transform) or not _valid_intervals(primitive.get("bounds")): return false
	var local := AABB(Vector3.ONE * -0.5, Vector3.ONE)
	if primitive.type == "mesh":
		if not primitive.get("localMeshBounds") is AABB: return false
		local = primitive.localMeshBounds
		if not local.position.is_finite() or not local.size.is_finite() or local.size == Vector3.ZERO or local.size.x < 0 or local.size.y < 0 or local.size.z < 0: return false
	return _contains_intervals(primitive.bounds, _payload_intervals(primitive.transform, local))

func _material_digest(material: Variant) -> String:
	if material == null: return _stable_digest(null)
	if not material is Material:
		_stop_reason = "invalid_material_resource"
		return "invalid"
	if _materials.has(material):
		_work.materialCacheHits += 1
		return _materials[material]
	if _materials.size() >= MAX_MATERIAL_OBJECTS or not _within_budget():
		_stop_reason = "material_snapshot_budget_exceeded"
		return "invalid"
	# Same real resource snapshot as the rigid-payload contract. Retained object
	# keys prevent recycled instance IDs from returning another material's hash.
	var digest := _stable_digest(_remove_resource_ids(_value_snapshot(material, {})))
	_materials[material] = digest
	_work.materialSnapshots += 1
	return digest

func _extract_overlap_payload(publisher, blueprint, part, phase: String) -> Dictionary:
	_counts.publishedParts += 1
	if not _within_budget(): return {"status": "invalid", "primitives": [], "bounds": []}
	if not bool(part.recipe.get("visual", true)):
		_counts.sourceHiddenParts += 1
		return {"status": "no_collision", "primitives": [], "bounds": [], "sourceVisualFalse": true}
	var captured: Dictionary = _complete_payload(publisher, blueprint, part)
	var result := _visual_payload(captured, "buildingVisualPrimitives")
	_inventory.append({"phase": phase, "partId": part.id, "primitiveCount": result.primitives.size(), "errors": captured.errors})
	# Publication retains nodes for normal finish/cleanup. This diagnostic frees
	# each temporary parent immediately; do not accumulate dangling node entries.
	publisher.published_nodes.clear()
	return result

func _visual_payload(captured: Dictionary, counter: String) -> Dictionary:
	var result := {"status": "published", "primitives": [], "bounds": []}
	if not captured.errors.is_empty() or captured.primitives.is_empty() or captured.primitives.size() > MAX_PART_PRIMITIVES:
		_stop_reason = "incomplete_or_excessive_visual_payload"
		result.status = "invalid"
		return result
	for primitive in captured.primitives:
		_counts.publishedPrimitives += 1
		_work[counter] += 1
		if not _within_budget():
			result.status = "invalid"
			return result
		var local: AABB = AABB(Vector3.ONE * -0.5, Vector3.ONE) if primitive.type == "box" else primitive.meshBounds
		var row := {"id": primitive.id, "type": primitive.type, "transform": primitive.transform,
			"localMeshBounds": local, "bounds": _payload_intervals(primitive.transform, local),
			"materialDigests": primitive.get("materialDigests", []), "customData": primitive.get("customData"),
			"meshDigest": primitive.get("meshDigest", ""), "meshClass": primitive.get("meshClass", "BoxMesh"),
			"castShadow": primitive.get("castShadow", null)}
		if primitive.has("publisherNodeIdentity"): row["publisherNodeIdentity"] = primitive.publisherNodeIdentity
		if not _valid_primitive(row) or not primitive.has("materialDigests") or not primitive.has("customData"):
			_stop_reason = "invalid_visual_primitive_or_missing_parity_data"
			result.status = "invalid"
			return result
		result.primitives.append(row)
		result.bounds = _union_intervals(result.bounds, row.bounds)
	if not _valid_payload(result):
		_stop_reason = "invalid_visual_payload"
		result.status = "invalid"
	return result

func _collect_nonboxes(parent: Node, accumulated: Transform3D, prefix: String, result: Dictionary) -> void:
	_nonbox_depth += 1
	_work.nodes += parent.get_child_count()
	if _nonbox_depth > MAX_COLLECT_DEPTH or not _within_budget() or result.primitives.size() > MAX_PART_PRIMITIVES:
		_stop_reason = "visual_collection_budget_exceeded"
		result.errors.append(_stop_reason)
		_nonbox_depth -= 1
		return
	super._collect_nonboxes(parent, accumulated, prefix, result)
	# The parent overlap collector captures CPU mesh-batch transforms but omits
	# material/custom data. Recover those exact input values for its matched node.
	if _active_mesh_capture != null:
		for child in parent.get_children():
			if not child is MultiMeshInstance3D: continue
			var capture: Dictionary = _active_mesh_capture.captured_mesh_batches.get(child.get_instance_id(), {})
			if capture.is_empty(): continue # Parent already reports the missing capture.
			var custom: Array = capture.customDataOverride
			# Match the publisher's actual fallback for any nonmatching length.
			if custom.size() != capture.transforms.size(): custom = _active_mesh_capture.build_batch_custom_data(capture.transforms)
			if custom.size() != capture.transforms.size():
				result.errors.append("mesh_batch_custom_data_count_mismatch")
				continue
			var id_prefix := "cpu_multimesh:" + prefix + "/" + String(child.name) + ":"
			var digest := _material_digest(capture.material)
			for primitive in result.primitives:
				if not String(primitive.id).begins_with(id_prefix): continue
				var index := int(String(primitive.id).trim_prefix(id_prefix))
				if index < 0 or index >= custom.size():
					result.errors.append("mesh_batch_custom_data_index_invalid")
					continue
				primitive["materialDigests"] = [digest]
				primitive["customData"] = custom[index]
				primitive["castShadow"] = child.cast_shadow
	if result.primitives.size() > MAX_PART_PRIMITIVES:
		_stop_reason = "part_visual_primitive_limit"
		result.errors.append(_stop_reason)
	_nonbox_depth -= 1

func _within_budget() -> bool:
	if _work.nodes > MAX_COLLECTED_NODES:
		_stop_reason = "collector_node_limit_exceeded"
	return super._within_budget()

func _classify_overlap(a: Dictionary, b: Dictionary) -> Dictionary:
	if not _valid_payload(a) or not _valid_payload(b):
		_stop_reason = "invalid_payload_before_comparison"
		return {"status": "invalid_payload", "candidates": []}
	return super._classify_overlap(a, b)

func _classify_validated_overlap(a: Dictionary, b: Dictionary) -> Dictionary:
	# Diagnostic batch-only entry: caller has validated complete immutable
	# payloads during extraction. Untrusted/direct calls use _classify_overlap.
	return super._classify_overlap(a, b)

func _separation(first: Transform3D, second: Transform3D) -> float:
	if not _valid_box(first) or not _valid_box(second):
		_stop_reason = "invalid_box_before_sat"
		return INF
	var result := super._separation(first, second)
	if not is_finite(result): _stop_reason = "nonfinite_sat_result"
	return result

func _joint_measurement(bearer: Dictionary, counterpart: Dictionary, counterpart_above: bool) -> Dictionary:
	var classification := _classify_overlap(bearer, counterpart)
	var closest: Variant = null
	var closest_pair: Dictionary = {}
	var nonbox_pairs := 0
	for a in bearer.primitives:
		for b in counterpart.primitives:
			_counts.primitiveTests += 1
			_work.jointPrimitiveTests += 1
			if not _within_budget(): return {"status": "incomplete"}
			if a.type != "box" or b.type != "box":
				nonbox_pairs += 1
				continue
			_counts.satTests += 1
			var gap := _separation(a.transform, b.transform)
			if not is_finite(gap):
				_stop_reason = "invalid_joint_sat_result"
				return {"status": "invalid"}
			# Minimum greatest-axis SAT gap: positive separation; negative overlap.
			# Stable source traversal is the deterministic tie preference.
			if closest == null or gap < float(closest):
				closest = gap
				closest_pair = {"bearerPrimitiveId": a.id, "otherPrimitiveId": b.id,
					"axisAlignedWorldVerticalSeatGap": _vertical_seat_gap(a, b, counterpart_above)}
	var all_axis_aligned: bool = not bearer.primitives.is_empty() and not counterpart.primitives.is_empty()
	for primitive in bearer.primitives + counterpart.primitives:
		all_axis_aligned = all_axis_aligned and primitive.type == "box" and _axis_aligned(primitive.transform)
	var envelope_gap: Variant = null
	if all_axis_aligned:
		var lower: Dictionary = bearer if counterpart_above else counterpart
		var upper: Dictionary = counterpart if counterpart_above else bearer
		var top := -INF
		var bottom := INF
		for primitive in lower.primitives: top = maxf(top, _box_vertical(primitive.transform)[1])
		for primitive in upper.primitives: bottom = minf(bottom, _box_vertical(primitive.transform)[0])
		envelope_gap = bottom - top
	return {"status": classification.status, "overlapMeasurement": classification,
		"closestSignedSatGap": closest, "closestPair": closest_pair, "nonboxPairCount": nonbox_pairs,
		"axisAlignedWorldVerticalSeatGap": envelope_gap,
		"gapConvention": "upper bottom minus lower top; positive is a gap. Raw represented transforms, no rounding guard or contact tolerance subtracted.",
		"notAutomaticallyAccepted": true}

func _axis_aligned(transform: Transform3D) -> bool:
	# Exact signed/permuted cardinal axes only. Do not snap quarter-turn residue.
	var rows: Dictionary = {}
	for axis in range(3):
		var row := -1
		for component in range(3):
			if transform.basis[axis][component] != 0.0:
				if row != -1: return false
				row = component
		if row == -1 or rows.has(row): return false
		rows[row] = true
	return true

func _box_vertical(transform: Transform3D) -> Array:
	var half := (absf(float(transform.basis.x.y)) + absf(float(transform.basis.y.y)) + absf(float(transform.basis.z.y))) * 0.5
	return [float(transform.origin.y) - half, float(transform.origin.y) + half]

func _vertical_seat_gap(a: Dictionary, b: Dictionary, counterpart_above: bool) -> Variant:
	if not _axis_aligned(a.transform) or not _axis_aligned(b.transform): return null
	var av := _box_vertical(a.transform)
	var bv := _box_vertical(b.transform)
	return float(bv[0]) - float(av[1]) if counterpart_above else float(av[0]) - float(bv[1])

func _collector_controls() -> Dictionary:
	var b = Blueprint.new("collision_collector_unit", 1, "timber")
	var part = b.add_part({"id": "box", "kind": "beam", "position": Vector3(3, 4, 5), "size": Vector3(2, 3, 4), "collision": true})
	var publisher := ColliderPublisher.new()
	var payload := _collision_payload(publisher, part)
	var expected := Transform3D(Basis.from_scale(part.size), part.position)
	var checks := {"one_box_valid_bounds": _valid_payload(payload) and payload.primitives.size() == 1,
		"actual_collider_pose_exact": payload.primitives.size() == 1 and payload.primitives[0].transform == expected}
	checks["repeat_exact"] = var_to_bytes(payload) == var_to_bytes(_collision_payload(publisher, part))
	part.collision_enabled = false
	var empty := _collision_payload(publisher, part)
	checks["no_collision_is_valid_empty"] = _valid_payload(empty) and empty.status == "no_collision"
	checks["empty_collision_pair_skipped"] = _classify_overlap(payload, empty).status == "no_collision"
	var door = b.add_part({"id": "door", "kind": "door", "position": Vector3(4, 2, 3), "size": Vector3(1, 2, 0.2), "collision": true})
	var door_payload := _collision_payload(publisher, door)
	checks["actual_door_tree_precondition_and_payload"] = _valid_payload(door_payload) and door_payload.primitives.size() == 1 and door_payload.shapes.size() == 2
	checks["door_proxy_distinct_role_and_id"] = door_payload.shapes.size() == 2 and door_payload.shapes[0].id != door_payload.shapes[1].id and door_payload.shapes[0].state.role == "blocking_part" and door_payload.shapes[1].state.role == "door_interaction_proxy" and not door_payload.shapes[1].state.blocking and door_payload.shapes[1].state.collisionLayer == (1 << 10)
	checks["malformed_bounds_rejected"] = not _valid_payload({"status": "published", "bounds": [], "primitives": [{"bounds": []}]})
	for mode in ["nan_bounds", "infinite_bounds", "reversed_bounds", "zero_bounds", "shrunk_aggregate", "shrunk_primitive", "nan_transform", "degenerate_transform", "unsupported_type", "missing_mesh_bounds", "duplicate_id"]:
		var malformed: Dictionary = payload.duplicate(true)
		match mode:
			"nan_bounds": malformed.bounds[0] = NAN
			"infinite_bounds": malformed.bounds[3] = INF
			"reversed_bounds": malformed.bounds[0] = malformed.bounds[3] + 1
			"zero_bounds": malformed.bounds[0] = malformed.bounds[3]
			"shrunk_aggregate": malformed.bounds[0] += 0.1
			"shrunk_primitive": malformed.primitives[0].bounds[0] += 0.1
			"nan_transform": malformed.primitives[0].transform.origin.x = NAN
			"degenerate_transform": malformed.primitives[0].transform.basis.x = Vector3.ZERO
			"unsupported_type": malformed.primitives[0].type = "sphere"
			"missing_mesh_bounds": malformed.primitives[0].type = "mesh"
			"duplicate_id": malformed.primitives.append(malformed.primitives[0].duplicate(true))
		checks[mode + "_rejected"] = not _valid_payload(malformed)
	var shape_parent := Node3D.new()
	var body := StaticBody3D.new()
	shape_parent.add_child(body)
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	shape.disabled = true
	var disabled := _collect_collision_payload(shape_parent)
	checks["disabled_retained_not_blocking"] = _valid_payload(disabled) and disabled.status == "no_collision" and disabled.shapes.size() == 1 and disabled.shapes[0].state.disabled
	shape.disabled = false
	body.collision_layer = 0
	var layer_zero := _collect_collision_payload(shape_parent)
	checks["layer_zero_retained_not_blocking"] = _valid_payload(layer_zero) and layer_zero.status == "no_collision" and layer_zero.shapes.size() == 1
	body.collision_layer = 1
	shape.shape = SphereShape3D.new()
	var unsupported := _collect_collision_payload(shape_parent)
	checks["nonbox_collider_fails_closed"] = not _valid_payload(unsupported) and _stop_reason == "unsupported_collision_shape_or_owner"
	_stop_reason = ""
	shape.shape = BoxShape3D.new()
	var nan_pose := Transform3D.IDENTITY
	nan_pose.origin.x = NAN
	var invalid_pose := _collect_collision_payload(shape_parent, nan_pose)
	checks["nonfinite_collider_node_fails_closed"] = not _valid_payload(invalid_pose) and _stop_reason == "invalid_collision_node_transform"
	_stop_reason = ""
	shape_parent.free()
	var other: Dictionary = payload.duplicate(true)
	other.erase("shapes")
	other.primitives[0].transform.origin.y += 3.000001
	other.primitives[0].bounds = _payload_intervals(other.primitives[0].transform, AABB(Vector3.ONE * -0.5, Vector3.ONE))
	other.bounds = other.primitives[0].bounds.duplicate()
	var positive_gap := _joint_measurement(payload, other, true)
	checks["separated_joint_still_measured"] = positive_gap.status == "certified_separated" and float(positive_gap.closestSignedSatGap) > 0 and float(positive_gap.axisAlignedWorldVerticalSeatGap) > 0 and not positive_gap.closestPair.is_empty()
	var material := StandardMaterial3D.new()
	var identical := StandardMaterial3D.new()
	var distinct := StandardMaterial3D.new()
	distinct.albedo_color = Color(0.1, 0.3, 0.7, 1.0)
	var digest := _material_digest(material)
	checks["retained_material_cache_repeat"] = digest == _material_digest(material) and _materials.has(material)
	checks["resource_ids_removed_not_material_properties"] = digest == _material_digest(identical) and digest != _material_digest(distinct)
	var captured := {"errors": [], "primitives": [{"id": "unit", "type": "box", "transform": Transform3D.IDENTITY, "materialDigests": [digest], "customData": Color(0.2, 0.3, 0.4, 1.0)}]}
	var custom_before := _visual_payload(captured, "buildingVisualPrimitives")
	captured.primitives[0].customData = Color(0.2, 0.3, 0.5, 1.0)
	var custom_after := _visual_payload(captured, "buildingVisualPrimitives")
	checks["custom_data_change_retained_in_parity"] = _valid_payload(custom_before) and _valid_payload(custom_after) and var_to_bytes(custom_before) != var_to_bytes(custom_after)
	var custom_split := _compare_channels({"visual": custom_before, "collision": empty}, {"visual": custom_after, "collision": empty})
	checks["custom_change_does_not_falsify_spatial_parity"] = custom_split.spatialExact and not custom_split.appearanceExact and not custom_split.exact
	var plant_plan := FurnishingPlanScript.new("plant_identity_control", 13, "synthetic")
	var plant = plant_plan.add_part({"id": "plant", "archetype": "pot_plant", "material": "ceramic_glaze", "position": Vector3(2, 3, 4), "occupiedSize": Vector3(0.5, 0.8, 0.5), "collision": false})
	var plant_a := _furnishing_payload(Furnisher.new(), plant)
	var plant_b := _furnishing_payload(Furnisher.new(), plant)
	var plant_comparison := _compare_channels(plant_a, plant_b)
	checks["actual_plant_duplicate_names_normalized_only"] = plant_comparison.exact and plant_a.generatedNodeNames.size() == 2 and plant_b.generatedNodeNames.size() == 2 and var_to_bytes(plant_a.generatedNodeNames) != var_to_bytes(plant_b.generatedNodeNames)
	var changed_material: Dictionary = plant_b.duplicate(true)
	changed_material.visual.primitives[0].materialDigests = [_material_digest(distinct)]
	var material_comparison := _compare_channels(plant_a, changed_material)
	checks["normalized_identity_retains_real_material_changes"] = material_comparison.spatialExact and not material_comparison.appearanceExact and not material_comparison.exact
	var changed_pose: Dictionary = plant_b.duplicate(true)
	changed_pose.visual.primitives[0].transform.origin.x += 0.125
	changed_pose.visual.primitives[0].bounds = _payload_intervals(changed_pose.visual.primitives[0].transform, changed_pose.visual.primitives[0].localMeshBounds)
	changed_pose.visual.bounds = []
	for primitive in changed_pose.visual.primitives: changed_pose.visual.bounds = _union_intervals(changed_pose.visual.bounds, primitive.bounds)
	var pose_comparison := _compare_channels(plant_a, changed_pose)
	checks["normalized_identity_retains_real_spatial_changes"] = not pose_comparison.spatialExact and pose_comparison.appearanceExact and not pose_comparison.exact
	var changed_name: Dictionary = plant_b.duplicate(true)
	changed_name.visual.primitives[0].publisherNodeIdentity[-1].name = "DifferentAuthoredPot"
	checks["authored_node_names_not_discarded"] = not _compare_channels(plant_a, changed_name).exact
	checks["controls_leave_no_unexpected_stop"] = _stop_reason.is_empty()
	return {"passed": checks.values().all(func(value): return value), "checks": checks, "work": _work.duplicate(true), "counts": _counts.duplicate(true), "evidenceLevel": "synthetic_collision_collector_unit_only"}

func _collect_collision_payload(parent: Node3D, pose := Transform3D.IDENTITY) -> Dictionary:
	var result := {"status": "no_collision", "primitives": [], "shapes": [], "bounds": []}
	_collect_shapes(parent, pose, "", {}, 0, result)
	if not _stop_reason.is_empty(): result.status = "invalid"
	elif not result.primitives.is_empty(): result.status = "published"
	return result

func _collect_shapes(parent: Node, pose: Transform3D, path: String, owner: Dictionary, depth: int, result: Dictionary) -> void:
	if depth > MAX_COLLECT_DEPTH:
		_stop_reason = "collision_tree_depth_limit"
		return
	for index in range(parent.get_child_count()):
		if not _within_budget(): return
		_work.nodes += 1
		var child := parent.get_child(index)
		# Sibling index paths remain unique without engine-generated node names.
		var child_path := path + "/%d" % index
		var transform := pose
		if child is Node3D:
			if child.top_level:
				_stop_reason = "unsupported_top_level_collision_transform"
				return
			transform = pose * child.transform
		if not _valid_box(transform):
			_stop_reason = "invalid_collision_node_transform"
			return
		var current_owner := owner
		if child is CollisionObject3D:
			current_owner = {"path": child_path, "class": child.get_class(), "physicsBody": child is PhysicsBody3D,
				"collisionLayer": child.collision_layer, "collisionMask": child.collision_mask,
				"partId": str(child.get_meta("building_part_id", child.get_meta("furnishing_part_id", ""))),
				"semantic": str(child.get_meta("building_semantic", child.get_meta("furnishing_semantic", ""))),
				"role": str(child.get_meta("building_collision_role", ""))}
		if child is CollisionShape3D:
			_work.collisionShapes += 1
			_counts.publishedPrimitives += 1
			if not _within_budget(): return
			if result.shapes.size() >= MAX_PART_PRIMITIVES:
				_stop_reason = "part_collision_primitive_limit"
				return
			if not child.shape is BoxShape3D or current_owner.is_empty():
				_stop_reason = "unsupported_collision_shape_or_owner"
				return
			var size: Vector3 = child.shape.size
			if not size.is_finite() or size.x <= 0 or size.y <= 0 or size.z <= 0 or not is_finite(child.shape.margin):
				_stop_reason = "invalid_collision_shape_resource"
				return
			var box := transform * Transform3D(Basis.from_scale(size), Vector3.ZERO)
			var state: Dictionary = current_owner.duplicate(true)
			state["disabled"] = child.disabled
			state["role"] = str(child.get_meta("building_collision_role", current_owner.role))
			state["partId"] = str(child.get_meta("building_part_id", current_owner.partId))
			state["blocking"] = bool(current_owner.physicsBody) and not child.disabled and int(current_owner.collisionLayer) != 0
			var primitive := {"id": "collision:" + child_path, "type": "box", "transform": box,
				"bounds": _payload_intervals(box, AABB(Vector3.ONE * -0.5, Vector3.ONE)), "state": state,
				"shapeResource": {"class": child.shape.get_class(), "size": size, "margin": child.shape.margin}}
			if not _valid_primitive(primitive):
				_stop_reason = "invalid_collision_primitive"
				return
			result.shapes.append(primitive)
			if state.blocking:
				_work.blockingShapes += 1
				result.primitives.append(primitive)
				result.bounds = _union_intervals(result.bounds, primitive.bounds)
			else: _work.nonblockingShapes += 1
		_collect_shapes(child, transform, child_path, current_owner, depth + 1, result)
