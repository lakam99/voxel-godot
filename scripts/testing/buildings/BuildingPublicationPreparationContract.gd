extends SceneTree
## Actual frozen source plus explicit synthetic ownership/cancellation controls.
## No recipe rebuild, parts, gameplay, live streaming or visual acceptance.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
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
	var cancellation_hits := [0]
	var cancel_started := Time.get_ticks_usec()
	var cancelled := Preparation.prepare_source(fixture.blueprint,fixture.furnishingPlan,BINDING,func(stage):
		if stage=="physical_resolve_support": cancellation_hits[0]+=1
		return cancellation_hits[0]<3)
	c.actual_cancellation_no_holder = cancelled=={"ready":false,"reason":"cancelled"} and cancellation_hits[0]==3
	var cancellation_total := Time.get_ticks_usec()-cancel_started
	c.fixture_hash_unchanged = FileAccess.get_sha256(INPUT)==SHA
	return {"ready":true,"prepared":prepared.prepared,"failurePrepared":synthetic.prepared,"checks":c,"reportBytes":old_reports,"snapshotBytes":old_snapshot,
		"threadId":OS.get_thread_caller_id(),"metrics":{"maxCallbackGapUsec":maximum_gap[0],"stages":stages,
		"syntheticCancellationStages":synthetic.stageCount,"actualCancellationTotalUsec":cancellation_total,
		"spatialDependencies":payload.spatialDependencies.summary()}}

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

func _finish() -> void:
	report.checks=checks
	report.complete=true
	report.passed=not checks.values().has(false)
	var f := FileAccess.open(OS.get_environment("BUILDING_PREPARATION_REPORT"),FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"\t")); f.close()
	print("PREPARATION CONTRACT ",JSON.stringify({"passed":report.passed,"checks":checks.size(),"mainBeginUsec":report.get("mainBeginUsec",0)}))
	quit(0 if report.passed else 1)

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
