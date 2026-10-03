extends RefCounted
class_name GeneratedStructureVisualManifest

## Reads only completed production structure regions and receipts the actual
## generated block meshes. Physical readiness remains owned by StructureSystem.
const MAX_BLOCKS := 100000

## A bounded submission keeps only value descriptions and weak scene owners.
## The static submit above remains the direct oracle for this protocol.
var _bounded: Dictionary = {}
var _diagnostic_call_usec: Dictionary = {}
static var _bounded_diagnostics: Dictionary = {}


static func reset_bounded_diagnostics() -> void:
	_bounded_diagnostics.clear()


static func bounded_diagnostics() -> Dictionary:
	return _bounded_diagnostics.duplicate(true)


static func _record_bounded_event(event: String) -> void:
	var events: Dictionary = _bounded_diagnostics.get("events", {})
	events[event] = int(events.get(event, 0)) + 1
	_bounded_diagnostics.events = events


static func _record_bounded_stage(stage: String, elapsed_usec: int) -> void:
	var stages: Dictionary = _bounded_diagnostics.get("stages", {})
	var row: Dictionary = stages.get(stage, {"calls": 0, "totalUsec": 0,
		"maxUsec": 0, "samplesUsec": [], "samplesDropped": 0})
	row.calls = int(row.calls) + 1
	row.totalUsec = int(row.totalUsec) + maxi(0, elapsed_usec)
	row.maxUsec = maxi(int(row.maxUsec), elapsed_usec)
	var samples: Array = row.samplesUsec
	if samples.size() < 256: samples.append(maxi(0, elapsed_usec))
	else: row.samplesDropped = int(row.samplesDropped) + 1
	stages[stage] = row
	_bounded_diagnostics.stages = stages


func _diagnostic_add(stage: String, elapsed_usec: int) -> void:
	_diagnostic_call_usec[stage] = int(_diagnostic_call_usec.get(stage, 0)) \
		+ maxi(0, elapsed_usec)


static func submit(main: Object, structure_system: Object, readiness: Object,
		request_id: int, view_revision: int, bounds: Rect2i,
		near_bounds: Rect2i, require_physical: bool = true,
		global_near_bounds: Rect2i = Rect2i()) -> Dictionary:
	if not is_instance_valid(main) or not is_instance_valid(structure_system) \
			or not is_instance_valid(readiness) \
			or not structure_system.has_method("region_publication_readiness") \
			or not structure_system.has_method("region_dependency_requirements") \
			or not structure_system.has_method("region_dependency_revision") \
			or not structure_system.has_method("region_dependency_scheduling_revision") \
			or not structure_system.has_method("region_citadel_visual_source") \
			or not structure_system.has_method("region_ordinary_visual_source") \
			or not readiness.has_method("expect_source") \
			or not readiness.has_method("describe_candidate") \
			or not readiness.has_method("has_candidate") \
			or not readiness.has_method("candidate_in_view") \
			or not readiness.has_method("accept_receipt") \
			or not readiness.has_method("accept_publisher_receipt") \
			or not readiness.has_method("finish_source"):
		return {"status": "failed", "reason": "generated_structure_visual_owner_missing"}
	if bounds.size.x <= 0 or bounds.size.y <= 0 or near_bounds.size.x <= 0 \
			or near_bounds.size.y <= 0 or not bounds.encloses(near_bounds):
		return {"status": "failed", "reason": "invalid_generated_structure_visual_bounds"}
	# A chunk source may straddle the near/horizon boundary. The source-local
	# rectangle proves coverage; this optional view rectangle selects the tier
	# without claiming physical readiness for the horizon.
	var tier_near_bounds := global_near_bounds if global_near_bounds.has_area() else near_bounds
	var source_method := "region_publication_readiness" if require_physical else "region_dependency_requirements"
	var required_status := "ready" if require_physical else "described"
	var phase_usec := {}
	var phase_started := Time.get_ticks_usec()
	var source_state: Dictionary = structure_system.call(source_method, bounds)
	phase_usec["sourceDescription"] = Time.get_ticks_usec() - phase_started
	if source_state.get("status") != required_status:
		return {"status": String(source_state.get("status", "pending")),
			"reason": String(source_state.get("reason", "structure_source_description_pending")),
			"sourceDescription": source_state,
			"physicalPublication": source_state if require_physical else {}}
	# Horizon visual identity follows source membership, not live physical/nav
	# proof counters. The Citadel scene owner is fenced separately below.
	var dependency_method := "region_dependency_revision" if require_physical \
		else "region_dependency_scheduling_revision"
	phase_started = Time.get_ticks_usec()
	var dependency_revision := JSON.stringify(structure_system.call(dependency_method, bounds))
	phase_usec["dependencyRevision"] = Time.get_ticks_usec() - phase_started
	phase_started = Time.get_ticks_usec()
	var citadel_source: Dictionary = structure_system.call("region_citadel_visual_source", bounds)
	phase_usec["citadelDescription"] = Time.get_ticks_usec() - phase_started
	if citadel_source.get("status") != "described" or not citadel_source.get("descriptionComplete",false):
		return {"status":String(citadel_source.get("status","pending")),
			"reason":String(citadel_source.get("reason","citadel_visual_description_pending")),
			"citadelSource":citadel_source}
	phase_started = Time.get_ticks_usec()
	var ordinary_source: Dictionary = structure_system.call("region_ordinary_visual_source", bounds)
	phase_usec["ordinaryDescription"] = Time.get_ticks_usec() - phase_started
	if ordinary_source.get("status") != "described":
		return {"status":String(ordinary_source.get("status","pending")),
			"reason":String(ordinary_source.get("reason","ordinary_visual_description_pending")),
			"ordinarySource":ordinary_source}
	var ordinary_revision_value: Variant = structure_system.get("ordinary_visual_revision")
	var ordinary_producer_revision := int(ordinary_revision_value) \
		if ordinary_revision_value is int else -1
	var ordinary_values: Array = ordinary_source.get("candidates",[])
	if ordinary_values.size() > MAX_BLOCKS:
		return {"status": "pending", "reason": "generated_structure_visual_capacity", "retryable": true}
	var candidates: Array[Dictionary] = []
	var candidate_ids: Array[String] = []
	var candidates_by_id := {}
	phase_started = Time.get_ticks_usec()
	for ordinary_value in ordinary_values:
		if not ordinary_value is Dictionary:
			return {"status": "failed", "reason": "generated_structure_block_record_invalid"}
		var ordinary: Dictionary = ordinary_value
		var body := ordinary.get("owner") as Node3D
		var cell_value_meta: Variant = ordinary.get("cell")
		if not cell_value_meta is Vector3i:
			return {"status": "failed", "reason": "generated_structure_block_cell_missing"}
		var cell: Vector3i = cell_value_meta
		var position_xz: Vector2 = ordinary.get("positionXZ", Vector2.INF)
		var candidate_id := String(ordinary.get("candidateId",""))
		if candidate_id.is_empty() or candidates_by_id.has(candidate_id) \
				or position_xz == Vector2.INF:
			return {"status":"failed","reason":"ordinary_visual_candidate_identity_invalid"}
		if not bounds.has_point(Vector2i(cell.x, cell.z)):
			return {"status": "failed", "reason": "generated_structure_block_outside_region"}
		if is_instance_valid(body) and (not body.is_inside_tree() or body.is_queued_for_deletion() \
				or not bool(body.get_meta("generated",false)) or bool(body.get_meta("player_placed",false))):
			return {"status":"failed","reason":"generated_structure_block_owner_mismatch"}
		# Bounds are a broad-phase rectangle. Only cells whose centers are in
		# the configured circular view are obligations for this visual demand.
		if not bool(readiness.call("candidate_in_view", position_xz)):
			continue
		var representation := ordinary.get("representation") as Node3D
		candidate_ids.append(candidate_id)
		var candidate := {"candidateId": candidate_id, "positionXZ": position_xz,
			"owner": body, "representation": representation, "cell": cell}
		candidates.append(candidate)
		candidates_by_id[candidate_id] = candidate
	for citadel_value in citadel_source.get("candidates",[]):
		if not citadel_value is Dictionary:
			return {"status":"failed","reason":"citadel_visual_candidate_invalid"}
		if candidates.size() >= MAX_BLOCKS:
			return {"status":"pending","reason":"generated_structure_visual_capacity","retryable":true}
		var citadel: Dictionary = citadel_value
		var citadel_id := String(citadel.get("candidateId",""))
		if citadel_id.is_empty() or candidates_by_id.has(citadel_id) \
				or not citadel.get("positionXZ") is Vector2 \
				or not citadel.get("binding") is Dictionary:
			return {"status":"failed","reason":"citadel_visual_candidate_identity_invalid"}
		var position_xz: Vector2 = citadel.positionXZ
		if not bool(readiness.call("candidate_in_view",position_xz)):
			continue
		candidate_ids.append(citadel_id)
		var candidate := {"candidateId":citadel_id,"positionXZ":position_xz,
			"publisher":citadel.get("publisher"),"memberId":String(citadel.get("memberId","")),
			"binding":citadel.binding,"sourceSignature":String(citadel.get("sourceSignature",""))}
		candidates.append(candidate)
		candidates_by_id[citadel_id] = candidate
	candidate_ids.sort()
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	_update_hasher(hasher, dependency_revision)
	_update_hasher(hasher, String(citadel_source.get("sourceRevision","")))
	_update_hasher(hasher, String(ordinary_source.get("sourceRevision","")))
	for candidate_id: String in candidate_ids:
		var candidate: Dictionary = candidates_by_id[candidate_id]
		_update_hasher(hasher, candidate_id)
		if candidate.has("publisher"):
			_update_hasher(hasher, str(candidate["publisher"].get_instance_id()) \
				if is_instance_valid(candidate["publisher"]) else "pending")
		else:
			_update_hasher(hasher, str(candidate["owner"].get_instance_id()) \
				if is_instance_valid(candidate["owner"]) else "pending")
			_update_hasher(hasher, str(candidate["representation"].get_instance_id()) \
				if is_instance_valid(candidate["representation"]) else "pending")
	var source_identity := "generated-structure-blocks:%d:%d:%s" % [
		main.get_instance_id(), structure_system.get_instance_id(), str(bounds)]
	var source_revision := hasher.finish().hex_encode()
	phase_usec["candidateDescriptionHash"] = Time.get_ticks_usec() - phase_started
	var source_id := "generated-structure-blocks:%s" % str(bounds)
	var declared: Dictionary = readiness.call("expect_source", source_id, "structures",
		source_identity, source_revision, bounds, view_revision)
	if declared.get("status") != "ready":
		return declared
	var represented := 0
	var pending := 0
	var pending_ids: Array[String] = []
	phase_started = Time.get_ticks_usec()
	for candidate: Dictionary in candidates:
		var candidate_id := String(candidate["candidateId"])
		var position_xz: Vector2 = candidate["positionXZ"]
		var required_tier := "near" if tier_near_bounds.has_point(
			Vector2i(floori(position_xz.x), floori(position_xz.y))) else "horizon"
		if not bool(readiness.call("has_candidate", source_id, candidate_id)):
			var metadata := {"positionXZ":position_xz}
			if candidate.has("publisher"):
				metadata["citadelMemberId"] = candidate.memberId
				metadata["citadelBinding"] = candidate.binding
				metadata["citadelCandidateId"] = candidate_id
				metadata["citadelSourceSignature"] = candidate.sourceSignature
				metadata["citadelVisualSourceIdentity"] = source_identity
				metadata["citadelVisualSourceRevision"] = source_revision
			else:
				metadata["cell"] = candidate.cell
			var described: Dictionary = readiness.call("describe_candidate", source_id,
				candidate_id, required_tier, metadata)
			if described.get("status") != "ready":
				return described
		if candidate.has("publisher"):
			if not is_instance_valid(candidate.publisher):
				pending += 1
				if pending_ids.size() < 64: pending_ids.append(candidate_id)
				continue
			var published: Dictionary = readiness.call("accept_publisher_receipt",source_id,
				candidate_id,"%s:scene:%d" % [candidate_id,candidate.publisher.get_instance_id()],
				required_tier,source_identity,source_revision,view_revision,
				candidate.publisher,&"visual_receipt_installed")
			if published.get("status") == "failed": return published
			if published.get("status") == "ready": represented += 1
			else:
				pending += 1
				if pending_ids.size() < 64: pending_ids.append(candidate_id)
			continue
		if not is_instance_valid(candidate["representation"]):
			pending += 1
			if pending_ids.size() < 64: pending_ids.append(candidate_id)
			continue
		var receipt: Dictionary = readiness.call("accept_receipt", source_id, candidate_id,
			"%s:installed" % candidate_id, required_tier, source_identity,
			source_revision, view_revision, candidate["owner"], candidate["representation"])
		if receipt.get("status") == "failed":
			return receipt
		if receipt.get("status") == "ready":
			represented += 1
		else:
			pending += 1
			if pending_ids.size() < 64: pending_ids.append(candidate_id)
	phase_usec["receiptAdmission"] = Time.get_ticks_usec() - phase_started
	phase_started = Time.get_ticks_usec()
	var current_source: Dictionary = structure_system.call(source_method, bounds)
	phase_usec["sourceRecheck"] = Time.get_ticks_usec() - phase_started
	phase_started = Time.get_ticks_usec()
	var current_citadel: Dictionary = structure_system.call("region_citadel_visual_source", bounds)
	phase_usec["citadelRecheck"] = Time.get_ticks_usec() - phase_started
	# Submission and receipt checks run synchronously. Reuse the description
	# unless its producer changed while a receipt was checked; the ledger also
	# checks the installed owners before a completed view can be accepted.
	var current_ordinary: Dictionary = ordinary_source
	phase_started = Time.get_ticks_usec()
	var current_ordinary_revision: Variant = structure_system.get("ordinary_visual_revision")
	if ordinary_producer_revision < 0 or not current_ordinary_revision is int \
			or int(current_ordinary_revision) != ordinary_producer_revision:
		current_ordinary = structure_system.call("region_ordinary_visual_source", bounds)
	phase_usec["ordinaryRecheck"] = Time.get_ticks_usec() - phase_started
	phase_started = Time.get_ticks_usec()
	var current_dependency_revision := JSON.stringify(structure_system.call(dependency_method, bounds))
	phase_usec["dependencyRecheck"] = Time.get_ticks_usec() - phase_started
	if current_source.get("status") != required_status or current_dependency_revision != dependency_revision \
			or current_citadel.get("status") != "described" \
			or current_citadel.get("sourceRevision") != citadel_source.get("sourceRevision") \
			or current_ordinary.get("status") != "described" \
			or current_ordinary.get("sourceRevision") != ordinary_source.get("sourceRevision"):
		return {"status": "pending", "reason": "generated_structure_source_revision_changed",
			"sourceRevision": source_revision, "dependencyRevision": dependency_revision,
			"currentDependencyRevision": current_dependency_revision,
			"sourceDescription": current_source,
			"physicalPublication": current_source if require_physical else {}}
	var finished: Dictionary = readiness.call("finish_source", source_id,
		source_identity, source_revision, view_revision)
	if finished.get("status") != "ready":
		return finished
	return {"status": "pending" if pending > 0 else "ready",
		"reason": "structure_visual_publication_pending" if pending > 0 else "",
		"sourceId": source_id, "sourceIdentity": source_identity,
		"sourceRevision": source_revision, "requestId": request_id,
		"viewRevision": view_revision, "bounds": bounds,
		"candidateCount": candidates.size(), "representedCount": represented,
		"pendingCount": pending, "pendingIds": pending_ids,
		"ordinaryVisualProofScope":"producer_emission_ledger",
		"ordinarySourceCount":int(ordinary_source.get("sourceCount",0)),
		"phaseUsec":phase_usec,
		"sourceDescription": source_state,
		"physicalPublication": source_state if require_physical else {}}


static func begin_bounded(main: Object, structure_system: Object, readiness: Object,
		request_id: int, view_revision: int, bounds: Rect2i,
		near_bounds: Rect2i, require_physical: bool = true,
		global_near_bounds: Rect2i = Rect2i(),
		ordinary_capture: Object = null) -> Dictionary:
	var job := GeneratedStructureVisualManifest.new()
	var begun: Dictionary = job._begin_bounded(main, structure_system, readiness,
		request_id, view_revision, bounds, near_bounds, require_physical, global_near_bounds,
		{}, ordinary_capture)
	_record_bounded_event("begin")
	var source_usec := int(job._bounded.get("sourceDescriptionUsec",
		begun.get("sourceDescriptionUsec", 0)))
	var citadel_usec := int(job._bounded.get("citadelDescriptionUsec",
		begun.get("citadelDescriptionUsec", 0)))
	var ordinary_usec := int(job._bounded.get("ordinaryDescriptionUsec",
		begun.get("ordinaryDescriptionUsec", 0)))
	_record_bounded_stage("producerRegionSourceCapture",
		source_usec + citadel_usec + ordinary_usec)
	_record_bounded_stage("producerOrdinaryCapture", ordinary_usec)
	_record_bounded_stage("producerCitadelCapture", citadel_usec)
	_record_bounded_stage("candidateAdmission", int(job._bounded.get("admissionUsec", 0)))
	if begun.get("status") == "pending" and bool(begun.get("retryable", false)) \
			and not job._bounded.is_empty():
		begun["job"] = job
	return begun


func _begin_bounded(main: Object, structure_system: Object, readiness: Object,
		request_id: int, view_revision: int, bounds: Rect2i,
		near_bounds: Rect2i, require_physical: bool,
		global_near_bounds: Rect2i,
		ordinary_source_override: Dictionary = {},
		ordinary_capture: Object = null) -> Dictionary:
	if not is_instance_valid(main) or not is_instance_valid(structure_system) \
			or not is_instance_valid(readiness) \
			or not structure_system.has_method("region_publication_readiness") \
			or not structure_system.has_method("region_dependency_requirements") \
			or not structure_system.has_method("region_dependency_revision") \
			or not structure_system.has_method("region_dependency_scheduling_revision") \
			or not structure_system.has_method("region_citadel_visual_source") \
			or not structure_system.has_method("region_ordinary_visual_source") \
			or not structure_system.has_method("begin_region_ordinary_visual_source_capture") \
			or not readiness.has_method("expect_source") \
			or not readiness.has_method("describe_candidate") \
			or not readiness.has_method("has_candidate") \
			or not readiness.has_method("candidate_in_view") \
			or not readiness.has_method("accept_receipt") \
			or not readiness.has_method("accept_publisher_receipt") \
			or not readiness.has_method("finish_source"):
		return {"status": "failed", "reason": "generated_structure_visual_owner_missing"}
	if bounds.size.x <= 0 or bounds.size.y <= 0 or near_bounds.size.x <= 0 \
			or near_bounds.size.y <= 0 or not bounds.encloses(near_bounds):
		return {"status": "failed", "reason": "invalid_generated_structure_visual_bounds"}
	if ordinary_source_override.is_empty():
		var capture := ordinary_capture if is_instance_valid(ordinary_capture) \
			else structure_system.call("begin_region_ordinary_visual_source_capture", bounds) as Object
		if not is_instance_valid(capture) or not capture.has_method("advance"):
			return {"status": "failed", "reason": "ordinary_visual_capture_owner_missing"}
		if capture.has_method("eligible_for") \
				and not bool(capture.call("eligible_for", structure_system, bounds)):
			return {"status": "pending", "reason": "ordinary_visual_capture_source_changed",
				"retryable": true}
		_bounded = {"stage": "ordinary_capture", "capture": capture,
			"main": weakref(main), "mainId": main.get_instance_id(),
			"structure": weakref(structure_system),
			"structureId": structure_system.get_instance_id(),
			"readiness": weakref(readiness), "readinessId": readiness.get_instance_id(),
			"requestId": request_id, "viewRevision": view_revision,
			"bounds": bounds, "nearBounds": near_bounds,
			"requirePhysical": require_physical,
			"globalNearBounds": global_near_bounds}
		return _bounded_pending("ordinary_visual_capture_budget")
	var source_method := "region_publication_readiness" if require_physical \
		else "region_dependency_requirements"
	var dependency_method := "region_dependency_revision" if require_physical \
		else "region_dependency_scheduling_revision"
	var required_status := "ready" if require_physical else "described"
	var started := Time.get_ticks_usec()
	var source_state: Dictionary = structure_system.call(source_method, bounds)
	var source_description_usec := maxi(0, Time.get_ticks_usec() - started)
	if source_state.get("status") != required_status:
		return {"status": String(source_state.get("status", "pending")),
			"reason": String(source_state.get("reason", "structure_source_description_pending")),
			"sourceDescriptionUsec": source_description_usec,
			"sourceDescription": source_state,
			"physicalPublication": source_state if require_physical else {}}
	var dependency_revision := JSON.stringify(structure_system.call(dependency_method, bounds))
	started = Time.get_ticks_usec()
	var citadel_source: Dictionary = structure_system.call("region_citadel_visual_source", bounds)
	var citadel_description_usec := maxi(0, Time.get_ticks_usec() - started)
	if citadel_source.get("status") != "described" \
			or not bool(citadel_source.get("descriptionComplete", false)):
		return {"status": String(citadel_source.get("status", "pending")),
			"reason": String(citadel_source.get("reason", "citadel_visual_description_pending")),
			"citadelDescriptionUsec": citadel_description_usec,
			"citadelSource": citadel_source}
	started = Time.get_ticks_usec()
	var ordinary_source: Dictionary = ordinary_source_override if not ordinary_source_override.is_empty() \
		else structure_system.call("region_ordinary_visual_source", bounds)
	var ordinary_description_usec := maxi(0, Time.get_ticks_usec() - started)
	var ordinary_phase: Dictionary = ordinary_source.get("phaseUsec", {})
	for phase_value in ordinary_phase:
		_record_bounded_stage("producerOrdinary" + String(phase_value).capitalize().replace(" ", ""),
			int(ordinary_phase[phase_value]))
	if ordinary_source.get("status") != "described":
		return {"status": String(ordinary_source.get("status", "pending")),
			"reason": String(ordinary_source.get("reason", "ordinary_visual_description_pending")),
			"ordinaryDescriptionUsec": ordinary_description_usec,
			"ordinarySource": ordinary_source}
	var ordinary_values: Array = ordinary_source.get("candidates", [])
	var citadel_values: Array = citadel_source.get("candidates", [])
	if ordinary_values.size() > MAX_BLOCKS:
		return {"status": "pending", "reason": "generated_structure_visual_capacity",
			"retryable": true}
	# Producer descriptions may contain Nodes. Replace every such field before
	# retaining a cross-frame job; scalar membership remains in producer order.
	started = Time.get_ticks_usec()
	var ordinary_rows: Array[Dictionary] = []
	for value in ordinary_values:
		if not value is Dictionary:
			return {"status": "failed", "reason": "generated_structure_block_record_invalid"}
		var row: Dictionary = value
		var owner_value: Variant = row.get("owner")
		var representation_value: Variant = row.get("representation")
		var owner := (_bounded_weak_node(owner_value) if owner_value is WeakRef \
			else owner_value) as Node3D
		var representation := (_bounded_weak_node(representation_value) \
			if representation_value is WeakRef else representation_value) as Node3D
		if owner_value is WeakRef and int(row.get("ownerId", 0)) != (owner.get_instance_id() \
				if is_instance_valid(owner) else 0) \
				or representation_value is WeakRef \
				and int(row.get("representationId", 0)) != (representation.get_instance_id() \
				if is_instance_valid(representation) else 0):
			return {"status": "pending", "reason": "generated_structure_bounded_owner_changed",
				"retryable": true}
		ordinary_rows.append({"candidateId": String(row.get("candidateId", "")),
			"positionXZ": row.get("positionXZ", Vector2.INF), "cell": row.get("cell"),
			"owner": weakref(owner) if is_instance_valid(owner) else null,
			"ownerId": owner.get_instance_id() if is_instance_valid(owner) else 0,
			"representation": weakref(representation) if is_instance_valid(representation) else null,
			"representationId": representation.get_instance_id() \
				if is_instance_valid(representation) else 0})
	var citadel_rows: Array[Dictionary] = []
	for value in citadel_values:
		if not value is Dictionary:
			return {"status": "failed", "reason": "citadel_visual_candidate_invalid"}
		var row: Dictionary = value
		var publisher := row.get("publisher") as Object
		var binding_value: Variant = row.get("binding")
		if binding_value is Dictionary and not _value_record_is_owned(binding_value):
			return {"status": "failed", "reason": "citadel_visual_binding_not_value_data"}
		citadel_rows.append({"candidateId": String(row.get("candidateId", "")),
			"positionXZ": row.get("positionXZ"), "memberId": String(row.get("memberId", "")),
			"binding": (binding_value as Dictionary).duplicate(true) \
				if binding_value is Dictionary else binding_value,
			"sourceSignature": String(row.get("sourceSignature", "")),
			"publisher": weakref(publisher) if is_instance_valid(publisher) else null,
			"publisherId": publisher.get_instance_id() if is_instance_valid(publisher) else 0})
	var admission_usec := maxi(0, Time.get_ticks_usec() - started)
	var tier_near_bounds := global_near_bounds if global_near_bounds.has_area() else near_bounds
	_bounded = {"main": weakref(main), "mainId": main.get_instance_id(),
		"structure": weakref(structure_system), "structureId": structure_system.get_instance_id(),
		"readiness": weakref(readiness), "readinessId": readiness.get_instance_id(),
		"requestId": request_id, "viewRevision": view_revision,
		"bounds": bounds, "tierNearBounds": tier_near_bounds,
		"requirePhysical": require_physical, "sourceMethod": source_method,
		"dependencyMethod": dependency_method, "requiredStatus": required_status,
		"dependencyRevision": dependency_revision,
		"citadelRevision": String(citadel_source.get("sourceRevision", "")),
		"ordinaryRevision": String(ordinary_source.get("sourceRevision", "")),
		"ordinarySourceCount": int(ordinary_source.get("sourceCount", 0)),
		"ordinaryRows": ordinary_rows, "citadelRows": citadel_rows,
		"candidateCursor": 0, "candidates": [], "candidateById": {},
		"sortedIds": [], "hashCursor": 0, "receiptCursor": 0,
		"pendingCount": 0, "representedCount": 0, "pendingIds": [],
		"stage": "candidates", "sourceId": "generated-structure-blocks:%s" % str(bounds),
		"sourceIdentity": "generated-structure-blocks:%d:%d:%s" % [
			main.get_instance_id(), structure_system.get_instance_id(), str(bounds)],
		"sourceDescriptionUsec": source_description_usec,
		"citadelDescriptionUsec": citadel_description_usec,
		"ordinaryDescriptionUsec": ordinary_description_usec,
		"admissionUsec": admission_usec}
	return _bounded_pending("generated_structure_candidate_budget")


func advance(max_candidates: int = 32, max_usec: int = 2000) -> Dictionary:
	_diagnostic_call_usec.clear()
	_record_bounded_event("continue")
	var result: Dictionary = _advance_bounded_impl(max_candidates, max_usec)
	for stage_value in _diagnostic_call_usec:
		_record_bounded_stage(String(stage_value), int(_diagnostic_call_usec[stage_value]))
	if result.get("status") == "ready":
		_record_bounded_event("complete")
	elif String(result.get("reason", "")) in ["generated_structure_bounded_owner_changed",
			"generated_structure_source_revision_changed"]:
		_record_bounded_event("restart")
	elif String(result.get("reason", "")) == "generated_structure_bounded_budget":
		_record_bounded_event("budget")
	return result


func _advance_bounded_impl(max_candidates: int, max_usec: int) -> Dictionary:
	if _bounded.is_empty():
		return {"status": "failed", "reason": "generated_structure_bounded_job_missing"}
	var owner_started_usec := Time.get_ticks_usec()
	var context: Dictionary = _bounded_context()
	_diagnostic_add("ownerValidation", Time.get_ticks_usec() - owner_started_usec)
	if context.is_empty():
		_bounded.clear()
		return {"status": "pending", "reason": "generated_structure_bounded_owner_changed",
			"retryable": true}
	var main: Object = context.main
	var structure_system: Object = context.structure
	var readiness: Object = context.readiness
	if String(_bounded.stage) == "ordinary_capture":
		var capture: Object = _bounded.get("capture") as Object
		if not is_instance_valid(capture):
			_bounded.clear()
			return {"status": "pending", "reason": "ordinary_visual_capture_owner_changed",
				"retryable": true}
		var capture_started_usec := Time.get_ticks_usec()
		var ordinary_source: Dictionary = capture.call("advance", 512, 3000)
		_diagnostic_add("producerOrdinaryCaptureSlice",
			maxi(0, Time.get_ticks_usec() - capture_started_usec))
		if ordinary_source.get("status") != "described":
			if String(ordinary_source.get("reason", "")) != "ordinary_visual_capture_budget":
				_bounded.clear()
			return ordinary_source
		var near_bounds: Rect2i = _bounded.nearBounds
		var global_near_bounds: Rect2i = _bounded.globalNearBounds
		var bounds: Rect2i = _bounded.bounds
		var request_id := int(_bounded.requestId)
		var view_revision := int(_bounded.viewRevision)
		var require_physical := bool(_bounded.requirePhysical)
		_bounded.clear()
		return _begin_bounded(main, structure_system, readiness, request_id,
			view_revision, bounds, near_bounds, require_physical, global_near_bounds,
			ordinary_source)
	var started := Time.get_ticks_usec()
	var processed := 0
	var limit := maxi(1, max_candidates)
	var deadline := maxi(1, max_usec)
	while processed < limit and (processed == 0 or Time.get_ticks_usec() - started < deadline):
		var stage := String(_bounded.stage)
		if stage == "candidates":
			var ordinary_rows: Array = _bounded.ordinaryRows
			var citadel_rows: Array = _bounded.citadelRows
			var cursor := int(_bounded.candidateCursor)
			if cursor >= ordinary_rows.size() + citadel_rows.size():
				_bounded.erase("ordinaryRows")
				_bounded.erase("citadelRows")
				var hasher := HashingContext.new()
				hasher.start(HashingContext.HASH_SHA256)
				_update_hasher(hasher, String(_bounded.dependencyRevision))
				_update_hasher(hasher, String(_bounded.citadelRevision))
				_update_hasher(hasher, String(_bounded.ordinaryRevision))
				_bounded["hasher"] = hasher
				_bounded.stage = "hash"
				continue
			var raw: Dictionary = ordinary_rows[cursor] if cursor < ordinary_rows.size() \
				else citadel_rows[cursor - ordinary_rows.size()]
			var candidate_started_usec := Time.get_ticks_usec()
			var outcome: Dictionary = _bounded_add_candidate(raw, cursor >= ordinary_rows.size(),
				readiness)
			_diagnostic_add("candidateFiltering", Time.get_ticks_usec() - candidate_started_usec)
			if outcome.get("status") != "ready":
				_bounded.clear()
				return outcome
			_bounded.candidateCursor = cursor + 1
			processed += 1
			continue
		if stage == "hash":
			var ids: Array = _bounded.sortedIds
			var index := int(_bounded.hashCursor)
			if index >= ids.size():
				var finalize_started_usec := Time.get_ticks_usec()
				_bounded.sourceRevision = (_bounded.hasher as HashingContext).finish().hex_encode()
				_diagnostic_add("candidateHashing", Time.get_ticks_usec() - finalize_started_usec)
				_bounded.erase("hasher")
				_bounded.stage = "declare"
				continue
			var hash_started_usec := Time.get_ticks_usec()
			var candidate: Dictionary = _bounded.candidateById[String(ids[index])]
			_update_hasher(_bounded.hasher, String(ids[index]))
			if candidate.has("publisher"):
				_update_hasher(_bounded.hasher, str(candidate.publisherId) \
					if int(candidate.publisherId) != 0 else "pending")
			else:
				_update_hasher(_bounded.hasher, str(candidate.ownerId) \
					if int(candidate.ownerId) != 0 else "pending")
				_update_hasher(_bounded.hasher, str(candidate.representationId) \
					if int(candidate.representationId) != 0 else "pending")
			_diagnostic_add("candidateHashing", Time.get_ticks_usec() - hash_started_usec)
			_bounded.hashCursor = index + 1
			processed += 1
			continue
		if stage == "declare":
			var declaration_started_usec := Time.get_ticks_usec()
			var declared: Dictionary = readiness.call("expect_source", String(_bounded.sourceId),
				"structures", String(_bounded.sourceIdentity), String(_bounded.sourceRevision),
				_bounded.bounds, int(_bounded.viewRevision))
			_diagnostic_add("sourceDeclaration", Time.get_ticks_usec() - declaration_started_usec)
			if declared.get("status") != "ready":
				return declared
			_bounded.stage = "receipts"
			continue
		if stage == "receipts":
			var candidates: Array = _bounded.candidates
			var receipt_cursor := int(_bounded.receiptCursor)
			if receipt_cursor >= candidates.size():
				_bounded.stage = "finish"
				continue
			var receipt_started_usec := Time.get_ticks_usec()
			var receipt_result: Dictionary = _bounded_admit_receipt(candidates[receipt_cursor], readiness)
			_diagnostic_add("liveReceiptSubmit", Time.get_ticks_usec() - receipt_started_usec)
			if receipt_result.get("status") == "failed" \
					or receipt_result.get("reason") == "generated_structure_bounded_owner_changed":
				_bounded.clear()
				return receipt_result
			if receipt_result.get("reason") in ["visual_receipt_revision_stale",
					"visual_receipt_source_missing", "visual_receipt_candidate_missing"]:
				_bounded.clear()
				return {"status": "pending", "reason": "generated_structure_source_revision_changed",
					"retryable": true}
			if receipt_result.get("status") == "pending" \
					and not bool(readiness.call("has_candidate", String(_bounded.sourceId),
						String(candidates[receipt_cursor].candidateId))):
				return receipt_result
			_bounded.receiptCursor = receipt_cursor + 1
			processed += 1
			continue
		if stage == "finish":
			var recheck_started_usec := Time.get_ticks_usec()
			var final_capture := _bounded.get("finalCapture") as Object
			if not is_instance_valid(final_capture):
				if not structure_system.has_method("begin_region_ordinary_visual_source_capture"):
					_bounded.clear()
					return {"status": "pending", "reason": "ordinary_visual_capture_owner_changed",
						"retryable": true}
				final_capture = structure_system.call(
					"begin_region_ordinary_visual_source_capture", _bounded.bounds)
				_bounded.finalCapture = final_capture
			if not is_instance_valid(final_capture) or not final_capture.has_method("advance"):
				_bounded.clear()
				return {"status": "pending", "reason": "ordinary_visual_capture_owner_changed",
					"retryable": true}
			var final_ordinary: Dictionary = final_capture.call("advance", 256, 1000)
			_diagnostic_add("finalProducerRecheck",
				maxi(0, Time.get_ticks_usec() - recheck_started_usec))
			if final_ordinary.get("status") != "described":
				if String(final_ordinary.get("reason", "")) != "ordinary_visual_capture_budget":
					_bounded.clear()
				return final_ordinary
			recheck_started_usec = Time.get_ticks_usec()
			var current: Dictionary = _bounded_current_producer_state(
				structure_system, final_ordinary)
			_diagnostic_add("finalProducerRecheck", Time.get_ticks_usec() - recheck_started_usec)
			if not bool(current.get("valid", false)):
				_bounded.clear()
				return {"status": "pending", "reason": "generated_structure_source_revision_changed",
					"retryable": true}
			var finish_started_usec := Time.get_ticks_usec()
			var finished: Dictionary = readiness.call("finish_source", String(_bounded.sourceId),
				String(_bounded.sourceIdentity), String(_bounded.sourceRevision),
				int(_bounded.viewRevision))
			_diagnostic_add("finishSource", Time.get_ticks_usec() - finish_started_usec)
			if finished.get("status") != "ready":
				if finished.get("reason") == "visual_source_revision_changed":
					_bounded.clear()
				return finished
			var result := {"status": "pending" if int(_bounded.pendingCount) > 0 else "ready",
				"reason": "structure_visual_publication_pending" \
					if int(_bounded.pendingCount) > 0 else "",
				"retryable": int(_bounded.pendingCount) > 0,
				"sourceId": _bounded.sourceId,
				"sourceIdentity": _bounded.sourceIdentity,
				"sourceRevision": _bounded.sourceRevision,
				"requestId": _bounded.requestId,
				"viewRevision": _bounded.viewRevision,
				"bounds": _bounded.bounds,
				"candidateCount": (_bounded.candidates as Array).size(),
				"representedCount": _bounded.representedCount,
				"pendingCount": _bounded.pendingCount,
				"pendingIds": _bounded.pendingIds,
				"ordinaryVisualProofScope": "producer_emission_ledger",
				"ordinarySourceCount": _bounded.ordinarySourceCount,
				"candidateAdmissionUsec": _bounded.admissionUsec,
				"sourceDescriptionUsec": _bounded.sourceDescriptionUsec,
				"citadelDescriptionUsec": _bounded.citadelDescriptionUsec,
				"ordinaryDescriptionUsec": _bounded.ordinaryDescriptionUsec,
				"sourceDescription": current.source,
				"physicalPublication": current.source if bool(_bounded.requirePhysical) else {}}
			result["producerCertificate"] = current.get("producerCertificate", {})
			if (result.producerCertificate as Dictionary).is_empty():
				_bounded.clear()
				return {"status": "pending", "reason": "generated_structure_producer_certificate_changed",
					"retryable": true}
			if int(_bounded.pendingCount) > 0:
				_bounded.stage = "receipts"
				_bounded.receiptCursor = 0
				_bounded.pendingCount = 0
				_bounded.representedCount = 0
				_bounded.pendingIds = []
			else:
				_bounded.stage = "complete"
			return result
		if stage == "complete":
			_bounded.clear()
			return {"status": "failed", "reason": "generated_structure_bounded_job_consumed"}
		return {"status": "failed", "reason": "generated_structure_bounded_stage_invalid"}
	return _bounded_pending("generated_structure_bounded_budget")


func _bounded_current_producer_state(structure_system: Object,
		ordinary_override: Dictionary = {}) -> Dictionary:
	var current_source: Dictionary = structure_system.call(String(_bounded.sourceMethod),
		_bounded.bounds)
	var current_citadel: Dictionary = structure_system.call("region_citadel_visual_source",
		_bounded.bounds)
	var current_ordinary: Dictionary = ordinary_override if not ordinary_override.is_empty() \
		else structure_system.call("region_ordinary_visual_source", _bounded.bounds)
	var current_dependency := JSON.stringify(structure_system.call(
		String(_bounded.dependencyMethod), _bounded.bounds))
	var ordinary_mutation_revision: Variant = structure_system.get("ordinary_visual_revision")
	var certificate := {"structureId": structure_system.get_instance_id(),
		"bounds": _bounded.bounds,
		"ordinaryMutationRevision": int(ordinary_mutation_revision)
			if ordinary_mutation_revision is int else -1,
		"citadelRevision": String(current_citadel.get("sourceRevision", "")),
		"dependencyRevision": current_dependency}
	return {"source": current_source,
		"producerCertificate": certificate,
		"valid": current_source.get("status") == _bounded.requiredStatus \
			and current_citadel.get("status") == "described" \
			and bool(current_citadel.get("descriptionComplete", false)) \
			and String(current_citadel.get("sourceRevision", "")) == _bounded.citadelRevision \
			and current_ordinary.get("status") == "described" \
			and String(current_ordinary.get("sourceRevision", "")) == _bounded.ordinaryRevision \
			and current_dependency == _bounded.dependencyRevision}


static func producer_certificate(structure_system: Object, bounds: Rect2i) -> Dictionary:
	if not is_instance_valid(structure_system) \
			or not structure_system.has_method("region_citadel_visual_source") \
			or not structure_system.has_method("region_dependency_scheduling_revision"):
		return {}
	var ordinary_revision: Variant = structure_system.get("ordinary_visual_revision")
	if not ordinary_revision is int: return {}
	var citadel: Dictionary = structure_system.call("region_citadel_visual_source", bounds)
	if citadel.get("status") != "described" \
			or not bool(citadel.get("descriptionComplete", false)):
		return {}
	return {"structureId": structure_system.get_instance_id(),
		"bounds": bounds,
		"ordinaryMutationRevision": int(ordinary_revision),
		"citadelRevision": String(citadel.get("sourceRevision", "")),
		"dependencyRevision": JSON.stringify(structure_system.call(
			"region_dependency_scheduling_revision", bounds))}


func _bounded_add_candidate(raw: Dictionary, citadel: bool, readiness: Object) -> Dictionary:
	var candidate_id := String(raw.get("candidateId", ""))
	var position_xz: Variant = raw.get("positionXZ")
	var by_id: Dictionary = _bounded.candidateById
	if citadel:
		if (_bounded.candidates as Array).size() >= MAX_BLOCKS:
			return {"status": "pending", "reason": "generated_structure_visual_capacity",
				"retryable": true}
		if candidate_id.is_empty() or by_id.has(candidate_id) or not position_xz is Vector2 \
				or not raw.get("binding") is Dictionary:
			return {"status": "failed", "reason": "citadel_visual_candidate_identity_invalid"}
	else:
		var cell_value: Variant = raw.get("cell")
		if not cell_value is Vector3i:
			return {"status": "failed", "reason": "generated_structure_block_cell_missing"}
		var cell: Vector3i = cell_value
		if candidate_id.is_empty() or by_id.has(candidate_id) or position_xz == Vector2.INF:
			return {"status": "failed", "reason": "ordinary_visual_candidate_identity_invalid"}
		if not (_bounded.bounds as Rect2i).has_point(Vector2i(cell.x, cell.z)):
			return {"status": "failed", "reason": "generated_structure_block_outside_region"}
		var body := _bounded_weak_node(raw.get("owner")) as Node3D
		if int(raw.get("ownerId", 0)) != (body.get_instance_id() if is_instance_valid(body) else 0):
			return {"status": "pending", "reason": "generated_structure_bounded_owner_changed",
				"retryable": true}
		if is_instance_valid(body) and (not body.is_inside_tree() or body.is_queued_for_deletion() \
				or not bool(body.get_meta("generated", false)) \
				or bool(body.get_meta("player_placed", false))):
			return {"status": "failed", "reason": "generated_structure_block_owner_mismatch"}
	if not bool(readiness.call("candidate_in_view", position_xz)):
		return {"status": "ready"}
	if not citadel:
		var representation := _bounded_weak_node(raw.get("representation"))
		if int(raw.get("representationId", 0)) != (representation.get_instance_id() \
				if is_instance_valid(representation) else 0):
			return {"status": "pending", "reason": "generated_structure_bounded_owner_changed",
				"retryable": true}
	var candidate := raw.duplicate()
	(_bounded.candidates as Array).append(candidate)
	by_id[candidate_id] = candidate
	_bounded_insert_id(candidate_id)
	return {"status": "ready"}


func _bounded_insert_id(candidate_id: String) -> void:
	var ids: Array = _bounded.sortedIds
	var low := 0
	var high := ids.size()
	while low < high:
		var middle := int((low + high) / 2)
		if String(ids[middle]) < candidate_id:
			low = middle + 1
		else:
			high = middle
	ids.insert(low, candidate_id)


func _bounded_admit_receipt(candidate: Dictionary, readiness: Object) -> Dictionary:
	var candidate_id := String(candidate.candidateId)
	var position_xz: Vector2 = candidate.positionXZ
	var tier_near: Rect2i = _bounded.tierNearBounds
	var required_tier := "near" if tier_near.has_point(Vector2i(
		floori(position_xz.x), floori(position_xz.y))) else "horizon"
	var source_id := String(_bounded.sourceId)
	var source_identity := String(_bounded.sourceIdentity)
	var source_revision := String(_bounded.sourceRevision)
	var view_revision := int(_bounded.viewRevision)
	if not bool(readiness.call("has_candidate", source_id, candidate_id)):
		var metadata := {"positionXZ": position_xz}
		if candidate.has("publisher"):
			metadata["citadelMemberId"] = candidate.memberId
			metadata["citadelBinding"] = candidate.binding
			metadata["citadelCandidateId"] = candidate_id
			metadata["citadelSourceSignature"] = candidate.sourceSignature
			metadata["citadelVisualSourceIdentity"] = source_identity
			metadata["citadelVisualSourceRevision"] = source_revision
		else:
			metadata["cell"] = candidate.cell
			metadata["ordinaryVisualSourceId"] = String(candidate.get("sourceId", ""))
			metadata["ordinaryBlockType"] = String(candidate.get("blockType", ""))
		var described: Dictionary = readiness.call("describe_candidate", source_id,
			candidate_id, required_tier, metadata)
		if described.get("status") != "ready":
			return described
	if candidate.has("publisher"):
		var publisher := _bounded_weak_node(candidate.publisher)
		if int(candidate.publisherId) != (publisher.get_instance_id() \
				if is_instance_valid(publisher) else 0):
			return {"status": "pending", "reason": "generated_structure_bounded_owner_changed",
				"retryable": true}
		if not is_instance_valid(publisher):
			_bounded_pending_id(candidate_id)
			return {"status": "pending"}
		var published: Dictionary = readiness.call("accept_publisher_receipt", source_id,
			candidate_id, "%s:scene:%d" % [candidate_id, publisher.get_instance_id()],
			required_tier, source_identity, source_revision, view_revision,
			publisher, &"visual_receipt_installed")
		if published.get("status") == "ready":
			_bounded.representedCount = int(_bounded.representedCount) + 1
		elif published.get("status") != "failed":
			_bounded_pending_id(candidate_id)
		return published
	var owner := _bounded_weak_node(candidate.owner) as Node3D
	var representation := _bounded_weak_node(candidate.representation) as Node3D
	if int(candidate.ownerId) != (owner.get_instance_id() if is_instance_valid(owner) else 0) \
			or int(candidate.representationId) != (representation.get_instance_id() \
			if is_instance_valid(representation) else 0):
		return {"status": "pending", "reason": "generated_structure_bounded_owner_changed",
			"retryable": true}
	if not is_instance_valid(representation):
		_bounded_pending_id(candidate_id)
		return {"status": "pending"}
	var receipt: Dictionary = readiness.call("accept_receipt", source_id, candidate_id,
		"%s:installed" % candidate_id, required_tier, source_identity,
		source_revision, view_revision, owner, representation)
	if receipt.get("status") == "ready":
		_bounded.representedCount = int(_bounded.representedCount) + 1
	elif receipt.get("status") != "failed":
		_bounded_pending_id(candidate_id)
	return receipt


func _bounded_pending_id(candidate_id: String) -> void:
	_bounded.pendingCount = int(_bounded.pendingCount) + 1
	if (_bounded.pendingIds as Array).size() < 64:
		(_bounded.pendingIds as Array).append(candidate_id)


func _bounded_pending(reason: String) -> Dictionary:
	return {"status": "pending", "reason": reason, "retryable": true,
		"stage": _bounded.get("stage", ""), "cursor": _bounded.get("candidateCursor", 0),
		"candidateCount": (_bounded.get("candidates", []) as Array).size(),
		"candidateAdmissionUsec": _bounded.get("admissionUsec", 0)}


func _bounded_context() -> Dictionary:
	var main := _bounded_weak_node(_bounded.get("main"))
	var structure_system := _bounded_weak_node(_bounded.get("structure"))
	var readiness := _bounded_weak_node(_bounded.get("readiness"))
	if not is_instance_valid(main) or not is_instance_valid(structure_system) \
			or not is_instance_valid(readiness) \
			or main.get_instance_id() != int(_bounded.mainId) \
			or structure_system.get_instance_id() != int(_bounded.structureId) \
			or readiness.get_instance_id() != int(_bounded.readinessId) \
			or int(readiness.get("_view_revision")) != int(_bounded.viewRevision) \
			or int(readiness.get("_request_id")) != int(_bounded.requestId):
		return {}
	return {"main": main, "structure": structure_system, "readiness": readiness}


func _bounded_weak_node(value: Variant) -> Object:
	return (value as WeakRef).get_ref() if value is WeakRef else null


static func _value_record_is_owned(value: Variant, depth: int = 0) -> bool:
	if depth > 12 or value is Object:
		return false
	if value is Dictionary:
		for key in value:
			if not _value_record_is_owned(key, depth + 1) \
					or not _value_record_is_owned(value[key], depth + 1):
				return false
	if value is Array:
		for item in value:
			if not _value_record_is_owned(item, depth + 1):
				return false
	return true


static func _visible_renderable(root_node: Node) -> Node3D:
	if root_node is GeometryInstance3D:
		var geometry := root_node as GeometryInstance3D
		if geometry.visible and geometry.is_visible_in_tree():
			if geometry is MeshInstance3D and (geometry as MeshInstance3D).mesh != null:
				return geometry
			if geometry is MultiMeshInstance3D and (geometry as MultiMeshInstance3D).multimesh != null:
				return geometry
	for child in root_node.get_children():
		if child is Node:
			var found := _visible_renderable(child)
			if found != null:
				return found
	return null


static func _update_hasher(hasher: HashingContext, value: String) -> void:
	var bytes := value.to_utf8_buffer()
	var length := PackedByteArray()
	length.resize(4)
	length.encode_u32(0, bytes.size())
	hasher.update(length)
	if not bytes.is_empty():
		hasher.update(bytes)
