extends SceneTree

## Synthetic source/demand contract on a real worker. No scene publication,
## navigation-server acknowledgement, route, movement or live acceptance.
const Producer = preload("res://scripts/buildings/BuildingNavigationTileProducer.gd")
const Preparation = preload("res://scripts/buildings/BuildingNavigationTilePreparation.gd")

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var worker := Thread.new()
	if worker.start(_verify)!=OK: quit(2); return
	while worker.is_alive(): await process_frame
	var returned: Variant = worker.wait_to_finish()
	var report: Dictionary = returned if returned is Dictionary else {}
	if not report.get("checks") is Dictionary or not report.get("metrics") is Dictionary:
		report = {"schema":"building-navigation-tile-producer-contract/v1",
			"evidenceLevel":"synthetic_source_and_demand_worker_contract",
			"checks":{"worker_report_shape":false},"metrics":{},"workerThreadId":-1,
			"failure":"Worker did not return a complete contract report; inspect engine errors."}
	report.checks.executed_on_worker = int(report.get("workerThreadId",-1))>0 \
		and int(report.get("workerThreadId",-1)) != OS.get_thread_caller_id()
	report.complete = true
	report.passed = not report.checks.values().has(false)
	var file := FileAccess.open(OS.get_environment("BUILDING_NAVIGATION_PRODUCER_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("NAVIGATION PRODUCER CONTRACT ",JSON.stringify({"passed":report.passed,"checks":report.checks.size()}))
	quit(0 if report.passed else 1)

func _verify() -> Dictionary:
	var checks := {}
	var metrics := {}
	var report := {"schema":"building-navigation-tile-producer-contract/v1",
		"evidenceLevel":"synthetic_source_and_demand_worker_contract","complete":false,"passed":false,
		"checks":checks,"metrics":metrics,"workerThreadId":OS.get_thread_caller_id(),
		"doesNotProve":"No complete frozen Citadel oracle, scene publication, physical receipts, NavigationServer, routing, movement or live gameplay acceptance."}
	var fixture := _fixture()
	var original := _digest(fixture)
	var full: Dictionary = Preparation.compile(fixture.manifest,fixture.furniture,Callable(),fixture.solids)
	checks.full_compilation_ready = full.get("ready",false)
	if not checks.full_compilation_ready: return report
	checks.full_output_schema = full.get("tiles") is Dictionary \
		and full.tiles.values().all(_valid_tile) and full.get("sampleCount") is int \
		and full.get("surfaceCount") is int and full.get("blockedSampleCount") is int \
		and full.get("rejectedFootprintCount") is int and full.get("unresolvedCrossingIds") is Array
	if not checks.full_output_schema:
		metrics.fullFieldNames = full.keys()
		return report
	metrics.full = {"samples":full.sampleCount,"surfaces":full.surfaceCount,"tiles":full.tiles.size(),
		"tileKeys":full.tiles.keys(),"blocked":full.blockedSampleCount,"rejected":full.rejectedFootprintCount}
	checks.input_values_preserved = _digest(fixture)==original and not fixture.manifest.is_read_only()
	checks.analytical_sample_and_surface_counts = full.sampleCount==6 and full.surfaceCount==8 \
		and full.blockedSampleCount==0 and full.rejectedFootprintCount==0
	checks.legacy_first_occurrence_order = full.tiles.keys()==["30,0","31,0","1,0","2,0","10,0","20,0","21,0","40,0","41,0","42,0"]
	checks.unresolved_order_preserved = full.unresolvedCrossingIds==["unresolved-door","unresolved-only"]
	checks.required_fixture_tiles_present = full.tiles.has("30,0") and full.tiles.has("2,0")
	if not checks.required_fixture_tiles_present: return report
	checks.duplicate_collision_ids_retained = full.tiles["30,0"].collisionRecords.size()==2 \
		and full.tiles["30,0"].collisionRecords[0].id==full.tiles["30,0"].collisionRecords[1].id
	var producer := Producer.new()
	checks.initialized_without_dense_work = producer.begin(fixture.manifest,fixture.furniture,Callable(),fixture.solids).status=="ready" \
		and producer.status().sampleCount==0 and producer.status().compiledProducerCount==0
	if not checks.initialized_without_dense_work:
		metrics.initializationState = producer.status()
		return report
	var domain: Dictionary = producer.domain()
	checks.immutable_complete_navigation_domain = Producer._sealed(domain) and domain.get("scope")=="source_navigation_output" \
		and domain.get("producerTileKeys")==["1,0","10,0"] and domain.get("tileKeys") is Array \
		and domain.tileKeys.has("2,0") and domain.tileKeys.has("30,0") \
		and domain.tileKeys.has("21,0") and domain.tileKeys.has("40,0") and not domain.tileKeys.has("99,99")
	if not checks.immutable_complete_navigation_domain:
		metrics.domain = domain
		return report
	checks.unrequested_domain_tile_is_pending = producer.take("2,0").status=="pending"
	producer.request("99,99")
	_drain(producer)
	var empty: Dictionary = producer.take("99,99")
	checks.outside_domain_receipt_ready = empty.get("status")=="ready" and empty.get("outputPresent") is bool \
		and _valid_tile(empty.get("tile"))
	if not checks.outside_domain_receipt_ready:
		metrics.outsideDomainState = producer.status()
		return report
	checks.outside_domain_empty_requires_no_samples = empty.status=="ready" and not empty.outputPresent \
		and empty.tile.surfaces.is_empty() and producer.status().compiledProducerCount==0
	producer.request("2,0")
	producer.request("2,0")
	checks.repeated_request_retains_one_demand = producer.status().pendingRequestCount==1
	_drain(producer)
	var apron: Dictionary = producer.take("2,0")
	checks.apron_receipt_ready = apron.get("status")=="ready" and apron.get("outputPresent") is bool \
		and _valid_tile(apron.get("tile"))
	if not checks.apron_receipt_ready:
		metrics.apronState = producer.status()
		return report
	checks.apron_demand_compiles_only_relevant_original_producer = apron.status=="ready" and apron.outputPresent \
		and producer.status().compiledProducerCount==1 and producer.status().producerCount==2
	checks.apron_uses_link_owned_global_support = apron.tile.surfaces.size()==2 \
		and apron.tile.surfaces.all(func(surface): return surface.supportId=="a_link_only" and is_equal_approx(surface.worldPosition.y,0.24))
	checks.apron_tile_exact_before_unrelated_compile = _digest(apron.tile)==_digest(full.tiles["2,0"])
	checks.immutable_repeated_receipt = Producer._sealed(apron) and is_same(apron,producer.take("2,0"))
	checks.partial_full_export_stays_pending = not producer.full_result().get("ready",false)
	# Mutate the original caller graph after begin. The private input index and
	# already emitted frozen receipt must remain tied to the admitted values.
	fixture.manifest.supports[0].polygon[0] = Vector3(1000,1000,1000)
	var reverse: Array = domain.tileKeys.duplicate()
	reverse.reverse()
	for key: String in reverse: producer.request(key)
	_drain(producer)
	var reversed: Dictionary = producer.full_result()
	checks.reverse_demand_complete = reversed.get("ready",false)
	checks.reverse_demand_exact_typed_order = checks.reverse_demand_complete and _semantic_digest(reversed)==_semantic_digest(full)
	checks.earlier_receipt_unchanged_after_remote_work = _digest(apron.tile)==_digest(full.tiles["2,0"])
	checks.no_apron_or_outside_empty_tiles_in_full_export = checks.reverse_demand_complete and reversed.tiles.keys()==full.tiles.keys()
	metrics.reverse = producer.status()
	var frozen := _fixture()
	Producer._freeze(frozen,Callable())
	var shared := Producer.new()
	shared.begin(frozen.manifest,frozen.furniture,Callable(),frozen.solids)
	checks.sealed_source_values_reused = is_same(shared._manifest,frozen.manifest) and is_same(shared._furniture,frozen.furniture) \
		and is_same(shared._solids,frozen.solids)
	shared.request("2,0")
	shared.advance(0,func(stage): return stage!="publication_navigation_sample")
	checks.cancellation_during_sampling_is_terminal = shared.status().status=="cancelled" \
		and shared.take("2,0").status=="cancelled" and shared.full_result().is_empty() and shared.status().pendingRequestCount==0
	checks.cancelled_graph_retained_for_worker_retirement = not shared._job.is_empty() and not shared._manifest.is_empty()
	checks.cancelled_producer_cannot_accept_new_demand = shared.request("1,0").status=="cancelled" \
		and shared.advance(0).status=="cancelled" and shared.status().completedTileCount==0
	var rejected := _rejected_footprint_fixture()
	var rejected_full: Dictionary = Preparation.compile(rejected,{},Callable())
	checks.rejected_output_schema = rejected_full.get("ready",false) and rejected_full.get("tiles") is Dictionary \
		and rejected_full.tiles.has("0,0") and _valid_tile(rejected_full.tiles["0,0"])
	if not checks.rejected_output_schema:
		var rejected_tiles: Variant = rejected_full.get("tiles",{})
		metrics.rejectedState = {"ready":rejected_full.get("ready",false),
			"tileKeys":rejected_tiles.keys() if rejected_tiles is Dictionary else []}
		return report
	checks.footprint_rejection_preserves_present_empty_tile = rejected_full.get("ready",false) \
		and rejected_full.sampleCount==1 and rejected_full.surfaceCount==0 and rejected_full.rejectedFootprintCount==1 \
		and rejected_full.tiles.keys()==["0,0"] and rejected_full.tiles["0,0"].surfaces.is_empty()
	var rejection_producer := Producer.new()
	rejection_producer.begin(rejected,{},Callable())
	rejection_producer.request("0,0")
	_drain(rejection_producer)
	var rejected_receipt: Dictionary = rejection_producer.take("0,0")
	checks.present_empty_tile_is_distinct_from_outside_domain = rejected_receipt.get("status")=="ready" \
		and rejected_receipt.get("outputPresent",false) and _valid_tile(rejected_receipt.get("tile")) \
		and rejected_receipt.tile.surfaces.is_empty()
	# All producers and heavy graphs leave scope on this worker. The SceneTree
	# receives only small checks/counters, never a second retained source owner.
	return report

static func _drain(producer) -> void:
	var attempts := 0
	while producer.status().pendingRequestCount>0 and producer.status().status=="ready" and attempts<10000:
		producer.advance(1000)
		attempts += 1

static func _support(id: String, low: Vector2, high: Vector2, height: float, keys: Array) -> Dictionary:
	return {"id":id,"sourcePartId":id+"-part","sourceBlueprintId":"synthetic-demand-site",
		"polygon":[Vector3(low.x,height,low.y),Vector3(low.x,height,high.y),Vector3(high.x,height,high.y),Vector3(high.x,height,low.y)],
		"floorNormal":Vector3.UP,"worldPosition":Vector3((low.x+high.x)*0.5,height,(low.y+high.y)*0.5),"tileKeys":keys}

static func _fixture() -> Dictionary:
	# Cell132 spans[42.24,42.56]; its center42.40 belongs to producer1,
	# while its box crosses42.525 into output2. This is a genuine apron.
	var boundary := _support("b_boundary",Vector2(42.24,0),Vector2(42.60,0.64),0,["1,0"])
	# Its broad tile intentionally omits the actual owner tile. The declared
	# link adds it through the original global-support selection contract.
	var linked := _support("a_link_only",Vector2(42.24,0),Vector2(42.60,0.64),0.2,["10,0"])
	var remote := _support("c_remote",Vector2(216.0,0),Vector2(216.64,0.64),0,["10,0"])
	var manifest := {"supports":[linked,boundary,remote],"staticCollision":[],
		"doors":[{"id":"door-only","sourcePartId":"door","ownerTileKey":"20,0","position":Vector3(432,0,0),"sourcePortalReady":true},
			{"id":"unresolved-door","position":Vector3(453.6,0,0),"sourcePortalReady":false}],
		"verticalLinks":[{"id":"link-owned","ownerTileKey":"1,0","startSupportId":"a_link_only","endSupportId":"a_link_only",
			"sourcePartId":"stair","start":Vector3(42.40,0.2,0.16),"end":Vector3(42.40,0.2,0.48),"endpointCertification":{"resolved":true}},
			{"id":"unresolved-only","ownerTileKey":"40,0","endpointCertification":{"resolved":false}}],
		"supportSeamLinks":[{"id":"seam-only","ownerTileKey":"41,0","start":Vector3(886,0,0),"end":Vector3(887,0,0)}],
		"interiorPassageLinks":[{"id":"passage-only","ownerTileKey":"42,0","start":Vector3(907,0,0),"end":Vector3(908,0,0)}]}
	var solid := {"id":"duplicate-solid","sourcePartId":"solid","bounds":AABB(Vector3(648,0,0),Vector3.ONE),"tileKeys":["30,0","30,0"]}
	var furniture := {"staticCollision":[{"id":"furniture-only","bounds":AABB(Vector3(670,0,0),Vector3.ONE),"tileKeys":["31,0"]}]}
	return {"manifest":manifest,"furniture":furniture,"solids":[solid]}

static func _rejected_footprint_fixture() -> Dictionary:
	# The support cell's diagonal misses the blocker by more than clearance,
	# while the final full-rectangle certification catches its left edge.
	var blocker := {"id":"corner-blocker","sourcePartId":"corner","tileKeys":["0,0"],
		"bounds":AABB(Vector3(-0.50,0,0.31),Vector3(0.01,2,0.01)),
		"footprint":[Vector3(-0.50,0,0.31),Vector3(-0.50,0,0.32),Vector3(-0.49,0,0.32),Vector3(-0.49,0,0.31)]}
	return {"supports":[_support("rejected",Vector2.ZERO,Vector2(0.32,0.32),0,["0,0"])],
		"staticCollision":[blocker],"doors":[],"verticalLinks":[],"supportSeamLinks":[],"interiorPassageLinks":[]}

static func _semantic_digest(result: Dictionary) -> String:
	var value: Dictionary = result.duplicate(false)
	value.erase("preparationUsec")
	return _digest(value)

static func _valid_tile(value: Variant) -> bool:
	if not value is Dictionary: return false
	for field: String in ["surfaces","crossingLinks","requiredCrossingIds","unresolvedCrossings","collisionRecords","doors"]:
		if not value.get(field) is Array: return false
	return true

static func _digest(value: Variant) -> String:
	var bytes := var_to_bytes(value)
	bytes.fill(0)
	if bytes.encode_var(0,value,false)!=bytes.size(): return ""
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()
