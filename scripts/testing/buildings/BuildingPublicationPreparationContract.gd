extends SceneTree
## Actual frozen source plus explicit synthetic ownership/cancellation controls.
## No recipe rebuild, parts, gameplay, live streaming or visual acceptance.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const CitadelPlan = preload("res://scripts/world/CitadelPublicationPlan.gd")
const Source = preload("res://scripts/buildings/BuildingPublicationSource.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Assembly = preload("res://scripts/buildings/PavingFootingAssemblyRecipe.gd")
const Spatial = preload("res://scripts/buildings/BuildingSpatialDependencies.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"
const HISTORY := "res://artifacts/citadel-runtime-integration/publication-preflight-02/blueprint-mutation.bin"
const HISTORY_SHA := "c7832e3e27eb55e31f31d2ea3f25447e90d9b31eb2a8a69573fc6d7221c2b1a3"
const HISTORY_REPORT := "res://artifacts/citadel-runtime-integration/publication-preflight-02/report.json"
const BINDING := {"siteId":"atlas-1492:1,-3", "sourceKey":"actual-site-source-05", "generation":7}

class VirtualBlueprint extends "res://scripts/buildings/BuildingBlueprint.gd":
	var calls := 0
	func resolve_physical_contracts() -> void:
		calls += 1
		super.resolve_physical_contracts()

class Authority extends RefCounted:
	var calls := 0
	func validate_physical_integrity() -> Dictionary:
		calls += 1
		return {"passed":false,"syntheticSeparateAuthority":true}

class RejectMasonry extends "res://scripts/buildings/BuildingPartPublisher.gd":
	# Explicit synthetic injection after real paving setup, not live acceptance.
	func prepare_masonry_apertures(_blueprint) -> bool: return false

var checks := {}
var report := {"schema":"building-publication-preparation/v1", "passed":false,
	"evidenceLevel":"actual_frozen_source_and_synthetic_service_contract",
	"doesNotProve":"No recipe generation, owned runtime dispatch, parts, completed masonry, trees, doors, collision, visuals or normal-world acceptance. Remaining scene preparation is not frame-bounded."}

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var worker := Thread.new()
	if worker.start(_prepare)!=OK: quit(2); return
	while worker.is_alive(): await process_frame
	var result: Dictionary = worker.wait_to_finish()
	checks = result.get("checks",{})
	checks.worker_thread = result.get("threadId",OS.get_thread_caller_id()) != OS.get_thread_caller_id()
	if not result.get("ready",false):
		report.failure = result.get("reason", "worker_failed")
		checks.worker_prepared = false
		_finish(); return
	var prepared = result.prepared
	var publisher := Publisher.new()
	var parent := Node3D.new()
	root.add_child(parent)
	var wrong := BINDING.duplicate(); wrong.generation += 1
	checks.stale_generation_rejected = not publisher.begin_prepared_publication(prepared,parent,wrong).ready
	wrong = BINDING.duplicate(); wrong.sourceKey += ":changed"
	checks.stale_source_rejected = not publisher.begin_prepared_publication(prepared,parent,wrong).ready
	wrong = BINDING.duplicate(); wrong.siteId += ":other"
	checks.other_site_rejected = not publisher.begin_prepared_publication(prepared,parent,wrong).ready
	checks.invalid_parent_rejected = not publisher.begin_prepared_publication(prepared,null,BINDING).ready
	checks.authority_substitution_rejected = not publisher.begin_prepared_publication(prepared,parent,BINDING,{"structuralAuthorityBlueprint":null}).ready
	checks.rejections_have_no_scene_effect = parent.get_child_count()==0 and publisher._masonry_preparation==null
	var started := Time.get_ticks_usec()
	var installed: Dictionary = publisher.begin_prepared_publication(prepared,parent,BINDING,{"progressCallback":func(_progress):return true})
	report.mainBeginUsec = Time.get_ticks_usec()-started
	checks.prepared_begin_ready = installed.ready
	checks.begin_publishes_no_parts = parent.get_child_count()==0 and publisher.published_part_count==0
	var active_masonry = publisher._masonry_preparation
	var active_blueprint = publisher._paving_blueprint
	checks.double_consumption_rejected = not publisher.begin_prepared_publication(prepared,parent,BINDING).ready
	checks.stale_does_not_clear_active_publication = not publisher.begin_prepared_publication(result.failurePrepared,parent,wrong).ready \
		and publisher._masonry_preparation==active_masonry and publisher._paving_blueprint==active_blueprint
	report.diagnosticPreparationUsec = publisher.diagnostic_preparation_usec
	report.scenePreparationUsec = publisher.scene_preparation_usec
	report.masonryState = publisher._masonry_preparation.state if publisher._masonry_preparation!=null else "absent"
	report.workerMetrics = result.metrics
	# This is an admission census over the frozen Citadel source.  It does not
	# claim that an eligible group has been published, navigated, or rendered.
	report.actualPacketEligibilityCensus = result.get("actualPacketEligibilityCensus",{})
	# Exact test-only inspection and teardown are outside mainBeginUsec. This
	# synthetic fixture is not a whole-frame or runtime-disposal benchmark.
	if installed.ready:
		checks.transferred_complete_reports = var_to_bytes([publisher.raised_route_coverage,publisher.physical_integrity]) == result.reportBytes
		checks.gate_not_relabeled = not publisher.PHYSICAL_INTEGRITY_REQUIRED_FOR_PUBLICATION
		checks.worker_snapshot_unchanged_by_begin = var_to_bytes(installed.blueprint.snapshot()) == result.snapshotBytes
	var failing := RejectMasonry.new()
	var failure_source := _jointed_failure_source()
	checks.jointed_failure_source_ready = failure_source.get("ready",false)
	var failed: Dictionary = failing.begin_prepared_publication(failure_source.get("prepared"),parent,BINDING,{"progressCallback":func(_progress):return true})
	checks.failed_scene_has_retirement_owner = not failed.ready and failed.has("retirementPayload") \
		and failed.retirementPayload.scenePreparation.pavingBlueprint==failed.retirementPayload.blueprint
	checks.failed_scene_detaches_all_source_state = failing._paving_blueprint==null and failing._paving_source_parts.is_empty() \
		and failing._paving_artifacts.is_empty() and failing._masonry_preparation==null \
		and failing.physical_integrity.is_empty() and failing.raised_route_coverage.is_empty() and failing.paving_treatments.is_empty()
	checks.failed_scene_detaches_callback = not failing.incremental_progress_callback.is_valid() \
		and failed.get("retirementPayload",{}).get("scenePreparation",{}).get("progressCallback",Callable()).is_valid()
	failed.clear()
	failure_source.clear()
	failing.clear_published()
	failing = null
	publisher.clear_published()
	checks.success_clear_releases_callback = not publisher.incremental_progress_callback.is_valid()
	if installed.ready:
		checks.success_clear_preserves_blueprint = var_to_bytes(installed.blueprint.snapshot())==result.snapshotBytes
	parent.free()
	publisher = null
	installed.clear()
	result.clear()
	prepared = null
	await process_frame
	_finish()

static func _prepare() -> Dictionary:
	var c := {}
	if FileAccess.get_sha256(INPUT)!=SHA or FileAccess.get_sha256(HISTORY)!=HISTORY_SHA:
		return {"ready":false,"reason":"historical_fixture_hash"}
	var f := FileAccess.open(INPUT,FileAccess.READ)
	var fixture: Dictionary = f.get_var(false); f.close()
	var input_before := var_to_bytes([fixture.blueprint,fixture.furnishingPlan])
	# Independent explicit legacy sequence, not Preparation.evaluate.
	var old := Source.restore(fixture.blueprint,fixture.furnishingPlan)
	if not old.ready: return {"ready":false,"reason":"legacy_restore"}
	print("PREPARATION CONTRACT legacy_sequence")
	var old_route := Castle.validate_raised_route_coverage(old.blueprint)
	var old_physical: Dictionary = old.blueprint.validate_physical_integrity()
	var old_snapshot := var_to_bytes(old.blueprint.snapshot())
	var old_reports := var_to_bytes([old_route,old_physical])
	var historical_report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(HISTORY_REPORT))
	# Compare complete JSON values in the same representation. Native Vector3
	# values serialize as strings, and parsed JSON numbers are all floats. Raw
	# reserialized text is not a typed/report-content oracle.
	c.historical_full_route_report_json_exact = JSON.parse_string(JSON.stringify(old_route))==historical_report.raisedRouteCoverage
	c.historical_full_physical_report_json_exact = JSON.parse_string(JSON.stringify(old_physical))==historical_report.physicalIntegrity
	f = FileAccess.open(HISTORY,FileAccess.READ)
	var history: Dictionary = f.get_var(false); f.close()
	c.historical_post_resolution_snapshot_typed_exact = old_snapshot==var_to_bytes(history.snapshots.afterBegin)
	history.clear()
	old.clear()
	print("PREPARATION CONTRACT worker_preparation")
	var stages: Array[String] = []
	var previous := [Time.get_ticks_usec()]
	var maximum_gap := [0]
	var prepared := Preparation.prepare_source(fixture.blueprint,fixture.furnishingPlan,BINDING,func(stage):
		var now := Time.get_ticks_usec()
		maximum_gap[0] = maxi(maximum_gap[0],now-previous[0]); previous[0]=now
		if not stages.has(stage): stages.append(stage)
		return true)
	c.actual_prepared = prepared.ready
	if not prepared.ready: return {"ready":false,"checks":c,"reason":prepared.reason}
	# White-box service assertion only: production never reads the opaque holder.
	var payload: Dictionary = prepared.prepared._payload
	c.full_reports_typed_exact = old_reports==var_to_bytes([payload.raisedRouteCoverage,payload.physicalIntegrity])
	c.post_preparation_snapshot_typed_exact = old_snapshot==var_to_bytes(payload.blueprint.snapshot())
	c.immutable_source_unchanged = input_before==var_to_bytes([fixture.blueprint,fixture.furnishingPlan])
	var expected_furniture: Dictionary = fixture.furnishingPlan.duplicate(); expected_furniture.erase("accessReservations")
	c.furniture_exact = var_to_bytes(payload.furnishingPlan.snapshot())==var_to_bytes(expected_furniture)
	c.reservations_exact = payload.furnishingPlan.access_reservations_snapshot()==fixture.furnishingPlan.accessReservations
	c.spatial_all_source_parts_owned = payload.spatialDependencies.parts.size()==payload.blueprint.parts.size()+payload.furnishingPlan.parts.size()
	c.spatial_source_binding_exact = payload.spatialDependencies.binding==BINDING
	c.spatial_containers_read_only = payload.spatialDependencies.parts.is_read_only() and payload.spatialDependencies.navigation.is_read_only()
	_spatial_controls(c)
	var synthetic := _synthetic_controls(c)
	var actual_census := _actual_packet_eligibility_census(fixture,c)
	var cancellation_hits := [0]
	var cancel_started := Time.get_ticks_usec()
	var cancelled := Preparation.prepare_source(fixture.blueprint,fixture.furnishingPlan,BINDING,func(stage):
		if stage=="physical_resolve_support": cancellation_hits[0]+=1
		return cancellation_hits[0]<3)
	c.actual_cancellation_no_holder = cancelled=={"ready":false,"reason":"cancelled"} and cancellation_hits[0]==3
	var cancellation_total := Time.get_ticks_usec()-cancel_started
	c.fixture_hash_unchanged = FileAccess.get_sha256(INPUT)==SHA
	return {"ready":true,"prepared":prepared.prepared,"failurePrepared":synthetic.prepared,"checks":c,"reportBytes":old_reports,"snapshotBytes":old_snapshot,
		"actualPacketEligibilityCensus":actual_census,
		"threadId":OS.get_thread_caller_id(),"metrics":{"maxCallbackGapUsec":maximum_gap[0],"stages":stages,
		"syntheticCancellationStages":synthetic.stageCount,"actualCancellationTotalUsec":cancellation_total,
		"spatialDependencies":payload.spatialDependencies.summary()}}

static func _actual_packet_eligibility_census(fixture: Dictionary, c: Dictionary) -> Dictionary:
	# Prepare a distinct base from deep-frozen copies so the census is bound to
	# the exact admitted source but cannot mutate the fixture used by the legacy
	# comparison above.  This does not invoke a site recipe, scene publisher, or
	# engine navigation API.
	var building: Variant = fixture.get("blueprint")
	var furnishing: Variant = fixture.get("furnishingPlan")
	var profile: Variant = fixture.get("profile")
	if not building is Dictionary or not furnishing is Dictionary or not profile is Dictionary:
		c.actual_packet_eligibility_fixture_shape = false
		c.actual_packet_eligibility_base_ready = false
		c.actual_packet_eligibility_output_valid = false
		return {}
	var frozen_building: Dictionary = building.duplicate(true)
	var frozen_furnishing: Dictionary = furnishing.duplicate(true)
	frozen_building.make_read_only()
	frozen_furnishing.make_read_only()
	c.actual_packet_eligibility_fixture_shape = true
	var prepared := Preparation.prepare_publication_base(frozen_building,frozen_furnishing,BINDING,profile)
	c.actual_packet_eligibility_base_ready = prepared.ready
	if not prepared.ready:
		c.actual_packet_eligibility_output_valid = false
		return {}
	var base = prepared.base
	_publication_plan_controls(c,base)
	var census := Preparation.classify_physical_group_packet_eligibility(base.description.publication_groups,base.building_source,base.furnishing_source)
	var output := {
		"schema":"citadel-physical-group-packet-eligibility-census/v1",
		"fixture":{"path":INPUT,"sha256":SHA},
		"binding":BINDING.duplicate(),
		"sourceId":base.source_id,
		"groups":census.get("groups",{})
	}
	c.actual_packet_eligibility_output_valid = census.ready and _valid_actual_packet_eligibility_census(output,base.description.publication_groups)
	if not c.actual_packet_eligibility_output_valid: return {}
	return output

static func _publication_plan_controls(c: Dictionary, base) -> void:
	var plan = base.publication_plan
	var groups: Dictionary = base.description.publication_groups.groups
	c.publication_plan_bound_and_immutable = plan!=null and plan.matches(BINDING,groups) \
		and plan.order.is_read_only() and plan.dependency_closures.is_read_only() \
		and plan.center_buckets.is_read_only() and plan.bounds_buckets.is_read_only()
	c.publication_plan_timing_free_typed_signature = plan!=null and plan.output_signature.length()==64 \
		and plan.output_signature.is_valid_hex_number(false)
	if plan==null: return
	var replay := CitadelPlan.build(base.description,base.building_source,base.furnishing_source,base.packet_eligibility)
	c.publication_plan_replay_signature_exact = replay.get("ready",false) and replay.outputSignature==plan.output_signature \
		and replay.plan.order==plan.order
	var cancelled := CitadelPlan.build(base.description,base.building_source,base.furnishing_source,base.packet_eligibility,
		func(stage: String): return stage!="publication_plan_group")
	c.publication_plan_cancel_has_no_partial_output = not cancelled.get("ready",false) and cancelled.get("reason")=="cancelled" \
		and not cancelled.has("plan") and plan.matches(BINDING,groups)
	var closure_parity := true
	for index: int in [0,plan.order.size()/2,plan.order.size()-1]:
		var id: String = plan.order[index]
		var direct: Dictionary = base.description._publication_group_closure(id)
		var indexed: Dictionary = plan.dependency_window(id)
		var indexed_ids: Array = indexed.get("groupIds",[]).duplicate(); indexed_ids.sort()
		closure_parity = closure_parity and direct.get("status")=="described" and direct.get("groupIds",[])==indexed_ids
	c.publication_plan_dependency_closure_parity = closure_parity
	var first_bounds: AABB = groups[plan.order[0]].bounds
	var center := first_bounds.get_center()
	var cell := Vector2i(floori(center.x/1.35),floori(center.z/1.35))
	var query := Rect2i(cell-Vector2i.ONE,Vector2i(3,3))
	var direct_query: Dictionary = base.description.physical_group_requirements(query)
	var indexed_query: Dictionary = plan.physical_group_requirements(query)
	var indexed_set: Dictionary = {}
	for id: String in indexed_query.get("groupIds",[]): indexed_set[id]=true
	c.publication_plan_physical_query_conservatively_preserves_authority = direct_query.get("status")=="described" \
		and direct_query.get("groupIds",[]).all(func(id): return indexed_set.has(id)) \
		and int(indexed_query.get("queryCandidateCount",CitadelPlan.MAX_VIEW_CANDIDATES*2+1))<=CitadelPlan.MAX_VIEW_CANDIDATES*2
	var approach := {"origin":center+Vector3(0,2,96),"forward":Vector3(0,0,-1),
		"predictedOrigin":center+Vector3(0,2,64),"horizontalFovDegrees":72.0,"farDistance":180.0}
	var first_rank: Dictionary = plan.ranked_groups(approach,{})
	var side_rank: Dictionary = plan.ranked_groups({"origin":center+Vector3(96,2,0),"forward":Vector3(-1,0,0),
		"predictedOrigin":center+Vector3(64,2,0),"horizontalFovDegrees":72.0,"farDistance":180.0},{})
	var replay_rank: Dictionary = plan.ranked_groups(approach,{})
	c.publication_plan_approach_order_deterministic_and_bounded = var_to_bytes(first_rank)==var_to_bytes(replay_rank) \
		and first_rank.get("status")=="ready" and side_rank.get("status")=="ready" \
		and int(first_rank.get("candidateCount",0))<=CitadelPlan.MAX_VIEW_CANDIDATES \
		and int(side_rank.get("candidateCount",0))<=CitadelPlan.MAX_VIEW_CANDIDATES
	c.publication_plan_semantic_courtyard_anchor_is_immutable = not plan.courtyard_group_ids.is_empty() \
		and not plan.selected_courtyard_group_ids.is_empty() and plan.courtyard_group_ids.is_read_only() \
		and plan.selected_courtyard_group_ids.is_read_only() \
		and plan.courtyard_group_ids.has(plan.selected_courtyard_group_ids[0])
	var completed: Dictionary = {}
	if not first_rank.get("rows",[]).is_empty(): completed[String(first_rank.rows[0].id)]=true
	var after_edit_like_completion: Dictionary = plan.ranked_groups(approach,completed)
	c.publication_plan_completion_filter_is_stable = completed.is_empty() or not after_edit_like_completion.rows.any(
		func(row: Dictionary): return completed.has(String(row.id))) and var_to_bytes(plan.ranked_groups(approach,{}))==var_to_bytes(first_rank)

static func _valid_actual_packet_eligibility_census(output: Dictionary, publication_groups: Dictionary) -> bool:
	if output.size()!=5 or output.get("schema")!="citadel-physical-group-packet-eligibility-census/v1": return false
	var fixture: Variant = output.get("fixture")
	var binding: Variant = output.get("binding")
	var groups: Variant = output.get("groups")
	if not fixture is Dictionary or fixture.size()!=2 or fixture.get("path")!=INPUT or fixture.get("sha256")!=SHA: return false
	if not binding is Dictionary or binding!=BINDING or not Preparation.valid_binding(binding): return false
	if not output.get("sourceId") is String or String(output.sourceId).is_empty() or not groups is Dictionary: return false
	var expected: Variant = publication_groups.get("groups")
	if not expected is Dictionary or groups.keys().size()!=expected.keys().size(): return false
	for id_value in expected.keys():
		var id := String(id_value)
		var entry: Variant = groups.get(id)
		if not entry is Dictionary or entry.size()!=3 or not entry.get("eligible") is bool:
			return false
		var reasons: Variant = entry.get("reasons")
		var families: Variant = entry.get("families")
		if not reasons is Array or not families is Array: return false
		var prior_reason := ""
		for reason_value in reasons:
			if not reason_value is String or String(reason_value).is_empty() or String(reason_value)<=prior_reason: return false
			prior_reason=String(reason_value)
		var prior_family := ""
		for family_value in families:
			if not family_value is String or String(family_value).is_empty() or String(family_value)<=prior_family: return false
			prior_family=String(family_value)
		if bool(entry.eligible)!=reasons.is_empty(): return false
	return true

static func _spatial_controls(c: Dictionary) -> void:
	# Synthetic source closure, not physical support or gameplay acceptance.
	var blueprint := Blueprint.new("synthetic_spatial", 3, "timber")
	blueprint.add_part({"id":"crossing", "kind":"beam", "position":Vector3(0,4,0), "size":Vector3(4,1,2),
		"recipe":{"physicalRequiredSupportPartIds":["remote_root"]}})
	blueprint.add_part({"id":"remote_root", "kind":"beam", "position":Vector3(-90,0,0), "size":Vector3.ONE,
		"recipe":{"physicalRoot":true, "physicalAnchorPartIds":["crossing", "absent"]}})
	var plan := Plan.new("synthetic_furniture",3,blueprint.id)
	var before := var_to_bytes(blueprint.snapshot())
	var packet = Spatial.compile(blueprint,plan,BINDING,Vector3.ZERO,Callable())
	c.spatial_synthetic_compiled = packet != null
	if packet == null: return
	c.spatial_single_owner_cross_boundary = packet.parts["building:crossing"].ownerCell==Vector2i.ZERO \
		and packet.cells[Vector2i(-1,-1)].has("building:crossing") and packet.cells[Vector2i.ZERO].has("building:crossing")
	c.spatial_negative_owner = packet.parts["building:remote_root"].ownerCell==Vector2i(-3,0)
	var demand: Dictionary = packet.requirements(Rect2i(0,0,1,1))
	c.spatial_support_closure_reaches_remote_root = demand.partIds.has("building:remote_root") and demand.terrainRootBounds.size()==1
	c.spatial_cycle_terminates_and_missing_explicit = demand.partIds.size()==3 and demand.missingSourceIds==["building:absent"]
	c.spatial_description_never_acknowledges_publication = demand.status=="described" and not demand.publicationAcknowledged
	c.spatial_nested_containers_read_only = packet.parts["building:crossing"].is_read_only() \
		and packet.parts["building:crossing"].dependencies.is_read_only() and packet.cells[Vector2i.ZERO].is_read_only()
	c.spatial_source_unchanged = before==var_to_bytes(blueprint.snapshot())
	var compact = Spatial.compile_description(blueprint,plan,BINDING,Vector3.ZERO,Callable())
	c.spatial_compact_has_no_dense_samples = compact!=null and compact.navigation_tiles.is_empty() and compact.navigation_tiles.is_read_only()
	if compact!=null:
		c.spatial_compact_same_obligations = var_to_bytes(compact.requirements(Rect2i(0,0,1,1)))==var_to_bytes(demand)
		var dense = compact.compile_navigation(Callable())
		c.spatial_dense_is_separate_immutable_product = dense!=null and dense!=compact \
			and is_same(dense.parts,compact.parts) and is_same(dense.cells,compact.cells) \
			and is_same(dense.navigation,compact.navigation) and is_same(dense.solid_records,compact.solid_records) \
			and compact.navigation_tiles.is_empty()
		if dense!=null:
			var expected: Dictionary = packet.navigation_tiles.duplicate(false); expected.erase("preparationUsec")
			var actual: Dictionary = dense.navigation_tiles.duplicate(false); actual.erase("preparationUsec")
			c.spatial_dense_complete_ordered_values_preserved = var_to_bytes(actual)==var_to_bytes(expected)
	c.spatial_cancel_discards_artifact = Spatial.compile(blueprint,plan,BINDING,Vector3.ZERO,func(stage): return stage!="publication_navigation_manifest")==null
	c.spatial_invalid_query_failed = packet.requirements(Rect2i()).status=="failed"

static func _synthetic_controls(c: Dictionary) -> Dictionary:
	var b := VirtualBlueprint.new("synthetic",3,"timber")
	b.recipe={"castleGrammar":{"courtyardGrid":{"mode":"district_grid","streetRecords":[{"id":"street","width":1.0,"depth":1.0}]}}}
	b.add_part({"id":"floor","kind":"floor","size":Vector3.ONE,"collisionEnabled":true})
	var plan := Plan.new("furniture",3,"synthetic")
	var bs: Dictionary = b.snapshot()
	var fs: Dictionary = plan.snapshot(); fs.accessReservations = []
	var base_building: Dictionary = bs.duplicate(true); base_building.make_read_only()
	var base_furnishing: Dictionary = fs.duplicate(true); base_furnishing.make_read_only()
	var base_result := Preparation.prepare_publication_base(base_building,base_furnishing,BINDING,{"origin":Vector3.ZERO})
	c.packet_base_ready_and_immutable = base_result.ready and base_result.base.matches(BINDING) \
		and base_result.base.description.publication_groups.get("ready",false)
	var scene_source := Preparation.restore_publication_scene_source(base_result.get("base"),BINDING)
	c.packet_scene_source_restores_isolated_resolved_graph = scene_source.ready and scene_source.sourceId==base_result.base.source_id \
		and not is_same(scene_source.blueprint,b) and not is_same(scene_source.blueprint.parts[0],b.parts[0]) \
		and scene_source.blueprint.parts.size()==b.parts.size()
	c.packet_scene_source_stale_binding_rejected = Preparation.restore_publication_scene_source(base_result.get("base"),{"siteId":"other","sourceKey":"other","generation":1})=={"ready":false,"reason":"invalid_publication_base_scene_request"}
	var packet_ids: Array[String] = []
	if base_result.ready and not base_result.base.description.publication_groups.order.is_empty():
		packet_ids.append(String(base_result.base.description.publication_groups.order[0]))
	var packet_stages: Array[String] = []
	var group_packet := Preparation.compile_physical_group_packet(base_result.get("base"),packet_ids,func(stage):
		packet_stages.append(stage)
		return true)
	c.packet_group_reason = String(group_packet.get("reason",""))
	c.packet_group_compiles_from_isolated_source = group_packet.ready and group_packet.packet.matches(base_result.get("base"),packet_ids) \
		and group_packet.packet.building_entries.is_read_only() and group_packet.packet.static_records.is_read_only()
	var navigation_stages: Array[String] = []
	var base_navigation := Preparation.prepare_navigation_source(base_result.get("base"),BINDING,func(stage):
		navigation_stages.append(stage)
		return true)
	c.packet_base_navigation_source_isolated = base_navigation.ready and base_navigation.navigationSource.is_read_only() \
		and base_navigation.navigationSource.get("binding",{})==BINDING and base_navigation.navigationSource.get("producer")!=null \
		and navigation_stages.has("publication_navigation_source_ready") and not navigation_stages.any(func(stage):
			return String(stage).begins_with("publication_source_") or String(stage).begins_with("publication_physical_") \
				or String(stage).begins_with("publication_masonry_") or String(stage).begins_with("publication_paving_") \
				or String(stage).begins_with("publication_roof_"))
	c.packet_base_navigation_stale_binding_rejected = Preparation.prepare_navigation_source(base_result.get("base"),{"siteId":"other","sourceKey":"other","generation":1}) \
		=={"ready":false,"reason":"invalid_publication_base_navigation_request"}
	c.packet_reuses_resolved_base_without_whole_physical_replay = not packet_stages.any(func(stage):
		return String(stage).begins_with("publication_route_") or String(stage).begins_with("publication_physical_") \
			or String(stage).begins_with("publication_history_"))
	c.packet_unknown_group_rejected = Preparation.compile_physical_group_packet(base_result.get("base"),["missing-group"])=={"ready":false,"reason":"unknown_physical_group"}
	_packet_eligibility_census_controls(c)
	# A joint declaration must come from the real footing assembly recipe. The
	# worker packet retains the sealed value artifact, never a hydrated mesh.
	var jointed_base := _jointed_packet_base()
	var jointed_groups: Array[String] = []
	if jointed_base.ready:
		for group_id in jointed_base.base.description.publication_groups.order:
			jointed_groups.append(String(group_id))
	var jointed_packet := Preparation.compile_physical_group_packet(jointed_base.get("base"),jointed_groups)
	var jointed_family: Dictionary = {}
	if jointed_packet.ready:
		for entry in jointed_packet.packet.building_entries.values():
			if entry.families.has("jointed_paving"): jointed_family = entry.families.jointed_paving
	c.packet_jointed_paving_value_artifact_ready = jointed_base.ready and jointed_packet.ready and not jointed_family.is_empty() \
		and jointed_family.is_read_only() and jointed_family.kind=="jointed_paving" and jointed_family.artifact.get("completed",false) \
		and not _contains_object(jointed_family) and jointed_family.artifact.entries.all(func(entry):
			return entry.get("unchanged",true) or entry.get("meshPayload") is Dictionary and entry.meshPayload.is_read_only())
	c.packet_jointed_paving_declaration_digest_exact = not jointed_family.is_empty() \
		and jointed_family.joint.geometryDigest==jointed_family.artifact.geometryDigest \
		and jointed_family.joint.constructionDigest==jointed_family.artifact.constructionDigest \
		and jointed_family.footBindings.size()==jointed_family.joint.footPartIds.size()
	c.packet_mutable_source_rejected = Preparation.prepare_publication_base(bs,fs,BINDING,{"origin":Vector3.ZERO})=={"ready":false,"reason":"mutable_publication_base_source"}
	var evaluated := Preparation.evaluate(b)
	c.legacy_virtual_resolve_twice = evaluated.ready and b.calls==2
	var authority := Authority.new()
	var separate := Preparation.evaluate(b,{"structuralAuthorityBlueprint":authority})
	c.separate_legacy_authority_preserved = separate.ready and separate.physicalIntegrity=={"passed":false,"syntheticSeparateAuthority":true} and authority.calls==1
	var missing := Preparation.evaluate(b,{"structuralAuthorityBlueprint":null})
	c.null_authority_legacy_fallback = missing.ready and missing.physicalIntegrity=={"passed":true,"checkedPartCount":0,"checks":[],"violations":[]}
	var stages: Array[String] = []
	var sample := Preparation.prepare_source(bs,fs,BINDING,func(stage):
		if not stages.has(stage): stages.append(stage)
		return true)
	c.failed_diagnostics_remain_diagnostic = sample.ready and not sample.prepared._payload.physicalIntegrity.passed
	for target in stages:
		var rejected := [false]
		var after_reject := [0]
		var result := Preparation.prepare_source(bs,fs,BINDING,func(stage):
			if rejected[0]: after_reject[0]+=1
			if stage==target: rejected[0]=true
			return not rejected[0])
		c["cancel_"+target] = result=={"ready":false,"reason":"cancelled"} and rejected[0] and after_reject[0]==0
	c.invalid_binding_rejected = Preparation.prepare_source(bs,fs,{})=={"ready":false,"reason":"invalid_publication_binding"}
	var empty_holder := Preparation.PreparedSource.new()
	c.unprepared_holder_empty = empty_holder.take(BINDING).is_empty()
	var mutable_binding := BINDING.duplicate()
	var rebound := Preparation.prepare_source(bs,fs,mutable_binding,func(_stage):
		mutable_binding.generation=99
		mutable_binding.sourceKey="changed"
		return true)
	c.binding_frozen_before_callback = rebound.ready and rebound.prepared.take(mutable_binding).is_empty() \
		and not rebound.prepared.take(BINDING).is_empty()
	return {"stageCount":stages.size(),"prepared":sample.prepared}

static func _packet_eligibility_census_controls(c: Dictionary) -> void:
	var parts: Array = [
		{"id":"normal","kind":"foundation","material":"cobblestone","recipe":{}},
		{"id":"jointed","kind":"foundation","material":"cobblestone","recipe":{"pavingFootingJoints":{"footPartIds":["foot"]}}},
		{"id":"foot","kind":"beam","material":"stone","recipe":{}},
		{"id":"aperture","kind":"wall","material":"stone","recipe":{"masonryApertureSource":"opening"}},
		{"id":"door","kind":"door","material":"timber","recipe":{}},
		{"id":"unused","kind":"lantern","material":"iron","recipe":{}}
	]
	parts.make_read_only()
	var groups := {
		"normal":{"buildingIndices":[0],"furnitureIndices":[],"treeIndices":[],"doorPartIds":[]},
		"jointed":{"buildingIndices":[1,2],"furnitureIndices":[],"treeIndices":[],"doorPartIds":[]},
		"aperture":{"buildingIndices":[3],"furnitureIndices":[],"treeIndices":[],"doorPartIds":[]},
		"door":{"buildingIndices":[4],"furnitureIndices":[],"treeIndices":[],"doorPartIds":["door"]},
		"furniture":{"buildingIndices":[],"furnitureIndices":[0],"treeIndices":[],"doorPartIds":[]},
		"tree":{"buildingIndices":[],"furnitureIndices":[],"treeIndices":[0],"doorPartIds":[]},
		"unsupported":{"buildingIndices":[99],"furnitureIndices":[],"treeIndices":[],"doorPartIds":[]}
	}
	groups.make_read_only()
	var furnishings: Array = [{"id":"packet-chair","roomId":"room","archetype":"chair","material":"timber_board",
		"position":Vector3.ZERO,"rotation":Vector3.ZERO,"occupiedSize":Vector3.ONE,"collision":true,"semantic":"chair","recipe":{}}]
	furnishings.make_read_only()
	var census := Preparation.classify_physical_group_packet_eligibility({"groups":groups,"treeRecords":[{"id":"tree-record"}]},{"parts":parts},{"parts":furnishings})
	c.packet_eligibility_census_ready = census.ready
	c.packet_eligibility_normal_and_jointed = census.ready and census.groups.normal.eligible and census.groups.normal.families==["normal"] \
		and census.groups.jointed.eligible and census.groups.jointed.families==["jointed_paving"]
	# Furnishing, doors, aperture-tagged masonry and valid tree records each have
	# a packet path. Trees still publish and retire through their existing owner;
	# the packet only binds that callback work to the exact source group.
	c.packet_eligibility_packet_capable_and_tree_owned = census.ready and census.groups.furniture.eligible \
		and census.groups.aperture.eligible and census.groups.aperture.reasons.is_empty() \
		and census.groups.door.eligible and census.groups.door.reasons.is_empty() \
		and census.groups.tree.eligible and census.groups.tree.reasons.is_empty() and census.groups.unsupported.reasons==["unsupported"]

func _finish() -> void:
	report.checks=checks
	report.complete=true
	report.passed=not checks.values().has(false)
	var f := FileAccess.open(OS.get_environment("BUILDING_PREPARATION_REPORT"),FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"\t")); f.close()
	print("PREPARATION CONTRACT ",JSON.stringify({"passed":report.passed,"checks":checks.size(),"mainBeginUsec":report.get("mainBeginUsec",0)}))
	quit(0 if report.passed else 1)

static func _contains_object(value: Variant) -> bool:
	if value is Object: return true
	if value is Dictionary:
		for key in value:
			if _contains_object(key) or _contains_object(value[key]): return true
	elif value is Array:
		for item in value:
			if _contains_object(item): return true
	return false

static func _jointed_failure_source() -> Dictionary:
	# Same minimal jointed-paving construction as PavingFootingPublisherContract;
	# resources are created on the main thread in this synthetic failure fixture.
	var b := Blueprint.new("synthetic_paving_publisher",41,"timber")
	b.recipe={"sourceBlueprintId":"synthetic_canonical_history"}
	var finish = b.add_part({"id":"finish","kind":"foundation","material":"cobblestone","collision":false,
		"position":Vector3(0,0.0625,0),"size":Vector3(4,0.125,4),"recipe":{"pavingFamily":"civic_setts"}})
	var foot = b.add_part({"id":"foot","kind":"beam","material":"stone_foundation","collision":true,
		"position":Vector3(0,0.25,0),"size":Vector3(0.25,0.5,0.25)})
	var assembly: Dictionary = Assembly.prepare(b,[finish.id],[foot],0.01)
	if not assembly.ready: return assembly
	finish.recipe.pavingFootingJoints=assembly.joints.finish.duplicate(true)
	var p := Plan.new("furniture",41,b.id)
	var fs: Dictionary = p.snapshot(); fs.accessReservations=[]
	return Preparation.prepare_source(b.snapshot(),fs,BINDING)

static func _jointed_packet_base() -> Dictionary:
	# This value source deliberately follows the production assembly path; a
	# hand-written pavingFootingJoints dictionary would not prove the special
	# packet gate sees a valid jointed-paving declaration.
	var b := Blueprint.new("synthetic_jointed_packet",42,"timber")
	b.recipe={"sourceBlueprintId":"synthetic_jointed_packet_history"}
	var finish = b.add_part({"id":"finish","kind":"foundation","material":"cobblestone","collision":false,
		"position":Vector3(0,0.0625,0),"size":Vector3(4,0.125,4),"recipe":{"pavingFamily":"civic_setts"}})
	var foot = b.add_part({"id":"foot","kind":"beam","material":"stone_foundation","collision":true,
		"position":Vector3(0,0.25,0),"size":Vector3(0.25,0.5,0.25)})
	var assembly: Dictionary = Assembly.prepare(b,[finish.id],[foot],0.01)
	if not assembly.ready: return assembly
	finish.recipe.pavingFootingJoints=assembly.joints.finish.duplicate(true)
	var plan := Plan.new("synthetic_jointed_packet_furniture",42,b.id)
	var building_source: Dictionary = b.snapshot(); building_source.make_read_only()
	var furnishing_source: Dictionary = plan.snapshot(); furnishing_source.accessReservations=[]; furnishing_source.make_read_only()
	return Preparation.prepare_publication_base(building_source,furnishing_source,BINDING,{"origin":Vector3.ZERO})
