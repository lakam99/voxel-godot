extends SceneTree
## Read-only inventory of the actual frozen Citadel navigation-output domain.
## It maps the same per-tile physical-group closure queried by a scene job
## before a navigation artifact can be acknowledged.  It does not drain dense
## tiles, publish a scene, register NavigationServer data, or run routing.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"
const BINDING := {"siteId":"atlas-1492:1,-3", "sourceKey":"actual-site-source-05", "generation":7}
const SUPPORTED_FAMILIES := ["jointed_paving","normal"]

var output_path := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	output_path = OS.get_environment("CITADEL_TILE_PACKET_CLOSURE_REPORT")
	if not output_path.is_absolute_path() or FileAccess.file_exists(output_path):
		quit(2)
		return
	var worker := Thread.new()
	if worker.start(_audit) != OK:
		quit(2)
		return
	while worker.is_alive():
		await process_frame
	var report: Dictionary = worker.wait_to_finish()
	report["workerThreadId"] = report.get("workerThreadId", -1)
	report["workerThread"] = report.workerThreadId != OS.get_thread_caller_id()
	report["passed"] = bool(report.get("complete",false)) and report.get("checks",{}).values().all(func(value): return value == true)
	var file := FileAccess.open(output_path,FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report,"  ",true,true))
	file.flush()
	var saved := file.get_error()==OK
	file.close()
	print("ACTUAL NAVIGATION TILE PACKET CLOSURE ",JSON.stringify({"passed":report.passed,"counts":report.get("counts",{})}))
	quit(0 if saved and report.passed else 1)

static func _audit() -> Dictionary:
	var checks := {"fixture_sha256":FileAccess.get_sha256(INPUT)==SHA}
	var report := {
		"schema":"citadel-actual-navigation-tile-packet-closure-audit/v1",
		"passed":false,"complete":false,"checks":checks,
		"fixture":{"path":INPUT,"sha256":SHA},"binding":BINDING.duplicate(),
		"evidenceLevel":"actual_frozen_source_compact_navigation_domain_and_packet_eligibility_audit",
		"doesNotProve":"No recipe generation, dense tile drain, scene publication, collision acknowledgement, NavigationServer registration, route query, NPC movement, gameplay, or runtime performance acceptance.",
		"closureSemantics":"Each row calls BuildingSpatialDependencies.physical_group_requirements on the exact 32-cell navigation output bounds used by BuildingScenePublicationJob before a tile receipt can be acknowledged."
	}
	if not checks.fixture_sha256:
		report.failure="fixture_sha256"
		return report
	var file := FileAccess.open(INPUT,FileAccess.READ)
	var fixture_value: Variant = file.get_var(false) if file!=null else null
	if file!=null: file.close()
	checks.fixture_shape = fixture_value is Dictionary and fixture_value.get("blueprint") is Dictionary \
		and fixture_value.get("furnishingPlan") is Dictionary and fixture_value.get("profile") is Dictionary
	if not checks.fixture_shape:
		report.failure="fixture_shape"
		return report
	var fixture: Dictionary = fixture_value
	var building: Dictionary = fixture.blueprint.duplicate(true)
	var furnishing: Dictionary = fixture.furnishingPlan.duplicate(true)
	building.make_read_only()
	furnishing.make_read_only()
	var base_result := Preparation.prepare_publication_base(building,furnishing,BINDING,fixture.profile)
	checks.publication_base_ready = base_result.get("ready",false)
	if not checks.publication_base_ready:
		report.failure=base_result.get("reason","publication_base_failed")
		return report
	var base = base_result.base
	checks.base_binding_exact = base.matches(BINDING)
	var census := Preparation.classify_physical_group_packet_eligibility(base.description.publication_groups,base.building_source,base.furnishing_source)
	checks.packet_census_ready = census.get("ready",false)
	var navigation_source := Preparation.prepare_navigation_source(base,BINDING)
	checks.navigation_source_ready = navigation_source.get("ready",false)
	if not checks.base_binding_exact or not checks.packet_census_ready or not checks.navigation_source_ready:
		report.failure="base_or_navigation_source_invalid"
		return report
	var domain: Dictionary = navigation_source.navigationSource.get("domain",{})
	var keys_value: Variant = domain.get("tileKeys")
	checks.domain_complete = domain.get("status")=="complete" and domain.get("scope")=="source_navigation_output" and keys_value is Array and not keys_value.is_empty()
	if not checks.domain_complete:
		report.failure="navigation_domain_invalid"
		return report
	var keys: Array = keys_value.duplicate()
	keys.sort()
	var unique_keys := {}
	for key_value in keys: unique_keys[String(key_value)] = true
	checks.domain_canonical = keys==keys_value and keys.size()==unique_keys.size()
	if not checks.domain_canonical:
		report.failure="navigation_domain_noncanonical"
		return report
	var description = base.description
	var tile_cells: int = int(description.NAV_TILE_CELLS)
	checks.navigation_tile_cell_size = tile_cells>0
	if not checks.navigation_tile_cell_size:
		report.failure="navigation_tile_cell_size"
		return report
	var tiles: Array[Dictionary] = []
	var closure_histogram := {}
	var blocker_tile_counts := {"aperture":0,"door":0,"furniture":0,"tree":0,"unsupported":0}
	var eligible_nonempty := 0
	var eligible_with_supported_family := 0
	var strict_family_complete := 0
	var empty_closures := 0
	var all_described := true
	for key_value in keys:
		var key := String(key_value)
		var coordinates := key.split(",")
		if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int():
			all_described=false
			continue
		var tile := Vector2i(int(coordinates[0]),int(coordinates[1]))
		var closure: Dictionary = description.physical_group_requirements(Rect2i(tile*tile_cells,Vector2i.ONE*tile_cells))
		if closure.get("status")!="described":
			all_described=false
			tiles.append({"tileKey":key,"status":closure.get("status",""),"reason":closure.get("reason","")})
			continue
		var ids: Array = closure.get("groupIds",[]).duplicate()
		ids.sort()
		var blockers := {}
		var families := {}
		var all_eligible := true
		var every_group_has_supported_family := not ids.is_empty()
		for id_value in ids:
			var id := String(id_value)
			var entry: Dictionary = census.groups.get(id,{})
			if not entry.get("eligible",false):
				all_eligible=false
				for reason_value in entry.get("reasons",[]):
					var reason := String(reason_value)
					blockers[reason]=int(blockers.get(reason,0))+1
			for family_value in entry.get("families",[]):
				var family := String(family_value)
				families[family]=int(families.get(family,0))+1
			var has_supported := false
			for family: String in SUPPORTED_FAMILIES:
				if entry.get("families",[]).has(family): has_supported=true
			if not has_supported: every_group_has_supported_family=false
		for reason: String in blocker_tile_counts:
			if blockers.has(reason): blocker_tile_counts[reason]+=1
		var size := ids.size()
		closure_histogram[str(size)]=int(closure_histogram.get(str(size),0))+1
		if size==0: empty_closures+=1
		if size>0 and all_eligible: eligible_nonempty+=1
		var has_supported_family := false
		for family: String in SUPPORTED_FAMILIES:
			if int(families.get(family,0))>0: has_supported_family=true
		if size>0 and all_eligible and has_supported_family: eligible_with_supported_family+=1
		if all_eligible and every_group_has_supported_family: strict_family_complete+=1
		tiles.append({"tileKey":key,"status":"described","closureSize":size,"groupIds":ids,
			"allGroupsPacketEligible":all_eligible,"blockerGroupCounts":blockers,"familyGroupCounts":families,
			"hasSupportedPacketFamily":has_supported_family,"allGroupsHaveSupportedPacketFamily":every_group_has_supported_family,
			"packetAcknowledgementCandidate":size>0 and all_eligible and has_supported_family})
	checks.all_tile_closures_described = all_described and tiles.size()==keys.size()
	checks.census_covers_every_closure_group = all_described and tiles.all(func(row):
		if row.get("status")!="described": return false
		for id_value in row.groupIds:
			if not census.groups.has(String(id_value)): return false
		return true)
	# Compile only the 16 fully packet-eligible nonempty closures through the
	# base-derived producer. This stays below scene publication and records the
	# actual source output needed to choose a nonempty-region acknowledgement
	# candidate; it does not infer surfaces from packet family classification.
	var candidates: Array[Dictionary] = []
	for row: Dictionary in tiles:
		if bool(row.get("packetAcknowledgementCandidate",false)): candidates.append(row)
	candidates.sort_custom(func(a: Dictionary,b: Dictionary) -> bool:
		var a_size := int(a.get("closureSize",0)); var b_size := int(b.get("closureSize",0))
		return a_size < b_size if a_size != b_size else String(a.get("tileKey","")) < String(b.get("tileKey","")))
	var producer = navigation_source.navigationSource.producer
	var producer_outputs := []
	var output_terminal := true
	for row: Dictionary in candidates:
		var key := String(row.tileKey)
		producer.request(key)
		var deadline := Time.get_ticks_msec()+60000
		var receipt: Dictionary = producer.take(key)
		while receipt.get("status") == "pending" and Time.get_ticks_msec()<deadline:
			producer.advance(4000)
			receipt=producer.take(key)
		var tile_output: Dictionary = receipt.get("tile",{}) if receipt.get("tile",{}) is Dictionary else {}
		var facts := {"status":receipt.get("status",""),"reason":receipt.get("reason",""),
			"outputPresent":bool(receipt.get("outputPresent",false)),"surfaceCount":(tile_output.get("surfaces",[]) as Array).size(),
			"collisionRecordCount":(tile_output.get("collisionRecords",[]) as Array).size(),
			"crossingLinkCount":(tile_output.get("crossingLinks",[]) as Array).size(),"doorCount":(tile_output.get("doors",[]) as Array).size(),
			"unresolvedCrossingCount":(tile_output.get("unresolvedCrossings",[]) as Array).size()}
		row["producerOutput"]=facts
		producer_outputs.append({"tileKey":key,"closureSize":row.closureSize,"groupIds":row.groupIds,
			"familyGroupCounts":row.familyGroupCounts,"output":facts})
		if facts.status!="ready": output_terminal=false
	checks.packet_candidate_outputs_terminal = output_terminal and producer_outputs.size()==eligible_nonempty
	var smallest_nonempty := {}
	for output: Dictionary in producer_outputs:
		if int(output.output.surfaceCount)<=0: continue
		if smallest_nonempty.is_empty() or int(output.closureSize)<int(smallest_nonempty.closureSize) \
				or (int(output.closureSize)==int(smallest_nonempty.closureSize) and String(output.tileKey)<String(smallest_nonempty.tileKey)):
			smallest_nonempty=output
	report.sourceId=base.source_id
	report.navigationDomain={"tileCount":keys.size(),"tileKeys":keys,"producerTileKeys":domain.get("producerTileKeys",[])}
	report.counts={"tiles":keys.size(),"emptyClosures":empty_closures,"fullyPacketEligibleNonempty":eligible_nonempty,
		"eligibleWithSupportedPacketFamily":eligible_with_supported_family,"strictFamilyComplete":strict_family_complete,
		"blockedTileCountsByReason":blocker_tile_counts,"closureSizeDistribution":closure_histogram}
	report.tiles=tiles
	report.packetCandidateOutputs=producer_outputs
	report.smallestNonemptyWalkableCandidate=smallest_nonempty
	report.complete=checks.values().all(func(value): return value == true)
	return report
