extends SceneTree

const TutorialSystemScript := preload("res://scripts/TutorialSystem.gd")
const MainCoreScript := preload("res://scripts/MainCore.gd")
const TitleMenuScript := preload("res://scripts/TitleMenu.gd")
const StartupReadinessResultScript := preload("res://scripts/world/StartupReadinessResult.gd")
const TownRuntimeManifestScript := preload("res://scripts/world/TownRuntimeManifest.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")

class SyntheticStartupMain extends MainCoreScript:
	# Suppress world setup only. Lifecycle observation, timeline reset and failure
	# handling remain production methods; these state transitions are synthetic.
	func _ready() -> void:
		set_process(false)
		set_process_unhandled_input(false)
		set_physics_process(false)

class SyntheticTileWorld extends RefCounted:
	var stale_snapshot := false
	func navmesh_tile_source_key_for_tile(_key: String) -> String: return "current-source"
	func build_navmesh_tile_snapshot(key: String) -> Dictionary:
		return {"tileKey":key,"sourceKey":"stale-source" if stale_snapshot else "current-source","sourceRevision":1,
			"surfaces":[{"cell":Vector3i.ZERO,"worldPosition":Vector3.ZERO}]}

class SyntheticTileDelegate extends RefCounted:
	var navmesh_world

class SyntheticNavigationOwnerLinks extends RefCounted:
	var seed_text := "synthetic-captured-navigation"
	var npc_system
	var structure_system
	var pathing
	var autonomy_system
	var navigation_world
	var route_planner
	var navmesh_world
	var delegate
	var door_portals

class SyntheticOrdinaryPortal extends RefCounted:
	var portal_id := "synthetic-double-door"
	var leaf_nodes: Array[Node3D] = []

class SyntheticOrdinaryPortals extends RefCounted:
	var portals := {}
	var door_to_portal := {}
	func portal_for_door(body):
		return portals.get(door_to_portal.get(body.get_instance_id(),""))

class SyntheticCapturedNavigationOwners extends RefCounted:
	# Minimal source, nav-service and publisher stand-ins; no NavigationServer or
	# geometry acceptance. Only RegionalNavigationPublication is production here.
	var source_key := "synthetic-local-v1"
	var navmesh_tile_snapshot_cache := {}
	var queued_navmesh_tile_source_keys := {"0,0":"synthetic-local-v1","1,0":"synthetic-new-work"}
	var published_navmesh_tile_keys := {}
	var empty_navmesh_tile_keys := {}
	var last_navmesh_tile_queue_debug: Array[Dictionary] = []
	var _tile_publication_receipts := {"region:chunk:0,0":{
		"status":"ready","sourceKey":"synthetic-local-v1","sourceRevision":7,"installationSerial":11}}
	var dirty_regions_by_region := {}
	var region_rids_by_region := {"region:chunk:0,0":true} # Synthetic presence only.
	var navigation_map_dirty_serial := 11
	var navigation_map_synced_serial := 11
	var calls: Array[String] = []
	var pump_budgets: Array[int] = []
	var slice_exhausted := false
	var enqueue_calls := 0
	var build_calls := 0
	var proof_calls := 0
	var accepted_proofs := 0
	var expected_links: Array = ["synthetic-crossing-link"]
	var last_proof_links: Array = []
	var allow_cached_surface_proof := false
	func navmesh_tile_source_key_for_tile(key: String) -> String:
		return source_key if key == "0,0" else "synthetic-new-work"
	func building_navigation_sources(_key: String) -> Dictionary:
		return {"status":"ready","sources":[]}
	func build_navmesh_tile_snapshot(_key: String) -> Dictionary:
		build_calls += 1
		return {"publicationStatus":"pending"}
	func queue_navmesh_tile_publish(key: String, _urgent: bool) -> void:
		enqueue_calls += 1
		queued_navmesh_tile_source_keys[key] = navmesh_tile_source_key_for_tile(key)
	func advance_publication(_budget_usec: int) -> void:
		calls.append("nav_advance")
	func _process_queued_navmesh_tile_publishes(_count: int, budget_usec: int, _force: bool, _sync: bool) -> int:
		calls.append("publisher_pump")
		pump_budgets.append(budget_usec)
		# Deterministic exhausted-slice simulation: refuse any later proof in this
		# slice. Do not sleep/spin or publish the uncaptured neighbouring source.
		slice_exhausted = true
	func promote_queued_navmesh_tile_priority(key: String, expected_source: String) -> bool:
		return queued_navmesh_tile_source_keys.get(key) == expected_source
		return 0
	func _sync_navmesh_after_queued_tile_publish() -> void:
		calls.append("publisher_sync")
	func tile_publication_readiness(key: String, expected_source: String, surfaces: Array, links: Array) -> Dictionary:
		proof_calls += 1
		last_proof_links = links.duplicate(true)
		calls.append("receipt_proof")
		var receipt: Dictionary = _tile_publication_receipts.get("region:chunk:"+key,{})
		if slice_exhausted or receipt.get("sourceKey") != expected_source \
				or (surfaces != ["surface:0,0:2,0,3:4","synthetic-building-surface"] and not (allow_cached_surface_proof and surfaces.is_empty())) \
				or links != expected_links:
			return {"status":"pending","reason":"synthetic_slice_or_receipt_proof_pending"}
		accepted_proofs += 1
		calls.append("receipt_accepted")
		return receipt.duplicate(true)

class SyntheticRegionProvider extends RefCounted:
	var ready := true
	var pending_bounds := Rect2i()
	var source_revision := 1
	var dependency_status := "described"
	var dependency_bounds: Array[Rect2i] = []
	var missing_sources: Array[String] = []
	var unresolved_crossings: Array[String] = []
	var reject_admission := false
	var admission_calls := 0
	var requirements_calls := 0
	var next_id := 1
	var retained := {}
	var releases: Array[int] = []
	func request_region(bounds: Rect2i, _priority: int, _reason: String) -> int:
		admission_calls += 1
		if reject_admission: return 0
		var id := next_id
		next_id += 1
		retained[id] = bounds
		return id
	func release_region(id: int) -> void:
		releases.append(id)
		retained.erase(id)
	func region_dependency_revision(_bounds: Rect2i) -> String:
		return "synthetic-source:%d" % source_revision
	func region_dependency_requirements(_bounds: Rect2i) -> Dictionary:
		requirements_calls += 1
		return {"status":dependency_status,"reason":"synthetic_dependencies",
			"dependencyBounds":dependency_bounds.duplicate(),"sourceRevisions":{"fixture":source_revision},
			"missingSourceIds":missing_sources.duplicate(),"unresolvedCrossingIds":unresolved_crossings.duplicate(),"requiredCrossings":{}}
	func region_publication_readiness(bounds: Rect2i) -> Dictionary:
		var held := retained.values().any(func(area: Rect2i):return area.encloses(bounds))
		return {"status":"ready" if ready and held and (not pending_bounds.has_area() or not pending_bounds.intersects(bounds)) else "pending",
			"reason":"synthetic_owner_pending","sourceRevisions":{"fixture":source_revision}}

class FakeStructureSystem:
	extends RefCounted
	var update_calls := 0
	var publication_calls := 0

	func update_around(_center: Vector2i) -> void:
		update_calls += 1

	func request_town_manifest_publication(_town: Dictionary, _requirements: Dictionary, _max_ops: int, _budget_ms: float) -> Dictionary:
		publication_calls += 1
		return {
			"ok": false,
			"status": "failed",
			"reason": "required_town_manifest_generation_failed",
			"manifest": {},
			"pending": [],
			"metrics": {"failureReasons": ["missing required homeKey 3"]}
		}

class FakeNpcSystem:
	extends RefCounted
	var npcs: Array = []
	var autonomy_system = null

class FakeMain:
	extends Node
	var startup_loading_active := true
	var runtime_loading_active := false
	var town_region_cache := {}
	var structure_system = FakeStructureSystem.new()
	var npc_system = null
	var blocks := {}
	var player = null

	func town_region(_rx: int, _rz: int) -> Dictionary:
		return {
			"regionX": 1,
			"regionZ": 0,
			"centerX": 280,
			"centerZ": 0,
			"radius": 30,
			"level": 16.0
		}

	func unlock_crafting_group(_group_id: String, _reason := "") -> bool:
		return true

var report_path := ""
var results: Array[Dictionary] = []
var failure_signal_reason := ""
var completion_signal_count := 0

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_STARTUP_READINESS_CONTRACT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/tutorial-town/startup-loading-readiness-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	test_scenario_requirements_are_semantic()
	test_regional_demand_contract()
	await test_regional_provider_closure_contract()
	await test_regional_subregion_readiness()
	await test_regional_cached_navigation_proof_precedes_publisher()
	test_regional_ordinary_door_leaf_sources()
	test_missing_manifest_doors_are_structured_failure()
	test_missing_npc_registration_is_structured_failure()
	test_continue_restore_defers_world_setup()
	test_gameplay_physics_gate_rejects_enabled_npc()
	await test_startup_lifecycle_wait_contract()
	test_passive_streaming_notification_priority()
	test_loading_completion_requires_all_readiness_domains()
	await test_startup_requires_revision_matched_navigation()
	await test_forced_manifest_failure_keeps_gameplay_disabled_and_visible()
	finish()

func test_regional_demand_contract() -> void:
	const Regions := preload("res://scripts/world/WorldStreamingCoordinator.gd")
	var regions := Regions.new()
	regions.configure("contract-seed")
	var bounds := Regions.playable_bounds(Vector3(-0.25,0.0,-0.25))
	var keys := Regions.chunks_for_bounds(bounds)
	add_result("regional_64m_negative_grid_coverage",keys.has(Vector2i(-2,-2)) and keys.has(Vector2i(1,1)) and keys.size() == 16,{"bounds":bounds,"chunks":keys})
	var first := regions.request_region(bounds,0,"player")
	var second := regions.request_region(bounds,1,"actor")
	var held := regions.retained_gameplay_chunks()
	regions.release_region(first)
	regions.advance(Time.get_ticks_msec()+Regions.RELEASE_HYSTERESIS_MS+1)
	add_result("regional_overlapping_owner_retains_demand",first > 0 and second > 0 and regions.retained_gameplay_chunks() == held,{"count":held.size()})
	var state := regions.region_readiness(bounds)
	var missing_domains: Array = []
	for item: Dictionary in state.missing: missing_domains.append(String(item.domain))
	add_result("regional_missing_owner_cannot_report_ready",state.status == "pending" and missing_domains.has("dependencies")
		and missing_domains.has("terrain") and missing_domains.has("structures") and missing_domains.has("navigation"),state)
	regions.release_region(second)
	add_result("regional_release_hysteresis",not regions.retained_gameplay_chunks().is_empty(),{})
	regions.advance(Time.get_ticks_msec()+Regions.RELEASE_HYSTERESIS_MS+1)
	add_result("regional_release_drains",regions.retained_gameplay_chunks().is_empty(),{})
	regions.configure("next-seed")
	var next := regions.request_region(bounds,0,"new player")
	regions.release_region(first)
	regions.advance(Time.get_ticks_msec()+Regions.RELEASE_HYSTERESIS_MS+1)
	add_result("regional_stale_release_cannot_touch_new_world",next > second and not regions.retained_gameplay_chunks().is_empty(),{})
	var before := regions.retained_gameplay_chunks()
	var rejected := regions.request_region(Rect2i(Vector2i(10000,10000),Vector2i(512,512)),0,"oversized resident request")
	add_result("regional_capacity_rejects_without_dropping_demand",rejected == 0 and regions.last_rejection == "region_resident_capacity" and before == regions.retained_gameplay_chunks(),{})
	const TerrainRuntime := preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
	var runtime := TerrainRuntime.new()
	var chunk := Vector2i(-1,0)
	# Synthetic bookkeeping only: no claim that this dictionary is terrain proof.
	runtime.retained_gameplay_chunks[chunk] = true
	runtime.desired_gameplay_chunks[chunk] = true
	runtime.published_gameplay_chunks[chunk] = {"synthetic":true}
	runtime.release_gameplay_chunk(chunk)
	add_result("regional_terrain_release_respects_retained_owner",runtime.published_gameplay_chunks.has(chunk),{})
	runtime.retained_gameplay_chunks.clear()
	runtime.release_gameplay_chunk(chunk)
	add_result("regional_terrain_release_invalidates_publication",not runtime.desired_gameplay_chunks.has(chunk) and not runtime.published_gameplay_chunks.has(chunk),{})
	runtime.free()

func test_regional_provider_closure_contract() -> void:
	# Synthetic owners exercise the real coordinator, not geometry/playability.
	const Regions := preload("res://scripts/world/WorldStreamingCoordinator.gd")
	var terrain := SyntheticRegionProvider.new()
	var structures := SyntheticRegionProvider.new()
	var navigation := SyntheticRegionProvider.new()
	var providers := {"terrain":terrain,"structures":structures,"navigation":navigation}
	var regions := Regions.new()
	regions.configure("regional-provider-contract",providers)
	var bounds := Rect2i(Vector2i.ZERO,Vector2i(8,8))
	var dependency := Rect2i(Vector2i(-12,-6),Vector2i(40,24))
	structures.dependency_bounds.assign([dependency])
	navigation.ready = false
	var first := regions.request_region(bounds,0,"synthetic_player")
	await process_frame
	regions.advance()
	# SceneTree's first process_frame signal can precede the frame counter's
	# first increment; allow that startup boundary without bypassing the guard.
	await process_frame
	regions.advance()
	add_result("regional_expansion_waits_for_fixed_point",regions.region_readiness(bounds).status=="pending"
		and terrain.retained.is_empty() and navigation.retained.is_empty(),{})
	await process_frame
	regions.advance()
	var state := regions.region_readiness(bounds)
	var demanded: bool = first>0 and state.closedBounds==dependency
	for provider: SyntheticRegionProvider in [terrain,structures,navigation]:
		demanded = demanded and provider.retained.size()==1 and provider.retained.values()[0]==dependency
	add_result("regional_dependency_closure_reaches_every_owner",demanded and regions.retained_cell_bounds().has(dependency.grow(Regions.RENDER_CELL_SIZE)),state)
	add_result("regional_navigation_ack_required_after_physical_owners",state.status=="pending"
		and state.domains.terrain.status=="ready" and state.domains.structures.status=="ready" and state.domains.navigation.status=="pending",{})
	navigation.ready=true
	state=regions.region_readiness(bounds)
	add_result("regional_composed_acks_and_source_revisions",state.status=="ready"
		and state.sourceRevisions.terrain.fixture==1 and state.sourceRevisions.structures.fixture==1 and state.sourceRevisions.navigation.fixture==1,{})
	var compiled_count := structures.requirements_calls
	await process_frame
	regions.advance()
	add_result("regional_stable_source_reuses_dependency_closure",structures.requirements_calls==compiled_count,{})
	# Invalidate before coordinator advance: stale closure must immediately stop
	# reporting ready even when all previous provider acknowledgements persist.
	structures.source_revision+=1
	var expanded := dependency.merge(Rect2i(Vector2i(50,0),Vector2i(8,8)))
	structures.dependency_bounds.assign([expanded])
	navigation.reject_admission=true
	state=regions.region_readiness(bounds)
	add_result("regional_source_revision_invalidates_ready_immediately",state.status=="pending",state)
	var old_navigation_id: int=navigation.retained.keys()[0]
	await process_frame
	regions.advance()
	await process_frame
	regions.advance()
	state=regions.region_readiness(bounds)
	add_result("regional_rejected_replacement_keeps_old_owner_demand",state.status=="pending"
		and state.closedBounds==expanded and navigation.retained.get(old_navigation_id)==dependency
		and navigation.releases.is_empty(),{})
	var admission_count := navigation.admission_calls
	var expanded_compiled_count := structures.requirements_calls
	navigation.reject_admission=false
	await process_frame
	regions.advance()
	state=regions.region_readiness(bounds)
	add_result("regional_provider_admission_retries_without_source_recompile",state.status=="ready"
		and navigation.admission_calls==admission_count+1 and navigation.retained.size()==1
		and navigation.retained.values()[0]==expanded and navigation.releases.has(old_navigation_id)
		and structures.requirements_calls==expanded_compiled_count and expanded_compiled_count==compiled_count+2,{})
	# Declared unresolved obligations block even if providers otherwise say ready.
	structures.source_revision+=1
	structures.unresolved_crossings.assign(["synthetic-stair-seam"])
	await process_frame
	regions.advance()
	add_result("regional_unresolved_declared_crossing_blocks_ready",regions.region_readiness(bounds).status=="failed",{})
	structures.unresolved_crossings.clear()
	structures.missing_sources.assign(["synthetic-support"])
	structures.source_revision+=1
	await process_frame
	regions.advance()
	add_result("regional_missing_source_part_blocks_ready",regions.region_readiness(bounds).status=="failed",{})
	structures.missing_sources.clear()
	structures.source_revision+=1
	await process_frame
	regions.advance()
	var second := regions.request_region(bounds,1,"synthetic_actor")
	# Round-robin refresh visits both retained logical owners.
	for frame in range(4):
		await process_frame
		regions.advance()
	var held := regions.retained_gameplay_chunks()
	regions.release_region(first)
	regions.advance(Time.get_ticks_msec())
	add_result("regional_provider_release_waits_for_hysteresis",navigation.retained.size()==2,{})
	regions.advance(Time.get_ticks_msec()+Regions.RELEASE_HYSTERESIS_MS+1)
	add_result("regional_overlapping_provider_owner_survives_release",second>first and navigation.retained.size()==1
		and regions.retained_gameplay_chunks()==held and regions.region_readiness(bounds).status=="ready",{})
	regions.configure("regional-provider-next-world",providers)
	var all_released := regions.retained_gameplay_chunks().is_empty()
	for provider: SyntheticRegionProvider in [terrain,structures,navigation]: all_released=all_released and provider.retained.is_empty()
	add_result("regional_reset_releases_every_provider_request",all_released,{})
	var fresh := regions.request_region(bounds,0,"synthetic_next_player")
	await process_frame
	regions.advance()
	await process_frame
	regions.advance()
	regions.release_region(second)
	regions.advance(Time.get_ticks_msec()+Regions.RELEASE_HYSTERESIS_MS+1)
	add_result("regional_old_world_release_cannot_release_fresh_provider",fresh>second and navigation.retained.size()==1
		and regions.region_readiness(bounds).status=="ready",{})
	regions.configure("",{})

func test_regional_subregion_readiness() -> void:
	const Regions := preload("res://scripts/world/WorldStreamingCoordinator.gd")
	var terrain := SyntheticRegionProvider.new()
	var structures := SyntheticRegionProvider.new()
	var navigation := SyntheticRegionProvider.new()
	navigation.pending_bounds = Rect2i(16,16,16,16)
	var regions := Regions.new()
	regions.configure("synthetic-local-query",{"terrain":terrain,"structures":structures,"navigation":navigation})
	var full := Rect2i(0,0,32,32)
	regions.request_region(full,0,"player")
	for frame in range(3):
		await process_frame
		regions.advance()
	add_result("regional_local_query_does_not_wait_for_unrelated_tiles",regions.region_readiness(full).status=="pending"
		and regions.region_readiness(Rect2i(0,0,8,8)).status=="ready",{})
	add_result("regional_local_query_requires_its_own_acknowledgement",regions.region_readiness(Rect2i(20,20,8,8)).status=="pending",{})
	regions.configure("")

func test_regional_cached_navigation_proof_precedes_publisher() -> void:
	# Synthetic ordering/identity regression only; never live NPC acceptance.
	const Publication := preload("res://scripts/world/RegionalNavigationPublication.gd")
	var main := SyntheticNavigationOwnerLinks.new()
	var npc := SyntheticNavigationOwnerLinks.new()
	var pathing := SyntheticNavigationOwnerLinks.new()
	var authority := SyntheticNavigationOwnerLinks.new()
	var owners := SyntheticCapturedNavigationOwners.new()
	main.npc_system = npc
	main.structure_system = SyntheticRegionProvider.new()
	npc.pathing = pathing
	npc.autonomy_system = pathing
	pathing.navigation_world = owners
	pathing.navmesh_world = owners
	pathing.route_planner = authority
	authority.delegate = owners
	owners.navmesh_tile_snapshot_cache["captured-local"] = {
		"tileKey":"0,0","sourceKey":owners.source_key,"worldSeed":main.seed_text,
		"publicationSource":{"status":"prepared","snapshot":{
			"sourceKey":owners.source_key,"sourceRevision":7,
			"surfaces":[{"cell":Vector3i(2,0,3),"spanIndex":4},{"cell":Vector3i.ZERO,"blocked":true}],
			"buildingSurfaces":[{"id":"synthetic-building-surface"}],
			"crossingLinks":[{"id":"synthetic-crossing-link"}]}}}
	var door_sources := [
		{"id":"door-link:synthetic-pair:0,0","portalId":"synthetic-pair","cell":Vector2i(2,3),"start":Vector3(2,0,2),"end":Vector3(2,0,4)},
		{"id":"door-link:synthetic-pair:0,0","portalId":"synthetic-pair","cell":Vector2i(3,3),"start":Vector3(3,0,2),"end":Vector3(3,0,4)}]
	owners.navmesh_tile_snapshot_cache["captured-local"].publicationSource.snapshot["doorLinks"] = door_sources
	owners.expected_links.append_array(door_sources)
	var publication := Publication.new()
	var configured := publication.configure(main)
	var local_bounds := Rect2i(0,0,16,16)
	var full_bounds := Rect2i(0,0,32,16)
	var request := publication.request_region(full_bounds,0,"synthetic_cached_before_new_work")
	var before := publication.region_publication_readiness(local_bounds)
	var ready := before
	# Bounded retries respect the real once-per-frame guard and cooperative
	# deadline. Call order, not elapsed wall time, detects the old pump-first bug.
	for frame in range(8):
		await process_frame
		owners.slice_exhausted = false
		publication.advance(4000)
		ready = publication.region_publication_readiness(local_bounds)
		if ready.status == "ready" and not owners.pump_budgets.is_empty(): break
	var proof_index := owners.calls.find("receipt_accepted")
	var nav_index := owners.calls.find("nav_advance")
	var pump_index := owners.calls.find("publisher_pump")
	add_result("synthetic_regional_cached_proof_precedes_busy_publisher",configured and request>0
		and before.status=="pending" and ready.status=="ready" and owners.accepted_proofs>0
		and proof_index>=0 and nav_index>proof_index and pump_index>nav_index
		and owners.pump_budgets.all(func(budget: int):return budget>0 and budget<=4000)
		and owners.enqueue_calls==0 and owners.build_calls==0
		and publication.region_publication_readiness(full_bounds).status=="pending",
		{"evidenceLevel":"synthetic_contract","ready":ready,"calls":owners.calls.duplicate(),
		"pumpBudgetsUsec":owners.pump_budgets.duplicate(),"enqueueCalls":owners.enqueue_calls,"buildCalls":owners.build_calls})
	owners.allow_cached_surface_proof = true
	owners.slice_exhausted = false
	publication._tiles["0,0"].proofCheckedMsec = Time.get_ticks_msec()-Publication.RECEIPT_RECHECK_MSEC-1
	var prior_proofs := owners.proof_calls
	publication._advance_tile("0,0",Time.get_ticks_usec()+4000)
	add_result("synthetic_regional_door_source_receipts_rechecked",owners.proof_calls==prior_proofs+1
		and publication._tiles["0,0"].status=="ready" and owners.last_proof_links==owners.expected_links,
		{"evidenceLevel":"synthetic_contract","requested":owners.last_proof_links})
	# Public readiness must recheck the installed receipt, not trust cached ready.
	owners._tile_publication_receipts["region:chunk:0,0"].installationSerial = 12
	var changed_receipt := publication.region_publication_readiness(local_bounds)
	add_result("synthetic_regional_cached_proof_requires_current_installation",ready.status=="ready"
		and changed_receipt.status=="pending" and changed_receipt.missing.any(
			func(item: Dictionary):return item.get("reason")=="navigation_acknowledgement_changed"),changed_receipt)
	owners._tile_publication_receipts["region:chunk:0,0"].installationSerial = 11
	# Keep the prepared v1 capture and installed v1 receipt; only the local
	# authoritative identity changes. They must never be accepted for v2.
	owners.source_key = "synthetic-local-v2"
	var stale_before := publication.region_publication_readiness(local_bounds)
	var previous_proof_calls := owners.proof_calls
	for frame in range(3):
		await process_frame
		owners.slice_exhausted = false
		publication.advance(4000)
	var stale_after := publication.region_publication_readiness(local_bounds)
	add_result("synthetic_regional_stale_local_capture_remains_pending",ready.status=="ready"
		and stale_before.status=="pending" and stale_after.status=="pending"
		and stale_after.sourceRevisions.tiles.get("0,0")==owners.source_key
		and owners.proof_calls==previous_proof_calls and owners.build_calls==0,
		{"evidenceLevel":"synthetic_contract","before":stale_before,"after":stale_after,
		"proofCallsBefore":previous_proof_calls,"proofCallsAfter":owners.proof_calls})
	publication.release_region(request)
	add_result("synthetic_regional_receipt_requests_preserve_both_door_sources",owners.last_proof_links == owners.expected_links,
		{"evidenceLevel":"synthetic_contract","requested":owners.last_proof_links})

func test_regional_ordinary_door_leaf_sources() -> void:
	# Synthetic live-leaf registry/source data; production requirement/mapping
	# helpers and adapter cell/orientation queries. No installed links or gameplay.
	const Structure := preload("res://scripts/StructureSystem.gd")
	const Publication := preload("res://scripts/world/RegionalNavigationPublication.gd")
	const Adapter := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
	for seam in [false,true]:
		var main := SyntheticNavigationOwnerLinks.new()
		var npc := SyntheticNavigationOwnerLinks.new()
		var pathing := SyntheticNavigationOwnerLinks.new()
		var portals := SyntheticOrdinaryPortals.new()
		var portal := SyntheticOrdinaryPortal.new()
		var adapter := Adapter.new()
		main.npc_system = npc
		npc.pathing = pathing
		npc.autonomy_system = pathing
		pathing.navigation_world = adapter
		pathing.door_portals = portals
		portals.portals[portal.portal_id] = portal
		var structure := Structure.new()
		structure.main = main
		var publication := Publication.new()
		publication._main = weakref(main)
		var first_x: int = 15 if seam else 14
		for x in [first_x,first_x+1]:
			var leaf := Node3D.new()
			root.add_child(leaf)
			leaf.set_meta("cell",Vector3i(x,1,3))
			leaf.set_meta("block_type","door")
			leaf.set_meta("door_side",0)
			leaf.set_meta("door_portal_id",portal.portal_id)
			portal.leaf_nodes.append(leaf)
			portals.door_to_portal[leaf.get_instance_id()] = portal.portal_id
			adapter.cached_doors[Vector2i(x,3)] = leaf
		var requirements := {"status":"described","reason":"","requiredCrossings":{},"dependencyBounds":[]}
		structure._describe_regional_portal_leaves(portal,"synthetic-home:door",{"sourceKey":"synthetic-home-v1"},portals,requirements)
		var obligations: Array = requirements.requiredCrossings.values()
		var snapshot := {"doorLinks":[],"doorPortals":[]}
		for obligation: Dictionary in obligations:
			snapshot.doorLinks.append(obligation.doorSource.duplicate())
			snapshot.doorPortals.append({"id":obligation.portalId,"cell":obligation.cell,
				"entrance":obligation.entrance,"exit":obligation.exit})
		var all_mapped: bool = requirements.status == "described" and obligations.size() == 2
		for obligation: Dictionary in obligations:
			var mapped: Dictionary = publication._ordinary_door_crossing(obligation,obligation.ownerTileKey,snapshot,adapter)
			all_mapped = all_mapped and mapped.status == "described" \
				and mapped.get("mapping",{}).get("doorSource") == obligation.doorSource
		var owned_tiles: Array = obligations.map(func(value: Dictionary):return value.ownerTileKey)
		add_result("synthetic_ordinary_double_leaf_"+("seam" if seam else "shared_id"),all_mapped
			and owned_tiles == (["0,0","1,0"] if seam else ["0,0","0,0"])
			and requirements.dependencyBounds.has(Rect2i(first_x,2,1,1))
			and requirements.dependencyBounds.has(Rect2i(first_x+1,4,1,1)),
			{"evidenceLevel":"synthetic_contract","requirements":requirements})
		if obligations.size() == 2:
			var obligation: Dictionary = obligations[0]
			var duplicated: Dictionary = snapshot.duplicate(true)
			duplicated.doorLinks.append(obligation.doorSource.duplicate())
			var duplicate_result: Dictionary = publication._ordinary_door_crossing(obligation,obligation.ownerTileKey,duplicated,adapter)
			var wrong_source: Dictionary = snapshot.duplicate(true)
			wrong_source.doorLinks[0].cell = Vector2i(99,99)
			var source_result: Dictionary = publication._ordinary_door_crossing(obligation,obligation.ownerTileKey,wrong_source,adapter)
			var wrong_endpoint: Dictionary = snapshot.duplicate(true)
			wrong_endpoint.doorLinks[0].start += Vector3.UP
			var endpoint_result: Dictionary = publication._ordinary_door_crossing(obligation,obligation.ownerTileKey,wrong_endpoint,adapter)
			add_result("synthetic_ordinary_leaf_rejects_ambiguous_or_mismatched_source_"+str(seam),
				duplicate_result.reason == "ordinary_door_link_ambiguous" and source_result.status == "failed" and endpoint_result.status == "failed",
				{"evidenceLevel":"synthetic_contract","duplicate":duplicate_result,"source":source_result,"endpoint":endpoint_result})
		for leaf in portal.leaf_nodes: leaf.free()
		portal.leaf_nodes.clear()

func test_startup_requires_revision_matched_navigation() -> void:
	# Synthetic source, real NavigationServer install/sync and production startup
	# consumer. Proves the receipt gate, not generated topology or NPC movement.
	var main = MainCoreScript.new()
	var world := SyntheticTileWorld.new()
	var delegate := SyntheticTileDelegate.new()
	delegate.navmesh_world = NavmeshWorldServiceScript.new()
	var ready: Dictionary = main.publish_startup_navmesh_tile(world,delegate,"0,0")
	for frame in 60:
		if ready.get("status") != "pending": break
		await physics_frame
		ready=main.publish_startup_navmesh_tile(world,delegate,"0,0")
	add_result("startup_navigation_requires_installed_revision",ready.get("ok",false) and ready.get("receipt",{}).get("status")=="ready",ready)
	world.stale_snapshot=true
	var stale: Dictionary = main.publish_startup_navmesh_tile(world,delegate,"0,0")
	add_result("startup_navigation_rejects_stale_registered_source",not stale.get("ok",true),stale)
	delegate.navmesh_world.clear()
	main.free()

func test_scenario_requirements_are_semantic() -> void:
	var tutorial = TutorialSystemScript.new()
	var requirements: Dictionary = tutorial.tutorial_scenario_requirements()
	add_result(
		"tutorial_scenario_derives_semantic_home_requirements",
		bool(requirements.get("ok", false)) \
			and requirements.get("requiredHomeKeys", []) == [0, 1, 2, 3] \
			and int((requirements.get("actorHomeAssignments", {}) as Dictionary).get("mira", -1)) == 3,
		requirements
	)
	tutorial.free()

func test_missing_manifest_doors_are_structured_failure() -> void:
	var tutorial = TutorialSystemScript.new()
	var fake_main := FakeMain.new()
	root.add_child(fake_main)
	fake_main.add_child(tutorial)
	tutorial.main = fake_main
	var manifest := {"doorPortalIds": ["door:required-home"]}
	var result: Dictionary = tutorial.tutorial_manifest_door_readiness(manifest)
	var metrics: Dictionary = result.get("metrics", {})
	add_result(
		"missing_manifest_door_block_and_portal_fail_structurally",
		String(result.get("status", "")) == "failed" \
			and String(result.get("reason", "")) == "required_town_doors_not_registered" \
			and metrics.get("missingDoorBlocks", []) == ["door:required-home"] \
			and metrics.get("missingDoorPortals", []) == ["door:required-home"],
		result
	)
	fake_main.free()

func test_missing_npc_registration_is_structured_failure() -> void:
	var tutorial = TutorialSystemScript.new()
	var fake_main := FakeMain.new()
	var fake_npcs := FakeNpcSystem.new()
	var bodies: Array[Node3D] = []
	for npc_id in ["rowan", "niko", "sera", "toma", "lyra"]:
		var body := Node3D.new()
		bodies.append(body)
		fake_npcs.npcs.append({"id": npc_id, "body": body})
	fake_main.npc_system = fake_npcs
	tutorial.main = fake_main
	var result: Dictionary = tutorial.tutorial_npc_registration_readiness({})
	add_result(
		"missing_required_npc_registration_fails_before_gameplay",
		String(result.get("status", "")) == "failed" \
			and String(result.get("reason", "")) == "required_tutorial_npcs_not_registered" \
			and (result.get("metrics", {}) as Dictionary).get("missingNpcIds", []) == ["mira"],
		result
	)
	for body in bodies:
		body.free()
	tutorial.free()
	fake_main.free()

func test_continue_restore_defers_world_setup() -> void:
	var tutorial = TutorialSystemScript.new()
	var fake_main := FakeMain.new()
	tutorial.setup(fake_main)
	tutorial.restore({
		"started": true,
		"interacted": [],
		"completedSteps": [],
		"lastMessage": "saved tutorial",
		"startCell": [267, -10],
		"introRepair": {}
	})
	add_result(
		"continue_restore_defers_generation_and_spawn_to_readiness_gate",
		bool(tutorial.restore_world_setup_pending) \
			and fake_main.structure_system.update_calls == 0 \
			and tutorial.npc_count() == 0,
		{
			"restorePending": tutorial.restore_world_setup_pending,
			"structureUpdateCalls": fake_main.structure_system.update_calls,
			"npcCount": tutorial.npc_count()
		}
	)
	tutorial.free()
	fake_main.free()

func test_gameplay_physics_gate_rejects_enabled_npc() -> void:
	var main = MainCoreScript.new()
	main.set_process(false)
	main.set_process_unhandled_input(false)
	main.set_physics_process(false)
	var player_body := CharacterBody3D.new()
	player_body.set_physics_process(false)
	main.player = player_body
	var npc_body := CharacterBody3D.new()
	npc_body.set_physics_process(true)
	var fake_npcs := FakeNpcSystem.new()
	fake_npcs.npcs = [{"id": "early_npc", "body": npc_body}]
	main.npc_system = fake_npcs
	var failed_result: Dictionary = main.startup_physics_gate_readiness()
	npc_body.set_physics_process(false)
	var execution_owner := Node.new()
	fake_npcs.autonomy_system = execution_owner
	execution_owner.set_physics_process(true)
	var execution_failed_result: Dictionary = main.startup_physics_gate_readiness()
	main.set_registered_npc_physics_enabled(false)
	var ready_result: Dictionary = main.startup_physics_gate_readiness()
	add_result(
		"gameplay_physics_gate_rejects_enabled_registered_npc",
		String(failed_result.get("status", "")) == "failed" \
			and String(failed_result.get("reason", "")) == "gameplay_physics_enabled_before_readiness" \
			and (failed_result.get("metrics", {}) as Dictionary).get("enabledNpcIds", []) == ["early_npc"] \
			and String(ready_result.get("status", "")) == "ready",
		{"failed": failed_result, "ready": ready_result}
	)
	add_result(
		"synthetic_gameplay_gate_rejects_shared_npc_execution_and_pauses_owner",
		String(execution_failed_result.get("status", "")) == "failed" \
			and bool(execution_failed_result.get("metrics", {}).get("npcExecutionEnabled", false)) \
			and not execution_owner.is_physics_processing() \
			and String(ready_result.get("status", "")) == "ready",
		{"enabledExecution": execution_failed_result, "paused": ready_result}
	)
	main.set_registered_npc_physics_enabled(true)
	add_result("synthetic_gameplay_gate_resumes_shared_execution_and_bodies",
		execution_owner.is_physics_processing() and npc_body.is_physics_processing(), {})
	execution_owner.free()
	player_body.free()
	npc_body.free()
	main.free()

func test_startup_lifecycle_wait_contract() -> void:
	var main := SyntheticStartupMain.new()
	var outside_tree: bool = await main.wait_for_startup_loading_complete(0.0)
	root.add_child(main)
	var unstarted: bool = await main.wait_for_startup_loading_complete(0.0)
	add_result("synthetic_startup_wait_rejects_unstarted_or_detached_owner",not outside_tree and not unstarted,
		{"evidenceLevel":"synthetic_contract","outsideTree":outside_tree,"unstarted":unstarted})

	main.startup_readiness_domains["gameplay"] = {"status":"ready"}
	main.startup_loading_active = true
	var startup_pending: bool = await main.wait_for_startup_loading_complete(0.0)
	main.startup_loading_active = false
	main.runtime_loading_active = true
	var reload_pending: bool = await main.wait_for_startup_loading_complete(0.0)
	add_result("synthetic_startup_wait_loading_overrides_old_ready",not startup_pending and not reload_pending,
		{"evidenceLevel":"synthetic_contract","startup":startup_pending,"reload":reload_pending})

	main.apply_startup_loading_failure_state(StartupReadinessResultScript.failed("synthetic_startup_failure"))
	var failed: bool = await main.wait_for_startup_loading_complete(0.0)
	main.startup_readiness_domains["diagnostic_fast_boot"] = {"status":"excluded"}
	var failed_diagnostic: bool = await main.wait_for_startup_loading_complete(0.0,true)
	add_result("synthetic_startup_wait_failure_overrides_terminal_markers",not failed and not failed_diagnostic
		and not main.startup_loading_active and not main.runtime_loading_active,
		{"evidenceLevel":"synthetic_contract","gameplay":failed,"diagnostic":failed_diagnostic})

	main.begin_startup_loading_timeline()
	var reset_pending: bool = await main.wait_for_startup_loading_complete(0.0,true)
	add_result("synthetic_startup_wait_reload_discards_previous_outcome",not reset_pending
		and main.startup_loading_failure_result.is_empty() and main.startup_readiness_domains.is_empty(),
		{"evidenceLevel":"synthetic_contract","afterReset":reset_pending})
	main.startup_readiness_domains["diagnostic_fast_boot"] = {"status":"pending"}
	var diagnostic_pending: bool = await main.wait_for_startup_loading_complete(0.0,true)
	main.startup_readiness_domains["diagnostic_fast_boot"] = {"status":"excluded"}
	var ordinary_diagnostic: bool = await main.wait_for_startup_loading_complete(0.0)
	var explicit_diagnostic: bool = await main.wait_for_startup_loading_complete(0.0,true)
	main.startup_loading_active = true
	var active_diagnostic: bool = await main.wait_for_startup_loading_complete(0.0,true)
	add_result("synthetic_startup_wait_requires_explicit_completed_diagnostic_exclusion",
		not diagnostic_pending and not ordinary_diagnostic and explicit_diagnostic and not active_diagnostic
		and not main.is_physics_processing(),
		{"evidenceLevel":"synthetic_contract","pending":diagnostic_pending,"ordinary":ordinary_diagnostic,
		"explicit":explicit_diagnostic,"active":active_diagnostic,"physicsEnabled":main.is_physics_processing()})

	main.startup_loading_active = false
	main.begin_startup_loading_timeline()
	main.runtime_loading_active = true
	var completion_probe := {"dispatched":false}
	var complete_reload := func() -> void:
		completion_probe.dispatched = true
		main.startup_readiness_domains["gameplay"] = {"status":"ready"}
		main.runtime_loading_active = false
	complete_reload.call_deferred()
	var completed_reload: bool = await main.wait_for_startup_loading_complete(1.0)
	var completion_was_observed: bool = completion_probe.dispatched
	# Drain the controlled callback even if a broken waiter returned prematurely.
	await process_frame
	var terminal_ready: bool = await main.wait_for_startup_loading_complete(0.0)
	add_result("synthetic_startup_wait_resumes_on_current_reload_completion",completed_reload
		and completion_was_observed and terminal_ready,
		{"evidenceLevel":"synthetic_contract","waitResult":completed_reload,
		"completionObservedBeforeReturn":completion_was_observed,"terminalReady":terminal_ready})

	main.shutdown_requested = true
	var shutting_down_ready: bool = await main.wait_for_startup_loading_complete(0.0,true)
	main.shutdown_requested = false
	main.runtime_loading_active = true
	var shutdown_probe := {"dispatched":false}
	var cancel_wait := func() -> void:
		shutdown_probe.dispatched = true
		main.shutdown_requested = true
	cancel_wait.call_deferred()
	var cancelled_wait: bool = await main.wait_for_startup_loading_complete(1.0)
	var shutdown_was_observed: bool = shutdown_probe.dispatched
	await process_frame
	add_result("synthetic_startup_wait_refuses_shutdown_before_and_during_wait",not shutting_down_ready
		and not cancelled_wait and shutdown_was_observed and main.runtime_loading_active,
		{"evidenceLevel":"synthetic_contract","terminalReadyDuringShutdown":shutting_down_ready,
		"pendingWait":cancelled_wait,"shutdownObservedBeforeReturn":shutdown_was_observed})
	main.shutdown_requested = false
	main.runtime_loading_active = false
	root.remove_child(main)
	var detached_ready: bool = await main.wait_for_startup_loading_complete(0.0)
	add_result("synthetic_startup_wait_detached_ready_owner_is_not_success",not detached_ready,
		{"evidenceLevel":"synthetic_contract","detachedReady":detached_ready})
	main.free()

func test_passive_streaming_notification_priority() -> void:
	var hud = preload("res://scripts/GameHud.gd").new()
	var label := Label.new()
	hud.notification_label = label
	hud.show_notification("Preparing nearby world", 1.25, -1)
	var initial_status := label.text == "Preparing nearby world"
	hud.show_notification("Needs Copper Pickaxe for Iron Vein")
	var action_replaced_status := label.text == "Needs Copper Pickaxe for Iron Vein"
	hud.show_notification("Preparing nearby world", 1.25, -1)
	var action_preserved := label.text == "Needs Copper Pickaxe for Iron Vein" and is_equal_approx(hud.notification_time, 3.0)
	# Controlled timer expiry; production decrements this through the HUD frame.
	hud.notification_time = 0.0
	hud.show_notification("Preparing nearby world", 1.25, -1)
	var status_resumed := label.text == "Preparing nearby world"
	add_result("synthetic_passive_streaming_preserves_action_feedback_and_resumes_after_expiry",
		initial_status and action_replaced_status and action_preserved and status_resumed,
		{"evidenceLevel":"synthetic_hud_contract","initialStatus":initial_status,
		"actionReplacedStatus":action_replaced_status,"actionPreserved":action_preserved,"statusResumed":status_resumed})
	label.free()
	hud.free()

func test_loading_completion_requires_all_readiness_domains() -> void:
	var main_source := FileAccess.get_file_as_string("res://scripts/MainCore.gd")
	var tutorial_source := FileAccess.get_file_as_string("res://scripts/TutorialSystem.gd")
	var ready_start := main_source.find("func _ready()")
	var ready_end := main_source.find("\nfunc ",ready_start + 1)
	var ready_source := main_source.substr(ready_start,ready_end-ready_start)
	var staged_entry := ready_source.find("call_deferred(\"_run_startup_boot\")")
	var direct_boot_is_staged := ready_start >= 0 and ready_end > ready_start and staged_entry >= 0 \
		and ready_source.find("startup_loading_active = true") >= 0 \
		and ready_source.find("WorldLoadingOverlayScript.new()") >= 0 \
		and ready_source.find("set_physics_process(false)") < staged_entry \
		and ready_source.find("set_physics_process(false)") >= 0 \
		and not main_source.contains("deferred_startup_boot :=") \
		and not main_source.contains("func start_new_game(") \
		and not ready_source.contains("setup_game_systems()")
	var completion_index := main_source.find("startup_loading_completed.emit()")
	var tutorial_ready_index := main_source.find("if not startup_result_is_ready(tutorial_result):")
	var terrain_ready_index := main_source.find("if not startup_result_is_ready(terrain_result):")
	var navigation_ready_index := main_source.find("if not startup_result_is_ready(navigation_result):")
	var gameplay_ready_index := main_source.find("if not startup_result_is_ready(physics_gate_result):")
	var loading_release_index := main_source.find("startup_loading_active = false", gameplay_ready_index)
	var presentation_index := main_source.find("await wait_for_initial_terrain_presentation()", gameplay_ready_index)
	var presentation_ready_index := main_source.find("if not startup_result_is_ready(presentation_result):",presentation_index)
	var region_index := main_source.find("await wait_for_initial_region_readiness()",presentation_index)
	var region_ready_index := main_source.find("if not startup_result_is_ready(region_result):",region_index)
	var new_game_start := main_source.find("func run_new_game_staged(")
	var shared_completion_start := main_source.find("func complete_runtime_world_loading_staged(")
	var new_game_publication_call := main_source.find("await prepare_runtime_world_publication_staged()", new_game_start)
	var new_game_publication_guard := main_source.find("if not startup_result_is_ready(publication_result):", new_game_publication_call)
	var new_game_completion_call := main_source.find("await complete_runtime_world_loading_staged(", new_game_publication_guard)
	var runtime_load_start := main_source.find("func run_runtime_world_load_staged(")
	var runtime_load_tutorial_guard := main_source.find("if not startup_result_is_ready(tutorial_result):", runtime_load_start)
	var runtime_load_publication_call := main_source.find("await prepare_runtime_world_publication_staged()", runtime_load_tutorial_guard)
	var runtime_load_publication_guard := main_source.find("if not startup_result_is_ready(publication_result):", runtime_load_publication_call)
	var runtime_load_completion_call := main_source.find("await complete_runtime_world_loading_staged(", runtime_load_publication_guard)
	var both_runtime_entries_use_shared_gates := runtime_load_start >= 0 \
		and runtime_load_tutorial_guard > runtime_load_start \
		and runtime_load_publication_call > runtime_load_tutorial_guard \
		and runtime_load_publication_guard > runtime_load_publication_call \
		and runtime_load_completion_call > runtime_load_publication_guard and runtime_load_completion_call < new_game_start \
		and new_game_publication_call > new_game_start and new_game_publication_guard > new_game_publication_call \
		and new_game_completion_call > new_game_publication_guard and new_game_completion_call < shared_completion_start
	var new_game_tutorial_ready := main_source.find("if not startup_result_is_ready(tutorial_result):", new_game_start)
	var new_game_terrain_ready := main_source.find("if not startup_result_is_ready(terrain_result):",new_game_start)
	var new_game_navigation_ready := main_source.find("if not startup_result_is_ready(navigation_result):",new_game_start)
	var new_game_physics_ready := main_source.find("if not startup_result_is_ready(physics_gate_result):",new_game_start)
	var new_game_release := main_source.find("runtime_loading_active = false", shared_completion_start)
	var new_game_presentation := main_source.find("await wait_for_initial_terrain_presentation()", new_game_start)
	var new_game_presentation_ready := main_source.find("if not startup_result_is_ready(presentation_result):",new_game_presentation)
	var new_game_region := main_source.find("await wait_for_initial_region_readiness()",new_game_presentation)
	var new_game_region_ready := main_source.find("if not startup_result_is_ready(region_result):",new_game_region)
	var tutorial_domains_present := tutorial_source.find("ensure_town_manifest_ready_staged") >= 0 \
		and tutorial_source.find("tutorial_manifest_door_readiness") >= 0 \
		and tutorial_source.find("tutorial_npc_registration_readiness") >= 0 \
		and tutorial_source.find("claim_town_population") >= 0 \
		and tutorial_source.find("submit_initial_actor_orders") >= 0
	var passed := direct_boot_is_staged and completion_index >= 0 \
		and tutorial_ready_index >= 0 and tutorial_ready_index < completion_index \
		and terrain_ready_index > tutorial_ready_index and navigation_ready_index > terrain_ready_index \
		and gameplay_ready_index > navigation_ready_index and gameplay_ready_index < completion_index \
		and loading_release_index > gameplay_ready_index and loading_release_index < completion_index \
		and presentation_index > gameplay_ready_index and presentation_index < loading_release_index \
		and presentation_ready_index > presentation_index and region_index > presentation_ready_index \
		and region_ready_index > region_index and region_ready_index < loading_release_index \
		and new_game_start >= 0 and new_game_tutorial_ready > new_game_start \
		and new_game_terrain_ready > new_game_tutorial_ready and new_game_navigation_ready > new_game_terrain_ready \
		and new_game_physics_ready > new_game_navigation_ready and new_game_presentation > new_game_physics_ready \
		and new_game_presentation_ready > new_game_presentation and new_game_region > new_game_presentation_ready \
		and new_game_region_ready > new_game_region and new_game_release > new_game_region_ready \
		and tutorial_domains_present and both_runtime_entries_use_shared_gates
	add_result("loading_completion_is_guarded_by_manifest_door_registration_order_and_physics_readiness", passed, {
		"evidenceLevel":"static_audit",
		"directBootUsesStagedLoading":direct_boot_is_staged,
		"runtimeNewGameAndLoadUseSharedGates":both_runtime_entries_use_shared_gates,
		"completionIndex": completion_index,
		"tutorialReadyIndex": tutorial_ready_index,
		"terrainReadyIndex":terrain_ready_index,
		"navigationReadyIndex":navigation_ready_index,
		"gameplayReadyIndex": gameplay_ready_index,
		"presentationReadyIndex":presentation_ready_index,
		"regionReadyIndex":region_ready_index,
		"loadingReleaseIndex": loading_release_index,
		"newGameTutorialReadyIndex": new_game_tutorial_ready,
		"newGameTerrainReadyIndex":new_game_terrain_ready,
		"newGameNavigationReadyIndex":new_game_navigation_ready,
		"newGamePhysicsReadyIndex":new_game_physics_ready,
		"newGamePresentationReadyIndex":new_game_presentation_ready,
		"newGameRegionReadyIndex":new_game_region_ready,
		"newGameReleaseIndex": new_game_release,
		"tutorialDomainsPresent": tutorial_domains_present
	})

func test_forced_manifest_failure_keeps_gameplay_disabled_and_visible() -> void:
	failure_signal_reason = ""
	completion_signal_count = 0
	var tutorial = TutorialSystemScript.new()
	var fake_main := FakeMain.new()
	root.add_child(fake_main)
	fake_main.add_child(tutorial)
	tutorial.main = fake_main
	tutorial.town = fake_main.town_region(1, 0)
	var failure: Dictionary = await tutorial.ensure_town_manifest_ready_staged(tutorial.tutorial_scenario_requirements())
	var main = MainCoreScript.new()
	var player_body := CharacterBody3D.new()
	player_body.set_physics_process(true)
	main.player = player_body
	var fake_npcs := FakeNpcSystem.new()
	var npc_body := CharacterBody3D.new()
	npc_body.set_physics_process(true)
	fake_npcs.npcs = [{"id": "contract_npc", "body": npc_body}]
	main.npc_system = fake_npcs
	main.startup_loading_active = true
	main.runtime_loading_active = true
	main.set_process(true)
	main.set_process_unhandled_input(true)
	main.set_physics_process(true)
	main.startup_loading_failed.connect(Callable(self, "_on_failure_signal"))
	main.startup_loading_completed.connect(Callable(self, "_on_completion_signal"))

	var menu = TitleMenuScript.new()
	menu.status_label = Label.new()
	menu.loading_overlay = Control.new()
	menu.loading_overlay.visible = true
	menu.new_game_button = Button.new()
	menu.new_game_button.disabled = true
	menu.continue_button = Button.new()
	menu.quit_button = Button.new()
	menu.quit_button.disabled = true
	menu.launching = true
	main.startup_loading_failed.connect(Callable(menu, "_on_game_loading_failed"))

	var previous_save_override := OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE")
	OS.set_environment("VOXEL_SAVE_PATH_OVERRIDE", "user://vox73_missing_manifest_contract_save.json")
	var reason: String = main.apply_startup_loading_failure_state(failure)
	if previous_save_override == "":
		OS.unset_environment("VOXEL_SAVE_PATH_OVERRIDE")
	else:
		OS.set_environment("VOXEL_SAVE_PATH_OVERRIDE", previous_save_override)

	var passed: bool = reason == "required_town_manifest_generation_failed" \
		and fake_main.structure_system.publication_calls == 1 \
		and String(failure.get("status", "")) == "failed" \
		and failure_signal_reason == reason \
		and completion_signal_count == 0 \
		and not main.startup_loading_active \
		and not main.runtime_loading_active \
		and not main.is_processing() \
		and not main.is_processing_unhandled_input() \
		and not main.is_physics_processing() \
		and not player_body.is_physics_processing() \
		and not npc_body.is_physics_processing() \
		and String(main.startup_loading_failure_result.get("status", "")) == "failed" \
		and menu.status_label.text == reason \
		and not menu.loading_overlay.visible \
		and not menu.new_game_button.disabled \
		and not menu.quit_button.disabled
	add_result("forced_missing_manifest_is_visible_and_cannot_enable_gameplay", passed, {
		"reason": reason,
		"manifestPublicationCalls": fake_main.structure_system.publication_calls,
		"manifestFailure": failure,
		"failureSignalReason": failure_signal_reason,
		"completionSignalCount": completion_signal_count,
		"startupActive": main.startup_loading_active,
		"runtimeLoadingActive": main.runtime_loading_active,
		"mainProcess": main.is_processing(),
		"mainPhysics": main.is_physics_processing(),
		"playerPhysics": player_body.is_physics_processing(),
		"npcPhysics": npc_body.is_physics_processing(),
		"visibleMessage": menu.status_label.text,
		"failureResult": main.startup_loading_failure_result
	})

	menu.status_label.free()
	menu.loading_overlay.free()
	menu.new_game_button.free()
	menu.continue_button.free()
	menu.quit_button.free()
	menu.free()
	fake_main.free()
	player_body.free()
	npc_body.free()
	main.free()

func _on_failure_signal(reason: String) -> void:
	failure_signal_reason = reason

func _on_completion_signal() -> void:
	completion_signal_count += 1

func add_result(name: String, passed: bool, details) -> void:
	results.append({
		"name": name,
		"passed": passed,
		"details": TownRuntimeManifestScript.canonical_data(details)
	})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func finish() -> void:
	var failure_count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failure_count += 1
	var report := {
		"schemaVersion": 1,
		"runnerId": "startup_loading_readiness_contract",
		"testId": "vox_73_startup_loading_readiness_contract",
		"finished": true,
		"passed": failure_count == 0,
		"evidenceLevel": "contract",
		"scope": "Synthetic contract coverage for startup/reload observation and cancellation, tutorial startup requirements, missing door/NPC failure, deferred Continue setup, disabled gameplay on failure, and visible menu presentation; static audit of staged startup gates. No live gameplay acceptance is claimed.",
		"resultCount": results.size(),
		"failureCount": failure_count,
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify({
		"runnerId": report.runnerId,
		"passed": report.passed,
		"resultCount": report.resultCount,
		"failureCount": report.failureCount
	}, "  "))
	quit(0 if failure_count == 0 else 1)
