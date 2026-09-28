extends "res://scripts/testing/buildings/LowerFacadeBearingRecipeContract.gd"

## SYNTHETIC contract only. Inherits the one SceneTree and fixture helpers;
## overriding _run deliberately excludes every parent source/candidate probe.
## No production scene, publication, furniture relocation, NPC or nav work.
## Caller must supply a fresh absolute .json VOXEL_LOWER_FACADE_BATCH_REPORT.

func _run() -> void:
	var path: String = OS.get_environment("VOXEL_LOWER_FACADE_BATCH_REPORT")
	if not _batch_fresh_path(path):
		quit(2)
		return
	_batch_positive_controls()
	_batch_invalid_controls()
	_batch_partial_controls()
	_batch_sequential_collision()
	_batch_finish_synthetic(path)

func _batch_positive_controls() -> void:
	var fixture: Dictionary = _batch_fixture(2)
	var ids: Array = fixture.panelIds
	var good: Dictionary = _batch_probe("synthetic_two_independent_roots", fixture, ids)
	_batch_expect("synthetic_two_independent_roots", good, ids, [])
	if not good.get("ready", false): return
	_batch_preserved("synthetic_two_independent_roots", fixture, good)
	var seat_ids: Array = []
	for proposal: Dictionary in good.get("accepted", []):
		var root: Dictionary = proposal.get("independentSeatCheck", {})
		seat_ids.append(root.get("partId", ""))
		_checks["synthetic_root_proof_" + proposal.panelId] = root.get("passed", false) and root.get("intent") in ["structural_mass", "structural_root"] and (root.get("reachesGroundRoot", false) or root.get("physicalRoot", false))
		_checks["synthetic_finite_joints_" + proposal.panelId] = proposal.get("additions", []).size() == 3 and proposal.get("checks", []).size() == 4 and proposal.checks.all(func(c): return c.get("passed", false)) and _finite_sockets(proposal)
	_checks["synthetic_distinct_expected_masonry_seats"] = seat_ids == ["synthetic_stone_a", "synthetic_stone_b"]
	var reversed_ids: Array = ids.duplicate()
	reversed_ids.reverse()
	var reverse_request: Dictionary = _batch_probe("synthetic_reversed_request", fixture, reversed_ids)
	_checks["synthetic_request_order_exact_result"] = var_to_bytes(reverse_request) == var_to_bytes(good)
	# Source record order is not a geometry change. Compare by stable part ID;
	# do not require the recipe to reorder the caller's existing source records.
	var reversed_source: Dictionary = fixture.duplicate(true)
	reversed_source.snapshot.parts.reverse()
	var declarations: Dictionary = reversed_source.snapshot.recipe.facadeApertures
	var reverse_declarations: Dictionary = {}
	var keys: Array = declarations.keys()
	keys.reverse()
	for key: String in keys: reverse_declarations[key] = declarations[key]
	reversed_source.snapshot.recipe.facadeApertures = reverse_declarations
	var reverse_result: Dictionary = _batch_probe("synthetic_reversed_source", reversed_source, reversed_ids)
	_batch_expect("synthetic_reversed_source", reverse_result, ids, [])
	_checks["synthetic_source_order_same_proposals"] = var_to_bytes(reverse_result.get("accepted")) == var_to_bytes(good.get("accepted"))
	_checks["synthetic_source_order_same_parts"] = var_to_bytes(_batch_sorted_parts(reverse_result.get("afterSnapshot", {}))) == var_to_bytes(_batch_sorted_parts(good.afterSnapshot))
	_batch_preserved("synthetic_reversed_source", reversed_source, reverse_result)
	# Losing A's foundation must not borrow B's separate ground/root proof.
	var missing_root: Dictionary = fixture.duplicate(true)
	missing_root.snapshot.parts = missing_root.snapshot.parts.filter(func(p): return p.id != "synthetic_foundation_a")
	var root_loss: Dictionary = _batch_probe("synthetic_one_root_removed", missing_root, ids)
	_batch_expect("synthetic_one_root_removed", root_loss, [ids[1]], [ids[0]])
	_batch_preserved("synthetic_one_root_removed", missing_root, root_loss)
	# Four *real fitting* requests proves the inclusive cap, not merely schema.
	var four: Dictionary = _batch_fixture(4)
	var limit_result: Dictionary = _batch_probe("synthetic_four_panel_boundary", four, four.panelIds)
	_batch_expect("synthetic_four_panel_boundary", limit_result, four.panelIds, [])
	_batch_preserved("synthetic_four_panel_boundary", four, limit_result)
	# Returned dictionaries must not alias the input or a later returned batch.
	var frozen: PackedByteArray = var_to_bytes(fixture)
	good.afterSnapshot.recipe["synthetic_output_mutation"] = true
	good.afterSnapshot.rooms[0].bounds = AABB(Vector3(100, 100, 100), Vector3.ONE)
	good.afterSnapshot.parts[0].position = Vector3(100, 100, 100)
	good.accepted[0].additions[0].position = Vector3(100, 100, 100)
	_checks["synthetic_output_mutation_input_isolated"] = var_to_bytes(fixture) == frozen
	var fresh: Dictionary = _batch_probe("synthetic_fresh_after_output_mutation", fixture, ids)
	_checks["synthetic_output_mutation_repeat_isolated"] = var_to_bytes(fresh) == var_to_bytes(reverse_request)

func _batch_invalid_controls() -> void:
	var fixture: Dictionary = _batch_fixture(2)
	var id: String = fixture.panelIds[0]
	var cases: Dictionary = {
		"empty": [], "duplicate": [id, id], "duplicate_after_valid_prefix": [id, fixture.panelIds[1], id],
		"over_four": [id, fixture.panelIds[1], "synthetic_c", "synthetic_d", "synthetic_e"],
		"empty_string": [id, ""], "whitespace": [id, " \t\n"],
		"integer": [id, 7], "null": [id, null], "string_name": [id, StringName("synthetic_name")],
		"dictionary": [id, {"panelId": id}], "nested_array": [id, [id]],
	}
	for label: String in cases:
		var result: Dictionary = _batch_probe("synthetic_invalid_request_" + label, fixture, cases[label])
		_batch_atomic("synthetic_invalid_request_" + label, result)
	# Typed Dictionary/Array API: malformed *contents*, not illegal call types.
	for mode: String in ["snapshot", "policy", "duplicate_part"]:
		var invalid: Dictionary = fixture.duplicate(true)
		match mode:
			"snapshot": invalid.snapshot.erase("rooms")
			"policy": invalid.policy.erase("furnitureParts")
			"duplicate_part": invalid.snapshot.parts.append(invalid.snapshot.parts[0].duplicate(true))
		var result: Dictionary = _batch_probe("synthetic_invalid_" + mode, invalid, invalid.panelIds)
		_batch_atomic("synthetic_invalid_" + mode, result)
	var unknown: Dictionary = _batch_probe("synthetic_missing_panel", fixture, ["synthetic_missing"])
	_batch_expect("synthetic_missing_panel", unknown, [], ["synthetic_missing"])
	_checks["synthetic_missing_panel_reason"] = _batch_rejection(unknown, "synthetic_missing").get("reason") == "missing_panel"

func _batch_partial_controls() -> void:
	# Block first, then last: a rejection must neither abort later work nor
	# remove an earlier acceptance. Same IDs/source with changed policy also
	# exposes a stale result reused without the current protected contents.
	for blocked_index in range(2):
		var fixture: Dictionary = _batch_fixture(2)
		var ids: Array = fixture.panelIds
		var blocked_id: String = ids[blocked_index]
		var fit_id: String = ids[1 - blocked_index]
		fixture.policy.furnitureParts.append(_batch_blocking_furniture(blocked_index))
		var label: String = "synthetic_furniture_partial_" + str(blocked_index)
		var result: Dictionary = _batch_probe(label, fixture, ids)
		_batch_expect(label, result, [fit_id], [blocked_id])
		_batch_preserved(label, fixture, result)
		var single: Dictionary = _batch_single(fixture, blocked_id, label)
		var rejection: Dictionary = _batch_rejection(result, blocked_id)
		_checks[label + "_exact_rejection_provenance"] = not single.get("ready", false) and rejection.get("reason") == "protected_volume_blocked" and single.get("blockingPartId") == "furniture:synthetic_blocking_chest_" + str(blocked_index) and var_to_bytes(rejection.get("evidence")) == var_to_bytes(single)
	var blocked: Dictionary = _batch_fixture(2)
	for index in range(2): blocked.policy.furnitureParts.append(_batch_blocking_furniture(index))
	var none: Dictionary = _batch_probe("synthetic_all_blocked", blocked, blocked.panelIds)
	_batch_expect("synthetic_all_blocked", none, [], blocked.panelIds)
	_checks["synthetic_all_blocked_explicit_reasons"] = none.get("rejected", []).size() == 2 and none.rejected.all(func(row): return row.get("reason") == "protected_volume_blocked")
	# A protected declared opening is not furniture and must stay authoritative.
	var aperture: Dictionary = _batch_fixture(2)
	var declaration: Dictionary = aperture.snapshot.recipe.facadeApertures.synthetic_upper_a
	declaration.openings[0].fullVolume = AABB(Vector3(-0.15, 2.2, -0.3), Vector3(0.3, 1, 0.6))
	declaration.erase("sourceBinding")
	aperture.snapshot.recipe.facadeApertures.synthetic_upper_a = Recipe.Aperture.seal(declaration, [Part.new(aperture.snapshot.parts[2])])
	var aperture_result: Dictionary = _batch_probe("synthetic_aperture_partial", aperture, aperture.panelIds)
	_batch_expect("synthetic_aperture_partial", aperture_result, [aperture.panelIds[1]], [aperture.panelIds[0]])
	_batch_preserved("synthetic_aperture_partial", aperture, aperture_result)
	var aperture_rejection: Dictionary = _batch_rejection(aperture_result, aperture.panelIds[0])
	_checks["synthetic_aperture_rejection_provenance"] = aperture_rejection.get("reason") == "protected_volume_blocked" and aperture_rejection.get("evidence", {}).get("blockingPartId") == "aperture:synthetic_opening_a"

func _batch_sequential_collision() -> void:
	# Deliberately coincident synthetic panels, not a real-citadel fixture.
	# Each independently fits the SAME original masonry. The first new sill
	# occupies the second's proposed volume, which staged admission must see.
	var fixture: Dictionary = _batch_fixture(1)
	var first_id: String = fixture.panelIds[0]
	var second: Dictionary = fixture.snapshot.parts[2].duplicate(true)
	second.id = "synthetic_upper_panel_b"
	fixture.snapshot.parts.append(second)
	fixture.panelIds.append(second.id)
	var declaration: Dictionary = fixture.snapshot.recipe.facadeApertures.synthetic_upper_a.duplicate(true)
	declaration.producerPrefix = "synthetic_upper_b"
	declaration.openings[0].id = "synthetic_opening_b"
	declaration.erase("sourceBinding")
	# A new dot-assigned Dictionary key is a StringName, not the String
	# required by the production declaration schema. Existing-key writes above
	# preserve their key type; this NEW declaration needs an explicit String.
	fixture.snapshot.recipe.facadeApertures["synthetic_upper_b"] = Recipe.Aperture.seal(declaration, [Part.new(second)])
	_checks["synthetic_collision_declaration_keys_are_strings"] = fixture.snapshot.recipe.facadeApertures.keys().all(func(key): return key is String)
	var first: Dictionary = _batch_single(fixture, first_id, "synthetic_collision_first_alone")
	var other: Dictionary = _batch_single(fixture, second.id, "synthetic_collision_second_alone")
	_checks["synthetic_collision_both_fit_original_source"] = first.get("ready", false) and other.get("ready", false)
	var result: Dictionary = _batch_probe("synthetic_sequential_new_collider", fixture, [second.id, first_id])
	_batch_expect("synthetic_sequential_new_collider", result, [first_id], [second.id])
	_batch_preserved("synthetic_sequential_new_collider", fixture, result)
	var forward: Dictionary = _batch_probe("synthetic_sequential_forward_order", fixture, [first_id, second.id])
	_checks["synthetic_collision_sorted_winner_not_request_order"] = var_to_bytes(forward) == var_to_bytes(result)
	if not first.get("ready", false): return
	var staged: Dictionary = {"snapshot": first.afterSnapshot, "policy": fixture.policy}
	var expected: Dictionary = _batch_single(staged, second.id, "synthetic_collision_second_after_first")
	var rejection: Dictionary = _batch_rejection(result, second.id)
	_checks["synthetic_collision_exact_added_sill_blocker"] = expected.get("reason") == "foreign_solid_blocked" and expected.get("blockingPartId") == first_id + "_lower_bearing"
	_checks["synthetic_collision_explicit_staged_provenance"] = rejection.get("reason") == expected.get("reason") and var_to_bytes(rejection.get("evidence")) == var_to_bytes(expected)
	_checks["synthetic_collision_no_rejected_partial_additions"] = var_to_bytes(result.get("afterSnapshot")) == var_to_bytes(first.afterSnapshot)

func _batch_fixture(count: int) -> Dictionary:
	var combined: Dictionary = {}
	var ids: Array = []
	for index in range(count):
		var fixture: Dictionary = _fixture()
		var suffix: String = "_" + ["a", "b", "c", "d"][index]
		var offset := Vector3(0, 0, index * 8)
		for record: Dictionary in fixture.snapshot.parts:
			record.id += suffix
			record.position += offset
		var panel: Dictionary = fixture.snapshot.parts[2]
		var declaration: Dictionary = fixture.snapshot.recipe.facadeApertures.synthetic_upper.duplicate(true)
		declaration.producerPrefix += suffix
		declaration.wallDomain = AABB(declaration.wallDomain.position + offset, declaration.wallDomain.size)
		declaration.openings[0].id += suffix
		declaration.openings[0].input.centerZ += offset.z
		declaration.openings[0].fullVolume = AABB(declaration.openings[0].fullVolume.position + offset, declaration.openings[0].fullVolume.size)
		declaration.erase("sourceBinding")
		fixture.snapshot.recipe.facadeApertures = {declaration.producerPrefix: Recipe.Aperture.seal(declaration, [Part.new(panel)])}
		if combined.is_empty(): combined = fixture
		else:
			combined.snapshot.parts.append_array(fixture.snapshot.parts)
			combined.snapshot.recipe.facadeApertures.merge(fixture.snapshot.recipe.facadeApertures)
		ids.append(panel.id)
	combined.erase("panelId")
	combined["panelIds"] = ids
	combined.snapshot.rooms.append({"id": "synthetic_kept_room", "bounds": AABB(Vector3(20, 0, 20), Vector3(4, 3, 4)), "accesses": []})
	combined.policy.furnitureParts.append({"id": "synthetic_kept_chest", "position": Vector3(21, 0, 21), "size": Vector3.ONE, "rotation": Vector3.ZERO, "recipe": {"synthetic_contents": ["unchanged"]}})
	combined.policy.reservedVolumes.append(AABB(Vector3(24, 0, 24), Vector3.ONE))
	return combined

func _batch_blocking_furniture(index: int) -> Dictionary:
	return {"id": "synthetic_blocking_chest_" + str(index), "position": Vector3(0, 2.2, index * 8), "size": Vector3(0.5, 0.5, 0.5), "rotation": Vector3.ZERO, "recipe": {}}

func _batch_single(fixture: Dictionary, id: String, label: String) -> Dictionary:
	var frozen: PackedByteArray = var_to_bytes(fixture)
	var result: Dictionary = Recipe.prepare(fixture.snapshot, id, fixture.policy)
	_checks[label + "_single_input_immutable"] = frozen == var_to_bytes(fixture)
	return result

func _batch_probe(label: String, fixture: Dictionary, ids: Array) -> Dictionary:
	var frozen: PackedByteArray = var_to_bytes([fixture, ids])
	var result: Dictionary = Recipe.prepare_batch(fixture.snapshot, ids, fixture.policy)
	_checks[label + "_input_immutable"] = frozen == var_to_bytes([fixture, ids])
	var repeat: Dictionary = Recipe.prepare_batch(fixture.snapshot, ids, fixture.policy)
	_checks[label + "_repeat_exact_and_immutable"] = var_to_bytes(result) == var_to_bytes(repeat) and frozen == var_to_bytes([fixture, ids])
	var summary: Dictionary = result.duplicate(true)
	summary.erase("afterSnapshot")
	_results[label] = summary
	return result

func _batch_expect(label: String, result: Dictionary, accepted_ids: Array, rejected_ids: Array) -> void:
	var ready: bool = not accepted_ids.is_empty()
	_checks[label + "_ready_iff_accepted"] = result.get("ready") is bool and result.ready == ready and result.has("afterSnapshot") == ready
	var accepted: Variant = result.get("accepted")
	var rejected: Variant = result.get("rejected")
	_checks[label + "_explicit_arrays"] = accepted is Array and rejected is Array
	if not accepted is Array or not rejected is Array: return
	var schema: bool = accepted.all(func(row): return row is Dictionary and row.get("panelId") is String and row.get("ready") == true and not row.has("afterSnapshot")) and rejected.all(func(row): return row is Dictionary and row.get("panelId") is String and row.get("reason") is String and not row.reason.is_empty() and not row.has("afterSnapshot"))
	_checks[label + "_row_schema_no_nested_candidate"] = schema
	if not schema: return
	_checks[label + "_exact_accepted_ids"] = accepted.map(func(row): return row.panelId) == accepted_ids
	_checks[label + "_exact_rejected_ids"] = rejected.map(func(row): return row.panelId) == rejected_ids
	if not rejected_ids.is_empty():
		_checks[label + "_rejections_never_all_accepted"] = result.get("allRequestedAccepted", false) == false
	if ready:
		_checks[label + "_partial_not_all_accepted"] = result.get("allRequestedAccepted") == rejected_ids.is_empty()
		var requested: Array = accepted_ids + rejected_ids
		requested.sort()
		_checks[label + "_sorted_request_ids"] = result.get("requestedPanelIds") == requested
		_checks[label + "_explicit_scope"] = result.get("scope") is String and not result.scope.is_empty()

func _batch_atomic(label: String, result: Dictionary) -> void:
	_checks[label + "_atomic_no_candidate"] = result.get("ready") == false and not result.has("afterSnapshot") and not result.has("additions") and result.get("accepted", []) == []
	_checks[label + "_explicit_reason"] = result.get("reason") is String and not result.reason.is_empty()

func _batch_rejection(result: Dictionary, id: String) -> Dictionary:
	for row: Variant in result.get("rejected", []):
		if row is Dictionary and row.get("panelId") == id: return row
	return {}

func _batch_preserved(label: String, fixture: Dictionary, result: Dictionary) -> void:
	_checks[label + "_candidate_present_for_preservation"] = result.get("afterSnapshot") is Dictionary
	if not result.get("afterSnapshot") is Dictionary: return
	var after: Dictionary = result.afterSnapshot
	_checks[label + "_source_identity_unchanged"] = after.get("id") == fixture.snapshot.id and after.get("seed") == fixture.snapshot.seed and after.get("style") == fixture.snapshot.style
	_checks[label + "_rooms_and_apertures_byte_exact"] = var_to_bytes(after.get("rooms")) == var_to_bytes(fixture.snapshot.rooms) and var_to_bytes(after.get("recipe")) == var_to_bytes(fixture.snapshot.recipe)
	var by_id: Dictionary = {}
	for record: Dictionary in after.get("parts", []): by_id[record.id] = record
	var expected: Dictionary = {}
	for record: Dictionary in fixture.snapshot.parts: expected[record.id] = record
	var geometry_ok := true
	for proposal: Dictionary in result.get("accepted", []):
		geometry_ok = geometry_ok and var_to_bytes(Recipe.Aperture._geometry(Part.new(proposal.panel))) == var_to_bytes(Recipe.Aperture._geometry(Part.new(expected[proposal.panelId])))
		expected[proposal.panelId] = proposal.panel
		for record: Dictionary in proposal.additions:
			geometry_ok = geometry_ok and not expected.has(record.id)
			expected[record.id] = record
	_checks[label + "_source_geometry_unchanged_unique_additions"] = geometry_ok
	var exact: bool = by_id.size() == expected.size() and after.parts.size() == expected.size()
	for id: String in expected: exact = exact and var_to_bytes(by_id.get(id)) == var_to_bytes(expected[id])
	_checks[label + "_only_accepted_changes_untouched_rejections"] = exact
	var parts: Dictionary = {}
	for id: String in by_id: parts[id] = Part.new(by_id[id])
	_checks[label + "_unchanged_aperture_bindings_valid"] = after.recipe.facadeApertures.values().all(func(d): return Recipe.Aperture.validate(d, parts))
	var protected: Dictionary = Recipe._protected(after, fixture.policy, parts.values())
	var clear: bool = protected.get("ready", false)
	var volumes: Array = protected.get("volumes", []).duplicate(true)
	for declaration: Dictionary in after.recipe.facadeApertures.values():
		for opening: Dictionary in declaration.openings: volumes.append({"id": opening.id, "bounds": opening.fullVolume})
	for proposal: Dictionary in result.get("accepted", []):
		for record: Dictionary in proposal.additions: clear = clear and Recipe._admit(Part.new(record), [], volumes).get("ready", false)
	_checks[label + "_added_parts_clear_unchanged_furniture_apertures_reservations"] = clear

func _batch_sorted_parts(snapshot: Dictionary) -> Array:
	var parts: Array = snapshot.get("parts", []).duplicate(true)
	parts.sort_custom(func(a, b): return a.id < b.id)
	return parts

func _batch_fresh_path(path: String) -> bool:
	return path.is_absolute_path() and path.get_extension() == "json" and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path) and DirAccess.dir_exists_absolute(path.get_base_dir())

func _batch_finish_synthetic(path: String) -> void:
	var passed: bool = not _checks.is_empty() and _checks.values().all(func(value): return value == true)
	var report: Dictionary = {"passed": passed, "checks": _checks, "results": _results,
		"evidenceLevel": "synthetic_lower_facade_batch_contract_only",
		"passMeaning": "Synthetic API assertions, including EXPECTED rejection controls. Not every panel fits; each result retains its own ready, accepted and rejected state.",
		"limitations": "No real candidate, gate-zero, engine scene, rendered visuals, published collision, engineering capacity, performance, NPC, navigation or gameplay acceptance. Furniture and apertures checked as source records/protected volumes only."}
	var bytes: PackedByteArray = JSON.stringify(report, "\t").to_utf8_buffer()
	if not _batch_fresh_path(path):
		quit(2)
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_buffer(bytes)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_position() == bytes.size()
	file.close()
	var hash := HashingContext.new()
	written = written and hash.start(HashingContext.HASH_SHA256) == OK
	if written:
		written = hash.update(bytes) == OK
		if written: written = FileAccess.get_sha256(path) == hash.finish().hex_encode()
	quit(0 if passed and written else 1)
