extends SceneTree
## Tiny synthetic geometry, real route diagnostic/resolver. No generation or scenes.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Builder = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")

class Probe extends RefCounted:
	var blueprint
	var target := ""
	var occurrence := 1
	var counts: Dictionary = {}
	var records: Array = []
	var rejected := false
	var after_false := 0
	var rejected_snapshot := PackedByteArray()
	func call_stage(stage: String) -> bool:
		if rejected:
			after_false += 1
			# Deliberately recover to true: only the production latch may stop work.
			return true
		counts[stage]=int(counts.get(stage,0))+1
		var accepted: bool = stage!=target or counts[stage]!=occurrence
		if not records.is_empty() and records.back().stage==stage and records.back().accepted==accepted:
			records.back().count += 1
		else:
			records.append({"stage":stage,"count":1,"accepted":accepted})
		if not accepted:
			rejected=true
			rejected_snapshot=var_to_bytes(blueprint.snapshot())
		return accepted

var checks: Dictionary = {}
var evidence: Dictionary = {}
var report := {"schema":"building-route-diagnostic-cancellation/v1","complete":false,"passed":false,
	"evidenceLevel":"synthetic_small_geometry_real_route_diagnostic_and_physical_resolver",
	"doesNotProve":"No recipe generation, actual Site fixture, publisher, native terrain, navigation integration, headed or gameplay acceptance."}
func _initialize() -> void: call_deferred("_run")
func check(label: String, passed: bool) -> void:
	checks[label]=passed
	if not passed: print("ROUTE CONTRACT FAILURE ",label)

static func add(b, id: String, center: Vector3, size: Vector3, semantic: String, values: Dictionary) -> void:
	b.add_part({"id":id,"kind":"foundation","material":"stone_foundation","position":center,"size":size,
		"collision":true,"semantic":semantic,"recipe":values})

static func fixture(kind: String) -> Dictionary:
	var b = Blueprint.new("synthetic_route_"+kind,17,"stone")
	add(b,"base",Vector3(0,0.5,0),Vector3(24,1,16),"castle_courtyard_foundation",{"physicalIntent":"structural_root"})
	if kind.begins_with("residence"):
		add(b,"second",Vector3(2,0.5,0),Vector3(1,1,1),"castle_route_junction" if kind=="residence_invalid" else "synthetic_foundation",{"physicalIntent":"structural_root"})
		b.set_recipe({"publicationScope":"residence_district"})
		return b.snapshot()
	var transition: bool = kind=="transition"
	var street := {"id":"lane","x":0.0,"z":0.0,"width":3.0,"depth":4.0,"elevation":0.0,
		"allowedTransitionOwnerIds":["step","forecourt"] if transition else ["forecourt"],
		"handoffSeamZ":2.0 if transition else 3.0,"handoffTransitionOwnerId":"forecourt",
		"handoffTransitionSemantic":"castle_keep_palace_entry_forecourt",
		"handoffSourceOwnerId":"step" if transition else "junction",
		"handoffSourceSemantic":"castle_processional_step" if transition else "castle_route_terrace_walkway",
		"transitionOwned":transition}
	b.set_recipe({"foundationHeight":1.0,"castleGrammar":{"courtyardGrid":{"mode":"district_grid","streetRecords":[street]}}})
	if transition:
		add(b,"step",Vector3(0,1.1,0),Vector3(4,0.2,4),"castle_processional_step",{"physicalIntent":"structural_mass","routeTransitionRootPartIds":["base"]})
	else:
		add(b,"roadbed",Vector3(0,1.1,-1),Vector3(4,0.2,4),"castle_route_terrace_walkway",{"physicalIntent":"structural_mass","routeStreetId":"lane","physicalRequiredSupportPartIds":["base"]})
		add(b,"junction",Vector3(0,1.1,2),Vector3(4,0.2,2),"castle_route_junction",{"physicalIntent":"structural_mass","routeIncidentStreetIds":["lane"],"physicalRequiredSupportPartIds":["base"]})
		# Third disjoint route slab makes partition-pair occurrence 2 reachable.
		add(b,"other",Vector3(8,1.1,0),Vector3(2,0.2,2),"castle_route_terrace_walkway",{"physicalIntent":"structural_mass","routeStreetId":"other"})
	add(b,"forecourt",Vector3(0,1.1,3 if transition else 4),Vector3(4,0.2,2),"castle_keep_palace_entry_forecourt",{"physicalIntent":"structural_mass","routeTransitionRootPartIds":["base"]})
	return b.snapshot()

func parity(kind: String) -> Dictionary:
	var frozen := fixture(kind)
	var input_bytes := var_to_bytes(frozen)
	var baseline = Copy.copy_blueprint(frozen)
	var expected: Dictionary = Builder.validate_raised_route_coverage(baseline)
	var post: Dictionary = baseline.snapshot()
	check(kind+"_ordinary_classification",expected.get("passed",false)==(kind!="residence_invalid") and not expected.get("cancelled",false))
	var empty = Copy.copy_blueprint(frozen)
	var empty_result: Dictionary = Builder.validate_raised_route_coverage(empty,Callable())
	check(kind+"_empty_report_exact",var_to_bytes(empty_result)==var_to_bytes(expected))
	check(kind+"_empty_post_snapshot_exact",var_to_bytes(empty.snapshot())==var_to_bytes(post))
	var active = Copy.copy_blueprint(frozen)
	var probe := Probe.new()
	probe.blueprint=active
	var actual: Dictionary = Builder.validate_raised_route_coverage(active,probe.call_stage)
	check(kind+"_true_report_exact",var_to_bytes(actual)==var_to_bytes(expected))
	check(kind+"_true_post_snapshot_exact",var_to_bytes(active.snapshot())==var_to_bytes(post))
	check(kind+"_input_immutable",var_to_bytes(frozen)==input_bytes)
	check(kind+"_true_completed",not probe.rejected and probe.records.front().stage=="route_validation_started" and probe.records.back().stage=="route_validation_completed")
	if kind.begins_with("residence"):
		check(kind+"_residence_applicability",actual.get("applicability")=="not_applicable")
		check(kind+"_residence_skips_resolution",var_to_bytes(post)==input_bytes and not probe.counts.has("physical_resolve_schema"))
	evidence[kind]={"input":frozen,"omittedReport":expected,"omittedPostSnapshot":post,"emptyReport":empty_result,"emptyPostSnapshot":empty.snapshot(),
		"trueReport":actual,"truePostSnapshot":active.snapshot(),"callbackCounts":probe.counts,"callbackRecords":probe.records}
	return probe.counts

func cancellation(kind: String, stage: String, occurrence: int) -> void:
	var label := "%s_%s_%d" % [kind,stage,occurrence]
	var frozen := fixture(kind)
	var input_bytes := var_to_bytes(frozen)
	var b = Copy.copy_blueprint(frozen)
	var probe := Probe.new()
	probe.blueprint=b
	probe.target=stage
	probe.occurrence=occurrence
	var result: Dictionary = Builder.validate_raised_route_coverage(b,probe.call_stage)
	check(label+"_target_rejected",probe.rejected and int(probe.counts.get(stage,0))==occurrence)
	check(label+"_canonical_no_partial_report",var_to_bytes(result)==var_to_bytes({"passed":false,"cancelled":true}))
	check(label+"_no_callback_after_false",probe.after_false==0)
	check(label+"_terminal_record",not probe.records.is_empty() and probe.records.back().stage==stage and probe.records.back().accepted==false)
	check(label+"_no_mutation_after_false",var_to_bytes(b.snapshot())==probe.rejected_snapshot)
	check(label+"_input_immutable",var_to_bytes(frozen)==input_bytes)
	evidence[label]={"report":result,"counts":probe.counts,"records":probe.records,"afterFalse":probe.after_false}
	# b is a disposable proof copy; cancellation may legitimately have resolved
	# earlier parts before rejection. Never reuse it for successful publication.

func _run() -> void:
	var coverage: Dictionary = {}
	for kind in ["ordinary","transition","residence","residence_invalid"]: coverage[kind]=parity(kind)
	var targets := {"ordinary":["route_partition_pair","route_handoff_lane","route_junction_pair"],
		"transition":["route_transition_sample","route_root_support"],"residence":["route_residence_part"]}
	for kind in targets:
		for stage in targets[kind]:
			check(kind+"_covers_"+stage,int(coverage[kind].get(stage,0))>=2)
			for occurrence in [1,2]: cancellation(kind,stage,occurrence)
	for stage in ["route_validation_started","route_validation_completed"]: cancellation("ordinary",stage,1)
	var output := OS.get_environment("BUILDING_ROUTE_DIAGNOSTIC_OUTPUT")
	var binary := FileAccess.open(output+"/evidence.bin",FileAccess.WRITE)
	binary.store_var(evidence,false)
	binary.close()
	report.checks=checks
	report.callbackStageCounts=coverage
	report.parityFixtures=4
	report.cancellationCases=14
	report.complete=true
	report.passed=not checks.values().has(false)
	report.evidenceSha256=FileAccess.get_sha256(output+"/evidence.bin")
	var file := FileAccess.open(output+"/report.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("ROUTE CONTRACT COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size(),"cancellationCases":14}))
	quit(0 if report.passed else 1)
