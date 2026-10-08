extends SceneTree

const Structures := preload("res://scripts/StructureSystem.gd")
const Admission := preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Service := preload("res://scripts/world/CitadelPublicationService.gd")
const Field := preload("res://scripts/world/CitadelSiteField.gd")
const Preparation := preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const SourceRoster := preload("res://scripts/world/StaticSectionSourceRoster.gd")
const PacketOwner := preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const OwnerCompletion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const SEED := "atlas-1492"
const REGION := Vector2i(1, -3)
const REQUIRED_TRANSFORM_PART_ID := "castle_tower_04_battlement_front_0"
const PROVIDER_ID := "blueprint_buildings"
const REPORT_ENV := "VOXEL_CITADEL_NONEMPTY_SECTION_REPORT"
const PREFLIGHT_ENV := "VOXEL_CITADEL_NONEMPTY_SECTION_PREFLIGHT"
const SOURCE_DEADLINE_MSEC := 540000
const PLAN_DEADLINE_MSEC := 300000

class RuntimeOwner extends "res://scripts/Main.gd":
	func _ready() -> void: pass
	func _process(_delta: float) -> void: pass
	func _physics_process(_delta: float) -> void: pass

class FixturePlayer extends "res://scripts/PlayerController.gd":
	func _ready() -> void:
		set_physics_process(false)
		camera = Camera3D.new()
		camera.name = "Camera3D"
		camera.current = true
		camera.position = base_camera_position
		add_child(camera)
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.42
		capsule.height = 1.72
		var collider := CollisionShape3D.new()
		collider.name = "PlayerCollider"
		collider.shape = capsule
		collider.position.y = 0.86
		add_child(collider)

class WorldRoot extends Node3D:
	var static_section_render_root: Node3D
	var static_section_render_owners: Dictionary = {}
	func get_static_section_render_owner(owner_cell: Vector2i,
			create_if_missing := true) -> Dictionary:
		if not is_instance_valid(static_section_render_root) \
				or not static_section_render_root.is_inside_tree():
			return {"status":"pending", "reason":"fixture_render_owner_root_unavailable",
				"ownerCell":owner_cell}
		var section_owner := static_section_render_owners.get(owner_cell) as Node3D
		if is_instance_valid(section_owner) and section_owner.is_inside_tree() \
				and not section_owner.is_queued_for_deletion():
			var current_backend := section_owner.get_node_or_null(PacketOwner.BACKEND_NODE) as Node3D
			if current_backend == null:
				var attached: Dictionary = PacketOwner.attach_to_chunk(section_owner)
				if attached.get("status") != "ready": return attached
				current_backend = attached.backend as Node3D
			return {"status":"ready", "owner":section_owner, "backend":current_backend,
				"ownerCell":owner_cell}
		static_section_render_owners.erase(owner_cell)
		if not create_if_missing:
			return {"status":"pending", "reason":"fixture_render_owner_not_loaded",
				"ownerCell":owner_cell}
		section_owner = Node3D.new()
		section_owner.name = "Chunk_%d_%d" % [owner_cell.x, owner_cell.y]
		section_owner.position = Vector3(owner_cell.x * Grid.STREAM_CHUNK_SIZE_METERS,
			0.0, owner_cell.y * Grid.STREAM_CHUNK_SIZE_METERS)
		section_owner.set_meta("static_section_render_owner", true)
		section_owner.set_meta("static_section_owner_cell", owner_cell)
		static_section_render_root.add_child(section_owner)
		var attached: Dictionary = PacketOwner.attach_to_chunk(section_owner)
		if attached.get("status") != "ready":
			section_owner.queue_free()
			return attached
		static_section_render_owners[owner_cell] = section_owner
		return {"status":"ready", "owner":section_owner, "backend":attached.backend,
			"ownerCell":owner_cell}

class SelectorPlan extends RefCounted:
	var member_records: Array[Dictionary] = []
	func visual_members_intersecting_bounds(bounds: AABB) -> Dictionary:
		var members: Array[Dictionary] = []
		for member: Dictionary in member_records:
			var member_bounds: Variant = member.get("bounds")
			if member_bounds is AABB and member_bounds.intersects(bounds):
				members.append(member)
		return {"status":"described", "members":members}

class SelectorDescription extends RefCounted:
	var publication_groups: Dictionary = {"groups":{}}

class SyntheticCensusCaptureService extends "res://scripts/world/CitadelPublicationService.gd":
	var authority_calls: Array[String] = []
	func _capture_member_transform_artifact_authority(site_id: String,
			member_id: String) -> Dictionary:
		authority_calls.append(site_id + ":" + member_id)
		return {"status":"ready", "artifactAuthorityRevision":"a".repeat(64)}
	func _current_tree_member_artifact_authority(site_id: String,
			member_id: String) -> Dictionary:
		authority_calls.append(site_id + ":" + member_id)
		return {"status":"ready", "artifactAuthorityRevision":"b".repeat(64)}

var checks: Dictionary = {}
var trace: Array[Dictionary] = []
var report_path := ""
var owner: RuntimeOwner
var section_key := Vector3i.ZERO
var coordinator
var selected_groups: Array[String] = []
var selected_members: Array[Dictionary] = []
var target_section_keys: Array[Vector3i] = []
var target_member: Dictionary = {}
var target_part_id := ""
var target_geometry_family := ""
var initial_packet_group := ""
var publisher
var progress_path := ""
var phase_marker_path := ""
var _active_closure_frame := 0

func _initialize() -> void:
	report_path = OS.get_environment(REPORT_ENV)
	if not report_path.is_empty():
		progress_path = report_path.get_base_dir().path_join("progress.txt")
		phase_marker_path = report_path.get_base_dir().path_join("phase-marker.json")
	if OS.get_environment("VOXEL_CITADEL_NONEMPTY_SECTION_SELECTOR_SMOKE") == "1":
		call_deferred("_run_selector_smoke")
	else:
		call_deferred("_run")

func _run_selector_smoke() -> void:
	var plan := SelectorPlan.new()
	var section_origin := Grid.origin_for_key(Vector3i.ZERO)
	plan.member_records.append({"memberId":"building:smoke-contained",
		"groupId":"building:smoke-contained", "visual":true,
		"bounds":AABB(section_origin + Vector3(2.0, 2.0, 2.0), Vector3.ONE)})
	plan.member_records.append({"memberId":"building:smoke-crossing",
		"groupId":"building:smoke-crossing", "visual":true,
		"bounds":AABB(section_origin + Vector3(Grid.SECTION_SIZE_METERS - 0.5, 2.0, 2.0),
			Vector3(1.0, 1.0, 1.0))})
	var smoke_parts: Array = [{"id":"smoke-contained", "kind":"roof"}, {"id":"smoke-crossing", "kind":"roof"}]
	var contained := _select_sparse_section(plan, {}, {}, smoke_parts)
	_check("single_section_visual_selected",
		contained.get("status") == "ready" and contained.get("section") == Vector3i.ZERO
		and contained.get("members", []).size() == 2
		and contained.get("targetMember", {}).get("memberId", "") == "building:smoke-contained"
		and contained.get("targetSectionKeys", []) == [Vector3i.ZERO],
		{"result":contained})
	plan.member_records.clear()
	plan.member_records.append({"memberId":"building:smoke-crossing",
		"groupId":"building:smoke-crossing", "visual":true,
		"bounds":AABB(section_origin + Vector3(Grid.SECTION_SIZE_METERS - 0.5, 2.0, 2.0),
			Vector3(1.0, 1.0, 1.0))})
	var crossing := _select_sparse_section(plan, {}, {}, smoke_parts)
	_check("multi_section_visual_exposes_all_required_receipt_sections",
		crossing.get("status") == "ready"
		and crossing.get("targetMember", {}).get("memberId", "") == "building:smoke-crossing"
		and crossing.get("targetSectionKeys", []) == [Vector3i.ZERO, Vector3i(1, 0, 0)],
		{"result":crossing})
	var dependencies := _expand_group_dependency_closure(["building:smoke-target"], {
		"building:smoke-target":{"dependencies":["building:smoke-parent"]},
		"building:smoke-parent":{"dependencies":["building:smoke-root"]},
		"building:smoke-root":{"dependencies":[]},
		"building:smoke-unrelated":{"dependencies":[]}})
	_check("packet_demand_dependency_closure_is_transitive_and_exact",
		dependencies.get("status") == "ready"
		and dependencies.get("groupIds", []) == ["building:smoke-parent",
			"building:smoke-root", "building:smoke-target"],
		{"closure":dependencies})
	var missing_dependency := _expand_group_dependency_closure(["building:smoke-missing-root"], {
		"building:smoke-missing-root":{"dependencies":["building:smoke-absent"]}})
	_check("packet_demand_dependency_closure_rejects_missing_group",
		missing_dependency.get("status") == "failed"
		and missing_dependency.get("reason") == "dependency_group_missing",
		{"closure":missing_dependency})
	var cyclic_dependency := _expand_group_dependency_closure(["building:smoke-cycle-a"], {
		"building:smoke-cycle-a":{"dependencies":["building:smoke-cycle-b"]},
		"building:smoke-cycle-b":{"dependencies":["building:smoke-cycle-a"]}})
	_check("packet_demand_dependency_closure_rejects_multi_group_cycle",
		cyclic_dependency.get("status") == "failed"
		and cyclic_dependency.get("reason") == "dependency_cycle",
		{"closure":cyclic_dependency})
	var eligibility_plan := SelectorPlan.new()
	eligibility_plan.member_records.append({"memberId":"building:smoke-ineligible-a",
		"groupId":"building:smoke-ineligible-a", "visual":true,
		"bounds":AABB(section_origin + Vector3(3.0, 3.0, 3.0), Vector3.ONE)})
	eligibility_plan.member_records.append({"memberId":"building:smoke-ineligible-b",
		"groupId":"building:smoke-ineligible-b", "visual":true,
		"bounds":AABB(section_origin + Vector3(4.0, 3.0, 3.0), Vector3.ONE)})
	var eligible_origin := Grid.origin_for_key(Vector3i(2, 0, 0))
	eligibility_plan.member_records.append({"memberId":"building:smoke-eligible",
		"groupId":"building:smoke-eligible", "visual":true,
		"bounds":AABB(eligible_origin + Vector3(3.0, 3.0, 3.0), Vector3.ONE)})
	var eligible_ids := {"building:smoke-ineligible-a":true,
		"building:smoke-eligible":true}
	var eligible_groups := {"building:smoke-ineligible-a":{"dependencies":[]},
		"building:smoke-ineligible-b":{"dependencies":[]},
		"building:smoke-eligible":{"dependencies":[]}}
	var eligible_selection := _select_sparse_section(eligibility_plan,
		eligible_ids, eligible_groups, [{"id":"smoke-ineligible-a", "kind":"roof"},
			{"id":"smoke-ineligible-b", "kind":"roof"}, {"id":"smoke-eligible", "kind":"roof"}])
	_check("selector_rejects_section_with_any_ineligible_roster_member",
		eligible_selection.get("status") == "ready"
		and eligible_selection.get("section") == Vector3i(2, 0, 0)
		and eligible_selection.get("memberCount", 0) == 1,
		{"selection":eligible_selection})
	var large_description := SelectorDescription.new()
	var large_groups: Array[String] = []
	for index in range(1501):
		var id := "synthetic-part-%04d" % index
		large_groups.append(id)
		large_description.publication_groups.groups[id] = {"dependencies":[]}
	var synthetic_service := Service.new()
	var oversized: Dictionary = synthetic_service._bounded_packet_view_window(large_description, null, {}, [],
		[{"groupIds":large_groups, "priority":0, "dependencyComplete":true}], {}, false)
	_check("synthetic_actual_demand_authority_rejects_1501_foreground_groups",
		oversized.get("status") == "failed" and oversized.get("reason") == "packet_required_foreground_scope_too_large",
		oversized)
	var bounded := _next_owner_publication_window(large_groups, large_description.publication_groups.groups, {})
	_check("synthetic_owner_window_obeys_actual_expanded_closure_cap", bounded.get("status") == "ready"
		and bounded.get("groupIds", []).size() == 128, bounded)
	var complete_window: Dictionary = {}
	for id: String in bounded.get("groupIds", []): complete_window[id] = true
	var next_window := _next_owner_publication_window(large_groups, large_description.publication_groups.groups, complete_window)
	var excludes_completed := true
	for id: String in next_window.get("groupIds", []): excludes_completed = excludes_completed and not complete_window.has(id)
	_check("synthetic_owner_window_advances_only_past_completed_group_receipts",
		next_window.get("status") == "ready" and excludes_completed and next_window.get("groupIds", []).size() == 128, next_window)
	var excessive_dependencies: Array[String] = []
	for index in range(1, Service.MAX_REQUIRED_FOREGROUND_GROUPS + 1): excessive_dependencies.append(large_groups[index])
	large_description.publication_groups.groups[large_groups[0]]["dependencies"] = excessive_dependencies
	var excessive_seed := _next_owner_publication_window(large_groups, large_description.publication_groups.groups, {})
	_check("synthetic_single_seed_expanded_closure_cannot_bypass_production_cap",
		excessive_seed.get("status") == "failed" and excessive_seed.get("reason") == "single_owner_seed_closure_exceeds_production_cap", excessive_seed)
	var resumable_service := SyntheticCensusCaptureService.new()
	resumable_service._active_source_census_capture_key = "synthetic-census"
	resumable_service._section_source_census_capture_jobs["synthetic-census"] = {
		"memberAuthorities":{}, "memberAuthorityCount":0}
	var authority_slice_limit := maxi(1, int(Service.MAX_CITADEL_CENSUS_MEMBER_AUTHORITIES_PER_ADVANCE))
	resumable_service._active_source_census_started_usec = Time.get_ticks_usec()
	var first_authority: Dictionary = {}
	for member_index in range(authority_slice_limit):
		var member_id := "building:member-%03d" % member_index
		var admitted_authority: Dictionary = resumable_service._capture_citadel_member_authority_for_census(
			"site", member_id)
		if member_index == 0: first_authority = admitted_authority
	var deferred_authority: Dictionary = resumable_service._capture_citadel_member_authority_for_census(
		"site", "building:deferred")
	var validated_continuation := SourceRoster._validated_continuation_hint(
		deferred_authority.get("continuationHint"))
	_check("census_slice_admits_bounded_members_and_returns_a_valid_continuation",
		first_authority.get("status") == "ready"
		and deferred_authority.get("reason") == "citadel_section_source_census_slice_pending"
		and resumable_service.authority_calls.size() == authority_slice_limit
		and validated_continuation.get("stage") == "member_authority"
		and validated_continuation.get("cursor") == authority_slice_limit,
		{"first":first_authority, "deferred":deferred_authority,
		"sliceLimit":authority_slice_limit,
		"continuation":validated_continuation, "authorityCalls":resumable_service.authority_calls.size()})
	resumable_service._active_source_census_member_work = 0
	resumable_service._active_source_census_started_usec = Time.get_ticks_usec()
	var resumed_authority: Dictionary = resumable_service._capture_citadel_member_authority_for_census(
		"site", "building:deferred")
	var cached_authority: Dictionary = resumable_service._capture_citadel_member_authority_for_census(
		"site", "building:member-000")
	_check("census_slice_resumes_and_reuses_only_completed_authority",
		resumed_authority.get("status") == "ready"
		and cached_authority.get("artifactAuthorityRevision") \
			== first_authority.get("artifactAuthorityRevision")
		and resumable_service.authority_calls.size() == authority_slice_limit + 1,
		{"resumed":resumed_authority, "cached":cached_authority,
		"authorityCalls":resumable_service.authority_calls.size()})
	var failed: Array[String] = []
	for name: String in checks:
		if not bool(checks[name].get("passed", false)): failed.append(name)
	var result := {"schema":"citadel-nonempty-selector-smoke/v1",
		"passed":failed.is_empty(), "checks":checks, "failedChecks":failed,
		"evidenceLevel":"headless parser and isolated production section-selector smoke",
		"doesNotProve":"Fresh source generation, publication plan, native rendering, visual retirement, live gameplay, or performance."}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(result, "\t")); file.close()
	quit(0 if failed.is_empty() else 1)

func _run() -> void:
	var world := WorldRoot.new()
	world.name = "CitadelNonemptySectionWorld"
	root.add_child(world)
	current_scene = world
	world.static_section_render_root = Node3D.new()
	world.static_section_render_root.name = "StaticSectionRenderOwners"
	world.add_child(world.static_section_render_root)
	_check("canonical_static_section_owner_registry_ready",
		world.static_section_render_root.is_inside_tree())
	if not checks.canonical_static_section_owner_registry_ready.passed:
		_finish()
		return

	owner = RuntimeOwner.new()
	owner.name = "FreshCitadelRuntimeOwner"
	owner.seed_text = SEED
	owner.seed_hash = Service._seed_hash(SEED)
	owner.startup_loading_active = true
	root.add_child(owner)
	owner.set_process(false)
	owner.set_physics_process(false)
	# RuntimeOwner suppresses Main._ready; bind the same real catalog authority
	# Main initializes before admitting structure/tree publication callbacks.
	owner.setup_biome_environment_catalog()
	var catalog = owner.biome_environment_catalog
	_check("real_tree_admission_catalog_ready", is_instance_valid(catalog) and catalog.is_ready(),
		catalog.generation_receipt() if is_instance_valid(catalog) else {})
	if not checks.real_tree_admission_catalog_ready.passed:
		await _shutdown()
		_finish()
		return
	owner.player = FixturePlayer.new()
	owner.player.name = "Player"
	owner.add_child(owner.player)
	owner.player.set_physics_process(false)
	owner.player.main = owner
	owner.structure_system = Structures.new()
	owner.structure_system.citadel_terrain_admission = Admission.new()
	owner.structure_system.setup(owner)
	owner.setup_npc_system()
	owner.npc_system.set_process(false)
	owner.npc_system.set_physics_process(false)
	owner.npc_system.autonomy_system.set_physics_process(false)
	var service = owner.structure_system.citadel_publication
	# One production coordinator owns finite building and admitted tree sources.
	# Bind before the scene job can publish its first tree; no natural-world lane.
	var world_id := "seed:%s:%d" % [SEED, Service._seed_hash(SEED)]
	coordinator = Coordinator.new()
	owner.world_static_section_coordinator = coordinator
	var coordinator_binding: Dictionary = coordinator.configure(world_id)
	var provider_ids: Array[String] = [PROVIDER_ID]
	provider_ids.make_read_only()
	var roster: Dictionary = coordinator.configure_source_roster(provider_ids)
	var registration: Dictionary = coordinator.register_source_provider(PROVIDER_ID, service,
		"capture_static_section_sources")
	var admission = owner.structure_system.citadel_terrain_admission
	var finalization: Dictionary = admission.finalize_town_inputs({})
	var source_request: Dictionary = admission.request_source(REGION, true)
	_check("fresh_seeded_source_admitted_through_real_service", finalization.get("status") == "ready"
		and source_request.get("status") == "pending")
	if not checks.fresh_seeded_source_admitted_through_real_service.passed:
		await _shutdown()
		_finish()
		return

	var source_state: Dictionary = {"status":"pending"}
	var deadline := Time.get_ticks_msec() + SOURCE_DEADLINE_MSEC
	var next_progress := Time.get_ticks_msec()
	while Time.get_ticks_msec() < deadline:
		admission.advance()
		source_state = admission.source_state(REGION)
		if source_state.get("status") in ["ready", "prepared", "failed"]:
			break
		if Time.get_ticks_msec() >= next_progress:
			_progress("fresh_source_" + String(source_state.get("status", "pending")),
				{"admission":admission.stats()})
			next_progress = Time.get_ticks_msec() + 3000
		await process_frame
	_check("deterministic_fresh_site_source_prepared", source_state.get("status") == "ready"
		and source_state.get("source", {}).get("profile", {}).get("siteId", "") \
			== Field.candidate_for_region(SEED, REGION).get("siteId", ""),
		{"status":source_state.get("status", ""), "binding":source_state.get("binding", {}),
			"reservationCells":source_state.get("reservationCells", Rect2i()),
			"blueprintPartCount":source_state.get("source", {}).get("blueprint", {}).get("parts", []).size(),
			"profileSiteId":source_state.get("source", {}).get("profile", {}).get("siteId", "")})
	if not checks.deterministic_fresh_site_source_prepared.passed:
		await _shutdown()
		_finish()
		return
	_progress("fresh_source_prepared", {"siteId":source_state.binding.get("siteId", ""),
		"blueprintParts":source_state.source.get("blueprint", {}).get("parts", []).size()})
	initial_packet_group = _select_initial_packet_group(source_state.source)
	var target_source_part := _source_part_evidence(source_state.source,
		REQUIRED_TRANSFORM_PART_ID)
	_check("required_transform_group_selected_from_real_source_part",
		initial_packet_group == "building:" + REQUIRED_TRANSFORM_PART_ID,
		{"groupId":initial_packet_group, "sourceSiteId":source_state.binding.siteId,
			"requiredPartId":REQUIRED_TRANSFORM_PART_ID,
			"sourcePart":target_source_part})
	_check("required_transform_part_matches_authored_beam_source",
		bool(target_source_part.get("available", false))
		and target_source_part.get("kind") == "beam"
		and target_source_part.get("material") == "stone_foundation"
		and bool(target_source_part.get("visual", false)), target_source_part)
	if not checks.required_transform_group_selected_from_real_source_part.passed \
			or not checks.required_transform_part_matches_authored_beam_source.passed:
		await _shutdown()
		_finish()
		return
	deadline = Time.get_ticks_msec() + PLAN_DEADLINE_MSEC

	var site_bounds := Rect2i(Field.candidate_for_region(SEED, REGION).centerCell, Vector2i.ONE)
	_check("real_runtime_tree_door_and_construction_owners_bound",
		owner.structure_system.citadel_runtime_bindings != null
		and owner.structure_system.citadel_runtime_bindings.available()
		and service.stats().get("doorLifecycleAvailable", false),
		{"runtimeBindingsAvailable":owner.structure_system.citadel_runtime_bindings != null
			and owner.structure_system.citadel_runtime_bindings.available(),
			"doorLifecycleAvailable":service.stats().get("doorLifecycleAvailable", false)})
	var binding: Dictionary = admission.source_state(REGION).get("binding", {})
	var initial_demand := _packet_demand(site_bounds, binding, [initial_packet_group])
	_check("packet_mode_demand_admitted_before_scene_advance",
		service.set_retained_source_requests([initial_demand]),
		{"groupId":initial_packet_group, "binding":binding})
	var base = null
	next_progress = Time.get_ticks_msec()
	while Time.get_ticks_msec() < deadline:
		owner.structure_system.advance_citadel_publication(site_bounds, true)
		var scene_entry: Dictionary = service._scenes.get(REGION, {})
		var scene_job = scene_entry.get("job", null)
		var scene_base = scene_job._cpu.get("publicationBase") if scene_job != null else null
		if scene_base != null and scene_base.publication_plan != null \
				and scene_job._base_packet_mode:
			base = scene_base
			break
		if service.stats().get("fatal", "") != "":
			break
		if service._failures.has(REGION):
			break
		if Time.get_ticks_msec() >= next_progress:
			_progress("publication_plan_advance", {"service":service.stats(),
				"failure":service._failures.get(REGION, {})})
			next_progress = Time.get_ticks_msec() + 3000
		await process_frame
	_check("real_service_built_immutable_packet_mode_publication_plan", base != null,
		{"stats":service.stats(), "failures":service._failures,
			"inflightKind":service._inflight.get("kind", ""),
			"scenePresent":service._scenes.has(REGION),
			"packetMode":bool(service._scenes.get(REGION, {}).get("packetMode", false)),
			"baseAvailable":base != null})
	if base == null:
		await _shutdown()
		_finish()
		return
	_progress("immutable_plan_ready", {"groups":base.publication_plan.order.size(),
		"members":base.publication_plan.member_records.size()})
	var eligibility: Dictionary = Preparation.classify_physical_group_packet_eligibility(
		base.description.publication_groups, base.building_source, base.furnishing_source)
	var bootstrap_eligibility: Dictionary = eligibility.get("groups", {}).get(initial_packet_group, {})
	_check("target_transform_group_has_no_packet_geometry_family",
		eligibility.get("ready", false) and bootstrap_eligibility.get("eligible", false)
		and bootstrap_eligibility.get("families", []).is_empty(),
		{"groupId":initial_packet_group, "eligibility":bootstrap_eligibility,
			"geometryPath":"transform artifact; not prepared masonry/paving/roof packet family"})
	if not checks.target_transform_group_has_no_packet_geometry_family.passed:
		await _shutdown()
		_finish()
		return
	var bootstrap_group_record: Dictionary = base.description.publication_groups.groups.get(
		initial_packet_group, {})
	var target_group_owner := String(base.description.publication_groups.groupByPart.get(
		"building:" + REQUIRED_TRANSFORM_PART_ID, ""))
	_check("target_transform_source_resolves_to_demanded_real_group_owner",
		target_group_owner == initial_packet_group,
		{"sourceMemberId":"building:" + REQUIRED_TRANSFORM_PART_ID,
			"demandedGroupId":initial_packet_group, "actualGroupOwner":target_group_owner})
	if not checks.target_transform_source_resolves_to_demanded_real_group_owner.passed:
		await _shutdown()
		_finish()
		return
	_check("target_transform_group_has_no_tree_publication_dependency",
		bootstrap_group_record.get("treeIndices", []).is_empty(),
		{"groupId":initial_packet_group,
			"treeIndices":bootstrap_group_record.get("treeIndices", [])})

	var plan = base.publication_plan
	var selected := _select_sparse_section(plan, base.publication_plan.eligible_group_ids,
		base.description.publication_groups.groups, base.building_source.get("parts", []), true)
	var unsupported_battlement_gap: Dictionary = selected.get("diagnostics", {}).get(
		"requiredTransformTargetGap", {})
	_check("prepared_packet_selector_reports_battlement_family_gap",
		unsupported_battlement_gap.get("sourcePartId", "") == REQUIRED_TRANSFORM_PART_ID
		and unsupported_battlement_gap.get("visual", false)
		and unsupported_battlement_gap.get("boundsType", "") == "AABB"
		and unsupported_battlement_gap.get("kind", "") == "beam"
		and unsupported_battlement_gap.get("packetGeometryFamily", "") == ""
		and unsupported_battlement_gap.get("packetSupported", true) == false
		and unsupported_battlement_gap.get("reason", "") == "prepared_packet_family_unavailable"
		and unsupported_battlement_gap.get("familyResolver", "") \
			== "BuildingPublicationPreparation._snapshot_geometry_family",
		unsupported_battlement_gap)
	selected_groups.clear()
	for group_value: Variant in selected.get("groupIds", []):
		if group_value is String and not selected_groups.has(group_value):
			selected_groups.append(group_value)
	selected_members.clear()
	for member_value: Variant in selected.get("members", []):
		if member_value is Dictionary:
			selected_members.append(member_value)
	target_member = selected.get("targetMember", {})
	target_part_id = String(target_member.get("memberId", "")).trim_prefix("building:")
	target_geometry_family = String(selected.get("targetGeometryFamily", ""))
	target_section_keys.clear()
	for section_value: Variant in selected.get("targetSectionKeys", []):
		if section_value is Vector3i and not target_section_keys.has(section_value):
			target_section_keys.append(section_value)
	target_section_keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	section_key = selected.get("section", Vector3i(2147483647, 0, 2147483647))
	var selected_building_only := not selected_members.is_empty()
	for selected_member: Dictionary in selected_members:
		var selected_member_id := String(selected_member.get("memberId", ""))
		var selected_member_part_id := selected_member_id.trim_prefix("building:")
		if not selected_member_id.begins_with("building:") \
				or selected_member_part_id == REQUIRED_TRANSFORM_PART_ID \
				or String(selected.get("selectedMemberGeometryFamilies", {}).get(
					selected_member_part_id, "")).is_empty():
			selected_building_only = false
	_check("nonempty_section_selected_from_real_plan", selected.get("status") == "ready"
		and selected_building_only and not selected_groups.is_empty()
		and not target_part_id.is_empty() and target_part_id != REQUIRED_TRANSFORM_PART_ID
		and target_geometry_family in ["masonry", "paving", "roof"]
		and target_section_keys.size() > 1
		and target_section_keys.has(section_key), selected)
	if not checks.nonempty_section_selected_from_real_plan.passed:
		var target_row_samples: Array[Dictionary] = []
		var target_row_count := 0
		for row: Dictionary in plan.member_records:
			if String(row.get("memberId", "")).contains(REQUIRED_TRANSFORM_PART_ID):
				target_row_count += 1
				if target_row_samples.size() < 8:
					target_row_samples.append({"memberId":String(row.get("memberId", "")),
						"groupId":String(row.get("groupId", "")),
						"visual":bool(row.get("visual", false)),
						"boundsType":type_string(typeof(row.get("bounds", null))),
						"bounds":str(row.get("bounds", ""))})
		var selection_evidence := {"status":String(selected.get("status", "")),
			"reason":String(selected.get("reason", "")),
			"diagnostics":selected.get("diagnostics", {}),
			"targetMemberKeys":target_member.keys(),
			"targetRowCount":target_row_count, "targetRowSamples":target_row_samples}
		_progress("nonempty_section_selection_failed", selection_evidence)
		checks.nonempty_section_selected_from_real_plan["evidence"] = selection_evidence
		await _shutdown()
		_finish()
		return
	var target_bounds := target_member.get("bounds") as AABB
	var recomputed_target_sections: Array[Vector3i] = Grid.keys_intersecting_bounds(target_bounds)
	var target_center := target_bounds.get_center()
	# Fixture observation only: the generated source and production geometry stay
	# unchanged. Frame the selected crossing member rather than world origin.
	var observation_distance := maxf(12.0, target_bounds.size.length() * 1.6)
	owner.player.camera.global_position = target_center \
		+ Vector3(0.8, 0.65, 1.0).normalized() * observation_distance
	owner.player.camera.look_at(target_center, Vector3.UP)
	# This fixture disables Main's frame loop. Admit its real camera through the
	# same coordinator entry point that Main uses before requesting glass sources.
	var camera_refresh: Dictionary = coordinator.refresh_visible_section_demand_priorities(
		owner.player.camera.global_position, 16)
	_check("translucent_camera_admitted_through_production_coordinator",
		camera_refresh.get("status") in ["idle", "advanced"], camera_refresh)
	if not checks.translucent_camera_admitted_through_production_coordinator.passed:
		await _shutdown()
		_finish()
		return
	var fixture_light := DirectionalLight3D.new()
	fixture_light.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
	fixture_light.light_energy = 1.2
	world.add_child(fixture_light)
	var fixture_environment := WorldEnvironment.new()
	fixture_environment.environment = Environment.new()
	fixture_environment.environment.background_mode = Environment.BG_COLOR
	fixture_environment.environment.background_color = Color(0.12, 0.17, 0.23)
	fixture_environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	fixture_environment.environment.ambient_light_color = Color(0.75, 0.8, 0.9)
	fixture_environment.environment.ambient_light_energy = 0.65
	world.add_child(fixture_environment)
	_check("target_receipt_set_matches_immutable_plan_member_bounds",
		target_bounds.size.is_finite() and target_center.is_finite()
		and not recomputed_target_sections.is_empty()
		and recomputed_target_sections == target_section_keys,
		{"targetMemberId":target_member.get("memberId", ""),
			"targetAabb":target_bounds, "targetCenter":target_center,
			"computedSections":recomputed_target_sections,
			"targetSectionKeyCount":recomputed_target_sections.size(),
			"selectedSections":target_section_keys,
			"selectedSectionKeyCount":target_section_keys.size(),
			"planMappingDiagnostics":selected.get("diagnostics", {})})
	if not checks.nonempty_section_selected_from_real_plan.passed:
		await _shutdown()
		_finish()
		return

	var request_seeds := selected_groups.duplicate()
	if not request_seeds.has(initial_packet_group): request_seeds.append(initial_packet_group)
	var dependency_closure := _expand_group_dependency_closure(request_seeds,
		base.description.publication_groups.groups)
	var requested_groups: Array[String] = dependency_closure.get("groupIds", [])
	var closure_packet_eligible: bool = dependency_closure.get("status") == "ready"
	var ineligible_closure_group_ids: Array[String] = []
	for group_id: String in requested_groups:
		if not base.publication_plan.eligible_group_ids.has(group_id):
			closure_packet_eligible = false
			ineligible_closure_group_ids.append(group_id)
	_check("packet_demand_includes_plan_derived_transitive_group_dependencies",
		closure_packet_eligible,
		{"seedGroupIds":request_seeds, "closure":dependency_closure,
			"ineligibleClosureGroupIds":ineligible_closure_group_ids,
			"unavailableFailure":service._failures.get(REGION, {})})
	if not checks.packet_demand_includes_plan_derived_transitive_group_dependencies.passed:
		await _shutdown()
		_finish()
		return
	var demand := _packet_demand(site_bounds, binding, requested_groups)
	_check("section_packet_demand_admitted", service.set_retained_source_requests([demand]),
		{"section":section_key, "targetPartId":target_part_id,
			"targetSectionKeys":target_section_keys,
			"members":selected_members, "groupIds":requested_groups,
			"seedGroupIds":request_seeds})
	if not checks.section_packet_demand_admitted.passed:
		await _shutdown()
		_finish()
		return

	var section_proofs: Array[Dictionary] = []
	service.set_source_capture_phase_observer(Callable(self, "_record_admission_phase"))
	next_progress = Time.get_ticks_msec()
	for target_section: Vector3i in target_section_keys:
		var census: Dictionary = {"status":"pending"}
		var contribution: Dictionary = {"status":"pending"}
		while true:
			owner.structure_system.advance_citadel_publication(site_bounds, true)
			census = service.capture_static_section_sources(world_id, [target_section])
			if census.get("status") == "complete":
				var coordinator_census := _coordinator_census(census, target_section)
				contribution = service.capture_static_section_contribution(
					coordinator_census, target_section)
				if contribution.get("status") == "ready":
					break
			if census.get("status") == "failed" or service._failures.has(REGION):
				break
			trace.append({"section":target_section, "admission":admission.stats(),
				"service":service.stats(), "census":census.get("status", ""),
				"censusReason":census.get("reason", ""),
				"contribution":contribution.get("reason", contribution.get("status", ""))})
			if trace.size() > 256: trace.pop_front()
			if Time.get_ticks_msec() >= next_progress:
				_progress("section_contribution_" + String(contribution.get("status", "pending")),
					{"section":target_section,
						"census":census.get("status", ""), "censusReason":census.get("reason", ""),
						"captureProgress":census.get("captureProgress", {}),
						"sourcePartId":census.get("sourcePartId", ""),
						"contributionReason":contribution.get("reason", ""), "service":service.stats()})
				next_progress = Time.get_ticks_msec() + 3000
			await process_frame
		var contribution_value: Dictionary = contribution.get("contribution", {})
		var raw_expected_source_ids: Array = census.get("sections", {}).get(target_section, {}) \
			.get("sourcePartIds", []).duplicate()
		var expected_source_ids: Array[String] = []
		for raw_source_id_value: Variant in raw_expected_source_ids:
			var raw_source_id := String(raw_source_id_value)
			expected_source_ids.append(_section_source_identity_key(
				raw_source_id, raw_source_id))
		expected_source_ids.sort()
		var contributed_source_ids: Array = contribution_value.get(
			"authoritySourceRevisions", {}).keys()
		contributed_source_ids.sort()
		var ready: bool = census.get("status") == "complete" \
			and contribution.get("status") == "ready" \
			and contributed_source_ids == expected_source_ids \
			and (not contribution_value.get("inputs", []).is_empty() \
				or not contribution_value.get("supportRangesBySource", {}).is_empty())
		var expected_source_id := Service._citadel_census_source_id(
			String(binding.get("siteId", "")), String(target_member.get("memberId", "")),
			target_section)
		var expected_source_identity := _section_source_identity_key(
			expected_source_id, expected_source_id)
		var target_source_revision := String(contribution_value.get(
			"authoritySourceRevisions", {}).get(expected_source_identity, ""))
		var section_source_ids: Array = census.get("sections", {}).get(target_section, {}) \
			.get("sourcePartIds", [])
		var target_member_present := expected_source_id in section_source_ids
		ready = ready and target_member_present and not target_source_revision.is_empty()
		section_proofs.append({"section":target_section, "ready":ready,
			"targetMemberPresent":target_member_present,
			"expectedSourceId":expected_source_id,
			"targetSourceRevision":target_source_revision,
			"expectedSourceIds":expected_source_ids,
			"contributedSourceIds":contributed_source_ids,
			"census":census, "contribution":contribution})
		if not ready or service._failures.has(REGION): break
	var all_section_contributions_ready := section_proofs.size() == target_section_keys.size()
	for section_proof: Dictionary in section_proofs:
		if not bool(section_proof.get("ready", false)): all_section_contributions_ready = false
	_check("actual_packet_supported_plan_member_transform_artifact_contribution_ready",
		all_section_contributions_ready,
		{"targetMember":target_member, "targetSections":target_section_keys,
			"sectionProofs":section_proofs,
			"selectedMembers":selected_members, "selectedGroups":selected_groups,
			"serviceStats":service.stats(), "trace":trace.slice(maxi(0, trace.size() - 30)),
			"producerFailureEvidence":_producer_failure_evidence(service, requested_groups,
				binding, section_key, target_part_id, section_proofs) \
				if not all_section_contributions_ready else {}})
	if not checks.actual_packet_supported_plan_member_transform_artifact_contribution_ready.passed:
		await _shutdown()
		_finish()
		return
	_progress("section_contribution_ready", {"sections":target_section_keys,
		"targetPartId":target_part_id, "members":selected_members.size()})
	var actual_owner_sections: Array[Vector3i] = []
	var owner_roster_rows: Array[Dictionary] = []
	var all_owner_rosters_valid := true
	for proof: Dictionary in section_proofs:
		for raw_source_id: String in proof.get("census", {}).get("sections", {}).get(proof.section, {}).get("sourcePartIds", []):
			var full_roster: Dictionary = service._geometry_owner_rosters.get(raw_source_id, {})
			var owners := OwnerCompletion.owner_sections(full_roster)
			var census_revision := String(proof.get("census", {}).get("sourceRevisions", {}).get(raw_source_id, ""))
			var roster_valid: bool = OwnerCompletion.validate(full_roster) \
				and full_roster.get("sourceId") == raw_source_id \
				and full_roster.get("worldId") == world_id and not owners.is_empty() \
				and not census_revision.is_empty() and full_roster.get("sourceRevision") == census_revision
			all_owner_rosters_valid = all_owner_rosters_valid and roster_valid
			owner_roster_rows.append({"sourceId":raw_source_id, "rootSection":proof.section,
				"valid":roster_valid,
				"censusRevision":census_revision, "rosterRevision":full_roster.get("sourceRevision", ""),
				"ownerSections":owners, "memberCount":full_roster.get("members", []).size(),
				"rosterDigest":full_roster.get("digest", "")})
			for owner_section: Vector3i in owners:
				if owner_section not in actual_owner_sections: actual_owner_sections.append(owner_section)
	_check("full_source_geometry_owner_closure_is_explicit_before_native_install",
		all_owner_rosters_valid and not owner_roster_rows.is_empty() \
		and not actual_owner_sections.is_empty(), {"rootSections":target_section_keys,
			"actualOwnerSections":actual_owner_sections, "ownerCount":actual_owner_sections.size(),
			"sourceRosters":owner_roster_rows,
			"closureScope":"actual owners of root-section source parts; no recursive expansion from owner-section neighbors"})
	if OS.get_environment(PREFLIGHT_ENV) == "1":
		var complete_roster := section_proofs.size() == target_section_keys.size()
		for proof: Dictionary in section_proofs:
			if not _preflight_section_proof_is_complete(proof): complete_roster = false
		_check("preflight_every_required_section_has_complete_capturable_roster",
			complete_roster,
			{"sectionProofs":section_proofs, "requiredSections":target_section_keys})
		await _shutdown()
		_finish()
		return

	var publisher_before_result: Dictionary = service._current_packet_publisher_for_site(String(binding.siteId))
	var publisher_before = publisher_before_result.get("publisher")
	var visuals_before := _publisher_visuals_for_section(publisher_before, section_key)
	var target_visuals_before: Array = []
	for visual: GeometryInstance3D in visuals_before:
		if String(visual.get_meta("building_source_part_id", "")) == target_part_id:
			target_visuals_before.append(visual)
	var old_visuals_visible_before_receipt := not visuals_before.is_empty()
	var visible_visual_count := 0
	for visual: GeometryInstance3D in visuals_before:
		if visual.visible: visible_visual_count += 1
		else: old_visuals_visible_before_receipt = false
	var expected_part_ids: Array[String] = []
	var empty_projection_part_ids: Array[String] = []
	var selected_rosters_valid := true
	var selected_section_revisions: Dictionary = {}
	for proof: Dictionary in section_proofs:
		if proof.get("section") == section_key:
			selected_section_revisions = proof.get("census", {}).get("sourceRevisions", {})
			break
	for selected_member: Dictionary in selected_members:
		var selected_part_id := String(selected_member.get("memberId", "")).trim_prefix("building:")
		var selected_source_id := Service._citadel_census_source_id(
			String(binding.siteId), String(selected_member.get("memberId", "")), section_key)
		var selected_roster: Dictionary = service._geometry_owner_rosters.get(selected_source_id, {})
		if not OwnerCompletion.validate(selected_roster) \
				or String(selected_roster.get("sourceId", "")) != selected_source_id \
				or bool(selected_roster.get("explicitRemoval", true)) \
				or (selected_roster.get("members", []) as Array).is_empty() \
				or String(selected_section_revisions.get(selected_source_id, "")).is_empty() \
				or String(selected_roster.get("sourceRevision", "")) \
				!= String(selected_section_revisions.get(selected_source_id, "")):
			selected_rosters_valid = false
			continue
		if OwnerCompletion.owner_sections(selected_roster).has(section_key):
			if not expected_part_ids.has(selected_part_id): expected_part_ids.append(selected_part_id)
		elif not empty_projection_part_ids.has(selected_part_id):
			empty_projection_part_ids.append(selected_part_id)
	expected_part_ids.sort()
	empty_projection_part_ids.sort()
	var observed_part_ids := _observed_part_ids(visuals_before)
	var observed_target_sections := _visual_section_keys(target_visuals_before)
	_check("legacy_visuals_cover_every_selected_section_member",
		selected_rosters_valid and expected_part_ids == observed_part_ids,
		{"expectedPartIds":expected_part_ids, "observedPartIds":observed_part_ids,
			"emptyProjectionPartIds":empty_projection_part_ids,
			"selectedRostersValid":selected_rosters_valid})
	_check("target_member_plan_bounds_match_legacy_visual_section_closure",
		not target_visuals_before.is_empty() and observed_target_sections == target_section_keys,
		{"targetPartId":target_part_id, "plannedSections":target_section_keys,
			"observedVisualSections":observed_target_sections,
			"visualCount":target_visuals_before.size()})
	var building_job = service._scenes.get(REGION, {}).get("job", null)
	var door_ids_before: Dictionary = building_job._door_registered_ids.duplicate() \
		if building_job != null else {}
	var collision_body_before = publisher_before.get("static_collision_body") \
		if publisher_before != null else null
	_check("legacy_building_visuals_visible_before_candidate_submission",
		old_visuals_visible_before_receipt and not target_visuals_before.is_empty(),
		{"targetPartId":target_part_id,
			"publisher":publisher_before_result.get("status", ""),
			"matchedVisuals":visuals_before.size(),
			"visibleVisuals":visible_visual_count})
	await _exercise_full_owner_lifecycle(world, service, base.publication_plan,
		base.description.publication_groups.groups, site_bounds, binding,
		actual_owner_sections, owner_roster_rows, publisher_before,
		collision_body_before, building_job, door_ids_before)
	var assertions_passed := true
	for check_value: Dictionary in checks.values():
		assertions_passed = assertions_passed and bool(check_value.get("passed", false))
	var capture_ack := await _wait_for_final_viewport_capture_ack(assertions_passed)
	_check("installed_owner_closure_viewport_captured_before_teardown", capture_ack.get("captured", false), capture_ack)
	await _release_fixture_owner_slots(world, actual_owner_sections)
	await _shutdown()
	_finish()

func _exercise_full_owner_lifecycle(world: WorldRoot, service, plan,
		publication_groups: Dictionary, site_bounds: Rect2i, binding: Dictionary,
		owner_sections: Array[Vector3i], roster_rows: Array[Dictionary], publisher,
		collision_before, building_job, doors_before: Dictionary) -> void:
	var started := Time.get_ticks_usec()
	var group_seeds: Array[String] = []
	# Readiness is the exit signal: each owner remains admitted until its current
	# complete contribution arrives, then the whole-section install gate runs.
	for section: Vector3i in owner_sections:
		var description: Dictionary = plan.visual_members_intersecting_bounds(
			AABB(Grid.origin_for_key(section), Vector3.ONE * Grid.SECTION_SIZE_METERS))
		if description.get("status") != "described":
			_check("measured_owner_sections_have_complete_plan_membership", false, description)
			return
		for member: Dictionary in description.get("members", []):
			var group := String(member.get("groupId", ""))
			if not group.is_empty() and group not in group_seeds: group_seeds.append(group)
	var closure := _expand_group_dependency_closure(group_seeds, publication_groups)
	var groups: Array[String] = closure.get("groupIds", [])
	var initial_window := _next_owner_publication_window(groups, publication_groups,
		building_job.completed_physical_group_ids(binding))
	var request := _packet_demand(site_bounds, binding, groups)
	request.sites[0]["foregroundGroupIds"] = initial_window.get("groupIds", [])
	_check("measured_owner_sections_admit_only_plan_derived_group_dependencies",
		closure.get("status") == "ready" and initial_window.get("status") == "ready"
		and service.set_retained_source_requests([request]),
		{"ownerCount":owner_sections.size(), "seedGroupCount":group_seeds.size(), "closure":closure, "initialWindow":initial_window})
	if not checks.measured_owner_sections_admit_only_plan_derived_group_dependencies.passed: return
	var prepared: Dictionary = {}
	var deadline := Time.get_ticks_msec() + PLAN_DEADLINE_MSEC
	var next_progress := Time.get_ticks_msec()
	var max_prepare_usec := 0
	var window: Dictionary = initial_window
	var window_count := 1
	while Time.get_ticks_msec() < deadline:
		var phase_started := Time.get_ticks_usec()
		owner.structure_system.advance_citadel_publication(site_bounds, true)
		var completed: Dictionary = building_job.completed_physical_group_ids(binding)
		var window_complete := true
		for group_id: String in window.get("groupIds", []):
			window_complete = window_complete and completed.has(group_id)
		var packet_demand: Dictionary = service._scenes.get(REGION, {}).get("packetDemandStatus", {})
		if packet_demand.get("status") == "failed":
			_check("owner_publication_windows_remain_admitted", false, {"window":window, "packetDemand":packet_demand})
			return
		if window_complete:
			window = _next_owner_publication_window(groups, publication_groups, completed)
			if window.get("status") != "ready":
				_check("owner_publication_windows_remain_admitted", false, window)
				return
			if window.get("groupIds", []).is_empty(): break
			request.sites[0]["foregroundGroupIds"] = window.groupIds
			if not service.set_retained_source_requests([request]):
				_check("owner_publication_windows_remain_admitted", false, {"reason":"retained_window_rejected", "window":window})
				return
			window_count += 1
		if Time.get_ticks_msec() >= next_progress:
			_progress("owner_publication_window_preparation", {"windowIndex":window_count,
				"windowGroupCount":window.get("groupIds", []).size(), "completedGroupCount":completed.size(),
				"requiredGroupCount":groups.size(), "service":service.stats()})
			next_progress = Time.get_ticks_msec() + 3000
		max_prepare_usec = maxi(max_prepare_usec, Time.get_ticks_usec() - phase_started)
		await process_frame
	_check("owner_publication_windows_complete_through_real_group_receipts", window.get("groupIds", []).is_empty(),
		{"windowCount":window_count, "remainingWindow":window, "service":service.stats()})
	if not checks.owner_publication_windows_complete_through_real_group_receipts.passed: return
	# Capture waits for current source readiness. It does not turn a valid pending
	# contribution into failure on a fixture timer; the owned runner watchdog
	# remains the process safety boundary.
	for section: Vector3i in owner_sections:
		var census: Dictionary = {}
		var contribution: Dictionary = {}
		while true:
			var phase_started := Time.get_ticks_usec()
			owner.structure_system.advance_citadel_publication(site_bounds, true)
			census = service.capture_static_section_sources(String(coordinator._world_id), [section])
			if census.get("status") == "complete":
				contribution = service.capture_static_section_contribution(_coordinator_census(census, section), section)
			var packet_demand: Dictionary = service._scenes.get(REGION, {}).get("packetDemandStatus", {})
			if packet_demand.get("status") == "failed":
				_check("owner_source_preparation_demand_remains_admitted", false,
					{"section":section, "census":census, "packetDemand":packet_demand, "service":service.stats()})
				return
			max_prepare_usec = maxi(max_prepare_usec, Time.get_ticks_usec() - phase_started)
			if census.get("status") == "complete" and contribution.get("status") == "ready": break
			if census.get("status") == "failed" or contribution.get("status") == "failed": break
			if Time.get_ticks_msec() >= next_progress:
				_progress("owner_closure_source_preparation", {"section":section,
					"preparedOwners":prepared.size(), "ownerCount":owner_sections.size(),
					"census":census if census.get("status") != "complete" else {},
					"packetDemandStatus":packet_demand.get("status", ""), "packetDemandReason":packet_demand.get("reason", ""),
					"censusReason":census.get("reason", ""), "contributionReason":contribution.get("reason", ""),
					"contributionCompletedSourceCount":int(contribution.get("completedSourceCount", -1)),
					"contributionRequiredSourceCount":int(contribution.get("requiredSourceCount", -1)),
					"contributionSourceArtifactCacheHitCount":int(contribution.get("sourceArtifactCacheHitCount", -1)),
					"contributionSourceLookupUsec":int(contribution.get("sourceLookupUsec", -1)),
					"contributionColdCaptureUsec":int(contribution.get("coldCaptureUsec", -1)),
					"contributionMaxSourceCaptureUsec":int(contribution.get("maxSourceCaptureUsec", -1)),
					"contributionAdapterUsec":int(contribution.get("adapterUsec", -1)),
					"contributionFinalValidationUsec":int(contribution.get("finalValidationUsec", -1)),
					"contributionCandidateGeneration":int(contribution.get("continuationHint", {}).get(
						"candidateGeneration", -1))})
				next_progress = Time.get_ticks_msec() + 3000
			await process_frame
		if census.get("status") != "complete" or contribution.get("status") != "ready":
			_check("every_measured_owner_has_complete_capturable_section", false,
				{"section":section, "census":census, "contribution":contribution, "preparedCount":prepared.size(), "service":service.stats()})
			return
		prepared[section] = true
	_check("every_measured_owner_has_complete_capturable_section", prepared.size() == owner_sections.size(),
		{"ownerCount":owner_sections.size(), "groupCount":groups.size(),
			"prepareElapsedUsec":Time.get_ticks_usec() - started, "maxPreparePhaseUsec":max_prepare_usec})
	var root_rosters: Dictionary = {}
	for row: Dictionary in roster_rows:
		var source_id := String(row.sourceId)
		var current: Dictionary = service._geometry_owner_rosters.get(source_id, {})
		if current.get("digest") != row.rosterDigest:
			_check("root_full_part_rosters_remain_current_after_owner_preparation", false, {"sourceId":source_id})
			return
		root_rosters[source_id] = current
	_check("root_full_part_rosters_remain_current_after_owner_preparation", not root_rosters.is_empty(),
		{"sourceCount":root_rosters.size(), "ownerCount":owner_sections.size()})
	var doors_at_install: Dictionary = building_job._door_registered_ids.duplicate()
	var legacy_visuals: Dictionary = {}
	var legacy_ids: Dictionary = {}
	var native_tree_sources: Array[String] = []
	for source_id: String in root_rosters:
		var root_member := Service.SectionGeometryAdapter._member_id_from_census_source(source_id)
		if root_member.begins_with("tree:"):
			var tree_source: Dictionary = building_job.capture_tree_section_source(root_member, binding)
			if tree_source.get("status") != "ready":
				_check("root_tree_sources_are_actual_retained_compiler_artifacts", false, tree_source)
				return
			legacy_visuals[source_id] = tree_source.producer
			native_tree_sources.append(source_id)
			continue
		var part_id := String(Service.SectionGeometryAdapter._member_id_from_census_source(source_id)).trim_prefix("building:")
		var refs: Array = []
		var ids: Array = []
		for visual: GeometryInstance3D in Service._published_legacy_geometry(publisher):
			if String(visual.get_meta("building_source_part_id", "")) == part_id:
				refs.append(weakref(visual))
				ids.append(visual.get_instance_id())
		legacy_visuals[source_id] = refs
		legacy_ids[source_id] = ids
	var legacy_captured := true
	for source_id: String in root_rosters:
		legacy_captured = legacy_captured and _legacy_visuals_match(publisher, legacy_visuals[source_id], true)
	_check("root_parts_capture_exact_visible_legacy_identities_before_admission", legacy_captured,
		{"visualIdsBySource":legacy_ids, "nativeOnlyTreeSources":native_tree_sources,
			"treeEvidence":"exact admitted compiler/body source before native installation; no legacy child required"})
	if not legacy_captured: return
	var prior_doors_preserved := true
	for door_id: Variant in doors_before:
		prior_doors_preserved = prior_doors_preserved and doors_at_install.get(door_id) == doors_before[door_id]
	for section: Vector3i in target_section_keys:
		coordinator.request_visible_section_demand(section, 1, 0.0)
	var initial := await _drive_root_owner_closure(service, site_bounds, owner_sections, root_rosters, publisher, legacy_visuals)
	_check("root_demands_install_exact_native_owner_closure_and_settle_root_ack", initial.get("status") == "ready", initial)
	if initial.get("status") != "ready": return
	var native_trees_installed := true
	for tree_source_id: String in native_tree_sources:
		native_trees_installed = native_trees_installed and _legacy_visuals_match(publisher, legacy_visuals[tree_source_id], false)
	_check("finite_tree_members_have_exact_native_receipts_without_legacy_nodes", native_trees_installed,
		{"treeSourceCount":native_tree_sources.size(), "treeSourceIds":native_tree_sources,
			"coverage":"only admitted tree members in the unchanged root census; zero means no tree acceptance evidence"})
	_check("root_owner_closure_keeps_gameplay_collision_and_door_authorities",
		publisher.get("static_collision_body") == collision_before and is_instance_valid(collision_before) \
		and prior_doors_preserved and building_job._door_registered_ids == doors_at_install,
		{"collisionBodyId":collision_before.get_instance_id() if is_instance_valid(collision_before) else 0,
			"doorRegistrationCount":doors_at_install.size()})
	var root_cells: Dictionary = {}
	for section: Vector3i in target_section_keys: root_cells[Grid.chunk_key_for_section(section)] = true
	var external_cell: Variant = null
	for section: Vector3i in owner_sections:
		var cell := Grid.chunk_key_for_section(section)
		if not root_cells.has(cell): external_cell = cell; break
	_check("root_part_requires_real_external_renderer_owner", external_cell is Vector2i, {"ownerCell":external_cell})
	if not external_cell is Vector2i: return
	var prior_owner: Dictionary = world.get_static_section_render_owner(external_cell, false)
	var previous_owner_id: int = prior_owner.owner.get_instance_id()
	var previous_backend_id: int = prior_owner.backend.get_instance_id()
	for section: Vector3i in target_section_keys: coordinator.withdraw_visible_section_demand(section)
	var released: Dictionary = coordinator.reconcile_ordinary_geometry_support_owner_demands()
	_check("root_demand_exit_releases_nonrecursive_owner_leases", released.get("ownerSections", {}).is_empty()
		and int(released.get("pendingReleaseOwnerCount", -1)) == 0, released)
	if not checks.root_demand_exit_releases_nonrecursive_owner_leases.passed: return
	var owner_retirement: Dictionary = coordinator.request_stream_chunk_owner_retirement(external_cell, previous_owner_id)
	if owner_retirement.get("status") == "pending":
		await process_frame
		await RenderingServer.frame_post_draw
		owner_retirement = coordinator.request_stream_chunk_owner_retirement(external_cell, previous_owner_id)
	_check("external_owner_retirement_acknowledged_before_backend_cleanup", owner_retirement.get("status") == "ready", owner_retirement)
	if owner_retirement.get("status") != "ready": return
	var restored := true
	var affected_count := 0
	for source_id: String in root_rosters:
		var affected := false
		for section: Vector3i in OwnerCompletion.owner_sections(root_rosters[source_id]):
			if Grid.chunk_key_for_section(section) == external_cell: affected = true
		if not affected: continue
		affected_count += 1
		restored = restored and _legacy_visuals_match(publisher, legacy_visuals[source_id], true)
	_check("external_owner_unload_restores_affected_legacy_before_native_cleanup", restored and affected_count > 0,
		{"affectedSourceCount":affected_count, "ownerCell":external_cell})
	var removed_sections: Array[Vector3i] = []
	for section: Vector3i in owner_sections:
		if Grid.chunk_key_for_section(section) == external_cell: removed_sections.append(section)
	await _release_fixture_owner_slots(world, removed_sections, false)
	world.static_section_render_owners.erase(external_cell)
	prior_owner.owner.queue_free()
	await process_frame
	for section: Vector3i in target_section_keys: coordinator.request_visible_section_demand(section, 1, 0.0)
	var replay := await _drive_root_owner_closure(service, site_bounds, owner_sections, root_rosters, publisher, legacy_visuals)
	var replacement_owner: Dictionary = world.get_static_section_render_owner(external_cell, false)
	_check("root_reentry_replays_fresh_external_owner_before_full_part_retirement",
		replay.get("status") == "ready" and replacement_owner.get("status") == "ready" \
		and replacement_owner.owner.get_instance_id() != previous_owner_id \
		and replacement_owner.backend.get_instance_id() != previous_backend_id,
		{"replay":replay, "oldOwnerId":previous_owner_id, "oldBackendId":previous_backend_id,
			"newOwnerId":replacement_owner.owner.get_instance_id() if replacement_owner.get("status") == "ready" else 0})


func _next_owner_publication_window(groups: Array[String], publication_groups: Dictionary, completed: Dictionary) -> Dictionary:
	var selected: Dictionary = {}
	var seeds := 0
	for group_id: String in groups:
		if completed.has(group_id): continue
		var closure := _expand_group_dependency_closure([group_id], publication_groups)
		if closure.get("status") != "ready": return closure
		var pending: Dictionary = {}
		for dependency: String in closure.get("groupIds", []):
			if not completed.has(dependency): pending[dependency] = true
		if pending.size() > Service.MAX_REQUIRED_FOREGROUND_GROUPS:
			return {"status":"failed", "reason":"single_owner_seed_closure_exceeds_production_cap",
				"groupId":group_id, "expandedPendingCount":pending.size()}
		var merged := selected.duplicate()
		merged.merge(pending)
		if merged.size() > Service.MAX_REQUIRED_FOREGROUND_GROUPS: break
		selected = merged
		seeds += 1
		if seeds >= 128: break
	var result: Array[String] = []
	for id: String in selected: result.append(id)
	result.sort()
	return {"status":"ready", "groupIds":result, "seedCount":seeds,
		"expandedPendingCount":result.size(), "productionCap":Service.MAX_REQUIRED_FOREGROUND_GROUPS}


func _legacy_visuals_match(publisher, expected: Variant, visible: bool) -> bool:
	if expected is Dictionary:
		# Section-only trees have no legacy node. Require the actual queue owner,
		# body incarnation and native receipt; a fake named child is never proof.
		var body_reference: Variant = expected.get("body")
		var queue_reference: Variant = expected.get("queue")
		var body: Variant = body_reference.get_ref() if body_reference is WeakRef else null
		var queue: Variant = queue_reference.get_ref() if queue_reference is WeakRef else null
		if not is_instance_valid(body) or not is_instance_valid(queue) \
				or body.get_instance_id() != expected.get("bodyInstanceId") \
				or queue.get_instance_id() != expected.get("queueInstanceId"): return false
		var proof: Dictionary = queue.call("tree_publication_proof", body, not visible)
		if visible: return bool(proof.get("sourcePrepared", false))
		return bool(proof.get("installed", false)) and proof.get("representation") == "section" \
			and body.get_node_or_null("GeneratedTreeVisual") == null
	if not expected is Array: return false
	if expected.is_empty() or not is_instance_valid(publisher): return false
	var current_visuals := Service._published_legacy_geometry(publisher)
	for reference: WeakRef in expected:
		var value: Variant = reference.get_ref()
		if not is_instance_valid(value) or not value is GeometryInstance3D: return false
		var visual: GeometryInstance3D = value
		if visual.is_queued_for_deletion() \
				or visual not in current_visuals or visual.visible != visible:
			return false
	return true


func _legacy_visual_diagnostic(publisher, expected: Variant) -> Dictionary:
	var current_visuals := Service._published_legacy_geometry(publisher) \
		if is_instance_valid(publisher) else []
	var rows: Array[Dictionary] = []
	if expected is Array:
		for reference_value: Variant in expected:
			var value: Variant = reference_value.get_ref() \
				if reference_value is WeakRef else null
			if not is_instance_valid(value):
				rows.append({"instanceId":0, "valid":false})
				continue
			var visual := value as GeometryInstance3D
			var native_binding := Service._native_legacy_claim(visual)
			var native_claim: Dictionary = native_binding.get("claim", {})
			rows.append({"instanceId":visual.get_instance_id(), "valid":true,
				"insideTree":visual.is_inside_tree(),
				"queuedForDeletion":visual.is_queued_for_deletion(),
				"visible":visual.visible, "inCurrentPublisher":visual in current_visuals,
				"sourcePartId":String(visual.get_meta("building_source_part_id", "")),
				"sectionOwned":bool(visual.get_meta("citadel_section_owned", false)),
				"sectionOwnedSourceId":String(visual.get_meta("citadel_section_owned_source_id", "")),
				"nativeBackendId":int(visual.get_meta("section_attachment_native_backend_id", 0)),
				"nativeClaim":native_claim})
	return {"expectedCount":expected.size() if expected is Array else -1,
		"visuals":rows}


func _section_fallback_diagnostic(coordinator_value, roster: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for section: Vector3i in OwnerCompletion.owner_sections(roster):
		var current_candidate: Dictionary = coordinator_value._production_candidates_by_section.get(
			section, {})
		var current_receipt: Dictionary = coordinator_value._production_candidate_receipts.get(
			section, {})
		var owner_cell := Grid.chunk_key_for_section(section)
		var owner := PacketOwner.resolve_existing_static_section_backend(owner_cell)
		var installed: Dictionary = {}
		var pending_presentation: Dictionary = {}
		var backend_instance_id := 0
		var chunk_instance_id := 0
		if owner.get("status") == "ready":
			var backend: Node = owner.get("backend") as Node
			var chunk: Node3D = owner.get("chunk") as Node3D
			backend_instance_id = backend.get_instance_id() if is_instance_valid(backend) else 0
			chunk_instance_id = chunk.get_instance_id() if is_instance_valid(chunk) else 0
			if is_instance_valid(backend) and backend.has_method("installed_snapshot"):
				var slot_id := InstallSession.slot_id(String(roster.worldId), section)
				installed = backend.call("installed_snapshot", slot_id)
				if backend.has_method("pending_presentation_snapshot"):
					pending_presentation = backend.call("pending_presentation_snapshot", slot_id)
		rows.append({"section":section,
			"candidateGeneration":int(current_candidate.get("generation", -1)),
			"candidateManifestDigest":String(current_candidate.get("contentManifestDigest", "")),
			"candidateReceiptCurrent":coordinator_value.installed_section_receipt_is_current(
				section, current_receipt),
			"receiptGeneration":int(current_receipt.get("generation", -1)),
			"receiptManifestDigest":String(current_receipt.get("contentManifestDigest", "")),
			"receiptBackendId":int(current_receipt.get("backendInstanceId", 0)),
			"receiptChunkId":int(current_receipt.get("chunkInstanceId", 0)),
			"backendInstanceId":backend_instance_id,
			"chunkInstanceId":chunk_instance_id,
			"ownerStatus":String(owner.get("status", "")),
			"installed":installed, "pendingPresentation":pending_presentation})
	return rows


func _root_roster_has_current_or_presenting_sections(coordinator_value,
		roster: Dictionary) -> Dictionary:
	var pending_sections: Array[Vector3i] = []
	var checked_sections: Array[Vector3i] = []
	for section: Vector3i in OwnerCompletion.owner_sections(roster):
		checked_sections.append(section)
		var receipt: Dictionary = coordinator_value._production_candidate_receipts.get(
			section, {})
		if coordinator_value.installed_section_receipt_is_current(section, receipt):
			continue
		var candidate_job: Dictionary = coordinator_value._production_candidate_jobs.get(
			section, {})
		var candidate: Dictionary = candidate_job.get("candidate", {}) \
			if not candidate_job.is_empty() else coordinator_value._production_candidates_by_section.get(
				section, {})
		if candidate.is_empty():
			return {"status":"pending", "reason":"owner_section_candidate_missing",
				"section":section, "checkedSections":checked_sections}
		var owner_cell := Grid.chunk_key_for_section(section)
		var owner := PacketOwner.resolve_existing_static_section_backend(owner_cell)
		if owner.get("status") != "ready":
			return {"status":"pending", "reason":"owner_section_backend_unavailable",
				"section":section, "owner":owner, "checkedSections":checked_sections}
		var backend: Node = owner.get("backend") as Node
		if not is_instance_valid(backend) or not backend.has_method("pending_presentation_snapshot"):
			return {"status":"pending", "reason":"owner_section_pending_presentation_unavailable",
				"section":section, "checkedSections":checked_sections}
		var slot_id := InstallSession.slot_id(String(roster.worldId), section)
		var pending: Dictionary = backend.call("pending_presentation_snapshot", slot_id)
		var candidate_digest := String(candidate.get("contentManifestDigest", ""))
		if pending.get("status") != "pending_presentation" \
				or int(pending.get("generation", -1)) != int(candidate.get("generation", -2)) \
				or String(pending.get("packetDigest", "")) != candidate_digest \
				or String(pending.get("sourceId", "")) != slot_id:
			return {"status":"pending", "reason":"owner_section_exact_presentation_not_current",
				"section":section, "candidateGeneration":candidate.get("generation", -1),
				"candidateDigest":candidate_digest, "presentation":pending,
				"checkedSections":checked_sections}
		pending_sections.append(section)
	return {"status":"ready", "sections":checked_sections,
		"pendingPresentationSections":pending_sections,
		"requiresFrameRetry":not pending_sections.is_empty()}


func _drive_root_owner_closure(service, site_bounds: Rect2i, owner_sections: Array[Vector3i],
		root_rosters: Dictionary, publisher, legacy_visuals: Dictionary) -> Dictionary:
	service.set_source_capture_phase_observer(Callable(self, "_record_admission_phase"))
	var started := Time.get_ticks_usec()
	var next_progress := Time.get_ticks_msec()
	var max_phase_usec := 0
	var max_frame_usec := 0
	var last_frame := started
	var retention_valid := true
	var partial_observed := false
	var leases: Dictionary = {}
	var frames := 0
	var presentation_retry_count := 0
	var receipts: Dictionary = {}
	var retention_failures: Array[Dictionary] = []
	var phase_times: Dictionary = {}
	var phase_max: Dictionary = {}
	var phase_details: Dictionary = {}
	var provider_ack_phase_max_usec: Dictionary = {}
	var provider_ack_work_totals: Dictionary = {}
	while true:
		_active_closure_frame = frames
		var phase_started := Time.get_ticks_usec()
		max_frame_usec = maxi(max_frame_usec, phase_started - last_frame)
		last_frame = phase_started
		_mark_active_phase("publication_advance", frames)
		owner.structure_system.advance_citadel_publication(site_bounds, true)
		phase_times = {"publicationUsec":Time.get_ticks_usec() - phase_started}
		var phase_mark := Time.get_ticks_usec()
		_mark_active_phase("visible_candidate_admission", frames)
		coordinator.advance_visible_section_candidate_demands(2, false,
			Callable(self, "_record_admission_phase"))
		phase_times["candidateAdmissionUsec"] = Time.get_ticks_usec() - phase_mark
		phase_mark = Time.get_ticks_usec()
		_mark_active_phase("candidate_and_ack_advance", frames)
		var candidate_advance: Dictionary = coordinator.advance_queued_complete_section_candidates(4, 8)
		phase_times["candidateAdvanceUsec"] = Time.get_ticks_usec() - phase_mark
		var queued_phases: Variant = candidate_advance.get("phaseUsec", {})
		if queued_phases is Dictionary:
			for phase_name: Variant in queued_phases:
				phase_times["advance_" + String(phase_name)] = int(queued_phases[phase_name])
		var compile_samples: Array = []
		for value: Variant in candidate_advance.get("compileResults", []):
			if value is Dictionary:
				compile_samples.append({"sectionKey":value.get("sectionKey"),
					"status":value.get("status"), "reason":value.get("reason", ""),
					"phaseUsec":value.get("phaseUsec", {}),
					"censusProviderPhaseUsec":value.get("censusProviderPhaseUsec", {})})
		var install_samples: Array = []
		for value: Variant in candidate_advance.get("results", []):
			if value is Dictionary:
				install_samples.append({"sectionKey":value.get("sectionKey"),
					"stage":value.get("stage", ""), "status":value.get("status", ""),
					"reason":value.get("reason", ""), "phaseUsec":value.get("phaseUsec", {}),
					"sourceAcknowledgements":value.get("sourceAcknowledgements", {})})
		var acknowledgement_samples: Array = []
		for value: Variant in candidate_advance.get("acknowledgements", []):
			if value is Dictionary:
				var provider_results: Array[Dictionary] = []
				var provider_acknowledgements: Dictionary = value.get(
					"providerAcknowledgements", {})
				for provider_row_value: Variant in provider_acknowledgements.get(
					"providerAcknowledgements", []):
					if provider_row_value is Dictionary:
						var provider_row: Dictionary = provider_row_value
						var provider_result: Dictionary = provider_row.get("result", {})
						var ack_diagnostics: Dictionary = provider_result.get("ackDiagnostics", {})
						for phase_value: Variant in ack_diagnostics.get("phaseUsec", {}):
							var phase_name := String(phase_value)
							provider_ack_phase_max_usec[phase_name] = maxi(
								int(provider_ack_phase_max_usec.get(phase_name, 0)),
								int(ack_diagnostics.phaseUsec[phase_value]))
						for count_value: Variant in ack_diagnostics.get("counts", {}):
							var count_name := String(count_value)
							provider_ack_work_totals[count_name] = int(
								provider_ack_work_totals.get(count_name, 0)) + int(
								ack_diagnostics.counts[count_value])
						var visual_result_sample: Array[Dictionary] = []
						for visual_value: Variant in provider_result.get("visualResults", []):
							if visual_value is Dictionary and visual_result_sample.size() < 4:
								var visual_result: Dictionary = visual_value
								visual_result_sample.append({"sourceId":visual_result.get("sourceId", ""),
									"status":visual_result.get("status", ""),
									"reason":visual_result.get("reason", ""),
									"sectionKey":visual_result.get("sectionKey", null),
									"nodeInstanceId":visual_result.get("nodeInstanceId", 0)})
						provider_results.append({"providerId":provider_row.get("providerId", ""),
							"status":provider_result.get("status", ""),
							"reason":provider_result.get("reason", ""),
							"ackDiagnostics":provider_result.get("ackDiagnostics", {}),
							"indexedNodeCount":provider_result.get("indexedNodeCount", -1),
							"pendingNodeCount":provider_result.get("pendingNodeCount", -1),
							"waitingVisualCount":provider_result.get("waitingVisualCount", 0),
							"visualResults":visual_result_sample,
							"receiptValidationScope":provider_result.get(
								"receiptValidationScope", {})})
				acknowledgement_samples.append({"sectionKey":value.get("sectionKey"),
					"status":value.get("status", ""), "reason":value.get("reason", ""),
					"censusProviderPhaseUsec":value.get("censusProviderPhaseUsec", {}),
					"providerPhaseUsec":value.get("providerAcknowledgements", {}).get(
						"providerPhaseUsec", {}), "providerResults":provider_results})
		phase_details = {"queuedAdvancePhaseUsec":queued_phases,
			"providerAckPhaseMaxUsec":provider_ack_phase_max_usec,
			"providerAckWorkTotals":provider_ack_work_totals,
			"compileSamples":compile_samples, "installSamples":install_samples,
			"acknowledgementSamples":acknowledgement_samples}
		phase_mark = Time.get_ticks_usec()
		_mark_active_phase("support_reconciliation", frames)
		leases = coordinator.reconcile_ordinary_geometry_support_owner_demands()
		phase_times["supportReconciliationUsec"] = Time.get_ticks_usec() - phase_mark
		phase_mark = Time.get_ticks_usec()
		_mark_active_phase("receipt_retention_checks", frames)
		for demanded_section: Vector3i in coordinator._visible_section_demands:
			_mark_active_phase("retention:visible_demand_closure:%s" % str(demanded_section), frames)
			if demanded_section not in owner_sections:
				return {"status":"failed", "reason":"owner_lease_recursively_expanded", "section":demanded_section}
		receipts = {}
		for section: Vector3i in owner_sections:
			_mark_active_phase("retention:installed_receipt_collection:%s" % str(section), frames)
			var receipt: Dictionary = coordinator._production_candidate_receipts.get(section, {})
			if not receipt.is_empty(): receipts[section] = receipt
		if not receipts.is_empty() and receipts.size() < owner_sections.size(): partial_observed = true
		var retry_after_presentation_frame := false
		var presentation_retry_samples: Array[Dictionary] = []
		for source_id: String in root_rosters:
			_mark_active_phase("retention:source_receipt_proof:%s" % source_id, frames)
			var source_receipts_ready := true
			var pending_owner_checks: Array[Dictionary] = []
			for owner_section: Vector3i in OwnerCompletion.owner_sections(root_rosters[source_id]):
				_mark_active_phase("retention:section_ack_proof:%s:%s" % [source_id,
					str(owner_section)], frames)
				var owner_receipt: Dictionary = coordinator._production_candidate_receipts.get(
					owner_section, {})
				if owner_receipt.is_empty():
					if pending_owner_checks.size() < 4:
						pending_owner_checks.append({"section":owner_section,
							"reason":"installed_receipt_missing"})
					source_receipts_ready = false
					break
				_mark_active_phase("retention:receipt_currentness:%s:%s" % [source_id,
					str(owner_section)], frames)
				if not coordinator.installed_section_receipt_is_current(owner_section,
						owner_receipt):
					if pending_owner_checks.size() < 4:
						pending_owner_checks.append({"section":owner_section,
							"reason":"installed_receipt_stale",
							"receiptIncarnation":owner_receipt.get("incarnation", -1)})
					source_receipts_ready = false
					break
				_mark_active_phase("retention:source_acknowledgement_lookup:%s:%s" % [source_id,
					str(owner_section)], frames)
				var acknowledgement: Dictionary = coordinator.source_install_acknowledgement_proof(
					owner_section, owner_receipt)
				if acknowledgement.get("status") != "ready":
					if pending_owner_checks.size() < 4:
						pending_owner_checks.append({"section":owner_section,
							"reason":acknowledgement.get("reason", "source_ack_pending"),
							"acknowledgement":acknowledgement})
					source_receipts_ready = false
					break
			if not source_receipts_ready:
				_mark_active_phase("retention:legacy_visual_lookup:%s" % source_id, frames)
				var visible_retained := _legacy_visuals_match(publisher,
					legacy_visuals[source_id], true)
				if not visible_retained:
					_mark_active_phase("retention:section_replacement_fallback:%s" % source_id,
						frames)
					var section_replacement := _root_roster_has_current_or_presenting_sections(
						coordinator, root_rosters[source_id])
					if section_replacement.get("status") == "ready":
						# The native backend exposes one complete replacement root and hides
						# the prior root in one main-thread transition. Let RenderingServer
						# draw that exact generation before asking the session to finalize
						# its frame receipt on the next coordinator advance.
						retry_after_presentation_frame = true
						if presentation_retry_samples.size() < 8:
							presentation_retry_samples.append({"sourceId":source_id,
								"ownerSections":OwnerCompletion.owner_sections(root_rosters[source_id]),
								"pendingOwnerChecks":pending_owner_checks,
								"sectionReplacement":section_replacement,
								"sectionFallbacks":_section_fallback_diagnostic(coordinator,
									root_rosters[source_id])})
						continue
					retention_valid = false
					retention_failures.append({"sourceId":source_id,
						"ownerSections":OwnerCompletion.owner_sections(root_rosters[source_id]),
						"completion":{"status":"pending",
							"reason":"source_section_acknowledgement_pending"},
						"sectionReplacement":section_replacement,
						"sectionFallbacks":_section_fallback_diagnostic(coordinator,
							root_rosters[source_id]),
						"legacyVisuals":_legacy_visual_diagnostic(publisher,
							legacy_visuals[source_id])})
			else:
				# ACKs are authoritative for retirement; allow one presentation frame
				# for the old root to transition after complete section coverage.
				_mark_active_phase("retention:acknowledged_visual_lookup:%s" % source_id, frames)
				var either_representation := _legacy_visuals_match(publisher,
					legacy_visuals[source_id], true) \
					or _legacy_visuals_match(publisher, legacy_visuals[source_id], false)
				retention_valid = retention_valid and either_representation
				if not either_representation:
					retention_failures.append({"sourceId":source_id,
						"ownerSections":OwnerCompletion.owner_sections(root_rosters[source_id]),
						"completion":{"status":"ready",
							"reason":"all_current_owner_section_acknowledgements_ready"},
						"sectionFallbacks":_section_fallback_diagnostic(coordinator,
							root_rosters[source_id]),
						"legacyVisuals":_legacy_visual_diagnostic(publisher,
							legacy_visuals[source_id])})
		if retry_after_presentation_frame:
			await process_frame
			await RenderingServer.frame_post_draw
			presentation_retry_count += 1
			frames += 1
			var retry_elapsed := Time.get_ticks_usec() - phase_started
			max_frame_usec = maxi(max_frame_usec, int(retry_elapsed))
			if Time.get_ticks_msec() >= next_progress:
				_progress("geometry_owner_presentation_ack_wait", {
					"presentationRetryCount":presentation_retry_count,
					"frameCount":frames,
					"processFrame":Engine.get_process_frames(),
					"retryFrameUsec":retry_elapsed,
					"retrySamples":presentation_retry_samples,
					"pendingSourceAcknowledgements":_pending_source_acknowledgement_diagnostics(
						coordinator, service),
					"installedReceiptCount":receipts.size(),
					"ownerCount":owner_sections.size(),
					"coordinator":coordinator.status()})
				next_progress = Time.get_ticks_msec() + 3000
			continue
		if not retention_valid:
			return {"status":"failed",
				"reason":"expected_legacy_identity_missing_or_retired_before_owner_completion",
				"receipts":receipts, "retentionFailures":retention_failures}
		var complete := receipts.size() == owner_sections.size()
		var root_ack: Dictionary = {}
		var full_proofs: Dictionary = {}
		if complete:
			_mark_active_phase("retention:terminal_receipt_recheck", frames)
			for section: Vector3i in owner_sections:
				complete = complete and coordinator.installed_section_receipt_is_current(section, receipts[section])
			for section: Vector3i in target_section_keys:
				_mark_active_phase("retention:terminal_section_ack:%s" % str(section), frames)
				root_ack[section] = coordinator.source_install_acknowledgement_proof(section, receipts.get(section, {}))
				complete = complete and root_ack[section].get("status") == "ready"
			for source_id: String in root_rosters:
				_mark_active_phase("retention:terminal_owner_closure:%s" % source_id, frames)
				full_proofs[source_id] = coordinator.validate_geometry_owner_completion(root_rosters[source_id])
				complete = complete and full_proofs[source_id].get("status") == "ready"
				complete = complete and _legacy_visuals_match(publisher, legacy_visuals[source_id], false)
		phase_times["receiptAndRetentionUsec"] = Time.get_ticks_usec() - phase_mark
		phase_times["totalUsec"] = Time.get_ticks_usec() - phase_started
		for timing_key: String in phase_times:
			phase_max[timing_key] = maxi(int(phase_max.get(timing_key, 0)), int(phase_times[timing_key]))
		max_phase_usec = maxi(max_phase_usec, int(phase_times.totalUsec))
		frames += 1
		if complete:
			service.set_source_capture_phase_observer(Callable())
			return {"status":"ready" if retention_valid and partial_observed else "failed",
				"legacyRetentionValid":retention_valid, "partialNativeInstallObserved":partial_observed,
				"ownerCount":owner_sections.size(), "rootSourceCount":root_rosters.size(),
				"receipts":receipts, "rootAcknowledgements":root_ack, "fullPartProofs":full_proofs,
				"providerAckPhaseMaxUsec":provider_ack_phase_max_usec,
				"providerAckWorkTotals":provider_ack_work_totals,
				"ownerLeases":leases, "elapsedUsec":Time.get_ticks_usec() - started,
				"maxPhaseUsec":max_phase_usec, "maxFrameUsec":max_frame_usec, "frameCount":frames}
		if Time.get_ticks_msec() >= next_progress:
			_progress("geometry_owner_native_closure", {"installedOwners":receipts.size(), "ownerCount":owner_sections.size(),
				"leaseStatus":leases.get("status", ""),
				"waitingOwnerCount":leases.get("waitingOwnerSections", {}).size(),
				"reconciliationDiagnostics":leases.get("reconciliationDiagnostics", {}),
				"frameCount":frames, "processFrame":Engine.get_process_frames(),
				"phaseUsec":phase_times, "phaseMaxUsec":phase_max,
				"phaseDetails":phase_details,
				"legacyVisualIndex":service._legacy_visual_section_index.stats(),
				"demandSample":_closure_demand_sample(),
				"pendingSourceAcknowledgements":_pending_source_acknowledgement_diagnostics(
					coordinator, service),
				"rootAcknowledgements":root_ack, "coordinator":coordinator.status()})
			next_progress = Time.get_ticks_msec() + 3000
		_mark_active_phase("frame_render_yield", frames)
		await process_frame
		_mark_active_phase("coordinator_iteration_reentry", frames)
	return {"status":"failed", "reason":"owner_closure_loop_terminated_unexpectedly"}


func _mark_active_phase(phase: String, fixture_frame: int) -> void:
	if phase_marker_path.is_empty(): return
	var file := FileAccess.open(phase_marker_path, FileAccess.WRITE)
	if file == null: return
	file.store_string(JSON.stringify({"phase":phase, "fixtureFrame":fixture_frame,
		"processFrame":Engine.get_process_frames(), "writtenAtTicksUsec":Time.get_ticks_usec()}))
	file.flush()
	file.close()


func _record_admission_phase(phase: String, details: Dictionary) -> void:
	var marker := {"phase":"candidate_admission:%s" % phase,
		"fixtureFrame":_active_closure_frame,
		"processFrame":Engine.get_process_frames(),
		"writtenAtTicksUsec":Time.get_ticks_usec()}
	for key in ["attemptIndex", "providerId", "memberId", "sourcePartId",
			"groupId", "groupCount", "memberCount", "plannedMemberCount",
			"sourceCount", "removalCount", "status"]:
		if details.has(key): marker[key] = details[key]
	if details.get("sectionKey") is Vector3i:
		marker["sectionKey"] = str(details.sectionKey)
	if details.get("region") is Vector2i:
		marker["region"] = str(details.region)
	if phase == "provider_census_capture":
		marker["sectionKey"] = str(details.get("sections", [])[0]) \
			if not details.get("sections", []).is_empty() else ""
	if phase_marker_path.is_empty(): return
	var file := FileAccess.open(phase_marker_path, FileAccess.WRITE)
	if file == null: return
	file.store_string(JSON.stringify(marker))
	file.flush()
	file.close()


func _closure_demand_sample() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var selected: Dictionary = {}
	# Bounded identity/state telemetry only; do not invoke currentness or native
	# receipt validation again merely to report a slow installation.
	for priority in range(3):
		for section: Vector3i in coordinator._visible_section_demands:
			if selected.has(section): continue
			var demand: Dictionary = coordinator._visible_section_demands[section]
			var job: Dictionary = coordinator._production_candidate_jobs.get(section, {})
			var blocked := String(demand.get("stage", "")) == "blocked"
			if priority == 0 and not blocked: continue
			if priority == 1 and job.is_empty(): continue
			var row := {"sectionKey":section, "stage":String(demand.get("stage", "")),
				"blockedReason":String(demand.get("blockedReason", "")),
				"lastReason":String(demand.get("lastReason", "")),
				"lastInstallReason":String(demand.get("lastInstallReason", "")),
				"lastInstallStage":String(demand.get("lastInstallStage", "")),
				"lastAdmissionDetails":demand.get("lastAdmissionDetails", {}),
				"jobStage":String(job.get("stage", "")),
				"generation":int(job.get("candidate", {}).get("generation", 0))}
			var session: Variant = job.get("session")
			if is_instance_valid(session) and session is RefCounted:
				row["sessionState"] = String(session.get("state"))
				row["appendedBatchCount"] = int(session.get("_batch_index"))
				row["batchCount"] = session.get("_batches").size()
				if session.has_method("append_telemetry"):
					row["appendTelemetry"] = session.call("append_telemetry")
			selected[section] = true
			result.append(row)
			if result.size() == 8: return result
	return result


func _pending_source_acknowledgement_diagnostics(coordinator_value,
		service_value) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var pending: Dictionary = coordinator_value.get("_pending_source_acknowledgements")
	var visited_sections := 0
	for section_value: Variant in pending:
		if visited_sections >= 8 or rows.size() >= 8: break
		visited_sections += 1
		if not section_value is Vector3i: continue
		var section_key := Vector3i(section_value)
		var pending_ack: Dictionary = pending.get(section_key, {})
		var last_result: Dictionary = pending_ack.get("lastResult", {})
		var candidate: Dictionary = coordinator_value._production_candidates_by_section.get(
			section_key, {})
		var receipt: Dictionary = coordinator_value._production_candidate_receipts.get(
			section_key, {})
		var demand: Dictionary = coordinator_value._visible_section_demands.get(
			section_key, {})
		var source_samples: Array[Dictionary] = []
		var provider_rows: Variant = last_result.get("providerAcknowledgements", [])
		var visited_providers := 0
		var visited_visuals := 0
		for provider_value: Variant in provider_rows:
			if source_samples.size() >= 4 or visited_providers >= 4: break
			visited_providers += 1
			if not provider_value is Dictionary: continue
			var provider_result: Dictionary = provider_value.get("result", {})
			var visual_results: Variant = provider_result.get("visualResults", [])
			for visual_value: Variant in visual_results:
				if source_samples.size() >= 4 or visited_visuals >= 8: break
				visited_visuals += 1
				if not visual_value is Dictionary: continue
				var visual_result: Dictionary = visual_value
				var source_id := String(visual_result.get("sourceId", ""))
				if source_id.is_empty(): continue
				var details: Dictionary = visual_result.get("details", {})
				var completion: Dictionary = details.get("geometryCompletion", {})
				if completion.is_empty(): completion = details
				var roster: Dictionary = service_value._geometry_owner_rosters.get(source_id, {})
				var required_sections: Array[Vector3i] = OwnerCompletion.owner_sections(roster) \
					if not roster.is_empty() else []
				var session_key := String(coordinator_value._geometry_owner_completion_session_key_by_source.get(
					source_id, ""))
				var session: Dictionary = coordinator_value._geometry_owner_completion_sessions.get(
					session_key, {})
				var required_count := required_sections.size()
				var session_sections: Array = session.get("requiredSectionKeys", [])
				var session_section_count := session_sections.size()
				var stage := String(session.get("stage", ""))
				var stage_cursor := -1
				var stage_total := -1
				var manifest_total := -1
				var range_total := -1
				var compare_member_total := -1
				var session_section_cursor := int(session.get("sectionCursor", -1))
				var awaited_section: Variant = null
				if stage == "owner_closure":
					stage_cursor = int(session.get("ownerClosureCursor", -1))
					var owner_required_sections: Array = session.get("ownerRequiredSectionKeys", [])
					stage_total = owner_required_sections.size()
					if stage_cursor >= 0 and stage_cursor < stage_total:
						awaited_section = owner_required_sections[stage_cursor]
				elif stage == "visible_sections":
					stage_cursor = int(session.get("visibleCursor", -1))
					var visible_sections: Array = session.get("visibleSections", [])
					stage_total = visible_sections.size()
					if stage_cursor >= 0 and stage_cursor < stage_total:
						awaited_section = visible_sections[stage_cursor]
				elif stage == "section_manifests":
					stage_cursor = session_section_cursor
					stage_total = session_section_count
					if session_section_cursor >= 0 and session_section_cursor < session_section_count:
						var current_section: Vector3i = session_sections[session_section_cursor]
						awaited_section = current_section
						var token: Dictionary = session.get("sectionTokens", {}).get(
							current_section, {})
						var token_candidate: Dictionary = token.get("candidate", {})
						var manifest: Variant = token_candidate.get("candidate", {}).get(
							"snapshot", {}).get("manifest", [])
						manifest_total = manifest.size() if manifest is Array else -1
						var manifest_cursor := int(session.get("manifestCursor", -1))
						if manifest is Array and manifest_cursor >= 0 \
								and manifest_cursor < manifest.size():
							var manifest_entry: Variant = manifest[manifest_cursor]
							if manifest_entry is Dictionary:
								range_total = manifest_entry.get("geometrySourceRanges", []).size()
				elif stage == "compare_members":
					stage_cursor = int(session.get("compareSectionCursor", -1))
					stage_total = session_section_count
					var compare_cursor := int(session.get("compareSectionCursor", -1))
					if compare_cursor >= 0 and compare_cursor < session_section_count:
						var compare_section: Vector3i = session_sections[compare_cursor]
						awaited_section = compare_section
						compare_member_total = session.get("expectedMemberKeysBySection", {}).get(
							compare_section, []).size()
				elif stage == "final_receipts":
					stage_cursor = int(session.get("finalReceiptCursor", -1))
					stage_total = session_section_count
					if stage_cursor >= 0 and stage_cursor < session_section_count:
						awaited_section = session_sections[stage_cursor]
				elif stage == "complete":
					stage_cursor = session_section_count
					stage_total = session_section_count
				var awaited_demand: Dictionary = {}
				var awaited_candidate: Dictionary = {}
				var awaited_receipt: Dictionary = {}
				var awaited_job: Dictionary = {}
				var awaited_candidate_source := "missing"
				if awaited_section is Vector3i:
					awaited_demand = coordinator_value._visible_section_demands.get(
						awaited_section, {})
					awaited_candidate = coordinator_value._production_candidates_by_section.get(
						awaited_section, {})
					if not awaited_candidate.is_empty():
						awaited_candidate_source = "current_candidate"
					awaited_job = coordinator_value._production_candidate_jobs.get(
						awaited_section, {})
					if awaited_candidate.is_empty():
						awaited_candidate = awaited_job.get("candidate", {})
						if not awaited_candidate.is_empty():
							awaited_candidate_source = "candidate_job"
					awaited_receipt = coordinator_value._production_candidate_receipts.get(
						awaited_section, {})
				var session_sample := {
					"stage":stage,
					"stageCursor":stage_cursor,
					"stageTotal":stage_total,
					"awaitedSectionKey":awaited_section,
					"awaitedSectionState":{
						"demandStage":String(awaited_demand.get("stage", "")),
						"demandReason":String(awaited_demand.get("lastReason",
							awaited_demand.get("blockedReason", ""))),
						"candidatePresent":not awaited_candidate.is_empty(),
						"candidateSource":awaited_candidate_source,
						"candidateGeneration":int(awaited_candidate.get("generation", -1)),
						"candidateJobStage":String(awaited_job.get("stage", "")),
						"receiptPresent":not awaited_receipt.is_empty(),
						"receiptGeneration":int(awaited_receipt.get("generation", -1))},
					"sectionCursor":session_section_cursor,
					"requiredSectionCount":required_count,
					"sessionSectionCount":session_section_count,
					"manifestCursor":int(session.get("manifestCursor", -1)),
					"manifestTotal":manifest_total,
					"memberRangeCursor":int(session.get("memberRangeCursor", -1)),
					"memberRangeTotal":range_total,
					"compareSectionCursor":int(session.get("compareSectionCursor", -1)),
					"compareMemberCursor":int(session.get("compareMemberCursor", -1)),
					"compareMemberTotal":compare_member_total,
					"finalReceiptCursor":int(session.get("finalReceiptCursor", -1)),
					"expectedMemberCount":session.get("expectedMembers", []).size()}
				source_samples.append({
					"providerId":String(provider_value.get("providerId", "")),
					"sourceId":source_id,
					"visualReason":String(visual_result.get("reason", "")),
					"proofRequestReason":String(completion.get("proofRequestReason", "")),
					"completionReason":String(completion.get("reason", "")),
					"requiredOwnerSectionKeys":required_sections,
					"completionSession":session_sample})
		var current_candidate: Dictionary = coordinator_value._production_candidates_by_section.get(
			section_key, {})
		var current_receipt: Dictionary = coordinator_value._production_candidate_receipts.get(
			section_key, {})
		var candidate_object_current := not candidate.is_empty() \
			and is_same(current_candidate, candidate)
		var receipt_object_current := not receipt.is_empty() \
			and is_same(current_receipt, receipt)
		rows.append({
			"sectionKey":section_key,
			"attempts":int(pending_ack.get("attempts", 0)),
			"nextAttemptFrame":int(pending_ack.get("nextAttemptFrame", -1)),
			"lastResultStatus":String(last_result.get("status", "")),
			"lastResultReason":String(last_result.get("reason", "")),
			"candidateGeneration":int(candidate.get("generation", -1)),
			"candidateManifestDigest":String(candidate.get("contentManifestDigest", "")),
			"receiptGeneration":int(receipt.get("generation", -1)),
			"candidateObjectCurrent":candidate_object_current,
			"receiptObjectCurrent":receipt_object_current,
			"candidateReceiptGenerationMatches":int(candidate.get("generation", -1)) \
				== int(receipt.get("generation", -2)),
			"receiptCurrentnessRevalidated":false,
			"demandStage":String(demand.get("stage", "")),
			"demandReason":String(demand.get("lastReason", demand.get("blockedReason", ""))),
			"sourceSamples":source_samples})
	return rows


## Manual backend calls below are fixture cleanup only, after coordinator release.
func _release_fixture_owner_slots(world: WorldRoot, sections: Array[Vector3i], notify: bool = true) -> void:
	var notified: Dictionary = {}
	var results: Dictionary = {}
	var backends: Dictionary = {}
	if notify:
		_quiesce_fixture_admission()
		if not await _drain_fixture_section_owners("fixture_section_workers_and_presentations_drained"): return
	for section: Vector3i in sections:
		var cell := Grid.chunk_key_for_section(section)
		if notify and not notified.has(cell):
			coordinator.notify_stream_chunk_unloaded(cell)
			notified[cell] = true
		var owner_result: Dictionary = world.get_static_section_render_owner(cell, false)
		if owner_result.get("status") != "ready": continue
		var slot := InstallSession.slot_id(String(coordinator._world_id), section)
		var backend: Node3D = owner_result.backend
		backends[section] = backend
		var snapshot: Dictionary = backend.call("installed_snapshot", slot)
		if snapshot.get("status") == "ready":
			results[section] = backend.call("release_packet", slot, int(snapshot.generation))
	await process_frame
	await RenderingServer.frame_post_draw
	var released := true
	for result: Dictionary in results.values(): released = released and result.get("status") == "released"
	var post_release: Dictionary = {}
	for section: Vector3i in backends:
		var snapshot: Dictionary = backends[section].call("installed_snapshot", InstallSession.slot_id(String(coordinator._world_id), section))
		post_release[section] = snapshot
		released = released and snapshot.get("status") != "ready"
	_check("fixture_native_owner_slots_released_after_coordinator_notification" if notify else "external_native_slots_released_after_owner_retirement",
		released, {"releases":results, "postRelease":post_release})

func _select_sparse_section(plan, eligible_group_ids: Dictionary = {},
		publication_groups: Dictionary = {}, source_parts: Array = [],
		require_crossing: bool = false) -> Dictionary:
	var counts: Dictionary = {}
	var selected_rows: Dictionary = {}
	var selected_targets: Dictionary = {}
	var visual_row_count := 0
	var valid_bounds_row_count := 0
	var raw_intersecting_sections: Dictionary = {}
	var building_only_section_count := 0
	var packet_eligible_section_count := 0
	var single_section_target_count := 0
	var multi_section_target_count := 0
	var packet_ineligible_section_count := 0
	var first_packet_ineligible_section: Dictionary = {}
	var packet_unsupported_section_count := 0
	var packet_capable_section_count := 0
	var first_packet_unsupported_section: Dictionary = {}
	var geometry_family_by_part_id: Dictionary = {}
	var source_part_by_id: Dictionary = {}
	for source_part_value: Variant in source_parts:
		if source_part_value is Dictionary:
			var source_part_id := String(source_part_value.get("id", ""))
			geometry_family_by_part_id[source_part_id] = \
				Preparation._snapshot_geometry_family(source_part_value)
			source_part_by_id[source_part_id] = source_part_value
	var first_query: Dictionary = {}
	var required_transform_target_gap: Dictionary = {}
	var visited_sections: Dictionary = {}
	for row: Dictionary in plan.member_records:
		if not bool(row.get("visual", true)):
			continue
		var row_member_id := String(row.get("memberId", ""))
		if row_member_id == "building:" + REQUIRED_TRANSFORM_PART_ID \
				and required_transform_target_gap.is_empty():
			var target_source_part: Dictionary = source_part_by_id.get(
				REQUIRED_TRANSFORM_PART_ID, {})
			var target_family := String(geometry_family_by_part_id.get(
				REQUIRED_TRANSFORM_PART_ID, ""))
			required_transform_target_gap = {"sourcePartId":REQUIRED_TRANSFORM_PART_ID,
				"memberId":row_member_id, "groupId":String(row.get("groupId", "")),
				"visual":bool(row.get("visual", false)),
				"boundsType":type_string(typeof(row.get("bounds", null))),
				"kind":String(target_source_part.get("kind", "")),
				"material":String(target_source_part.get("material",
					target_source_part.get("materialId", ""))),
				"packetGeometryFamily":target_family,
				"packetSupported":not target_family.is_empty(),
				"familyResolver":"BuildingPublicationPreparation._snapshot_geometry_family",
				"reason":"" if not target_family.is_empty() else \
					"prepared_packet_family_unavailable"}
		visual_row_count += 1
		if not row.get("bounds") is AABB:
			continue
		valid_bounds_row_count += 1
		var row_keys: Array[Vector3i] = Grid.keys_intersecting_bounds(row.bounds)
		for row_key: Vector3i in row_keys: raw_intersecting_sections[row_key] = true
		if not String(row.get("memberId", "")).begins_with("building:"):
			continue
		var keys: Array[Vector3i] = row_keys
		for key: Vector3i in keys:
			if visited_sections.has(key): continue
			visited_sections[key] = true
			var bounds := AABB(Grid.origin_for_key(key), Vector3.ONE * Grid.SECTION_SIZE_METERS)
			var members: Dictionary = plan.visual_members_intersecting_bounds(bounds)
			if first_query.is_empty():
				first_query = {"section":key, "status":members.get("status", ""),
					"memberCount":members.get("members", []).size(),
					"firstMember":members.get("members", [])[0].get("memberId", "") \
						if not members.get("members", []).is_empty() else ""}
			if members.get("status") != "described": continue
			var section_members: Array[Dictionary] = members.get("members", [])
			var building_only := not section_members.is_empty()
			for candidate: Dictionary in section_members:
				if not String(candidate.get("memberId", "")).begins_with("building:"):
					building_only = false
					break
			if not building_only: continue
			building_only_section_count += 1
			if not eligible_group_ids.is_empty():
				var section_group_ids: Array[String] = []
				for candidate: Dictionary in section_members:
					var group_id := String(candidate.get("groupId", ""))
					if group_id.is_empty() or not section_group_ids.has(group_id):
						section_group_ids.append(group_id)
				var closure := _expand_group_dependency_closure(section_group_ids,
					publication_groups)
				var packet_eligible: bool = closure.get("status") == "ready"
				var blocked_group_ids: Array[String] = []
				for group_id_value: Variant in closure.get("groupIds", []):
					var group_id := String(group_id_value)
					if not eligible_group_ids.has(group_id):
						packet_eligible = false
						blocked_group_ids.append(group_id)
				if not packet_eligible:
					packet_ineligible_section_count += 1
					if first_packet_ineligible_section.is_empty():
						first_packet_ineligible_section = {"section":key,
							"members":section_members.size(), "blockedGroupIds":blocked_group_ids,
							"closure":closure}
					continue
			if not geometry_family_by_part_id.is_empty():
				var unsupported_part_ids: Array[String] = []
				for candidate: Dictionary in section_members:
					var part_id := String(candidate.get("memberId", "")).trim_prefix("building:")
					if String(geometry_family_by_part_id.get(part_id, "")).is_empty():
						unsupported_part_ids.append(part_id)
				if not unsupported_part_ids.is_empty():
					packet_unsupported_section_count += 1
					if first_packet_unsupported_section.is_empty():
						first_packet_unsupported_section = {"section":key,
							"members":section_members.size(),
							"unsupportedPartIds":unsupported_part_ids}
					continue
			packet_capable_section_count += 1
			packet_eligible_section_count += 1
			var target_candidates: Array[Dictionary] = []
			for candidate: Dictionary in section_members:
				var candidate_part_id := String(candidate.get("memberId", "")).trim_prefix("building:")
				var candidate_family := String(geometry_family_by_part_id.get(candidate_part_id, ""))
				if candidate_family.is_empty(): continue
				var member_bounds: Variant = candidate.get("bounds")
				if not member_bounds is AABB: continue
				var target_keys: Array[Vector3i] = Grid.keys_intersecting_bounds(member_bounds)
				if require_crossing and target_keys.size() < 2: continue
				# Every required section must admit its complete producer census; selecting
				# only the primary section would hide missing adjacent contributors.
				if require_crossing:
					var complete_closure := _target_section_producer_closure(plan, target_keys,
						eligible_group_ids, publication_groups, geometry_family_by_part_id)
					if complete_closure.get("status") != "ready": continue
				if target_keys.size() == 1:
					single_section_target_count += 1
					target_candidates.append({"member":candidate, "sectionKeys":target_keys,
						"geometryFamily":candidate_family})
				else:
					multi_section_target_count += 1
					target_candidates.append({"member":candidate, "sectionKeys":target_keys,
						"geometryFamily":candidate_family})
			if target_candidates.is_empty(): continue
			target_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var a_sections: Array = a.get("sectionKeys", [])
				var b_sections: Array = b.get("sectionKeys", [])
				if a_sections.size() != b_sections.size(): return a_sections.size() < b_sections.size()
				return String(a.get("member", {}).get("memberId", "")) \
					< String(b.get("member", {}).get("memberId", "")))
			counts[key] = section_members.size()
			selected_rows[key] = section_members
			selected_targets[key] = target_candidates[0]
	var keys: Array[Vector3i] = []
	for key: Vector3i in counts: keys.append(key)
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var a_target_sections: Array = selected_targets[a].get("sectionKeys", [])
		var b_target_sections: Array = selected_targets[b].get("sectionKeys", [])
		if a_target_sections.size() != b_target_sections.size():
			return a_target_sections.size() < b_target_sections.size()
		if counts[a] != counts[b]: return counts[a] < counts[b]
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var diagnostics := {"visualRowCount":visual_row_count,
		"validBoundsRowCount":valid_bounds_row_count,
		"intersectingSectionCount":raw_intersecting_sections.size(),
		"buildingOnlySectionCount":building_only_section_count,
		"packetEligibleSectionCount":packet_eligible_section_count,
		"singleSectionTargetCount":single_section_target_count,
		"multiSectionTargetCount":multi_section_target_count,
		"packetIneligibleSectionCount":packet_ineligible_section_count,
		"firstPacketIneligibleSection":first_packet_ineligible_section,
		"packetCapableSectionCount":packet_capable_section_count,
		"packetUnsupportedSectionCount":packet_unsupported_section_count,
		"firstPacketUnsupportedSection":first_packet_unsupported_section,
		"firstQuery":first_query,
		"requiredTransformTargetGap":required_transform_target_gap}
	if keys.is_empty():
		return {"status":"failed", "reason":"real_plan_has_no_canonical_transform_target_section",
			"diagnostics":diagnostics}
	var key: Vector3i = keys[0]
	var rows: Array[Dictionary] = selected_rows[key]
	var group_ids: Array[String] = []
	var selected_member_geometry_families: Dictionary = {}
	for row: Dictionary in rows:
		var group_id := String(row.get("groupId", ""))
		if not group_id.is_empty() and not group_ids.has(group_id): group_ids.append(group_id)
		var member_part_id := String(row.get("memberId", "")).trim_prefix("building:")
		selected_member_geometry_families[member_part_id] = String(
			geometry_family_by_part_id.get(member_part_id, ""))
	group_ids.sort()
	var target: Dictionary = selected_targets[key]
	var required_sections: Array[Vector3i] = []
	for target_section_value: Variant in target.get("sectionKeys", []):
		if target_section_value is Vector3i: required_sections.append(target_section_value)
	if require_crossing:
		var target_closure := _target_section_producer_closure(plan, required_sections,
			eligible_group_ids, publication_groups, geometry_family_by_part_id)
		for closure_group: String in target_closure.get("groupIds", []):
			if not group_ids.has(closure_group): group_ids.append(closure_group)
	group_ids.sort()
	required_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	return {"status":"ready", "section":key, "members":rows,
		"memberCount":rows.size(), "groupIds":group_ids,
		"selectedMemberGeometryFamilies":selected_member_geometry_families,
		"targetMember":target.get("member", {}),
		"targetGeometryFamily":String(target.get("geometryFamily", "")),
		"targetSectionKeys":required_sections,
		"diagnostics":diagnostics,
		"selection":"smallest complete supported section closure; crossing required: " + str(require_crossing)}

func _target_section_producer_closure(plan, sections: Array[Vector3i],
		eligible_groups: Dictionary, publication_groups: Dictionary,
		geometry_families: Dictionary) -> Dictionary:
	var groups: Array[String] = []
	for target_section: Vector3i in sections:
		var census: Dictionary = plan.visual_members_intersecting_bounds(
			AABB(Grid.origin_for_key(target_section), Vector3.ONE * Grid.SECTION_SIZE_METERS))
		if census.get("status") != "described" or census.get("members", []).is_empty():
			return {"status":"pending", "reason":"incomplete_target_section"}
		for member: Dictionary in census.get("members", []):
			var member_id := String(member.get("memberId", ""))
			if not member_id.begins_with("building:") or String(geometry_families.get(
					member_id.trim_prefix("building:"), "")).is_empty():
				return {"status":"pending", "reason":"unsupported_target_section_member"}
			var group_id := String(member.get("groupId", ""))
			if not groups.has(group_id): groups.append(group_id)
	var closure := _expand_group_dependency_closure(groups, publication_groups)
	if closure.get("status") != "ready": return closure
	for group_id: String in closure.get("groupIds", []):
		if not eligible_groups.is_empty() and not eligible_groups.has(group_id):
			return {"status":"pending", "reason":"ineligible_target_section_dependency"}
	return closure

func _select_initial_packet_group(source: Dictionary) -> String:
	var blueprint: Variant = source.get("blueprint")
	if blueprint == null or not blueprint.get("parts") is Array:
		return ""
	for part_value: Variant in blueprint.parts:
		if not part_value is Dictionary:
			continue
		var part: Dictionary = part_value
		if String(part.get("id", "")) != REQUIRED_TRANSFORM_PART_ID:
			continue
		var recipe: Variant = part.get("recipe", {})
		if not recipe is Dictionary or not bool(recipe.get("visual", true)):
			return ""
		return "building:" + REQUIRED_TRANSFORM_PART_ID
	return ""

func _source_part_evidence(source: Dictionary, part_id: String) -> Dictionary:
	var blueprint: Variant = source.get("blueprint")
	if blueprint == null or not blueprint.get("parts") is Array:
		return {"available":false, "reason":"source_blueprint_parts_missing"}
	for part_value: Variant in blueprint.parts:
		if not part_value is Dictionary or String(part_value.get("id", "")) != part_id:
			continue
		var part: Dictionary = part_value
		return {"available":true, "id":part_id, "kind":part.get("kind", ""),
			"material":part.get("material", part.get("materialId", "")),
			"visual":bool(part.get("recipe", {}).get("visual", true)),
			"recipeKeys":part.get("recipe", {}).keys()}
	return {"available":false, "reason":"required_source_part_missing", "id":part_id}

func _packet_demand(bounds: Rect2i, binding: Dictionary, groups: Array[String]) -> Dictionary:
	var discovery: Dictionary = Service.DemandSet.from_regions([bounds], Service.DISCOVERY_CHUNK_SIZE,
		Service.MAX_DISCOVERY_CHUNKS, 32)
	var navigation: Dictionary = Service.DemandSet.from_regions([bounds], Service.NAVIGATION_TILE_CELLS,
		Service.MAX_PENDING_NAVIGATION_TILES)
	var nav_keys: Array[String] = []
	for key: Vector2i in navigation.keys: nav_keys.append("%d,%d" % [key.x, key.y])
	nav_keys.sort()
	return {"ownerId":81041, "bounds":bounds, "priority":0,
		"admissionKeys":discovery.keys.keys(), "navigationTileKeys":nav_keys,
		"sites":[{"binding":binding.duplicate(), "groupIds":groups.duplicate(),
			"foregroundGroupIds":groups.duplicate()}]}


func _producer_failure_evidence(service, requested_group_ids: Array[String], binding: Dictionary,
		target_section: Vector3i, part_id: String, proofs: Array[Dictionary]) -> Dictionary:
	var requested := requested_group_ids.duplicate()
	requested.sort()
	var scene_entry: Dictionary = service._scenes.get(REGION, {})
	var scene_job = scene_entry.get("job", null)
	var completed_map: Dictionary = scene_job.completed_physical_group_ids(binding) \
		if scene_job != null else {}
	var requested_set: Dictionary = {}
	for group_id: String in requested: requested_set[group_id] = true
	var completed_requested: Array[String] = []
	for group_id: String in completed_map:
		if requested_set.has(group_id): completed_requested.append(group_id)
	completed_requested.sort()
	var missing_requested: Array[String] = []
	for group_id: String in requested:
		if not completed_requested.has(group_id): missing_requested.append(group_id)
	var publisher_lookup: Dictionary = service._current_transform_artifact_publisher_for_site(
		String(binding.get("siteId", "")))
	var result := {"requestedGroupIds":requested,
		"requestedGroupCount":requested.size(),
		"completedPhysicalGroupCount":completed_map.size(),
		"completedRequestedGroupIds":completed_requested,
		"missingRequestedGroupIds":missing_requested,
		"targetPublisherLookup":{"status":String(publisher_lookup.get("status", "")),
			"reason":String(publisher_lookup.get("reason", "")),
			"siteId":String(binding.get("siteId", "")),
			"region":publisher_lookup.get("region", REGION)}}
	var publisher = publisher_lookup.get("publisher", null)
	if (publisher == null or not is_instance_valid(publisher)) and scene_job != null:
		publisher = scene_job.get("_building")
	if publisher == null or not is_instance_valid(publisher):
		result["targetPublisher"]={"available":false}
		return result
	var source_census: Dictionary = {}
	for proof: Dictionary in proofs:
		if proof.get("section") == target_section:
			source_census = proof.get("census", {})
			break
	var census_source_id := Service._citadel_census_source_id(String(binding.get("siteId", "")),
		"building:" + part_id, target_section)
	var source_revision := String(source_census.get("sourceRevisions", {}).get(census_source_id, ""))
	var roster: Dictionary = publisher.capture_static_section_transform_artifacts(part_id,
		source_revision)
	var last_boundary: Dictionary = publisher.get("_last_publication_boundary")
	var pending_boundary: Dictionary = publisher.get("_pending_publication_boundary")
	var last_source_ids: Array = last_boundary.get("sourcePartIds", [])
	var pending_source_ids: Array = pending_boundary.get("sourcePartIds", [])
	var artifact_rosters: Dictionary = publisher.get("_static_section_transform_artifacts")
	var artifact_revisions: Dictionary = publisher.get("_static_section_transform_artifact_revisions")
	var target_artifact_groups: Variant = artifact_rosters.get(part_id, [])
	var batches: Array[Dictionary] = []
	var batch_total := 0
	for batch_key_value: Variant in publisher.static_visual_batches:
		var group_value: Variant = publisher.static_visual_batches[batch_key_value]
		if not group_value is Dictionary or String(group_value.get("sourcePartId", "")) != part_id:
			continue
		batch_total += 1
		if batches.size() >= 16:
			continue
		var segments_value: Variant = group_value.get("preparedSegments", {})
		batches.append({"key":String(batch_key_value),
			"transformCount":group_value.get("transforms", []).size(),
			"customDataCount":group_value.get("customData", []).size(),
			"preparedSegmentCount":segments_value.size() if segments_value is Dictionary else -1})
	var flush = publisher.get("_static_flush")
	var flush_evidence := {"pending":publisher.has_pending_static_flush(), "state":"", "reason":"",
		"groupIndex":-1, "groupCount":0, "currentPartId":""}
	if flush != null and is_instance_valid(flush):
		var flush_keys: Array = flush.get("_keys")
		var flush_index := int(flush.get("_group_index"))
		var flush_groups: Dictionary = flush.get("_groups")
		var flush_part_id := ""
		if flush_index >= 0 and flush_index < flush_keys.size():
			var flush_group: Variant = flush_groups.get(flush_keys[flush_index])
			if flush_group is Dictionary: flush_part_id = String(flush_group.get("sourcePartId", ""))
		flush_evidence={"pending":true,"state":String(flush.get("state")),
			"reason":String(flush.get("reason")),"groupIndex":flush_index,
			"groupCount":flush_keys.size(),"currentPartId":flush_part_id}
	var artifact_diagnostics: Dictionary = publisher.get("_static_section_transform_artifact_diagnostics")
	result["targetPublisher"]={"available":true,
		"publicationSiteId":String(publisher.get("publication_site_id")),
		"publicationSiteMatchesBinding":String(publisher.get("publication_site_id")) \
			== String(binding.get("siteId", "")),
		"publicationEpoch":int(publisher.get("_publication_epoch")),
		"targetSourceRevision":source_revision,
		"committedBoundary":{"epoch":int(last_boundary.get("epoch", 0)),
			"containsTargetPart":last_source_ids.has(part_id),
			"sourcePartCount":last_source_ids.size()},
		"pendingBoundary":{"epoch":int(pending_boundary.get("epoch", 0)),
			"containsTargetPart":pending_source_ids.has(part_id),
			"sourcePartCount":pending_source_ids.size()},
		"targetPublicationEpoch":int(publisher.source_part_publication_epoch(part_id)),
		"committedArtifactPartCount":artifact_rosters.size(),
		"hasCommittedTargetArtifactRoster":target_artifact_groups is Array \
			and not target_artifact_groups.is_empty(),
		"committedArtifactRevision":String(artifact_revisions.get(part_id, "")),
		"roster":{"status":String(roster.get("status", "")),
			"reason":String(roster.get("reason", "")),
			"groupCount":int(roster.get("groupCount", 0)),
			"sourceRevision":String(roster.get("sourceRevision", ""))},
		"matchingStaticBatches":{"count":batch_total,"rows":batches,
			"omittedCount":maxi(0, batch_total - batches.size())},
		"staticFlush":flush_evidence,
		"artifactDiagnostics":{"preparedGroups":int(artifact_diagnostics.get("preparedGroups", 0)),
			"rejectedGroups":int(artifact_diagnostics.get("rejectedGroups", 0)),
			"lastRejectReason":String(artifact_diagnostics.get("lastRejectReason", "")),
			"rejectedBySource":artifact_diagnostics.get("rejectedBySource", {}).duplicate(true),
			"rejectedSourceOverflow":int(artifact_diagnostics.get("rejectedSourceOverflow", 0)),
			"rejectedGroupSamples":artifact_diagnostics.get("rejectedGroupSamples", []).duplicate(true),
			"rejectedGroupSampleOverflow":int(artifact_diagnostics.get("rejectedGroupSampleOverflow", 0))}}
	return result

func _coordinator_census(source_census: Dictionary, source_section_key: Vector3i) -> Dictionary:
	var section_row: Dictionary = source_census.get("sections", {}).get(source_section_key, {})
	var source_ids: Array[String] = []
	var source_revisions: Dictionary = {}
	var provider_ids: Dictionary = {}
	var source_identities: Dictionary = {}
	for source_value: Variant in section_row.get("sourcePartIds", []):
		if source_value is String and not String(source_value).is_empty():
			var source_id := String(source_value)
			var identity_key := _section_source_identity_key(source_id, source_id)
			var identity := {"sourceId":source_id, "sourcePartId":source_id}
			identity.make_read_only()
			source_ids.append(identity_key)
			source_revisions[identity_key] = String(
				source_census.get("sourceRevisions", {}).get(source_id, ""))
			provider_ids[identity_key] = PROVIDER_ID
			source_identities[identity_key] = identity
	source_ids.sort()
	source_ids.make_read_only()
	var expected_by_section := {source_section_key:source_ids}
	expected_by_section.make_read_only()
	provider_ids.make_read_only()
	source_revisions.make_read_only()
	source_identities.make_read_only()
	var coverage_by_section := {source_section_key:String(section_row.get("coverageRevision", ""))}
	coverage_by_section.make_read_only()
	var coverages := {PROVIDER_ID:coverage_by_section}
	coverages.make_read_only()
	var provider_snapshots := {PROVIDER_ID:source_census.get("authorityRevision", "")}
	provider_snapshots.make_read_only()
	var sections: Array[Vector3i] = [source_section_key]
	sections.make_read_only()
	var result := {"status":"complete", "worldId":source_census.get("worldId", ""),
		"authorityRevision":source_census.get("authorityRevision", ""),
		"sourceRevisions":source_revisions,
		"sections":sections,
		"expectedContributorsBySection":expected_by_section,
		"sourceProviderIds":provider_ids,
		"sourceIdentities":source_identities,
		"providerCoverageRevisions":coverages,
		"providerSnapshotRevisions":provider_snapshots}
	result.make_read_only()
	return result


func _section_source_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()

func _publisher_visuals_for_section(value, target_section: Vector3i) -> Array:
	var found: Array = []
	if value == null or not is_instance_valid(value): return found
	for visual: GeometryInstance3D in Service._published_legacy_geometry(value):
		if not visual.is_inside_tree() \
				or visual.is_queued_for_deletion():
			continue
		var visual_bounds := visual.global_transform * visual.get_aabb()
		if Grid.keys_intersecting_bounds(visual_bounds).has(target_section): found.append(visual)
	return found

func _observed_part_ids(visuals: Array) -> Array[String]:
	var ids: Array[String] = []
	for node_value: Variant in visuals:
		if not is_instance_valid(node_value) or not node_value is GeometryInstance3D: continue
		var visual: GeometryInstance3D = node_value
		var id := String(visual.get_meta("building_source_part_id", ""))
		if not id.is_empty() and not ids.has(id): ids.append(id)
	ids.sort()
	return ids

func _visual_section_keys(visuals: Array) -> Array[Vector3i]:
	var found: Dictionary = {}
	for node_value: Variant in visuals:
		if not is_instance_valid(node_value) or not node_value is GeometryInstance3D: continue
		var visual: GeometryInstance3D = node_value
		var bounds := visual.global_transform * visual.get_aabb()
		for key: Vector3i in Grid.keys_intersecting_bounds(bounds): found[key] = true
	var keys: Array[Vector3i] = []
	for key: Vector3i in found: keys.append(key)
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	return keys

func _expand_group_dependency_closure(seed_group_ids: Array,
		publication_groups: Dictionary) -> Dictionary:
	var pending: Array[String] = []
	var included: Dictionary = {}
	for raw_id: Variant in seed_group_ids:
		if not raw_id is String or String(raw_id).is_empty():
			return {"status":"failed", "reason":"invalid_dependency_seed"}
		var group_id := String(raw_id)
		if not included.has(group_id):
			included[group_id] = true
			pending.append(group_id)
	var cursor := 0
	while cursor < pending.size():
		var group_id: String = pending[cursor]
		cursor += 1
		var group_value: Variant = publication_groups.get(group_id)
		if not group_value is Dictionary:
			return {"status":"failed", "reason":"dependency_group_missing",
				"groupId":group_id, "groupIds":pending}
		var dependencies: Variant = group_value.get("dependencies", [])
		if not dependencies is Array:
			return {"status":"failed", "reason":"dependency_edges_invalid",
				"groupId":group_id, "groupIds":pending}
		for dependency_value: Variant in dependencies:
			if not dependency_value is String or String(dependency_value).is_empty():
				return {"status":"failed", "reason":"dependency_edge_invalid",
					"groupId":group_id, "dependency":dependency_value,
					"groupIds":pending}
			var dependency := String(dependency_value)
			if dependency == group_id:
				return {"status":"failed", "reason":"dependency_cycle",
					"groupId":group_id, "dependency":dependency,
					"groupIds":pending}
			if not included.has(dependency):
				included[dependency] = true
				pending.append(dependency)
	var group_ids: Array[String] = []
	var indegree: Dictionary = {}
	var dependents: Dictionary = {}
	for group_id: String in included:
		indegree[group_id] = 0
		dependents[group_id] = []
	for group_id: String in included:
		var group_record: Dictionary = publication_groups[group_id]
		for dependency_value: Variant in group_record.get("dependencies", []):
			var dependency := String(dependency_value)
			indegree[group_id] = int(indegree[group_id]) + 1
			dependents[dependency].append(group_id)
	var topological_queue: Array[String] = []
	for group_id: String in included:
		if int(indegree[group_id]) == 0: topological_queue.append(group_id)
	var topological_cursor := 0
	while topological_cursor < topological_queue.size():
		var ready_id: String = topological_queue[topological_cursor]
		topological_cursor += 1
		for dependent_value: Variant in dependents[ready_id]:
			var dependent := String(dependent_value)
			indegree[dependent] = int(indegree[dependent]) - 1
			if int(indegree[dependent]) == 0: topological_queue.append(dependent)
	if topological_queue.size() != included.size():
		return {"status":"failed", "reason":"dependency_cycle", "groupIds":pending}
	for group_id: String in included: group_ids.append(group_id)
	group_ids.sort()
	return {"status":"ready", "groupIds":group_ids,
		"seedGroupIds":seed_group_ids.duplicate(), "includedDependencyCount":
		maxi(0, group_ids.size() - seed_group_ids.size())}


func _preflight_section_proof_is_complete(proof: Dictionary) -> bool:
	var census_row: Dictionary = proof.get("census", {}).get("sections", {}).get(
		proof.get("section"), {})
	var contribution_candidate: Dictionary = proof.get("contribution", {})
	var expected_ids: Array[String] = []
	for source_id_value: Variant in census_row.get("sourcePartIds", []):
		var source_id := String(source_id_value)
		expected_ids.append(_section_source_identity_key(source_id, source_id))
	expected_ids.sort()
	var contribution: Dictionary = contribution_candidate.get("contribution", {})
	var contribution_ids: Array = contribution.get("authoritySourceRevisions", {}).keys()
	contribution_ids.sort()
	return proof.get("ready", false) and census_row.get("status") == "complete" \
		and contribution_candidate.get("status") == "ready" \
		and contribution_ids == expected_ids \
		and proof.get("expectedSourceIds", []) == expected_ids \
		and proof.get("contributedSourceIds", []) == expected_ids \
		and (not contribution.get("inputs", []).is_empty() \
			or not contribution.get("supportRangesBySource", {}).is_empty())


func _drain_fixture_section_owners(label: String) -> bool:
	# The fixture owns its coordinator separately from Main. Use the same
	# compile/install/frame drain sequence as Main's teardown contract.
	if coordinator == null or not is_instance_valid(coordinator): return true
	var compile_drain: Dictionary = coordinator.drain_section_compiles()
	if compile_drain.get("status") != "drained":
		_check(label, false, {"compiles":compile_drain, "ownerMustBeRetained":true})
		return false
	var presentation_drain: Dictionary = await coordinator.drain_pending_frame_presentations()
	var drained := bool(presentation_drain.get("drained", false))
	_check(label, drained, {"compiles":compile_drain, "presentations":presentation_drain,
		"ownerMustBeRetained":not drained})
	return drained

func _quiesce_fixture_admission() -> void:
	# Match Main's graceful-quit admission/physics quiescence before any
	# yielding worker drain can advance a loading publication callback.
	if is_instance_valid(owner):
		owner.shutdown_requested = true
		owner.set_process(false)
		owner.set_process_unhandled_input(false)
		owner.set_physics_process(false)
		owner.set_registered_npc_physics_enabled(false)
		if is_instance_valid(owner.player): owner.player.set_physics_process(false)

func _shutdown() -> void:
	_quiesce_fixture_admission()
	if not await _drain_fixture_section_owners("fixture_shutdown_section_owners_drained"): return
	if owner != null and is_instance_valid(owner):
		# Main's worker drain advances its loading publication callback. This
		# isolated fixture has no live camera owner during shutdown, so clear the
		# player reference before that callback can inspect a generic CharacterBody3D.
		owner.player = null
		await owner.wait_for_terrain_workers_before_quit()
		if owner.tree_publication_queue != null and is_instance_valid(owner.tree_publication_queue):
			var tree_deadline := Time.get_ticks_msec() + 15000
			while Time.get_ticks_msec() < tree_deadline:
				var tree_state: Dictionary = owner.tree_publication_queue.metrics()
				if tree_state.get("pending", 0) == 0 and tree_state.get("activeWorkers", 0) == 0 \
						and tree_state.get("completed", 0) == 0:
					break
				await process_frame
			var drained: Dictionary = owner.tree_publication_queue.metrics()
			_check("real_tree_publication_queue_drained_on_fixture_shutdown",
				drained.get("pending", 0) == 0 and drained.get("activeWorkers", 0) == 0 \
				and drained.get("completed", 0) == 0, drained)
		await owner.wait_for_npc_navigation_before_quit()
		if owner.structure_system != null:
			owner.structure_system.main = null
		owner.structure_system = null
		owner.free()
		owner = null

func _check(label: String, passed: bool, evidence: Variant = {}) -> void:
	checks[label] = {"passed":passed, "evidence":evidence}
	if not passed:
		print("CITADEL NONEMPTY SECTION FAILURE ", label)
		if not report_path.is_empty():
			var failure_file := FileAccess.open(report_path + ".failure.json", FileAccess.WRITE)
			if failure_file != null:
				failure_file.store_string(JSON.stringify({
					"schema":"citadel-nonempty-section-failure-snapshot/v1",
					"runId":OS.get_environment("VOXEL_AUTOMATED_TEST_RUN_ID"),
					"check":label, "evidence":evidence,
					"checkCount":checks.size()}, "\t"))
				failure_file.close()

func _progress(phase: String, evidence: Dictionary = {}) -> void:
	var line := phase + " " + JSON.stringify(evidence)
	print("CITADEL NONEMPTY SECTION ", line)
	if not progress_path.is_empty():
		var file := FileAccess.open(progress_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify({"stage":phase, "details":evidence}))
			file.close()

func _wait_for_final_viewport_capture_ack(passed: bool) -> Dictionary:
	if OS.get_environment("VOXEL_AUTOMATED_TEST") != "1":
		return {"required":true, "captured":false,
			"reason":"automated in-game viewport capture handshake is required for this gate"}
	_progress("awaiting_final_viewport_capture", {"passed":passed})
	if OS.get_environment("VOXEL_AUTOMATED_TEST_CAPTURE_MODE") != "godot_viewport":
		return {"required":true, "captured":false,
			"reason":"automated cohabitation gate requires in-game viewport capture mode"}
	var ack_path := OS.get_environment("VOXEL_AUTOMATED_TEST_FINAL_CAPTURE_ACK").strip_edges()
	if ack_path.is_empty():
		return {"required":true, "captured":false,
			"reason":"final viewport capture acknowledgement path is missing"}
	var expected_run_id := OS.get_environment("VOXEL_AUTOMATED_TEST_RUN_ID").strip_edges()
	var expected_runner_id := OS.get_environment("VOXEL_AUTOMATED_TEST_NAME").strip_edges()
	var expected_source_identity_sha256 := OS.get_environment(
		"VOXEL_AUTOMATED_TEST_SOURCE_IDENTITY_SHA256").strip_edges()
	var expected_checkpoint := "test-success" if passed else "test-failure"
	var expected_phase := "test_success" if passed else "test_failure"
	var expected_phase_kind := "harness" if passed else "failure"
	var sha256_pattern := RegEx.new()
	sha256_pattern.compile("^[0-9a-f]{64}$")
	var deadline_usec := Time.get_ticks_usec() \
		+ int(30.0 * 1000000.0)
	while Time.get_ticks_usec() < deadline_usec:
		if FileAccess.file_exists(ack_path):
			var file := FileAccess.open(ack_path, FileAccess.READ)
			if file != null:
				var ack: Variant = JSON.parse_string(file.get_as_text())
				file.close()
				if ack is Dictionary and ack.get("schema") == "godot-viewport-final-capture-ack/v1" \
						and ack.get("runId") == expected_run_id \
						and ack.get("runnerId") == expected_runner_id \
						and ack.get("checkpoint") == expected_checkpoint \
						and ack.get("phase") == expected_phase \
						and ack.get("phaseKind") == expected_phase_kind \
						and ack.get("accepted") == passed \
						and ack.get("sourceIdentitySha256") == expected_source_identity_sha256:
					var viewport_receipt: Variant = ack.get("viewportCaptureReceipt", {})
					var capture_id := String(ack.get("captureId", ""))
					var screenshot_hash := String(ack.get("screenshotSha256", ""))
					var receipt_matches: bool = viewport_receipt is Dictionary \
						and viewport_receipt.get("schema") == "voxel-automated-test-viewport-capture-receipt/v1" \
						and viewport_receipt.get("captured") == true \
						and viewport_receipt.get("captureId") == capture_id \
						and viewport_receipt.get("runnerId") == expected_runner_id \
						and viewport_receipt.get("runId") == expected_run_id \
						and viewport_receipt.get("phase") == expected_phase \
						and viewport_receipt.get("phaseKind") == expected_phase_kind \
						and viewport_receipt.get("sourceIdentitySha256") == expected_source_identity_sha256
					if ack.get("captured") == true and capture_id.begins_with(expected_run_id + ":") \
							and sha256_pattern.search(screenshot_hash) != null and receipt_matches:
						return ack
					if ack.get("captured") == false:
						return ack
		await process_frame
	return {"required":true, "captured":false, "timedOut":true,
		"reason":"timed_out_waiting_for_runner_final_viewport_capture_ack",
		"runId":expected_run_id, "runnerId":expected_runner_id,
		"checkpoint":expected_checkpoint, "sourceIdentitySha256":expected_source_identity_sha256}

func _finish() -> void:
	var preflight := OS.get_environment(PREFLIGHT_ENV) == "1"
	if not preflight and not checks.has("root_reentry_replays_fresh_external_owner_before_full_part_retirement"):
		_check("complete_owner_lifecycle_act_reached", false,
			{"reason":"required_native_owner_unload_replay_act_did_not_reach_final_assertion"})
	var failed: Array[String] = []
	for name: String in checks:
		if not bool(checks[name].get("passed", false)): failed.append(name)
	var result := {"schema":"citadel-nonempty-section-preflight/v1" if preflight \
		else "citadel-nonempty-section-receipt-fixture/v1",
		"complete":true, "passed":failed.is_empty(), "checks":checks,
		"checkCount":checks.size(), "failedChecks":failed,
		"targetMember":{"memberId":target_member.get("memberId", ""),
			"geometryFamily":target_geometry_family,
			"sectionKeys":target_section_keys, "sectionCount":target_section_keys.size()},
		"knownCoverageGaps":[{"scope":"prepared_packet_family_selection_only",
			"evidence":checks.get(
				"prepared_packet_selector_reports_battlement_family_gap", {}).get(
				"evidence", {}),
			"transformArtifactCoverage":"unproven_by_this_fixture"}],
		"evidenceLevel":"renderer-backed real CitadelPublicationService fresh deterministic source and immutable plan; every root section has complete transform-artifact contributions and exact current full-part geometry-owner rosters; no native installation in preflight" if preflight \
			else "headed actual CitadelPublicationService fresh deterministic source and plan; independently demanded root sections, complete root-part geometry-owner closure installed through production queues/native receipts, root acknowledgement and external-owner unload/replay",
		"source":{"seed":SEED, "region":REGION, "sourceOrigin":"generated by current real admission path; no frozen fixture"},
		"traceTail":trace.slice(maxi(0, trace.size() - 30)),
	"doesNotProve":"Prepared-packet family selection remains a separate contract from committed transform-artifact coverage. This fixture does not prove normal menu startup, a full multi-provider world roster, full Citadel-wide retirement, live player/door interaction or navigation traversal, save/reload parity, or broad performance. Tree native acceptance is limited to the explicitly reported nonzero tree source set; an empty set provides no tree acceptance evidence."}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(result, "\t")); file.close()
	quit(0 if failed.is_empty() else 1)

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
