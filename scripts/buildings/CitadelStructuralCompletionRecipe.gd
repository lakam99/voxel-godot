extends RefCounted

## Transactional source completion for ordinary generated street houses.
## Producer ownership comes only from CitadelStreetHouseStructuralManifest.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Facades = preload("res://scripts/buildings/CitadelFacadeCompletionRecipe.gd")
const Manifest = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const Chimneys = preload("res://scripts/buildings/ChimneyBearingRecipe.gd")
const Brackets = preload("res://scripts/buildings/DoorHoodBracketMountRecipe.gd")
const Signs = preload("res://scripts/buildings/HouseholdSignPlacementRecipe.gd")
const PartyWalls = preload("res://scripts/buildings/MasonryPartyWallBearingRecipe.gd")
const Thresholds = preload("res://scripts/buildings/CitadelThresholdBearingRecipe.gd")
const DoorGeometry = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const MAX_STAGE_ATTEMPTS := 256
const FailureEvidence = preload("res://scripts/buildings/CitadelPhysicalFailureEvidence.gd")
const BuntingManifest = preload("res://scripts/buildings/CitadelBuntingAssemblyManifest.gd")
const BuntingAnchors = preload("res://scripts/buildings/CitadelBuntingAnchorRecipe.gd")
const BuntingDomain = preload("res://scripts/buildings/CitadelMarketBuntingDomain.gd")

static func prepare(blueprint, policy: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	# Execution control is deliberately separate from serializable source policy.
	# These are operation boundaries, not a bound on inner physical validation.
	if not _continue(continuation, "structural_started"): return _fail("cancelled")
	if blueprint == null or not policy.get("furnitureParts") is Array or not policy.get("reservedVolumes") is Array \
			or not policy.get("protectedObstacles") is Array:
		return _fail("invalid_structural_completion_input")
	var frozen := var_to_bytes(blueprint.snapshot())
	var frozen_policy := var_to_bytes(policy)
	# Reject stale producer ownership before any expensive private construction.
	# The post-facade prepare_later path repeats this validation against its own
	# immutable working copy.
	var manifest := Manifest.read(blueprint)
	var bunting_manifest := _bunting_manifest(blueprint)
	if not bunting_manifest.ready: return _fail("bunting_manifest_invalid",{"detail":bunting_manifest})
	if not manifest.ready:
		if frozen != var_to_bytes(blueprint.snapshot()) or frozen_policy != var_to_bytes(policy):
			return _fail("structural_completion_failure_mutated_input")
		return _fail("structural_manifest_invalid", {"detail": manifest})
	var facade := Facades.prepare(blueprint, policy, continuation)
	if facade.get("reason", "") == "cancelled": return facade
	if frozen != var_to_bytes(blueprint.snapshot()) or frozen_policy != var_to_bytes(policy):
		return _fail("structural_completion_failure_mutated_input")
	if not facade.ready: return _fail("facade_completion_failed", {"detail": facade})
	var result := prepare_later(Copy.copy_blueprint(facade.afterSnapshot), policy, continuation)
	if result.get("reason", "") == "cancelled": return result
	if frozen != var_to_bytes(blueprint.snapshot()) or frozen_policy != var_to_bytes(policy):
		return _fail("structural_completion_mutated_input")
	if not result.ready: return result
	result["facade"] = _without_snapshot(facade)
	if not _continue(continuation, "structural_completed"): return _fail("cancelled")
	return result

static func prepare_later(blueprint, policy: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	if not _continue(continuation, "structural_later_started"): return _fail("cancelled")
	if blueprint == null or not policy.get("protectedObstacles") is Array: return _fail("invalid_later_completion_input")
	var source_bytes := var_to_bytes(blueprint.snapshot())
	var policy_bytes := var_to_bytes(policy)
	var working = Copy.copy_blueprint(blueprint.snapshot())
	var bunting_manifest := _bunting_manifest(working)
	if not bunting_manifest.ready: return _fail("bunting_manifest_invalid",{"detail":bunting_manifest})
	var manifest := Manifest.read(working)
	if not manifest.ready:
		if source_bytes != var_to_bytes(blueprint.snapshot()) or policy_bytes != var_to_bytes(policy): return _fail("later_completion_failure_mutated_input")
		return _fail("structural_manifest_invalid", {"detail": manifest})
	var protected := _protected_bounds(working, manifest.records, policy.protectedObstacles)
	if not protected.ready: return protected
	var stages: Array = []
	var chimney := _complete_chimneys(working, manifest.records, policy.protectedObstacles, continuation)
	if not chimney.ready: return chimney
	stages.append(chimney)
	var bracket_first := _complete_brackets(working, manifest.records, "bracket_first", continuation)
	if not bracket_first.ready: return bracket_first
	stages.append(bracket_first)
	var sign := _complete_signs(working, manifest.records, protected.bounds, continuation)
	if not sign.ready: return sign
	stages.append(sign)
	var party := _complete_party_walls(working, manifest.records, continuation)
	if not party.ready: return party
	stages.append(party)
	var bracket_retry := _complete_brackets(working, manifest.records, "bracket_retry", continuation)
	if not bracket_retry.ready: return bracket_retry
	stages.append(bracket_retry)
	var bunting := _complete_bunting(working, protected.bounds, continuation)
	if not bunting.ready: return bunting
	working = Copy.copy_blueprint(bunting.afterSnapshot)
	bunting.erase("afterSnapshot")
	stages.append(bunting)
	# Threshold completion is last because it adds collision-backed support columns.
	# Its terminal proof is the ordinary terminal proof; never validate a third time.
	var threshold := _complete_thresholds(working, manifest.records, policy.protectedObstacles, continuation)
	if not threshold.ready: return threshold
	working = Copy.copy_blueprint(threshold.afterSnapshot)
	var final: Dictionary = threshold._terminalProof
	threshold.erase("afterSnapshot")
	threshold.erase("_terminalProof")
	stages.append(threshold)
	if not final.failedIds.is_empty():
		return _fail("structural_completion_unresolved", {"failedIds": final.failedIds, "stages": stages,
			"physicalFailureEvidence": FailureEvidence.collect(final.proof, final.report)})
	# Generic physical attachment can name foreign mass and does not prove
	# dressing clearance. Reuse the final proof after all structural changes;
	# proposing another relocation here is a rejection, never a final-state pass.
	var verified_signs := _verify_final_signs(final.proof, manifest.records, protected.bounds, continuation)
	if not verified_signs.ready: return verified_signs
	var verified_bunting := _verify_final_bunting(final.proof,bunting,continuation)
	if not verified_bunting.ready: return verified_bunting
	bunting["terminalVerification"] = verified_bunting
	Copy.clear_caches(working)
	if source_bytes != var_to_bytes(blueprint.snapshot()) or policy_bytes != var_to_bytes(policy): return _fail("later_completion_mutated_input")
	if not _continue(continuation, "structural_later_completed"): return _fail("cancelled")
	return {"ready": true, "afterSnapshot": working.snapshot(), "stages": stages,
		"finalFailureCount": 0, "scope": "Private source completion only; caller has not committed or published it."}

static func _bunting_manifest(source) -> Dictionary:
	if not source.recipe.has(BuntingManifest.KEY) and not source.parts.any(func(part):return part.semantic in [BuntingManifest.ROPE_SEMANTIC,BuntingManifest.PENNANT_SEMANTIC]):
		return {"ready":true,"records":[]}
	return BuntingManifest.read(source)

static func _complete_bunting(source, protected: Array, continuation: Callable = Callable()) -> Dictionary:
	var frozen := var_to_bytes(source.snapshot())
	var inputs := var_to_bytes(protected)
	if not _continue(continuation,"bunting_completion_started"): return _fail("cancelled")
	if frozen!=var_to_bytes(source.snapshot()) or inputs!=var_to_bytes(protected): return _fail("bunting_completion_inputs_changed")
	var declaration := _bunting_manifest(source)
	if not declaration.ready: return _fail("bunting_manifest_invalid",{"detail":declaration})
	var selected: Array = []
	var bounds: Array = protected.duplicate(true)
	if not declaration.records.is_empty():
		var current := _physical(source,continuation)
		if not current.ready: return current
		if frozen!=current.sourceBytes or frozen!=var_to_bytes(source.snapshot()): return _fail("bunting_selection_source_changed")
		var checks: Dictionary = {}
		for row: Dictionary in current.report.checks:
			if checks.has(row.partId): return _fail("duplicate_bunting_source_check")
			checks[row.partId]=row.passed
		for assembly: Dictionary in declaration.records:
			var members: Array = [assembly.ropeId]; members.append_array(assembly.pennantIds)
			var failed := false
			for id: String in members:
				if not checks.has(id): return _fail("missing_bunting_source_check")
				failed=failed or not checks[id]
			if not failed: continue
			var record: Dictionary = assembly.duplicate(true)
			var owners: Variant = Manifest.find_part(source,assembly.ropeId).recipe.get("buntingMarketOwners")
			if owners!=null:
				if not owners is Dictionary or owners.size()!=3: return _fail("invalid_bunting_market_owners")
				for key: String in ["leftHouseId","rightHouseId","plazaPartId"]:
					if not owners.get(key) is String: return _fail("invalid_bunting_market_owners")
				var domain: Dictionary = BuntingDomain.build(source,owners.leftHouseId,owners.rightHouseId,owners.plazaPartId)
				if not domain.ready: return _fail("bunting_market_domain_failed",{"detail":domain})
				record["placementDomain"]=domain.domain
				for room_bounds: AABB in domain.protectedRooms:
					if not bounds.has(room_bounds): bounds.append(room_bounds)
			selected.append(record)
	var snapshot: Dictionary = source.snapshot()
	var details := {}
	if not selected.is_empty():
		var proposal := BuntingAnchors.prepare(source,selected,bounds,continuation)
		if proposal.get("reason","")=="cancelled": return _fail("cancelled")
		if not proposal.ready: return _fail("bunting_completion_failed",{"detail":proposal})
		if proposal.sourceBytes!=frozen or var_to_bytes(source.snapshot())!=frozen: return _fail("bunting_proposal_source_changed")
		var owned: Dictionary = {}
		for record: Dictionary in selected:
			owned[record.ropeId]=true
			for id: String in record.pennantIds: owned[id]=true
		var replacements: Dictionary = {}
		for record: Dictionary in proposal.changes:
			if not owned.has(record.id) or replacements.has(record.id): return _fail("foreign_bunting_replacement")
			replacements[record.id]=record
		# Replace only existing owned records. All other geometry, passing
		# assemblies, rooms, furniture policy and recipe metadata stay byte-exact.
		for index in range(snapshot.parts.size()):
			var id: String=snapshot.parts[index].id
			if replacements.has(id): snapshot.parts[index]=replacements[id].duplicate(true); replacements.erase(id)
		if not replacements.is_empty(): return _fail("missing_bunting_replacement")
		details=proposal.duplicate(true); details.erase("changes"); details.erase("sourceBytes")
	if not _continue(continuation,"bunting_completion_completed"): return _fail("cancelled")
	if frozen!=var_to_bytes(source.snapshot()) or inputs!=var_to_bytes(protected): return _fail("bunting_completion_inputs_changed")
	return {"ready":true,"kind":"bunting","afterSnapshot":snapshot,"assemblies":selected,
		"protectedBounds":bounds,"sourceSha256":_sha256(frozen),"details":details}

static func _verify_final_bunting(proof, stage: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	var verified := BuntingAnchors.verify_stored(proof,stage.assemblies,stage.protectedBounds,continuation)
	if verified.get("reason","")=="cancelled": return _fail("cancelled")
	if not verified.ready:return _fail("terminal_bunting_invalid",{"detail":verified})
	return verified

static func _complete_thresholds(source, records: Array, obstacles: Array, continuation: Callable = Callable()) -> Dictionary:
	if not _continue(continuation, "threshold_started"): return _fail("cancelled")
	var frozen_records := var_to_bytes(records)
	var frozen_obstacles := var_to_bytes(obstacles)
	var working = Copy.copy_blueprint(source.snapshot())
	Copy.clear_caches(working)
	var proof_source_bytes := var_to_bytes(working.snapshot())
	var initial := _physical(working, continuation)
	if not initial.ready: return initial
	var validation_events: Array = [{"phase": "initial", "sourceSha256": _sha256(proof_source_bytes)}]
	# _physical records bytes before its private proof classifies any fresh part.
	if proof_source_bytes != initial.sourceBytes or proof_source_bytes != var_to_bytes(working.snapshot()):
		return _threshold_failure("threshold_proof_source_binding_failed", {}, [], validation_events)
	initial.erase("sourceBytes")
	var checks: Dictionary = {}
	var initially_passing: Array = []
	for row: Dictionary in initial.report.checks:
		if checks.has(row.partId): return _threshold_failure("duplicate_threshold_stage_check", {}, [], validation_events)
		checks[row.partId] = row
		if row.passed: initially_passing.append(row.partId)
	var selected: Array = []
	for record: Dictionary in records:
		var threshold_id: Variant = record.get("threshold", {}).get("id")
		if not threshold_id is String or not checks.has(threshold_id):
			return _threshold_failure("missing_manifest_threshold_check", {}, [], validation_events)
		if not checks[threshold_id].passed: selected.append({"id": threshold_id, "record": record.duplicate(true), "check": checks[threshold_id].duplicate(true)})
	selected.sort_custom(func(a, b): return a.id < b.id)
	var accepted: Array = []
	var details: Array = []
	var permitted_threshold_edits: Dictionary = {}
	for item: Dictionary in selected:
		if not _continue(continuation, "threshold_item:" + String(item.id)): return _fail("cancelled")
		var current_snapshot: Dictionary = working.snapshot()
		var binding := {"partId": item.id, "check": item.check.duplicate(true),
			"proofSourceBytes": proof_source_bytes, "currentSourceBytes": var_to_bytes(current_snapshot),
			"proofChecks": checks, "permittedThresholdEdits": permitted_threshold_edits}
		var result := Thresholds._prepare_bound(current_snapshot, item.record, obstacles, binding)
		if not _continue(continuation, "threshold_item_completed:" + String(item.id)): return _fail("cancelled")
		if not result.ready or not result.changed or result.get("globalPhysicalValidations", -1) != 0:
			return _threshold_failure("threshold_completion_failed",
				{"id": item.id, "detail": _without_snapshot(result)}, accepted, validation_events)
		working = Copy.copy_blueprint(result.afterSnapshot)
		permitted_threshold_edits[item.id] = var_to_bytes(Thresholds._snapshot_part(result.afterSnapshot, item.id))
		accepted.append(item.id)
		details.append(_without_snapshot(result))
	var final_source_bytes := var_to_bytes(working.snapshot())
	var final := _physical(working, continuation)
	if final.get("reason", "") == "cancelled": return final
	if not final.ready:
		return _threshold_failure("threshold_final_validation_failed", {"detail": final}, accepted, validation_events)
	validation_events.append({"phase": "final", "sourceSha256": _sha256(final_source_bytes)})
	if final.sourceBytes != final_source_bytes:
		return _threshold_failure("threshold_final_proof_source_binding_failed", {}, accepted, validation_events)
	final.erase("sourceBytes")
	var final_checks: Dictionary = {}
	for row: Dictionary in final.report.checks:
		if final_checks.has(row.partId):
			return _threshold_failure("duplicate_final_threshold_check", {}, accepted, validation_events)
		final_checks[row.partId] = row
	for id: String in initially_passing:
		if not final_checks.has(id) or not final_checks[id].passed:
			return _threshold_failure("threshold_completion_regressed_source", {"partId": id}, accepted, validation_events)
	for id: String in accepted:
		var bearing_id := id + "_bearing"
		if not final_checks.has(id) or not final_checks[id].passed or not final_checks.has(bearing_id) or not final_checks[bearing_id].passed:
			return _threshold_failure("threshold_completion_unproven", {"partId": id}, accepted, validation_events)
	for detail: Dictionary in details:
		var course_ids: Array = detail.get("courseIds", [])
		if course_ids.is_empty() or course_ids.size() > 2:
			return _threshold_failure("threshold_course_inventory_missing", {}, accepted, validation_events)
		for course_id: String in course_ids:
			if not final_checks.has(course_id) or not final_checks[course_id].passed:
				return _threshold_failure("threshold_course_unproven", {"partId": course_id}, accepted, validation_events)
	if frozen_records != var_to_bytes(records) or frozen_obstacles != var_to_bytes(obstacles):
		return _threshold_failure("threshold_completion_mutated_inputs", {}, accepted, validation_events)
	var source_sha := _sha256(proof_source_bytes)
	if source_sha.length() != 64:
		return _threshold_failure("threshold_proof_source_hash_failed", {}, accepted, validation_events)
	if not _continue(continuation, "threshold_completed"): return _fail("cancelled")
	return {"ready": true, "kind": "threshold", "acceptedIds": accepted, "selectedIds": selected.map(func(item): return item.id),
		"attempts": selected.size(), "details": details, "globalPhysicalValidations": validation_events.size(), "validationEvents": validation_events,
		"proofSourceByteCount": proof_source_bytes.size(), "proofSourceSha256": source_sha,
		"afterSnapshot": working.snapshot(), "_terminalProof": final}

static func _threshold_failure(reason: String, detail: Dictionary, accepted: Array, validation_events: Array) -> Dictionary:
	var evidence := detail.duplicate(true)
	evidence["acceptedIdsBeforeFailure"] = accepted.duplicate()
	evidence["globalPhysicalValidations"] = validation_events.size()
	evidence["validationEvents"] = validation_events.duplicate(true)
	return _fail(reason, evidence)

static func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(bytes) != OK: return ""
	return context.finish().hex_encode()

static func _complete_chimneys(working, records: Array, obstacles: Array, continuation: Callable = Callable()) -> Dictionary:
	if not _continue(continuation, "chimney_started"): return _fail("cancelled")
	var physical := _physical(working, continuation)
	if not physical.ready: return physical
	var accepted: Array = []
	var pending: Array = []
	var attempts := 0
	for record: Dictionary in records:
		var chimney: Dictionary = record.chimney
		if not _continue(continuation, "chimney_item:" + String(chimney.id)): return _fail("cancelled")
		if not physical.failedIds.has(chimney.id): continue
		attempts += 1
		if attempts > MAX_STAGE_ATTEMPTS: return _fail("chimney_attempt_limit")
		var result := Chimneys.apply(working, chimney.id, chimney.gableIds, chimney.upstreamIds, obstacles)
		if not _continue(continuation, "chimney_item_completed:" + String(chimney.id)): return _fail("cancelled")
		if result.ready:
			accepted.append(chimney.id)
		elif result.reason == "no_clear_bearing_candidate":
			pending.append({"id": chimney.id, "reason": result.reason, "detail": result})
		else:
			return _fail("chimney_completion_failed", {"id": chimney.id, "detail": result})
	return {"ready": true, "kind": "chimney", "acceptedIds": accepted, "pending": pending, "attempts": attempts}

static func _complete_brackets(working, records: Array, kind: String, continuation: Callable = Callable()) -> Dictionary:
	if not _continue(continuation, kind + "_started"): return _fail("cancelled")
	var physical := _physical(working, continuation)
	if not physical.ready: return physical
	var proof = physical.proof
	var accepted: Array = []
	var pending: Array = []
	var attempts := 0
	for record: Dictionary in records:
		var facades := _facade_parts(working, record.facadeDeclarationKeys)
		if not facades.ready: return facades
		for id: String in record.bracketIds:
			if not _continue(continuation, kind + "_item:" + id): return _fail("cancelled")
			if not physical.failedIds.has(id): continue
			attempts += 1
			if attempts > MAX_STAGE_ATTEMPTS: return _fail("bracket_attempt_limit")
			var bracket = Manifest.find_part(working, id)
			var door = Manifest.find_part(working, record.doorId)
			var hood = Manifest.find_part(working, record.hoodId)
			var plan := Brackets.prepare(working, bracket, door, hood, facades.parts)
			if not _continue(continuation, kind + "_item_completed:" + id): return _fail("cancelled")
			if plan.ready:
				var pier = proof.find_part(plan.pierId)
				if pier == null or not proof.has_rooted_support_chain(pier, {}):
					pending.append({"id": id, "reason": "selected_pier_not_rooted"})
					continue
				bracket.position = plan.part.position
				accepted.append(id)
			elif plan.reason in ["no_solid_door_side_pier", "ambiguous_pier", "missing_exact_pier_contact", "missing_exact_hood_contact"]:
				pending.append({"id": id, "reason": plan.reason})
			else:
				return _fail("bracket_completion_failed", {"id": id, "detail": plan})
	return {"ready": true, "kind": kind, "acceptedIds": accepted, "pending": pending, "attempts": attempts}

static func _complete_signs(working, records: Array, protected: Array, continuation: Callable = Callable()) -> Dictionary:
	if not _continue(continuation, "signs_started"): return _fail("cancelled")
	var physical := _physical(working, continuation)
	if not physical.ready: return physical
	var proof = physical.proof
	var accepted: Array = []
	var preserved: Array = []
	var pending: Array = []
	var attempts := 0
	for record: Dictionary in records:
		if record.signAssembly.is_empty(): continue
		if not _continue(continuation, "sign_item:" + String(record.signAssembly.armId)): return _fail("cancelled")
		attempts += 1
		if attempts > MAX_STAGE_ATTEMPTS: return _fail("sign_attempt_limit")
		var anchors := _sign_anchor_parts(proof, record)
		if not anchors.ready: return anchors
		var sign: Dictionary = record.signAssembly
		var arm = proof.find_part(sign.armId)
		var board = proof.find_part(sign.boardId)
		var door = proof.find_part(record.doorId)
		var result := Signs.propose(proof, arm, board, door, record.facadeDeclarationKeys, protected, anchors.parts)
		if not _continue(continuation, "sign_item_completed:" + String(sign.armId)): return _fail("cancelled")
		if result.ready:
			if result.mode == "existing_clear_exact":
				preserved.append(sign.armId)
				continue
			# One commit of the proven records; do not reset the old capped planner's
			# origin and re-run it. The proof copy also sees earlier accepted signs.
			for target in [proof,working]:
				var target_arm = Manifest.find_part(target, sign.armId)
				var target_board = Manifest.find_part(target, sign.boardId)
				target_arm.position = result.armRecord.position
				target_arm.recipe["physicalRequiredAnchorPartIds"] = result.armRecord.recipe.physicalRequiredAnchorPartIds.duplicate(true)
				target_arm.recipe["physicalRequiredAnchorFacts"] = result.armRecord.recipe.physicalRequiredAnchorFacts.duplicate(true)
				target_board.position = result.boardRecord.position
			accepted.append(sign.armId)
		elif result.reason == "no_initial_placement_in_bounded_candidates":
			pending.append({"id": sign.armId, "reason": result.reason, "detail": result})
		else:
			return _fail("sign_completion_failed", {"id": sign.armId, "detail": result})
	if not pending.is_empty():
		return _fail("sign_initial_placement_unresolved", {"kind":"sign","pending":pending,"acceptedIds":accepted,"preservedIds":preserved,"attempts":attempts})
	return {"ready": true, "kind": "sign", "acceptedIds": accepted, "preservedIds":preserved,"pending": pending, "attempts": attempts}


static func _verify_final_signs(proof, records: Array, protected: Array, continuation: Callable = Callable()) -> Dictionary:
	if not _continue(continuation, "final_signs_started"): return _fail("cancelled")
	for record: Dictionary in records:
		if not _continue(continuation, "final_sign_item:" + String(record.doorId)): return _fail("cancelled")
		if record.signAssembly.is_empty(): continue
		var sign: Dictionary = record.signAssembly
		var result := Signs.propose(proof, proof.find_part(sign.armId), proof.find_part(sign.boardId),
			proof.find_part(record.doorId), record.facadeDeclarationKeys, protected)
		if not result.ready or result.get("mode", "") != "existing_clear_exact":
			return _fail("final_sign_source_invalid", {"id":sign.armId,"detail":result})
	return {"ready":true}

static func _complete_party_walls(working, records: Array, continuation: Callable = Callable()) -> Dictionary:
	var expected_source := var_to_bytes(working.snapshot())
	if not _continue(continuation, "party_walls_started"): return _fail("cancelled")
	if expected_source!=var_to_bytes(working.snapshot()): return _fail("party_wall_source_changed_during_completion")
	var context: Variant=null
	var context_builds := 0
	var context_reuses := 0
	var context_invalidations := 0
	var independent_validations := 0
	var geometric_rejections := 0
	var accepted: Array = []
	var pending: Array = []
	var attempts := 0
	for record: Dictionary in records:
		for key: String in record.facadeDeclarationKeys:
			if not _continue(continuation, "party_wall_item:" + key): return _fail("cancelled")
			if expected_source!=var_to_bytes(working.snapshot()): return _fail("party_wall_source_changed_during_completion")
			if context==null:
				var prepared := PartyWalls.prepare_context(working,continuation)
				if not prepared.ready: return prepared
				if expected_source!=var_to_bytes(working.snapshot()): return _fail("party_wall_source_changed_during_completion")
				context=prepared.context
				context_builds+=1
			var binding := PartyWalls._context_valid(working,context)
			if not binding.ready: return binding
			var declaration: Dictionary = working.recipe.facadeApertures[key]
			var failed_ids: Array=Copy.failed_ids(context.report)
			if not declaration.partIds.any(func(id): return failed_ids.has(id)): continue
			attempts += 1
			if attempts > MAX_STAGE_ATTEMPTS: return _fail("party_wall_attempt_limit")
			context_reuses+=1
			var before_independent: int=context.independent_validations
			var before_geometric: int=context.geometric_rejections
			var result := PartyWalls.apply(working, key,context,continuation)
			independent_validations+=context.independent_validations-before_independent
			geometric_rejections+=context.geometric_rejections-before_geometric
			if result.get("reason")=="cancelled": return result
			if result.ready:
				# Any accepted declaration changes the source. Rebuild before another
				# failed-ID decision or plan; never reuse pre-mutation support facts.
				context=null
				context_invalidations+=1
				expected_source=var_to_bytes(working.snapshot())
			if not _continue(continuation, "party_wall_item_completed:" + key): return _fail("cancelled")
			if expected_source!=var_to_bytes(working.snapshot()): return _fail("party_wall_source_changed_during_completion")
			if context!=null:
				binding=PartyWalls._context_valid(working,context)
				if not binding.ready: return binding
			if result.ready:
				accepted.append({"declarationKey": key, "targetIds": result.targetIds})
			elif result.reason in ["no_failed_bottom_cohort", "no_finite_rooted_party_wall", "party_wall_without_independently_passing_root"]:
				pending.append({"declarationKey": key, "reason": result.reason, "detail": result})
			else:
				return _fail("party_wall_completion_failed", {"declarationKey": key, "detail": result})
	return {"ready": true, "kind": "party_wall", "accepted": accepted, "pending": pending, "attempts": attempts,
		"sourceProofBuilds":context_builds,"sourceProofReuses":context_reuses,"sourceProofInvalidations":context_invalidations,"independentProofs":independent_validations,"geometricRejections":geometric_rejections}

static func _physical(source, continuation: Callable = Callable()) -> Dictionary:
	if not _continue(continuation, "structural_physical_started"): return _fail("cancelled")
	var source_bytes := var_to_bytes(source.snapshot())
	var proof = Copy.copy_blueprint(source.snapshot())
	Copy.clear_caches(proof)
	var grid := Copy.validation_grid_work(proof)
	if not grid.ready: return _fail("completion_validation_work_limit")
	var report: Dictionary = proof.validate_physical_integrity_cancellable(continuation)
	if report.get("cancelled", false): return _fail("cancelled")
	if not _continue(continuation, "structural_physical_completed"): return _fail("cancelled")
	return {"ready": true, "failedIds": Copy.failed_ids(report), "violations": report.violations,
		"proof": proof, "report": report, "sourceBytes": source_bytes}

static func _facade_parts(source, keys: Array) -> Dictionary:
	var parts: Array = []
	var seen: Dictionary = {}
	for key: String in keys:
		var declaration: Variant = source.recipe.get("facadeApertures", {}).get(key)
		if not declaration is Dictionary or not declaration.get("partIds") is Array: return _fail("missing_completion_facade")
		for id: String in declaration.partIds:
			if seen.has(id): continue
			var part = Manifest.find_part(source, id)
			if part == null: return _fail("missing_completion_facade_part")
			# Opening completion extends the declaration with timber head members.
			# Door brackets and signs consume only its actual masonry facade panels;
			# party-wall completion separately consumes the complete declaration.
			if part.semantic != "citadel_urban_facade": continue
			seen[id] = true
			parts.append(part)
	parts.sort_custom(func(a, b): return a.id < b.id)
	if parts.is_empty(): return _fail("completion_facade_without_masonry_panels")
	return {"ready": true, "parts": parts}

static func _sign_anchor_parts(proof, record: Dictionary) -> Dictionary:
	var ids: Array = record.signAnchorIds.duplicate()
	for key: String in record.facadeDeclarationKeys:
		var declaration: Variant = proof.recipe.get("facadeApertures", {}).get(key)
		if not declaration is Dictionary or not declaration.get("partIds") is Array: return _fail("missing_sign_anchor_declaration")
		for id: String in declaration.partIds:
			if not ids.has(id): ids.append(id)
	ids.sort()
	var parts: Array = []
	for id: String in ids:
		var part = proof.find_part(id)
		if part != null and part.collision_enabled and part.rotation == Vector3.ZERO \
			and part.physical_intent in ["structural_mass", "structural_root"] and proof.has_rooted_support_chain(part, {}):
			parts.append(part)
	if parts.is_empty(): return _fail("no_rooted_sign_anchor_candidates")
	return {"ready": true, "parts": parts}

static func _protected_bounds(source, records: Array, obstacles: Array) -> Dictionary:
	var bounds: Array = []
	if obstacles.size() > 4096: return _fail("protected_obstacle_limit")
	for obstacle: Variant in obstacles:
		if not obstacle is Dictionary or not obstacle.get("bounds") is AABB: return _fail("invalid_protected_obstacle")
		bounds.append(obstacle.bounds)
	for record: Dictionary in records:
		var door = Manifest.find_part(source, record.doorId)
		if door == null: return _fail("missing_completion_door")
		var sweep := DoorGeometry.ordinary_sweep_bounds(door.size, Transform3D(Basis.from_euler(door.rotation), door.position),
			float(door.recipe.get("openSwing", DoorGeometry.DEFAULT_OPEN_SWING)))
		if sweep.is_empty(): return _fail("invalid_completion_door_sweep")
		bounds.append_array(sweep)
	return {"ready": true, "bounds": bounds}

static func _without_snapshot(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	result.erase("afterSnapshot")
	return result

static func _continue(continuation: Callable, stage: String) -> bool:
	return not continuation.is_valid() or continuation.call(stage) == true

static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate(true)
	result["ready"] = false
	result["reason"] = reason
	return result
