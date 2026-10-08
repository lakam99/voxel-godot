extends SceneTree

const Adapter := preload("res://scripts/world/EcologySectionValueAdapter.gd")
const Ledger := preload("res://scripts/world/EcologySourceValueLedger.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const AdapterFixture := preload("res://scripts/testing/world/EcologySectionValueAdapterContract.gd")
const SECTION := Vector3i.ZERO
const CHUNK_KEY := Vector2i.ZERO
const CLOSURE_SECTION := Vector3i(-1, 1, 0)
const CLOSURE_KEYS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(0, 0)]
const FAR_OWNER := Vector2i(-3, -3)


class Authority extends Node:
	var seed_text := "ecology-source-owner-discovery-contract"
	var seed_hash := 83
	var terrain_revision := 0
	var removed_props_revision := 0
	var removed_props := {}
	var underground_required := false
	var chunks: Dictionary = {}

	func _ecology_chunk_source_revision(key: Vector2i) -> String:
		return "source-owner-discovery:%s:%d,%d" % [seed_text, key.x, key.y]

	func visible_world_underground_visuals_required() -> bool:
		return underground_required

	func detail_mesh(_detail_type: String) -> Mesh:
		return BoxMesh.new()

	func detail_material(_detail_type: String) -> Material:
		return StandardMaterial3D.new()


var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var valid_source := _case("valid_source")
	var explicit_empty := _case("explicit_empty")
	var absent := _case("absent_metadata")
	var unproven := _case("unproven_metadata")
	var stale_revision := _case("stale_source_revision")
	_check("valid_snapshot_admits_exact_producer_owner_closure",
		valid_source.get("status") == "ready" \
		and valid_source.get("sourceChunks", []) == CLOSURE_KEYS \
		and valid_source.get("admittedOwnerKeys", []) == CLOSURE_KEYS, valid_source)
	_check("explicit_complete_empty_snapshot_is_empty_success",
		explicit_empty.get("status") == "ready" \
		and explicit_empty.get("sourceChunks", []) == CLOSURE_KEYS, explicit_empty)
	_check("absent_snapshot_is_retryable_unknown_not_empty",
		absent.get("status") == "pending" \
		and absent.get("reason") == "ecology_source_owner_discovery_snapshot_missing" \
		and absent.get("classification") == "unknown_not_empty", absent)
	_check("unproven_snapshot_is_retryable_and_never_empty_success",
		unproven.get("status") == "pending" \
		and unproven.get("reason") == "ecology_source_owner_discovery_snapshot_stale" \
		and unproven.get("snapshotValidation", {}).get("status") == "failed", unproven)
	_check("self_consistent_old_source_revision_stays_pending_not_empty",
		stale_revision.get("status") == "pending" \
		and stale_revision.get("reason") == "ecology_source_owner_discovery_snapshot_stale" \
		and stale_revision.get("snapshotValidation", {}).get("status") == "ready" \
		and String(stale_revision.get("snapshotSourceRevision", "")) \
			!= String(stale_revision.get("currentSourceRevision", "")) \
		and stale_revision.get("sourceChunks", []).is_empty(), stale_revision)
	for far_state: String in ["missing", "malformed", "stale"]:
		var far_owner := _closure_case("far_" + far_state)
		_check("far_%s_owner_is_excluded_with_exact_admitted_keys" % far_state,
			far_owner.get("status") == "ready" \
			and far_owner.get("sourceChunks", []) == CLOSURE_KEYS \
			and far_owner.get("admittedOwnerKeys", []) == CLOSURE_KEYS \
			and not far_owner.get("sourceChunks", []).has(FAR_OWNER) \
			and int(far_owner.get("scannedChunkCount", -1)) == CLOSURE_KEYS.size() \
			and int(far_owner.get("closureChunkCount", -1)) == CLOSURE_KEYS.size(), far_owner)
	var closure_unknown := _closure_case("closure_unknown")
	_check("unknown_snapshot_inside_closure_remains_pending",
		closure_unknown.get("status") == "pending" \
		and closure_unknown.get("reason") == "ecology_source_owner_discovery_snapshot_missing" \
		and closure_unknown.get("chunk") == Vector2i(0, -1), closure_unknown)
	var source_detail := _closure_case("source_detail")
	_check("surface_detail_owner_is_in_candidate_origin_closure",
		source_detail.get("status") == "ready" \
		and source_detail.get("sourceChunks", []).has(Vector2i(0, 0)) \
		and source_detail.get("detailCandidateCount", 0) == 1, source_detail)
	var member_aabb := _member_aabb_case()
	_check("static_prop_support_uses_exact_transformed_mesh_aabb",
		member_aabb.get("status") == "ready" \
		and member_aabb.get("actualMeshBounds") == member_aabb.get("capturedWorldBounds") \
		and member_aabb.get("supportSections", []) == member_aabb.get("expectedSections", []),
		member_aabb)
	var boundary := _closure_boundary_case()
	_check("negative_half_open_section_and_stream_chunk_bounds_are_exact",
		boundary.get("directOwners", []) == [Vector2i(-1, 0)] \
		and boundary.get("expandedOwners", []) == CLOSURE_KEYS \
		and boundary.get("negativeExpandedOwners", []) == [Vector2i(-2, -1),
			Vector2i(-2, 0), Vector2i(-1, -1), Vector2i(-1, 0)], boundary)
	var replay := _prior_owner_replay_case()
	_check("unloaded_prior_owner_stays_pending_then_recreated_tombstone_emits_empty_replacement",
		replay.get("unloadedStatus") == "pending" \
		and replay.get("unloadedReason") == "ecology_source_owner_discovery_chunk_owner_missing" \
		and replay.get("recreatedStatus") == "complete" \
		and replay.get("recreatedIncludesPriorOwner", false) \
		and replay.get("explicitOldSectionRemoval", false), replay)
	_check("same_id_relocation_removes_old_section_and_new_section_finds_new_owner",
		replay.get("initialCanonicalSourceAccepted", false) \
		and replay.get("oldSectionRemovalStatus") == "complete" \
		and replay.get("newSectionStatus") == "ready" \
		and replay.get("newSectionOwners", []) == [Vector2i(2, 2)] \
		and not String(replay.get("newCompiledSourceId", "")).is_empty() \
		and replay.get("newCompiledSourceId") == replay.get("expectedSourceId") \
		and replay.get("residentCandidatePropId", "") == "prop-old", replay)
	var passed := true
	for check: Dictionary in checks.values():
		passed = passed and bool(check.get("passed", false))
	var report := {"schema":"ecology-source-owner-discovery-contract/v2",
		"passed":passed, "checks":checks, "checkCount":checks.size(),
		"evidenceLevel":"focused production provider source-owner closure and deletion replay contract; no Main startup or gameplay acceptance"}
	var report_path := OS.get_environment("ECOLOGY_SOURCE_OWNER_DISCOVERY_CONTRACT_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	print("ECOLOGY_SOURCE_OWNER_DISCOVERY_CONTRACT ", JSON.stringify(report))
	quit(0 if passed else 1)


func _case(kind: String) -> Dictionary:
	var main := Authority.new()
	main.seed_text += ":" + kind
	root.add_child(main)
	var owners: Dictionary = {}
	for key: Vector2i in CLOSURE_KEYS:
		var closure_owner := Node3D.new()
		main.add_child(closure_owner)
		main.chunks[key] = closure_owner
		owners[key] = closure_owner
		_snapshot(main, closure_owner, false, key)
	var owner: Node3D = owners[CHUNK_KEY]
	var provider = Adapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	var configured: Dictionary = provider.configure(world_id)
	var bound: Dictionary = provider.bind_main_authority(main)
	var snapshot := {}
	match kind:
		"valid_source": snapshot = _snapshot(main, owner, true)
		"explicit_empty": snapshot = _snapshot(main, owner, false)
		"stale_source_revision":
			snapshot = _make_snapshot_stale(main, owner, CHUNK_KEY)
		"absent_metadata": owner.remove_meta("static_ecology_source_value_snapshot")
		"unproven_metadata": owner.set_meta("static_ecology_source_value_snapshot", {
			"schema":"ecology-source-values/v1", "status":"ready", "chunk":CHUNK_KEY,
			"producerOwnerInstanceId":owner.get_instance_id(), "candidates":[],
			"worldSeed":main.seed_text, "sourceRevision":"unproven",
			"contentRevision":"unproven"})
	var requested: Array[Vector3i] = [SECTION]
	var result: Dictionary = provider.call("_discover_static_prop_source_chunks", main, requested)
	var result_copy := {"kind":kind, "status":result.get("status", ""),
		"reason":result.get("reason", ""), "classification":result.get("classification", ""),
		"snapshotValidation":result.get("snapshotValidation", {}),
		"snapshotSourceRevision":result.get("snapshotSourceRevision", ""),
		"currentSourceRevision":result.get("currentSourceRevision", ""),
		"sourceChunks":result.get("sourceChunks", []),
		"admittedOwnerKeys":result.get("admittedOwnerKeys", []), "configured":configured,
		"bound":bound, "snapshotStatus":snapshot.get("status", "missing"),
		"snapshotCategories":snapshot.get("completeCategories", [])}
	main.free()
	return result_copy


func _closure_case(kind: String) -> Dictionary:
	var main := Authority.new()
	main.seed_text += ":closure:" + kind
	root.add_child(main)
	for key: Vector2i in CLOSURE_KEYS:
		var owner := Node3D.new()
		main.add_child(owner)
		main.chunks[key] = owner
		if kind == "closure_unknown" and key == Vector2i(0, -1):
			continue
		var with_detail := kind == "source_detail" and key == Vector2i(0, 0)
		_snapshot(main, owner, false, key, "", "", with_detail)
		if kind.begins_with("far_") and key == CLOSURE_KEYS[0]:
			var far_owner := Node3D.new()
			main.add_child(far_owner)
			main.chunks[FAR_OWNER] = far_owner
			match kind.trim_prefix("far_"):
				"missing": pass
				"malformed": far_owner.set_meta("static_ecology_source_value_snapshot", {
					"schema":"ecology-source-values/v1", "status":"ready"})
				"stale": _make_snapshot_stale(main, far_owner, FAR_OWNER)
			# Every far state is deliberately outside the proven owner closure.
	var provider = Adapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	provider.configure(world_id)
	provider.bind_main_authority(main)
	var result: Dictionary = provider.call("_discover_static_prop_source_chunks",
		main, _one_requested_section())
	var detail_count := 0
	if kind == "source_detail":
		var detail_snapshot: Dictionary = main.chunks[Vector2i(0, 0)].get_meta(
			"static_ecology_source_value_snapshot", {})
		for candidate_value: Variant in detail_snapshot.get("candidates", []):
			if candidate_value is Dictionary and String(candidate_value.get("kind", "")) == "surface_detail":
				detail_count += 1
	var copied := {"kind":kind, "status":result.get("status", ""),
		"reason":result.get("reason", ""), "chunk":result.get("chunk", Vector2i(-999, -999)),
		"sourceChunks":result.get("sourceChunks", []),
		"admittedOwnerKeys":result.get("admittedOwnerKeys", []),
		"scannedChunkCount":result.get("scannedChunkCount", -1),
		"closureChunkCount":result.get("closureChunkCount", -1),
		"detailCandidateCount":detail_count}
	main.free()
	return copied


func _closure_boundary_case() -> Dictionary:
	var section_size_meters := Grid.origin_for_key(Vector3i.RIGHT).x
	var section_bounds := AABB(Grid.origin_for_key(CLOSURE_SECTION),
		Vector3.ONE * section_size_meters)
	var expanded := AABB(section_bounds.position - Vector3(5.0, 0.0, 5.0),
		section_bounds.size + Vector3(10.0, 0.0, 10.0))
	var direct := Grid.stream_chunk_keys_intersecting_section(CLOSURE_SECTION)
	var expanded_owners: Array[Vector2i] = \
		Partitioner._stream_chunks_intersecting_bounds(expanded).duplicate()
	var negative_bounds := AABB(Grid.origin_for_key(Vector3i(-2, 1, 0))
		- Vector3(5.0, 0.0, 5.0),
		Vector3.ONE * section_size_meters + Vector3(10.0, 0.0, 10.0))
	var negative_owners: Array[Vector2i] = Partitioner._stream_chunks_intersecting_bounds(
		negative_bounds).duplicate()
	expanded_owners.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x: return a.x < b.x
		return a.y < b.y)
	negative_owners.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x: return a.x < b.x
		return a.y < b.y)
	return {"directOwners":direct, "expandedOwners":expanded_owners,
		"negativeExpandedOwners":negative_owners,
		"sectionBounds":section_bounds, "expandedBounds":expanded,
		"negativeExpandedBounds":negative_bounds}


func _prior_owner_replay_case() -> Dictionary:
	var main := Authority.new()
	main.seed_text += ":prior-owner-replay"
	main.removed_props["prop-old"] = true
	root.add_child(main)
	for key: Vector2i in CLOSURE_KEYS:
		var owner := Node3D.new()
		main.add_child(owner)
		main.chunks[key] = owner
		owner.set_meta("static_ecology_render_resource_bindings", {})
		owner.set_meta("static_ecology_source_value_snapshot", _snapshot(main,
			owner, false, key))
	var provider = Adapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	provider.configure(world_id)
	provider.bind_main_authority(main)
	var prior_source_id := "%s:surface_rocks:prop-old" % main.seed_text
	var prior_row := {"sourceId":prior_source_id, "sourcePartId":prior_source_id,
		"propId":"prop-old", "sourceOwnerChunk":FAR_OWNER,
		"sourceRevision":"prior-r1", "memberId":"old-member"}
	prior_row.make_read_only()
	var prior_rows: Array = [prior_row]
	prior_rows.make_read_only()
	provider.set("_latest_support_ranges_by_section", {CLOSURE_SECTION:{
		prior_source_id:prior_rows}})
	provider.set("_latest_by_section", {CLOSURE_SECTION:{prior_source_id:"prior-r1"}})
	var unloaded: Dictionary = provider.call("_discover_static_prop_source_chunks",
		main, _one_requested_section())
	var far_owner := Node3D.new()
	main.add_child(far_owner)
	main.chunks[FAR_OWNER] = far_owner
	far_owner.set_meta("static_ecology_render_resource_bindings", {})
	far_owner.set_meta("static_ecology_source_value_snapshot",
		_snapshot(main, far_owner, false, FAR_OWNER, prior_source_id))
	var recreated: Dictionary = provider.call("_discover_static_prop_source_chunks", main,
		_one_requested_section())
	var new_owner := Node3D.new()
	main.add_child(new_owner)
	var new_owner_key := Vector2i(2, 2)
	main.chunks[new_owner_key] = new_owner
	new_owner.set_meta("static_ecology_render_resource_bindings", {})
	new_owner.set_meta("static_ecology_source_value_snapshot", _snapshot(main,
		new_owner, true, new_owner_key, "", "prop-old"))
	var new_section := Vector3i(4, 1, 4)
	var new_discovery: Dictionary = provider.call("_discover_static_prop_source_chunks",
		main, _typed_section_array(new_section))
	var new_snapshot: Dictionary = new_owner.get_meta(
		"static_ecology_source_value_snapshot", {})
	var new_candidate_prop_id := ""
	for candidate_value: Variant in new_snapshot.get("candidates", []):
		if candidate_value is Dictionary:
			new_candidate_prop_id = String(candidate_value.get("propId", ""))
	# The resident discovery helper remains a separate legacy boundary check.
	# Publication now uses the real asynchronous canonical source API below;
	# a resident metadata snapshot is no longer a publication certificate.
	var canonical := _canonical_source_relocation_case()
	var copied := {"unloadedStatus":unloaded.get("status", ""),
		"unloadedReason":unloaded.get("reason", ""),
		"recreatedStatus":canonical.get("oldSectionRemovalStatus", ""),
		"recreatedIncludesPriorOwner":recreated.get("status") == "ready" \
			and recreated.get("sourceChunks", []).has(FAR_OWNER),
		"explicitOldSectionRemoval":canonical.get("explicitOldSectionRemoval", false),
		"initialCanonicalSourceAccepted":canonical.get("initialCanonicalSourceAccepted", false),
		"oldSectionRemovalStatus":canonical.get("oldSectionRemovalStatus", ""),
		"newSectionStatus":canonical.get("newSectionStatus", ""),
		"newSectionOwners":canonical.get("newSectionOwners", []),
		"newCandidatePropId":canonical.get("newCandidatePropId", ""),
		"newCompiledSourceId":canonical.get("newCompiledSourceId", ""),
		"expectedSourceId":canonical.get("expectedSourceId", ""),
		"residentRelocationDiscovery":new_discovery,
		"residentCandidatePropId":new_candidate_prop_id,
		"canonicalReplay":canonical,
		"newSection":new_section}
	main.free()
	return copied


func _canonical_source_relocation_case() -> Dictionary:
	var main := AdapterFixture.ProductionAuthority.new()
	main.seed_text = "canonical-source-owner-relocation-contract"
	main.underground_required = false
	root.add_child(main)
	var provider := Adapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	provider.configure(world_id)
	provider.bind_main_authority(main)
	var source_id := main.seed_text + ":forage:prop-old"
	var old_position := Vector3(2.0, 2.0, 2.0)
	var new_position := Vector3(2.0 * Grid.STREAM_CHUNK_SIZE_METERS + 2.0,
		2.0, 2.0 * Grid.STREAM_CHUNK_SIZE_METERS + 2.0)
	var old_section := Grid.key_for_world_position(old_position)
	var new_section := Grid.key_for_world_position(new_position)
	main.set_fixture_rows(Vector2i.ZERO, [_canonical_forage_row(main, source_id, old_position)])
	var initial := _advance_canonical_capture(provider, world_id, [old_section])
	var initial_query: Dictionary = provider.query_section(world_id, old_section)
	var initial_accepted: bool = initial.get("status") == "complete" \
		and _query_has_source(initial_query, source_id, "compiled")
	# Explicit source-authority revision change, not a render-node relocation.
	main.structure_system.revision = "synthetic-relocated-source-v2"
	main.set_fixture_rows(Vector2i.ZERO, [])
	main.set_fixture_rows(Vector2i(2, 2), [_canonical_forage_row(main, source_id, new_position)])
	var replacement := _advance_canonical_capture(provider, world_id, [old_section, new_section])
	var old_query: Dictionary = provider.query_section(world_id, old_section)
	var new_query: Dictionary = provider.query_section(world_id, new_section)
	var has_removal := false
	for value: Variant in replacement.get("removalsBySection", {}).get(old_section, []):
		if value is Dictionary and value.get("sourceId") == source_id \
				and String(value.get("sourceRevision", "")).length() == 64:
			has_removal = true
	var owners: Array[Vector2i] = []
	var accepted_prop_id := ""
	var accepted_source_id := ""
	for value: Variant in new_query.get("supportOwnerDemands", []):
		if value is Dictionary and value.get("sourceId") == source_id \
				and value.get("state") == "compiled":
			var owner_key: Variant = value.get("sourceChunkKey", value.get("sourceOwnerChunk", null))
			if owner_key is Vector2i and not owners.has(owner_key): owners.append(owner_key)
			accepted_source_id = String(value.get("sourceId", ""))
	if _query_has_source(new_query, source_id, "compiled"):
		var accepted_snapshot: Dictionary = main.fixture_snapshots_by_chunk.get(Vector2i(2, 2), {})
		for value: Variant in accepted_snapshot.get("sourceRows", []):
			if value is Dictionary and value.get("sourceId") == source_id:
				accepted_prop_id = String(value.get("propId", ""))
	var result := {"initialCanonicalSourceAccepted":initial_accepted,
		"oldSectionRemovalStatus":replacement.get("status", ""),
		"explicitOldSectionRemoval":has_removal and not _query_has_source(old_query, source_id, "compiled"),
		"newSectionStatus":new_query.get("status", ""), "newSectionOwners":owners,
		"newCandidatePropId":accepted_prop_id, "initialReason":initial.get("reason", ""),
		"newCompiledSourceId":accepted_source_id, "expectedSourceId":source_id,
		"replacementReason":replacement.get("reason", ""),
		"oldQueryStatus":old_query.get("status", ""),
		"newSupport":new_query.get("supportOwnerDemands", [])}
	provider.reset_source_domain_captures()
	main.free()
	return result


func _canonical_forage_row(main: Node, source_id: String, position: Vector3) -> Dictionary:
	var mesh := BoxMesh.new()
	var material: Material = main.materials.forage
	# Producer position is local to its stream chunk; sourceOrigin is world space.
	var chunk_origin := Vector3(
		floorf(position.x / Grid.STREAM_CHUNK_SIZE_METERS) * Grid.STREAM_CHUNK_SIZE_METERS,
		0.0,
		floorf(position.z / Grid.STREAM_CHUNK_SIZE_METERS) * Grid.STREAM_CHUNK_SIZE_METERS)
	return {"schema":"ecology.synthetic-source-row/v1", "sourceId":source_id,
		"propId":"prop-old", "producerFamily":"forage", "kind":"forage",
		"position":position - chunk_origin, "sourceOrigin":position, "bodyRotation":Vector3.ZERO,
		"renderMembers":[{"memberId":"body", "meshRecipe":{
			"identity":"synthetic-contract-box/v1", "version":1,
			"primitive":"box", "parameters":{"size":Vector3.ONE}},
			"materialKey":"forage", "fallbackMaterialKeys":[], "renderLayer":"opaque",
			"transform":Transform3D.IDENTITY,
			"meshContentDigest":String(MeshFingerprint.inspect(mesh).get("contentDigest", "")),
			"materialContentDigest":Adapter._material_digest(material)}]}


func _advance_canonical_capture(provider: Object, world_id: String, sections: Array) -> Dictionary:
	var result: Dictionary = provider.capture_static_section_sources(world_id, sections)
	for _attempt in range(256):
		if result.get("status") != "pending" \
				or result.get("reason") != "ecology_source_capture_queued": break
		provider.advance_source_domain_captures(8)
		result = provider.capture_static_section_sources(world_id, sections)
	return result


func _query_has_source(query: Dictionary, source_id: String, state: String) -> bool:
	for value: Variant in query.get("supportOwnerDemands", []):
		if value is Dictionary and value.get("sourceId") == source_id and value.get("state") == state:
			return true
	return false


func _snapshot(main: Authority, owner: Node3D, with_source: bool,
		chunk_key := CHUNK_KEY, tombstone_source_id := "", candidate_prop_id := "",
		with_detail := false, support_mesh: Mesh = null) -> Dictionary:
	var revision := String(main.call("_ecology_chunk_source_revision", chunk_key))
	var ledger = Ledger.new()
	ledger.configure(main.seed_text, chunk_key, revision,
		main.removed_props_revision, main.terrain_revision)
	if with_source:
		var member_mesh: Mesh = support_mesh if support_mesh != null else BoxMesh.new()
		var member_mesh_bounds: AABB = member_mesh.get_aabb()
		var member_local_bounds: AABB = Transform3D.IDENTITY * member_mesh_bounds
		var member_mesh_digest := String(MeshFingerprint.inspect(member_mesh).get(
			"contentDigest", ""))
		var member := {"memberId":"ordinary-rock-mesh-member",
			"meshContentDigest":member_mesh_digest, "transform":Transform3D.IDENTITY,
			"meshBounds":member_mesh_bounds, "localBounds":member_local_bounds,
			"materialKey":"test-rock-material", "renderLayer":"opaque"}
		var prop_id := candidate_prop_id if not candidate_prop_id.is_empty() else "rock-0"
		var category := "surface_rocks"
		var candidate := {"sourceId":"%s:%s:%s" % [main.seed_text, category, prop_id],
			"propId":prop_id, "kind":"realized_static_prop",
			"category":"surface_rocks", "renderLayers":["opaque"],
			"materials":["test-rock-material"], "transform":Transform3D(Basis.IDENTITY,
				Vector3(22.0, 2.0, 22.0) if chunk_key == Vector2i(2, 2) else Vector3.ZERO),
			"localBounds":member_local_bounds, "renderMembers":[member],
			"provenance":{"sourceRevision":revision, "chunk":chunk_key,
				"terrainRevision":main.terrain_revision, "creatorOutputComplete":true},
			"renderStatus":"ready"}
		if not ledger.record_candidate(candidate):
			return {"status":"fixture_candidate_rejected"}
	if with_detail:
		var detail_mesh := BoxMesh.new()
		detail_mesh.size = Vector3.ONE * 0.2
		var detail_transform := Transform3D(Basis.IDENTITY, Vector3(0.7, 4.0, 0.7))
		var detail := {"sourceId":"%s:detail:%d,%d:grass:0:surface:0" % [
			main.seed_text, chunk_key.x, chunk_key.y], "kind":"surface_detail",
			"detailType":"grass", "surfaceIndex":-1,
		"renderLayers":["opaque"], "materials":["detailGrass"],
		"meshSource":"procedural_detail:grass", "transform":detail_transform,
		"meshBounds":detail_mesh.get_aabb(),
		"localBounds":detail_transform * detail_mesh.get_aabb()}
		ledger.record_candidate(detail)
	if not tombstone_source_id.is_empty():
		ledger.record_tombstone(tombstone_source_id, "removed_props")
	for category: String in ["surface_rocks", "ore", "forage"]:
		ledger.mark_category_complete(category, {"producer":"fixture_complete_category",
			"chunk":chunk_key, "sourceRevision":revision,
			"terrainRevision":main.terrain_revision, "producerComplete":true})
	ledger.mark_category_complete("underground_props", {
		"producer":"fixture_complete_underground", "chunk":chunk_key,
		"sourceRevision":revision, "terrainRevision":main.terrain_revision,
		"scanRevision":"fixture-underground-scan-r1", "producerComplete":true})
	var snapshot: Dictionary = ledger.snapshot()
	snapshot["status"] = "ready"
	snapshot["producerOwnerInstanceId"] = owner.get_instance_id()
	owner.set_meta("static_ecology_source_value_snapshot", snapshot)
	return snapshot


func _make_snapshot_stale(main: Authority, owner: Node3D,
		chunk_key: Vector2i) -> Dictionary:
	var snapshot := _snapshot(main, owner, false, chunk_key)
	snapshot["sourceRevision"] = "old-source-revision-before-new-contributor"
	var digest_payload := snapshot.duplicate(true)
	digest_payload.erase("contentRevision")
	digest_payload.erase("status")
	digest_payload.erase("producerOwnerInstanceId")
	snapshot["contentRevision"] = Adapter._value_digest(digest_payload)
	snapshot["status"] = "ready"
	owner.set_meta("static_ecology_source_value_snapshot", snapshot)
	return snapshot


func _member_aabb_case() -> Dictionary:
	var main := Authority.new()
	main.seed_text += ":member-aabb"
	root.add_child(main)
	var owner := Node3D.new()
	main.add_child(owner)
	main.chunks[CHUNK_KEY] = owner
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.4, 0.8, 2.0)
	var snapshot := _snapshot(main, owner, true, CHUNK_KEY, "", "", false, mesh)
	var candidate: Dictionary = {}
	for candidate_value: Variant in snapshot.get("candidates", []):
		if candidate_value is Dictionary \
				and String(candidate_value.get("kind", "")) == "realized_static_prop":
			candidate = candidate_value
			break
	var member: Dictionary = candidate.get("renderMembers", [{}])[0]
	var member_id := String(member.get("memberId", ""))
	var source_id := String(candidate.get("sourceId", ""))
	var bindings := {source_id + "|" + member_id:{"mesh":mesh}}
	var provider = Adapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	provider.configure(world_id)
	provider.bind_main_authority(main)
	var captured: Dictionary = provider.call("_static_prop_support_ranges", snapshot,
		candidate, Transform3D.IDENTITY, bindings, world_id)
	var actual_bounds: AABB = (candidate.get("transform") as Transform3D) \
		* (member.get("transform") as Transform3D) * mesh.get_aabb()
	var ranges: Dictionary = captured.get("supportRangesBySection", {})
	var support_sections: Array[Vector3i] = []
	for section_value: Variant in ranges:
		support_sections.append(Vector3i(section_value))
	support_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var expected_sections: Array[Vector3i] = Grid.keys_intersecting_bounds(actual_bounds)
	expected_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	main.free()
	return {"status":captured.get("status", ""),
		"actualMeshBounds":actual_bounds,
		"capturedWorldBounds":ranges.values()[0][0].get("worldBounds", AABB()) \
			if not ranges.is_empty() else AABB(),
		"supportSections":support_sections, "expectedSections":expected_sections}


func _check(name: String, passed: bool, evidence: Variant) -> void:
	checks[name] = {"passed":passed, "evidence":evidence}


func _one_requested_section() -> Array[Vector3i]:
	return _typed_section_array(CLOSURE_SECTION)


func _typed_section_array(section: Vector3i) -> Array[Vector3i]:
	var sections: Array[Vector3i] = [section]
	return sections
