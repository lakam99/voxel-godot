extends SceneTree

## Synthetic input/ownership contract only. The real service validates retained
## manifests; no admission, source generation, scene, worker or navigation runs.
const Service = preload("res://scripts/world/CitadelPublicationService.gd")
const Coordinator = preload("res://scripts/world/WorldStreamingCoordinator.gd")
const QUERY := Rect2i(0,0,1,1)
var checks: Dictionary = {}
var metrics: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	checks[label] = passed
	if not passed: print("CITADEL RETENTION MANIFEST FAILURE ",label)

func _consumer(id: int, bounds := QUERY) -> Dictionary:
	var tiles: Dictionary = Service.DemandSet.from_regions([bounds],16,512)
	return {"ownerId":id,"bounds":bounds,"priority":0,
		"admissionKeys":Coordinator.chunks_for_bounds(bounds.grow(32)),
		"navigationTileKeys":Coordinator._string_keys(tiles.keys),"sites":[]}

func _snapshot(service) -> PackedByteArray:
	return var_to_bytes([service._retained_consumers,service._retained_region_bounds,service._demand_revision,
		service._retained_navigation_priorities,service._retained_binding_priorities,service._retained_discovery_priorities])

func _covers(service, point: Vector2i) -> bool:
	for bounds: Rect2i in service._retained_region_bounds:
		if bounds.has_point(point): return true
	return false

func _shutdown(service, label: String) -> void:
	service.request_shutdown()
	var state: Dictionary = service.advance(Rect2i(),false,2500)
	_check(label,state.get("shutdownComplete",false) and not state.get("worker",{}).get("busy",false)
		and service._retained_consumers.is_empty() and service._retained_region_bounds.is_empty())

func _ownership_and_schema() -> void:
	var service = Service.new()
	var request := _consumer(1)
	request.admissionKeys.append(Vector2i(30,30))
	request.admissionKeys.append(Vector2i(30,30))
	request.navigationTileKeys.append_array(["5,5","5,5"])
	var binding := {"siteId":"synthetic-site","sourceKey":"source-one","generation":1}
	request.sites = [{"binding":binding,"groupIds":["floor","roof","floor"]},
		{"binding":{"siteId":"synthetic-site","sourceKey":"source-two","generation":2},"groupIds":["new-floor"]}]
	var admitted: bool = service.set_retained_source_requests([request])
	_check("valid_sparse_manifest_admitted",admitted)
	if not admitted:
		_shutdown(service,"ownership_failed_setup_shutdown")
		return
	_check("discovery_compression_preserves_gap",_covers(service,Vector2i.ZERO)
		and _covers(service,Vector2i(840,840)) and not _covers(service,Vector2i(420,420)))
	_check("duplicate_keys_and_groups_deduplicated",service._retained_consumers[0].admissionKeys.size()==17
		and service._retained_consumers[0].sites[0].groupIds==["floor","roof"]
		and service._retained_consumers[0].navigationTileKeys==["0,0","5,5"])
	_check("same_site_different_binding_keeps_distinct_groups",service._retained_consumers[0].sites.size()==2
		and service._retained_consumers[0].sites[1].binding.generation==2
		and service._retained_consumers[0].sites[1].groupIds==["new-floor"])
	var owned: PackedByteArray = _snapshot(service)
	request.admissionKeys.clear()
	request.navigationTileKeys.clear()
	request.sites[0].groupIds.append("caller-only")
	binding.sourceKey = "caller-mutation"
	_check("caller_aliases_cannot_change_retention",_snapshot(service)==owned)
	var normalized: Array = service._retained_consumers.duplicate(true)
	_check("identical_normalized_manifest_is_revision_noop",service.set_retained_source_requests(normalized)
		and _snapshot(service)==owned)
	var rectangles: Array = service._retained_region_bounds.duplicate()
	var before_revision: int = service._demand_revision
	_check("explicit_bounds_switch_clears_group_pins_even_for_same_geometry",service.set_retained_region_bounds(rectangles)
		and service._retained_consumers.is_empty() and service._retained_region_bounds==rectangles
		and service._demand_revision==before_revision+1 and service._retained_navigation_priorities.is_empty()
		and service._retained_binding_priorities.is_empty() and service._retained_discovery_priorities.is_empty())
	before_revision = service._demand_revision
	_check("identical_explicit_bounds_remain_noop",service.set_retained_region_bounds(rectangles)
		and service._demand_revision==before_revision)
	_check("source_schema_can_reacquire_exact_pins",service.set_retained_source_requests(normalized)
		and service._retained_consumers==normalized and service._demand_revision==before_revision+1)
	metrics["sparseRectangles"] = service._retained_region_bounds.size()
	_shutdown(service,"ownership_schema_shutdown_balanced")

func _invalid_atomic_inputs() -> void:
	var service = Service.new()
	var valid := _consumer(1)
	_check("atomic_fixture_setup",service.set_retained_source_requests([valid]))
	var before: PackedByteArray = _snapshot(service)
	var invalid: Array[Dictionary] = []
	var value := valid.duplicate(true); value.ownerId = 0; invalid.append(value)
	value = valid.duplicate(true); value.priority = 5; invalid.append(value)
	value = valid.duplicate(true); value.bounds = Rect2i(); invalid.append(value)
	value = valid.duplicate(true); value.admissionKeys = []; invalid.append(value)
	value = valid.duplicate(true); value.erase("navigationTileKeys"); invalid.append(value)
	for tile_keys: Array in [[],["1,0"],["00,0"],["+0,0"],["0,0 "] ,["62500,0"],["-62501,0"],["2147483647,0"],[Vector2i.ZERO]]:
		value = valid.duplicate(true); value.navigationTileKeys = tile_keys; invalid.append(value)
	value = valid.duplicate(true); value.admissionKeys.erase(Vector2i.ZERO); invalid.append(value)
	var mixed_keys: Array = []
	mixed_keys.append_array(valid.admissionKeys); mixed_keys.append("0,0")
	value = valid.duplicate(true); value.admissionKeys = mixed_keys; invalid.append(value)
	for key: Vector2i in [Vector2i(-35716,0),Vector2i(35715,0),Vector2i(0,-35716),Vector2i(0,35715),Vector2i(2147483647,0),Vector2i(-2147483648,0)]:
		value = valid.duplicate(true); value.admissionKeys.append(key); invalid.append(value)
	for binding: Dictionary in [{"siteId":"s","sourceKey":"k","generation":0},
		{"siteId":"s","sourceKey":"k","generation":1,"unexpected":true},
		{"siteId":"s","sourceKey":"","generation":1}]:
		value = valid.duplicate(true); value.sites = [{"binding":binding,"groupIds":["g"]}]; invalid.append(value)
	value = valid.duplicate(true)
	value.sites = [{"binding":{"siteId":"s","sourceKey":"k","generation":1},"groupIds":["g"]}]
	value.sites.append(value.sites[0].duplicate(true)); invalid.append(value)
	value = valid.duplicate(true)
	value.sites = [{"binding":{"siteId":"s","sourceKey":"k","generation":1},"groupIds":[""]}]; invalid.append(value)
	var rejected := true
	for index: int in range(invalid.size()):
		var accepted: bool = service.set_retained_source_requests([invalid[index]])
		var unchanged: bool = _snapshot(service)==before
		_check("invalid_manifest_%02d_rejected_atomically" % index,not accepted and unchanged)
		rejected = rejected and not accepted and unchanged
	_check("duplicate_consumer_ids_reject_atomically",not service.set_retained_source_requests([valid,valid.duplicate(true)]) and _snapshot(service)==before)
	metrics["invalidInputs"] = invalid.size()
	metrics["allInvalidInputsRejected"] = rejected
	_shutdown(service,"atomic_input_shutdown_balanced")

func _limits_and_edges() -> void:
	var service = Service.new()
	var requests: Array[Dictionary] = []
	for id: int in range(1,65): requests.append(_consumer(id))
	_check("sixty_four_consumers_share_exact_discovery_union",service.set_retained_source_requests(requests)
		and service._retained_consumers.size()==64)
	var before: PackedByteArray = _snapshot(service)
	requests.append(_consumer(65))
	_check("sixty_fifth_consumer_rejects_without_loss",not service.set_retained_source_requests(requests) and _snapshot(service)==before)
	var full := _consumer(1)
	for x: int in range(240): full.admissionKeys.append(Vector2i(x,100))
	_check("exact_discovery_capacity_accepted",full.admissionKeys.size()==256 and service.set_retained_source_requests([full]))
	before = _snapshot(service)
	var extra := _consumer(2); extra.admissionKeys.append(Vector2i(500,500))
	_check("global_discovery_overflow_rejects_atomically",not service.set_retained_source_requests([full,extra]) and _snapshot(service)==before)
	full.admissionKeys.append(Vector2i(501,500))
	_check("per_consumer_discovery_overflow_rejects_atomically",not service.set_retained_source_requests([full]) and _snapshot(service)==before)
	var negative := _consumer(1,Rect2i(-999968,-999968,1,1))
	var positive := _consumer(2,Rect2i(999967,999967,1,1))
	var edge_ready: bool = service.set_retained_source_requests([negative,positive])
	_check("world_edge_discovery_chunks_admitted_and_clipped",edge_ready
		and _covers(service,Vector2i(-1000000,-1000000)) and _covers(service,Vector2i(999999,999999)))
	var legal := Rect2i(-1000000,-1000000,2000000,2000000)
	var all_legal := edge_ready
	for bounds: Rect2i in service._retained_region_bounds: all_legal = all_legal and legal.encloses(bounds)
	_check("clipped_discovery_never_escapes_world",all_legal and not _covers(service,Vector2i.ZERO))
	_shutdown(service,"limits_edges_shutdown_balanced")

func _group_capacity() -> void:
	var service = Service.new()
	var request := _consumer(1)
	var groups: Array[String] = []
	for index: int in range(15000): groups.append("group-%05d" % index)
	var duplicated: Array[String] = groups.duplicate()
	duplicated.append_array(groups)
	request.sites = [
		{"binding":{"siteId":"s","sourceKey":"old","generation":1},"groupIds":duplicated},
		{"binding":{"siteId":"s","sourceKey":"new","generation":2},"groupIds":groups.duplicate()}]
	var admitted: bool = service.set_retained_source_requests([request])
	_check("aggregate_thirty_thousand_unique_bound_groups_admitted",admitted)
	if not admitted:
		_shutdown(service,"group_capacity_failed_setup_shutdown")
		return
	_check("duplicates_deduplicate_only_within_same_binding",service._retained_consumers[0].sites[0].groupIds.size()==15000
		and service._retained_consumers[0].sites[1].groupIds.size()==15000)
	var before: PackedByteArray = _snapshot(service)
	request.sites[1].groupIds.append("one-over-total")
	_check("aggregate_group_overflow_rejects_atomically",not service.set_retained_source_requests([request])
		and _snapshot(service)==before)
	_shutdown(service,"group_capacity_shutdown_balanced")

func _navigation_priority_contract() -> void:
	var service = Service.new()
	var low := _consumer(1)
	low.priority = 3
	low.navigationTileKeys.append("8,0")
	var high := _consumer(2)
	high.priority = 0
	var entry := {"requested":{},"receipts":{}}
	_check("priority_fixture_retains_requested_intent",service._request_navigation_tile(entry,"0,0"))
	var pending: PackedByteArray = var_to_bytes(entry)
	_check("shared_tile_uses_minimum_owner_priority",service.set_retained_source_requests([low,high])
		and service._navigation_priority("0,0")==0 and service._navigation_priority("8,0")==3
		and service._navigation_priority("9,0")==4)
	high.priority = 4
	_check("priority_demotion_recomputes_shared_minimum",service.set_retained_source_requests([low,high])
		and service._navigation_priority("0,0")==3 and var_to_bytes(entry)==pending)
	_check("release_priority_does_not_cancel_pending_intent",service.set_retained_source_requests([])
		and service._navigation_priority("0,0")==4 and var_to_bytes(entry)==pending)
	var full := _consumer(1)
	full.navigationTileKeys.clear()
	for x: int in range(512): full.navigationTileKeys.append("%d,0" % x)
	_check("exact_navigation_union_capacity_admitted",service.set_retained_source_requests([full])
		and service._retained_navigation_priorities.size()==512)
	var before: PackedByteArray = _snapshot(service)
	var extra := _consumer(2)
	extra.navigationTileKeys.append("512,0")
	_check("global_navigation_overflow_rejects_all_priority_changes",not service.set_retained_source_requests([full,extra]) and _snapshot(service)==before)
	full.navigationTileKeys.append("513,0")
	_check("consumer_navigation_overflow_rejects_atomically",not service.set_retained_source_requests([full]) and _snapshot(service)==before)
	var edge := _consumer(1)
	edge.navigationTileKeys.append_array(["-62500,-62500","62499,62499"])
	_check("navigation_world_edge_tiles_are_valid_without_filling_gap",service.set_retained_source_requests([edge])
		and service._retained_navigation_priorities.size()==3 and service._navigation_priority("1,1")==4)
	var exact := _consumer(1)
	exact.priority = 1
	var binding := {"siteId":"priority-site","sourceKey":"current","generation":1}
	exact.sites = [{"binding":binding,"groupIds":[]}]
	_check("preparation_rank_fixture_admitted",service.set_retained_source_requests([exact]))
	var source := {"binding":binding.duplicate(),"reservationCells":Rect2i(500,500,1,1)}
	_check("preparation_rank_uses_exact_binding",service._preparation_priority(Vector2i.ZERO,source)==1)
	source.binding.sourceKey = "successor"
	_check("preparation_rank_does_not_transfer_old_binding",service._preparation_priority(Vector2i.ZERO,source)==4)
	source.reservationCells = QUERY
	_check("preparation_rank_uses_actual_admission_intersection",service._preparation_priority(Vector2i.ZERO,source)==1)
	_shutdown(service,"navigation_priority_shutdown_balanced")

func _view_intent_is_separate_scheduling_state() -> void:
	var service = Service.new()
	var request := _consumer(1)
	request.sites = [{"binding":{"siteId":"view-site","sourceKey":"view-source","generation":1},
		"groupIds":["floor","door"]}]
	_check("view_fixture_manifest_admitted",service.set_retained_source_requests([request]))
	var demand_revision: int = service._demand_revision
	var view_revision: int = service._view_revision
	var source_state: PackedByteArray = var_to_bytes([
		service._retained_region_bounds,
		service._retained_consumers[0].bounds,
		service._retained_consumers[0].admissionKeys,
		service._retained_consumers[0].navigationTileKeys,
		service._retained_consumers[0].sites,
		service._retained_navigation_priorities,
		service._retained_binding_priorities,
		service._retained_discovery_priorities])
	var raw := {"origin":Vector3(11.2,3.1,-6.7),"forward":Vector3(0.8,0.2,0.2),
		"predictedOrigin":Vector3(26.1,3.0,-2.2),"horizontalFovDegrees":73.0,"farDistance":181.0}
	var normalized: Dictionary = preload("res://scripts/world/GeneratedContentViewPriority.gd").normalize(raw)
	_check("view_update_is_admitted_without_spatial_revision",service.set_retained_view_intents([
		{"ownerId":1,"viewIntent":raw}]) and service._demand_revision==demand_revision
		and service._view_revision==view_revision+1)
	_check("view_update_preserves_source_membership_and_priority_state",var_to_bytes([
		service._retained_region_bounds,
		service._retained_consumers[0].bounds,
		service._retained_consumers[0].admissionKeys,
		service._retained_consumers[0].navigationTileKeys,
		service._retained_consumers[0].sites,
		service._retained_navigation_priorities,
		service._retained_binding_priorities,
		service._retained_discovery_priorities])==source_state)
	_check("view_update_is_normalized_and_privately_owned",service._retained_consumers[0].viewIntent==normalized)
	var after_view_revision: int = service._view_revision
	_check("identical_view_update_is_revision_noop",service.set_retained_view_intents([
		{"ownerId":1,"viewIntent":raw}]) and service._view_revision==after_view_revision
		and service._demand_revision==demand_revision)
	var before_invalid: PackedByteArray = var_to_bytes([service._retained_consumers,service._view_revision,service._demand_revision])
	_check("invalid_view_update_rejects_atomically",not service.set_retained_view_intents([
		{"ownerId":1,"viewIntent":{"origin":Vector3.ZERO}}])
		and var_to_bytes([service._retained_consumers,service._view_revision,service._demand_revision])==before_invalid)
	_shutdown(service,"view_intent_shutdown_balanced")

func _run() -> void:
	_ownership_and_schema()
	_invalid_atomic_inputs()
	_limits_and_edges()
	_group_capacity()
	_navigation_priority_contract()
	_view_intent_is_separate_scheduling_state()
	var report := {"schema":"citadel-retention-manifest-contract/v1","complete":true,
		"passed":not checks.values().has(false),"checks":checks,"metrics":metrics,
		"evidenceLevel":"synthetic_service_input_ownership_contract",
		"doesNotProve":"No source admission/generation, scene publication, NavigationServer, routes, movement, runtime performance or live gameplay acceptance."}
	var file := FileAccess.open(OS.get_environment("CITADEL_RETENTION_MANIFEST_REPORT"),FileAccess.WRITE)
	if file==null:
		push_error("Cannot write citadel retention manifest contract report")
		quit(2)
		return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("CITADEL RETENTION MANIFEST COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size()}))
	quit(0 if report.passed else 1)
