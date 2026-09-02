extends SceneTree
## Historical actual source, synthetic empty scene parent. Begin-only service measurement.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Furniture = preload("res://scripts/buildings/FurnishingPart.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"

class Trace extends RefCounted:
	var events: Array = []
	func mark(stage: String) -> void:
		var record := {"stage":stage,"usec":Time.get_ticks_usec(),"threadId":OS.get_thread_caller_id()}
		events.append(record)
		print("PREFLIGHT ",JSON.stringify(record))

class Authority extends RefCounted:
	var blueprint
	var trace: Trace
	var after_route: Dictionary
	var after_physical: Dictionary
	func validate_physical_integrity() -> Dictionary:
		after_route=blueprint.snapshot().duplicate(true)
		trace.mark("physical_started")
		var result: Dictionary = blueprint.validate_physical_integrity()
		trace.mark("physical_completed")
		after_physical=blueprint.snapshot().duplicate(true)
		return result

class History extends "res://scripts/buildings/SurfaceHistoryField.gd":
	var trace: Trace
	func configure(recipe: Dictionary, parts: Array = []) -> void:
		trace.mark("history_started")
		super.configure(recipe,parts)
		trace.mark("history_completed")

class Publisher extends "res://scripts/buildings/BuildingPartPublisher.gd":
	var trace: Trace
	func clear_published() -> void:
		trace.mark("clear_started")
		super.clear_published()
		trace.mark("clear_completed")
	func _prepare_paving_publication(b) -> bool:
		trace.mark("paving_started")
		var result: bool = super._prepare_paving_publication(b)
		trace.mark("paving_completed")
		return result
	func prepare_masonry_apertures(b) -> bool:
		trace.mark("masonry_started")
		var result: bool = super.prepare_masonry_apertures(b)
		trace.mark("masonry_completed")
		return result

var report := {"schema":"citadel-publication-preflight/v1","complete":false,"passed":false,
	"evidenceLevel":"historical_actual_frozen_source_worker_restore_main_thread_begin_synthetic_empty_parent",
	"doesNotProve":"No recipe rebuild, part publication, completed masonry preparation, rendering, collision, runtime activation, door/tree integration or gameplay acceptance."}
var checks: Dictionary = {}
func _initialize() -> void: call_deferred("_run")
func check(label: String, value: bool) -> void:
	checks[label] = value
	if not value: print("PREFLIGHT CHECK FAILED ",label)

static func restore() -> Dictionary:
	var started := Time.get_ticks_usec()
	if FileAccess.get_sha256(INPUT)!=SHA: return {"ready":false,"reason":"fixture_sha"}
	var file := FileAccess.open(INPUT,FileAccess.READ)
	if file==null or file.get_length()>16777216: return {"ready":false,"reason":"fixture_size"}
	var payload: Variant = file.get_var(false)
	if file.get_error()!=OK or file.get_position()!=file.get_length() or not payload is Dictionary or payload.get("status")!="prepared": return {"ready":false,"reason":"fixture_envelope"}
	file.close()
	var loaded := Time.get_ticks_usec()
	var blueprint = Copy.copy_blueprint(payload.blueprint)
	var f: Dictionary = payload.furnishingPlan
	var plan = Plan.new(f.id,f.seed,f.sourceBlueprintId)
	plan.egress_diagnostics=f.egressDiagnostics.duplicate(true)
	plan.protected_access_reservations.assign(f.accessReservations)
	# Preserve represented furniture exactly; add_part applies an admission filter.
	for record in f.parts: plan.parts.append(Furniture.new(record))
	var restored := Time.get_ticks_usec()
	var furniture_snapshot: Dictionary = plan.snapshot()
	furniture_snapshot["accessReservations"]=plan.access_reservations_snapshot()
	return {"ready":true,"blueprint":blueprint,"furnishingPlan":plan,"payload":payload,
		"loadUsec":loaded-started,"restoreUsec":restored-loaded,"threadId":OS.get_thread_caller_id(),
		"blueprintExact":var_to_bytes(blueprint.snapshot())==var_to_bytes(payload.blueprint),
		"furnitureExact":var_to_bytes(furniture_snapshot)==var_to_bytes(f),"keys":payload.keys()}

func _run() -> void:
	var worker := Thread.new()
	check("worker_started",worker.start(restore)==OK)
	if not checks.worker_started: finish(); return
	print("PREFLIGHT worker_restore_started")
	while worker.is_alive(): await process_frame
	var loaded: Dictionary = worker.wait_to_finish()
	check("restore_ready",loaded.get("ready",false))
	if not checks.restore_ready: report.failure=loaded; finish(); return
	check("restore_off_main",loaded.threadId!=OS.get_thread_caller_id())
	check("blueprint_snapshot_exact",loaded.blueprintExact)
	check("furniture_snapshot_and_reservations_exact",loaded.furnitureExact)
	report.fixtureSha256=SHA
	report.topLevelKeys=loaded.keys
	report.loadUsec=loaded.loadUsec
	report.restoreUsec=loaded.restoreUsec
	report.workerThreadId=loaded.threadId
	report.mainThreadId=OS.get_thread_caller_id()
	report.blueprintPartCount=loaded.blueprint.parts.size()
	report.furniturePartCount=loaded.furnishingPlan.parts.size()
	report.furnishingSnapshotKeys=loaded.payload.furnishingPlan.keys()
	save_report()
	if not loaded.blueprintExact or not loaded.furnitureExact: finish(); return
	var parent := Node3D.new()
	root.add_child(parent)
	var trace := Trace.new()
	var publisher := Publisher.new()
	publisher.trace=trace
	var history := History.new()
	history.trace=trace
	publisher.surface_history=history
	# Public structuralAuthorityBlueprint option delegates to the SAME restored
	# blueprint exactly once, without cache warming or substituted validation.
	var authority := Authority.new()
	authority.blueprint=loaded.blueprint
	authority.trace=trace
	var before: Dictionary = loaded.blueprint.snapshot().duplicate(true)
	trace.mark("begin_started")
	var started := Time.get_ticks_usec()
	var ready: bool = publisher.begin_publication(loaded.blueprint,parent,{"structuralAuthorityBlueprint":authority})
	report.beginUsec=Time.get_ticks_usec()-started
	trace.mark("begin_completed")
	report.beginReady=ready
	report.events=trace.events.duplicate(true)
	report.stagesUsec={}
	var timestamps: Dictionary = {}
	for event in report.events: timestamps[event.stage]=event.usec
	for stage in ["clear","physical","history","paving","masonry"]:
		if timestamps.has(stage+"_completed"): report.stagesUsec[stage]=timestamps[stage+"_completed"]-timestamps[stage+"_started"]
	if timestamps.has("physical_started"):
		report.stagesUsec["route_diagnostics_inferred_upper_bound"]=timestamps.physical_started-timestamps.clear_completed
	report.instrumentation="Timed superclass calls; real physical validation delegated once via public structural authority option. Follow-up captures detached snapshots after route and after physical validation; whole begin includes these capture costs and route upper bound includes the first. Not an isolated benchmark."
	report.physicalIntegrity=publisher.physical_integrity.duplicate(true)
	report.raisedRouteCoverage=publisher.raised_route_coverage.duplicate(true)
	report.physicalPublicationGateEnforced=publisher.PHYSICAL_INTEGRITY_REQUIRED_FOR_PUBLICATION
	report.masonryState=publisher._masonry_preparation.state if publisher._masonry_preparation!=null else "not_started"
	report.masonryMetrics=publisher._masonry_preparation.metrics.duplicate(true) if publisher._masonry_preparation!=null else {}
	report.pavingFailure=publisher._paving_failure
	report.publisherReportedPublicationUsec=publisher.publication_usec
	check("begin_returned_ready",ready)
	check("begin_main_thread",report.events.all(func(event):return event.threadId==report.mainThreadId))
	check("begin_publishes_no_parts",publisher.published_part_count==0 and parent.get_child_count()==0)
	var after: Dictionary = loaded.blueprint.snapshot().duplicate(true)
	check("source_blueprint_unchanged",var_to_bytes(after)==var_to_bytes(loaded.payload.blueprint))
	write_mutation_evidence(before,authority.after_route,authority.after_physical,after)
	var furniture_after: Dictionary = loaded.furnishingPlan.snapshot()
	furniture_after["accessReservations"]=loaded.furnishingPlan.access_reservations_snapshot()
	check("furniture_unchanged",var_to_bytes(furniture_after)==var_to_bytes(loaded.payload.furnishingPlan))
	check("fixture_sha_unchanged",FileAccess.get_sha256(INPUT)==SHA)
	check("existing_publication_timer_excludes_begin",publisher.publication_usec==0)
	publisher.clear_published()
	parent.free()
	publisher=null
	authority=null
	history=null
	loaded.clear()
	await process_frame
	finish()

static func classify(path: Array) -> String:
	for token in path:
		if token is String and token.begins_with("physical"): return "physical_facts"
	if path.has("recipe"): return "recipe"
	if path.size()>0 and path[0]=="parts": return "geometry_or_part_identity"
	return "blueprint_metadata_or_rooms"

static func leaf_changes(before: Variant, after: Variant, path: Array, changes: Array, before_present := true, after_present := true) -> void:
	if before_present and after_present and var_to_bytes(before)==var_to_bytes(after): return
	var initial_count := changes.size()
	if (before is Dictionary or not before_present) and (after is Dictionary or not after_present) and (before is Dictionary or after is Dictionary):
		var old: Dictionary = before if before_present else {}
		var current: Dictionary = after if after_present else {}
		for key in old:
			leaf_changes(old[key],current.get(key),path+[key],changes,true,current.has(key))
		for key in current:
			if not old.has(key): leaf_changes(null,current[key],path+[key],changes,false,true)
		if before_present and after_present and var_to_bytes(old.keys())!=var_to_bytes(current.keys()):
			changes.append({"path":path,"kind":"dictionary_key_order_or_membership","classification":classify(path),"beforePresent":true,"afterPresent":true,"before":old.keys(),"after":current.keys(),"beforeType":"Array","afterType":"Array"})
	elif (before is Array or not before_present) and (after is Array or not after_present) and (before is Array or after is Array):
		var old: Array = before if before_present else []
		var current: Array = after if after_present else []
		for i in range(maxi(old.size(),current.size())):
			leaf_changes(old[i] if i<old.size() else null,current[i] if i<current.size() else null,path+[i],changes,i<old.size(),i<current.size())
	else:
		changes.append({"path":path,"kind":"leaf","classification":classify(path),"beforePresent":before_present,"afterPresent":after_present,"beforeType":type_string(typeof(before)),"afterType":type_string(typeof(after)),"before":before,"after":after})
	# Keep exact binary-only differences visible too (typed container metadata,
	# empty insertion/removal). These are never silently treated as equal.
	if changes.size()==initial_count:
		changes.append({"path":path,"kind":"container_encoding_or_empty_presence","classification":classify(path),"beforePresent":before_present,"afterPresent":after_present,"beforeType":type_string(typeof(before)),"afterType":type_string(typeof(after)),"before":before,"after":after})

func write_mutation_evidence(before: Dictionary, route: Dictionary, physical: Dictionary, after: Dictionary) -> void:
	var snapshots := {"beforeBegin":before,"afterRoute":route,"afterPhysical":physical,"afterBegin":after}
	var comparisons: Dictionary = {}
	var summary: Dictionary = {}
	for pair in [["beforeBegin","afterRoute"],["afterRoute","afterPhysical"],["afterPhysical","afterBegin"],["beforeBegin","afterBegin"]]:
		var label: String = pair[0]+"_to_"+pair[1]
		var changes: Array = []
		leaf_changes(snapshots[pair[0]],snapshots[pair[1]],[],changes)
		var classes: Dictionary = {}
		var kinds: Dictionary = {}
		var changed_parts: Dictionary = {}
		for change in changes:
			classes[change.classification]=int(classes.get(change.classification,0))+1
			kinds[change.kind]=int(kinds.get(change.kind,0))+1
			var path: Array = change.path
			if path.size()>1 and path[0]=="parts" and path[1] is int:
				var index: int = path[1]
				change["partId"]=after.parts[index].id if index<after.parts.size() else before.parts[index].id
				changed_parts[change.partId]=true
		comparisons[label]=changes
		summary[label]={"changeRecords":changes.size(),"classes":classes,"kinds":kinds,"changedPartCount":changed_parts.size()}
	var directory := OS.get_environment("CITADEL_PUBLICATION_PREFLIGHT_OUTPUT")
	var binary := FileAccess.open(directory+"/blueprint-mutation.bin",FileAccess.WRITE)
	binary.store_var({"schema":"citadel-blueprint-mutation/v1","fixtureSha256":SHA,"snapshots":snapshots,"comparisons":comparisons},false)
	binary.close()
	var json := FileAccess.open(directory+"/blueprint-mutation.json",FileAccess.WRITE)
	json.store_string(JSON.stringify({"summary":summary,"comparisons":comparisons},"\t"))
	json.close()
	report.mutationSummary=summary
	report.mutationArtifact="blueprint-mutation.bin"
	report.mutationArtifactSha256=FileAccess.get_sha256(directory+"/blueprint-mutation.bin")
	# Independently round-trip the complete typed evidence, not JSON strings.
	var verify := FileAccess.open(directory+"/blueprint-mutation.bin",FileAccess.READ)
	var restored: Variant = verify.get_var(false)
	check("typed_mutation_evidence_roundtrip",verify.get_error()==OK and verify.get_position()==verify.get_length() and var_to_bytes(restored.snapshots)==var_to_bytes(snapshots) and var_to_bytes(restored.comparisons)==var_to_bytes(comparisons))
	verify.close()

func save_report() -> void:
	var file := FileAccess.open(OS.get_environment("CITADEL_PUBLICATION_PREFLIGHT_OUTPUT")+"/report.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
func finish() -> void:
	report.checks=checks
	report.complete=true
	report.passed=not checks.values().has(false)
	save_report()
	print("PREFLIGHT COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size(),"beginUsec":report.get("beginUsec",0),"stagesUsec":report.get("stagesUsec",{})}))
	quit(0 if report.passed else 1)
