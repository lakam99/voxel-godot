extends SceneTree

const Adapter := preload("res://scripts/world/EcologySectionValueAdapter.gd")
const Ledger := preload("res://scripts/world/EcologySourceValueLedger.gd")
const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const PacketOwner := preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const REPORT_ENV := "VOXEL_ECOLOGY_NATIVE_RETIREMENT_REPORT"
const SECTION_A := Vector3i.ZERO
const SECTION_B := Vector3i(1, 0, 0)
const PROP_SOURCE_ID := "fixture:forage:cross-section-prop"
const PROP_ID := "fixture-cross-section-prop"
const DETAIL_SOURCE_A := "ecology-native-retirement-fixture:detail:0,0:grass:a"
const DETAIL_SOURCE_B := "ecology-native-retirement-fixture:detail:0,0:grass:b"
const CHUNK_KEY := Vector2i.ZERO

var report_path := ""
var checks: Dictionary = {}
var fixture_main: FixtureMain
var provider
var coordinator
var world_id := ""
var detail_mesh_resource: BoxMesh
var detail_material_resource: StandardMaterial3D
var prop_mesh_resource: BoxMesh
var prop_material_resource: StandardMaterial3D
var prop_body: StaticBody3D
var prop_visual: MeshInstance3D
var prop_collision: CollisionShape3D
var surviving_prop_body: StaticBody3D
var surviving_prop_collision: CollisionShape3D
var legacy_detail_batch: MultiMeshInstance3D


class FixtureMain extends Node3D:
	var seed_text := "ecology-native-retirement-fixture"
	var seed_hash := 173
	var removed_props_revision := 0
	var removed_props: Dictionary = {}
	var terrain_revision := 0
	var chunks: Dictionary = {}
	var world_static_section_coordinator: Object
	var section_backend: Node
	var section_chunk: Node3D
	var detail_mesh_resource: Mesh
	var detail_material_resource: Material

	func _ecology_chunk_source_revision(key: Vector2i) -> String:
		return "ecology-v2:%s:%d,%d:fixture" % [seed_text, key.x, key.y]

	func terrain_volume_chunk_revision(_key: Vector2i, _chunk_size: int) -> int:
		return terrain_revision

	func visible_world_underground_visuals_required() -> bool:
		return false

	func detail_mesh(_detail_type: String) -> Mesh:
		return detail_mesh_resource

	func detail_material(_detail_type: String) -> Material:
		return detail_material_resource

	func get_static_section_render_owner(_owner_cell: Vector2i,
			_create_if_missing: bool) -> Dictionary:
		if not is_instance_valid(section_chunk) or not is_instance_valid(section_backend):
			return {"status":"pending", "reason":"fixture_native_section_owner_missing"}
		return {"status":"ready", "owner":section_chunk, "backend":section_backend}


func _initialize() -> void:
	report_path = OS.get_environment(REPORT_ENV)
	call_deferred("_run")


func _run() -> void:
	_build_resources()
	fixture_main = FixtureMain.new()
	fixture_main.detail_mesh_resource = detail_mesh_resource
	fixture_main.detail_material_resource = detail_material_resource
	root.add_child(fixture_main)
	current_scene = fixture_main
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	fixture_main.add_child(chunk)
	fixture_main.section_chunk = chunk
	fixture_main.chunks[CHUNK_KEY] = chunk
	var adjacent_source_chunk := Node3D.new()
	adjacent_source_chunk.name = "Chunk_1_0"
	adjacent_source_chunk.position = Vector3(28, 0, 0)
	fixture_main.add_child(adjacent_source_chunk)
	fixture_main.chunks[Vector2i(1, 0)] = adjacent_source_chunk
	var backend_result: Dictionary = PacketOwner.attach_to_chunk(chunk)
	fixture_main.section_backend = backend_result.get("backend") as Node
	_check("native_section_backend_attached", backend_result.get("status") == "ready"
		and is_instance_valid(fixture_main.section_backend), backend_result)
	if not checks["native_section_backend_attached"].passed:
		_finish()
		return
	world_id = "seed:%s:%d" % [fixture_main.seed_text, fixture_main.seed_hash]
	provider = Adapter.new()
	provider.configure(world_id)
	provider.bind_main_authority(fixture_main)
	coordinator = Coordinator.new()
	coordinator.configure(world_id)
	fixture_main.world_static_section_coordinator = coordinator
	var required_providers: Array[String] = [Adapter.PROVIDER_ID]
	required_providers.make_read_only()
	var roster_result: Dictionary = coordinator.configure_source_roster(required_providers)
	var registration: Dictionary = coordinator.register_source_provider(Adapter.PROVIDER_ID,
		provider, "capture_static_section_sources")
	_check("production_ecology_adapter_registered_in_section_roster",
		roster_result.get("status") == "ready" and registration.get("status") == "ready",
		{"roster":roster_result, "registration":registration})
	if not checks["production_ecology_adapter_registered_in_section_roster"].passed:
		_finish()
		return
	_install_source_snapshot(false)
	var initial_census: Dictionary = coordinator.capture_authoritative_source_census(
		[SECTION_A, SECTION_B])
	_check("initial_ecology_census_covers_both_old_visual_sections",
		initial_census.get("status") == "complete"
		and initial_census.get("sections", {}).has(SECTION_A)
		and initial_census.get("sections", {}).has(SECTION_B), initial_census)
	if not checks["initial_ecology_census_covers_both_old_visual_sections"].passed:
		_finish()
		return
	var initial_a := await _install_candidate(SECTION_A, 1)
	var initial_b := await _install_candidate(SECTION_B, 1)
	_check("initial_sections_installed_by_native_renderer",
		initial_a.get("status") == "installed" and initial_b.get("status") == "installed",
		{"sectionA":initial_a, "sectionB":initial_b})
	if not checks["initial_sections_installed_by_native_renderer"].passed:
		_finish()
		return
	_build_legacy_visuals(chunk)
	var target_probe := {"detailTarget":provider._find_detail_batch_target(chunk, "grass"),
		"propTargets":provider._find_static_prop_visual_targets(chunk, PROP_SOURCE_ID)}
	_check("fixture_legacy_targets_match_production_discovery",
		target_probe.detailTarget == legacy_detail_batch
		and target_probe.propTargets.has(prop_visual),
		{"detailTargetFound":is_instance_valid(target_probe.detailTarget),
			"propTargetCount":target_probe.propTargets.size()})
	var prior_visual_census: Dictionary = coordinator.capture_authoritative_source_census(
		[SECTION_A, SECTION_B])
	var initial_prop_unit: Dictionary = provider._latest_legacy_visual_units.get(
		"prop:%s" % PROP_SOURCE_ID, {})
	var initial_detail_unit: Dictionary = provider._latest_legacy_visual_units.get(
		"decor:0,0:grass", {})
	_check("legacy_prop_and_foliage_units_bind_both_section_owners",
		prior_visual_census.get("status") == "complete"
		and initial_prop_unit.get("requiredSections", []).has(SECTION_A)
		and initial_prop_unit.get("requiredSections", []).size() == 1
		and initial_detail_unit.get("requiredSections", []).has(SECTION_A)
		and initial_detail_unit.get("requiredSections", []).has(SECTION_B),
		{"census":prior_visual_census,
			"propRequiredSections":initial_prop_unit.get("requiredSections", []),
			"detailRequiredSections":initial_detail_unit.get("requiredSections", []),
			"unitIds":provider._latest_legacy_visual_units.keys()})
	_check("old_ecology_visuals_remain_visible_until_replacement_ack",
		legacy_detail_batch.visible and prop_visual.visible and not prop_collision.disabled,
		{"detailVisible":legacy_detail_batch.visible, "propVisible":prop_visual.visible,
			"bodyExists":is_instance_valid(prop_body), "collisionDisabled":prop_collision.disabled})
	fixture_main.removed_props[PROP_ID] = true
	fixture_main.removed_props_revision += 1
	_install_source_snapshot(true)
	var replacement_a_admission: Dictionary = await _admit_compiled_candidate(coordinator,
		SECTION_A, 2)
	var replacement_b_admission: Dictionary = await _admit_compiled_candidate(coordinator,
		SECTION_B, 2)
	_check("tombstone_replacement_candidates_admitted",
		replacement_a_admission.get("status") == "queued"
		and replacement_b_admission.get("status") == "queued",
		{"sectionA":replacement_a_admission, "sectionB":replacement_b_admission})
	var removal_unit: Dictionary = provider._latest_legacy_visual_units.get(
		"prop:%s" % PROP_SOURCE_ID, {})
	var removal_revisions: Dictionary = removal_unit.get("removalRevisionsBySection", {})
	var removal_revision := String(removal_revisions.get(SECTION_A, {}).get(
		PROP_SOURCE_ID, ""))
	var pending_removal_revision := String(provider._pending_legacy_removal_revisions_by_section \
		.get(SECTION_A, {}).get(PROP_SOURCE_ID, ""))
	_check("harvested_prop_has_exact_tombstone_revision_in_each_old_section",
		removal_revisions.get(SECTION_A, {}).has(PROP_SOURCE_ID)
		and removal_revisions.size() == 1
		and not removal_revision.is_empty()
		and removal_revision == pending_removal_revision,
		{"removalRevisionsBySection":removal_revisions,
			"pendingRemovalRevision":pending_removal_revision})
	var old_receipt_a: Dictionary = coordinator._production_candidate_receipts.get(SECTION_A, {})
	var changed_coverage_a := String(provider._latest_coverage_by_section.get(SECTION_A, ""))
	var stale_ack: Dictionary = provider.acknowledge_section_install(SECTION_A,
		changed_coverage_a, old_receipt_a)
	_check("stale_native_receipt_after_harvest_keeps_all_legacy_visuals",
		stale_ack.get("legacyVisualRetirement", {}).get("status") == "pending"
		and stale_ack.get("legacyVisualRetirement", {}).get("reason") \
			== "ecology_legacy_visual_receipt_not_current"
		and legacy_detail_batch.visible and prop_visual.visible,
		{"ack":stale_ack, "detailVisible":legacy_detail_batch.visible,
			"propVisible":prop_visual.visible})
	var harvested_body_id := prop_body.get_instance_id()
	prop_body.queue_free()
	await process_frame
	_check("harvested_prop_body_and_weak_visual_targets_are_gone_before_receipt",
		not is_instance_valid(prop_body) and not is_instance_valid(prop_visual)
		and not is_instance_valid(prop_collision),
		{"harvestedBodyInstanceId":harvested_body_id,
			"bodyGone":not is_instance_valid(prop_body),
			"visualGone":not is_instance_valid(prop_visual),
			"collisionGone":not is_instance_valid(prop_collision)})
	var replacement_a := await _finish_candidate(SECTION_A)
	var replacement_receipt_a: Dictionary = coordinator._production_candidate_receipts.get(SECTION_A, {})
	var ack_a := _provider_ack_from_install(replacement_a)
	var prop_acknowledged_after_tombstone: bool = ack_a.get("legacyVisualRetirement", {}) \
		.get("acknowledgedUnitIds", []).has("prop:%s" % PROP_SOURCE_ID)
	_check("single_section_prop_retires_while_multi_section_foliage_waits",
		replacement_a.get("status") == "installed" and ack_a.get("status") == "acknowledged"
		and prop_acknowledged_after_tombstone
		and ack_a.get("legacyVisualRetirement", {}).get("pendingUnitIds", []).has(
			"decor:0,0:grass")
		and legacy_detail_batch.visible and not is_instance_valid(prop_body)
		and not is_instance_valid(prop_visual) and not is_instance_valid(prop_collision)
		and is_instance_valid(surviving_prop_body)
		and is_instance_valid(surviving_prop_collision)
		and not surviving_prop_collision.disabled,
		{"install":replacement_a, "ack":ack_a, "detailVisible":legacy_detail_batch.visible,
			"propAckedAfterTombstone":prop_acknowledged_after_tombstone,
			"propBodyExists":is_instance_valid(prop_body),
			"survivingBodyExists":is_instance_valid(surviving_prop_body),
			"survivingCollisionDisabled":surviving_prop_collision.disabled \
				if is_instance_valid(surviving_prop_collision) else true})
	var repeated_ack: Dictionary = provider.acknowledge_section_install(SECTION_A,
		String(provider._latest_coverage_by_section.get(SECTION_A, "")),
		replacement_receipt_a)
	_check("current_tombstone_ack_replay_is_idempotent_after_weak_target_expiry",
		repeated_ack.get("status") == "acknowledged"
		and not repeated_ack.get("legacyVisualRetirement", {}).get(
			"pendingUnitIds", []).has("prop:%s" % PROP_SOURCE_ID)
		and is_instance_valid(surviving_prop_body)
		and is_instance_valid(surviving_prop_collision)
		and not surviving_prop_collision.disabled,
		{"ack":repeated_ack, "survivingBodyInstanceId":surviving_prop_body.get_instance_id() \
			if is_instance_valid(surviving_prop_body) else 0})
	var replacement_b := await _finish_candidate(SECTION_B)
	var replacement_receipt_b: Dictionary = coordinator._production_candidate_receipts.get(SECTION_B, {})
	var ack_b := _provider_ack_from_install(replacement_b)
	_check("current_receipts_for_all_sections_retire_only_legacy_visual_children",
		replacement_b.get("status") == "installed" and ack_b.get("status") == "acknowledged"
		and not legacy_detail_batch.visible and not is_instance_valid(prop_visual)
		and not is_instance_valid(prop_body) and not is_instance_valid(prop_collision)
		and is_instance_valid(surviving_prop_body) and surviving_prop_body.get_parent() == chunk
		and is_instance_valid(surviving_prop_collision) \
		and surviving_prop_collision.get_parent() == surviving_prop_body
		and not surviving_prop_collision.disabled,
		{"install":replacement_b, "ack":ack_b, "detailVisible":legacy_detail_batch.visible,
			"propVisualExists":is_instance_valid(prop_visual),
			"bodyExists":is_instance_valid(prop_body),
			"collisionExists":is_instance_valid(prop_collision),
			"survivingBodyExists":is_instance_valid(surviving_prop_body),
			"survivingCollisionDisabled":surviving_prop_collision.disabled \
				if is_instance_valid(surviving_prop_collision) else true})
	var receipts_current: bool = coordinator.installed_section_receipt_is_current(
		SECTION_A, replacement_receipt_a) and coordinator.installed_section_receipt_is_current(
		SECTION_B, replacement_receipt_b)
	_check("native_receipts_remain_authenticated_by_installed_backend",
		receipts_current and _backend_receipt_live(SECTION_A, replacement_receipt_a)
		and _backend_receipt_live(SECTION_B, replacement_receipt_b),
		{"sectionA":replacement_receipt_a, "sectionB":replacement_receipt_b})
	_finish()


func _build_resources() -> void:
	detail_mesh_resource = BoxMesh.new()
	detail_mesh_resource.size = Vector3(0.35, 0.8, 0.35)
	detail_material_resource = StandardMaterial3D.new()
	detail_material_resource.albedo_color = Color(0.28, 0.64, 0.31, 1.0)
	detail_material_resource.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	prop_mesh_resource = BoxMesh.new()
	prop_mesh_resource.size = Vector3(1.2, 1.0, 1.2)
	prop_material_resource = StandardMaterial3D.new()
	prop_material_resource.albedo_color = Color(0.45, 0.35, 0.24, 1.0)


func _build_legacy_visuals(chunk: Node3D) -> void:
	var decor_batches := Node3D.new()
	decor_batches.name = "DecorBatches"
	chunk.add_child(decor_batches)
	legacy_detail_batch = MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = detail_mesh_resource
	multimesh.instance_count = 2
	multimesh.set_instance_transform(0, Transform3D(Basis.IDENTITY, Vector3(2, 0.4, 2)))
	multimesh.set_instance_transform(1, Transform3D(Basis.IDENTITY, Vector3(24, 0.4, 2)))
	legacy_detail_batch.multimesh = multimesh
	legacy_detail_batch.material_override = detail_material_resource
	legacy_detail_batch.set_meta("detail_type", "grass")
	decor_batches.add_child(legacy_detail_batch)
	prop_body = StaticBody3D.new()
	prop_body.set_meta("static_ecology_source_id", PROP_SOURCE_ID)
	prop_body.set_meta("prop_id", PROP_ID)
	chunk.add_child(prop_body)
	prop_visual = MeshInstance3D.new()
	prop_visual.mesh = prop_mesh_resource
	prop_visual.material_override = prop_material_resource
	prop_visual.position = Vector3(2, 0.5, 2)
	prop_visual.set_meta("harvestable", true)
	prop_body.add_child(prop_visual)
	prop_collision = CollisionShape3D.new()
	prop_collision.shape = BoxShape3D.new()
	prop_collision.position = Vector3(2, 0.5, 2)
	prop_body.add_child(prop_collision)
	surviving_prop_body = StaticBody3D.new()
	surviving_prop_body.set_meta("static_ecology_source_id", "fixture:unrelated-survivor")
	surviving_prop_body.set_meta("prop_id", "fixture-unrelated-survivor")
	surviving_prop_body.position = Vector3(-4, 0, 2)
	chunk.add_child(surviving_prop_body)
	surviving_prop_collision = CollisionShape3D.new()
	surviving_prop_collision.shape = BoxShape3D.new()
	surviving_prop_collision.position = Vector3(0, 0.5, 0)
	surviving_prop_body.add_child(surviving_prop_collision)


func _install_source_snapshot(harvested: bool) -> void:
	for chunk_key_value: Variant in fixture_main.chunks:
		var chunk_key := Vector2i(chunk_key_value)
		var chunk_owner: Node3D = fixture_main.chunks[chunk_key]
		var revision := fixture_main._ecology_chunk_source_revision(chunk_key)
		var ledger = Ledger.new()
		ledger.configure(fixture_main.seed_text, chunk_key, revision,
			fixture_main.removed_props_revision, fixture_main.terrain_revision)
		if chunk_key == CHUNK_KEY:
			ledger.record_candidate(_detail_candidate(DETAIL_SOURCE_A, Vector3(2, 0.4, 2)))
			ledger.record_candidate(_detail_candidate(DETAIL_SOURCE_B, Vector3(24, 0.4, 2)))
			ledger.record_candidate(_prop_candidate(revision))
			if harvested:
				ledger.apply_removed_props(fixture_main.removed_props,
					fixture_main.removed_props_revision)
		for category: String in ["surface_rocks", "ore", "forage"]:
			ledger.mark_category_complete(category, {"producer":"fixture_surface_spawn",
				"chunk":chunk_key, "sourceRevision":revision,
				"terrainRevision":fixture_main.terrain_revision, "producerComplete":true})
		ledger.mark_category_complete("underground_props", {
			"producer":"fixture_underground_scan", "chunk":chunk_key,
			"sourceRevision":revision, "terrainRevision":fixture_main.terrain_revision,
			"scanRevision":"fixture-floor-scan:%d,%d" % [chunk_key.x, chunk_key.y],
			"producerComplete":true})
		var snapshot: Dictionary = ledger.snapshot()
		snapshot["status"] = "ready"
		snapshot["producerOwnerInstanceId"] = chunk_owner.get_instance_id()
		chunk_owner.set_meta("static_ecology_source_value_snapshot", snapshot)
		chunk_owner.set_meta("static_ecology_render_resource_bindings",
			_resource_bindings() if chunk_key == CHUNK_KEY else {}.duplicate())


func _detail_candidate(source_id: String, position: Vector3) -> Dictionary:
	var transform := Transform3D(Basis.IDENTITY, position)
	return {"sourceId":source_id, "kind":"surface_detail", "detailType":"grass",
		"renderLayers":["alpha_scissor"], "materials":["detailGrass"],
		"meshSource":"procedural_detail:grass", "transform":transform,
		"meshBounds":detail_mesh_resource.get_aabb(),
		"instanceColor":Color.WHITE, "customData":Color(0.5, 0, 0, 1),
		"localBounds":transform * detail_mesh_resource.get_aabb(),
		"shadowCasting":"off", "visibilityRangeEnd":40.0}


func _prop_candidate(source_revision: String) -> Dictionary:
	var mesh_digest := String(MeshFingerprint.inspect(prop_mesh_resource).get("contentDigest", ""))
	var material_digest := Adapter._material_digest(prop_material_resource)
	var transform_a := Transform3D(Basis.IDENTITY, Vector3(2, 0, 2))
	var transform_b := Transform3D(Basis.IDENTITY, Vector3(12, 0, 2))
	var local_bounds_a: AABB = transform_a * prop_mesh_resource.get_aabb()
	var local_bounds_b: AABB = transform_b * prop_mesh_resource.get_aabb()
	return {"sourceId":PROP_SOURCE_ID, "propId":PROP_ID,
		"kind":"realized_static_prop", "category":"forage", "sourceKind":"forage",
		"transform":Transform3D.IDENTITY,
		"localBounds":local_bounds_a.merge(local_bounds_b), "renderStatus":"ready",
		"renderLayers":["opaque"], "materials":["forage"],
		"renderMembers":[
			{"memberId":"prop-member-a", "meshContentDigest":mesh_digest,
				"materialContentDigest":material_digest, "transform":transform_a,
				"meshBounds":prop_mesh_resource.get_aabb(),
				"localBounds":local_bounds_a, "materialKey":"forage", "renderLayer":"opaque"},
			{"memberId":"prop-member-b", "meshContentDigest":mesh_digest,
				"materialContentDigest":material_digest, "transform":transform_b,
				"meshBounds":prop_mesh_resource.get_aabb(),
				"localBounds":local_bounds_b, "materialKey":"forage", "renderLayer":"opaque"}],
		"provenance":{"producer":"fixture_surface_spawn", "chunk":CHUNK_KEY,
			"sourceRevision":source_revision, "terrainRevision":fixture_main.terrain_revision,
			"creatorOutputComplete":true}}


func _resource_bindings() -> Dictionary:
	var detail_binding := {"mesh":detail_mesh_resource,
		"meshSource":"procedural_detail:grass", "meshResourceKey":"environment.detail.grass/v1",
		"material":detail_material_resource, "materialKey":"detailGrass",
		"materialContentDigest":Adapter._material_digest(detail_material_resource),
		"pipelineRevision":"fixture-detail-pipeline/v1", "fadeMargin":8.0}
	detail_binding.make_read_only()
	var prop_binding_a := {"mesh":prop_mesh_resource, "material":prop_material_resource,
		"meshContentDigest":String(MeshFingerprint.inspect(prop_mesh_resource).get("contentDigest", "")),
		"materialContentDigest":Adapter._material_digest(prop_material_resource),
		"materialKey":"forage", "renderLayer":"opaque"}
	prop_binding_a.make_read_only()
	var prop_binding_b := prop_binding_a.duplicate(false)
	prop_binding_b.make_read_only()
	var bindings := {
		"procedural_detail:grass|detailGrass":detail_binding,
		PROP_SOURCE_ID + "|prop-member-a":prop_binding_a,
		PROP_SOURCE_ID + "|prop-member-b":prop_binding_b}
	bindings.make_read_only()
	return bindings


func _install_candidate(section_key: Vector3i, generation: int) -> Dictionary:
	var admitted: Dictionary = await _admit_compiled_candidate(coordinator,
		section_key, generation)
	if admitted.get("status") != "queued":
		return admitted
	return await _finish_candidate(section_key)


func _finish_candidate(section_key: Vector3i) -> Dictionary:
	for frame_index in range(1600):
		var step: Dictionary = coordinator.advance_queued_complete_section_candidates(1, 8)
		for result_value: Variant in step.get("results", []):
			if result_value is Dictionary and result_value.get("sectionKey") == section_key \
					and result_value.get("status") in ["installed", "failed", "cancelled"]:
				return result_value
		await process_frame
	return {"status":"pending", "reason":"fixture_install_frame_budget_exhausted",
		"sectionKey":section_key}


func _backend_receipt_live(section_key: Vector3i, receipt: Dictionary) -> bool:
	var generation := int(receipt.get("generation", 0))
	var slot := InstallSession.slot_id(world_id, section_key)
	return generation > 0 and bool(fixture_main.section_backend.call("receipt_installed",
		slot, generation, "%s:%d" % [world_id, generation],
		String(receipt.get("contentManifestDigest", ""))))


func _provider_ack_from_install(install: Dictionary) -> Dictionary:
	var acknowledgements: Variant = install.get("sourceAcknowledgements", {}) \
		.get("providerAcknowledgements", [])
	if not acknowledgements is Array or acknowledgements.is_empty() \
			or not acknowledgements[0] is Dictionary:
		return {"status":"missing", "reason":"fixture_install_provider_ack_missing"}
	return acknowledgements[0].get("result", {})


func _check(name: String, passed: bool, evidence: Variant = {}) -> void:
	checks[name] = {"passed":passed, "evidence":evidence}


func _finish() -> void:
	var failures: Array[String] = []
	for check_name: String in checks:
		if not bool(checks[check_name].get("passed", false)):
			failures.append(check_name)
	var result := {"schema":"ecology-native-visual-retirement/v1",
		"passed":failures.is_empty(), "checkCount":checks.size(),
		"failures":failures, "checks":checks,
		"evidenceLevel":"production ecology adapter census and acknowledgement through live source roster, whole-section coordinator, install session, and native backend with synthetic immutable fixture producers",
		"doesNotProve":"Normal-world provider composition, visual parity in Main, gameplay harvest/save replay, collision response, or runtime performance."}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(result, "\t"))
	quit(0 if result.passed else 1)

## Admission now queues a native worker. Wait for its current identity receipt
## before the fixture inspects candidate data or controls upload/frame stages.
func _admit_compiled_candidate(owner_coordinator, section_key: Vector3i,
		generation: int) -> Dictionary:
	var admission: Dictionary = owner_coordinator.call(
		"assemble_and_submit_complete_section_candidate", section_key, generation)
	if admission.get("status") != "queued": return admission
	for wait_frame in range(1200):
		var outcomes: Array = owner_coordinator.call("_advance_section_compiles", 1)
		for outcome: Dictionary in outcomes:
			if outcome.get("sectionKey") == section_key and int(outcome.get("generation", -1)) == generation:
				if outcome.get("status") != "queued": return outcome
		var jobs: Dictionary = owner_coordinator.get("_production_candidate_jobs")
		var candidate: Dictionary = jobs.get(section_key, {}).get("candidate", {})
		if int(candidate.get("generation", -1)) == generation:
			var receipt: Dictionary = candidate.get("nativeCompileReceipt", {})
			if receipt.get("status") != "compiled":
				return {"status":"failed", "reason":"fixture_native_compile_receipt_missing"}
			var accepted := admission.duplicate(false)
			accepted["acceptedStage"] = "native_compile_accepted"
			accepted["compileWaitFrames"] = wait_frame
			accepted["nativeCompileReceipt"] = receipt
			return accepted
		await process_frame
	return {"status":"failed", "reason":"fixture_native_compile_wait_exhausted",
		"stage":"native_compile", "sectionKey":section_key, "generation":generation}
