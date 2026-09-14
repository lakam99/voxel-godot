extends SceneTree
## Bounded CPU-only trace for the smallest actual packet-eligible navigation
## closure.  It uses the frozen source and the same compiler as the worker,
## but it neither creates scene Nodes nor touches navigation/routing state.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"
const BINDING := {"siteId":"atlas-1492:1,-3", "sourceKey":"actual-site-source-05", "generation":7}
const GROUP_IDS: Array[String] = [
	"building:castle_compound_foundation_segment_00",
	"building:castle_tower_04_back",
	"building:castle_tower_04_battlement_back_0",
	"building:castle_tower_04_battlement_left_7",
	"building:castle_tower_04_floor",
	"building:castle_tower_04_foundation",
	"building:castle_tower_04_front",
	"building:castle_tower_04_left",
	"building:castle_tower_04_right",
	"building:castle_tower_04_roof_deck"
]
const LIMIT_USEC := 60000000

var output_path := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	output_path = OS.get_environment("CITADEL_PACKET_CLOSURE_PROFILE_REPORT")
	if not output_path.is_absolute_path() or FileAccess.file_exists(output_path):
		quit(2)
		return
	var worker := Thread.new()
	if worker.start(_profile) != OK:
		quit(2)
		return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	report.passed = bool(report.get("complete",false)) and report.get("checks",{}).values().all(func(value): return value == true)
	var file := FileAccess.open(output_path,FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report,"  ",true,true))
	file.flush()
	var saved := file.get_error()==OK
	file.close()
	print("ACTUAL PACKET CLOSURE PROFILE ",JSON.stringify({"passed":report.passed,"terminal":report.get("compile",{}).get("reason","")}))
	quit(0 if saved and report.passed else 1)

static func _profile() -> Dictionary:
	var checks := {"fixture_sha256":FileAccess.get_sha256(INPUT)==SHA}
	var report := {"schema":"citadel-actual-packet-closure-profile/v1","passed":false,"complete":false,"checks":checks,
		"fixture":{"path":INPUT,"sha256":SHA},"binding":BINDING.duplicate(),"groupIds":GROUP_IDS.duplicate(),
		"evidenceLevel":"actual_frozen_source_bounded_packet_compiler_trace",
		"doesNotProve":"No scene publication, physical receipt, navigation artifact, NavigationServer registration, route query, NPC movement, headed runtime, or performance acceptance.",
		"limitUsec":LIMIT_USEC}
	if not checks.fixture_sha256:
		report.failure="fixture_sha256"
		return report
	var file := FileAccess.open(INPUT,FileAccess.READ)
	var fixture_value: Variant = file.get_var(false) if file!=null else null
	if file!=null: file.close()
	checks.fixture_shape=fixture_value is Dictionary and fixture_value.get("blueprint") is Dictionary and fixture_value.get("furnishingPlan") is Dictionary and fixture_value.get("profile") is Dictionary
	if not checks.fixture_shape:
		report.failure="fixture_shape"
		return report
	var fixture: Dictionary = fixture_value
	var building: Dictionary = fixture.blueprint.duplicate(true)
	var furnishing: Dictionary = fixture.furnishingPlan.duplicate(true)
	building.make_read_only(); furnishing.make_read_only()
	var base_started := Time.get_ticks_usec()
	var base_result := Preparation.prepare_publication_base(building,furnishing,BINDING,fixture.profile)
	var base_usec := Time.get_ticks_usec()-base_started
	checks.publication_base_ready=base_result.get("ready",false)
	if not checks.publication_base_ready:
		report.failure=base_result.get("reason","publication_base_failed")
		report.baseUsec=base_usec
		return report
	var base = base_result.base
	checks.base_binding_exact=base.matches(BINDING)
	var closure: Dictionary = base.description.physical_group_requirements(Rect2i(Vector2i(198,-337)*int(base.description.NAV_TILE_CELLS),Vector2i.ONE*int(base.description.NAV_TILE_CELLS)))
	checks.exact_tile_closure=closure.get("status")=="described" and closure.get("groupIds",[])==GROUP_IDS
	if not checks.base_binding_exact or not checks.exact_tile_closure:
		report.failure="base_or_closure_invalid"
		report.baseUsec=base_usec
		return report
	var timeline: Array[Dictionary] = []
	var counts := {}
	var max_gap := {"usec":0,"fromStage":"","toStage":""}
	var started := Time.get_ticks_usec()
	var last_usec := started
	var last_stage := ""
	var continuation := func(stage: String) -> bool:
		var now := Time.get_ticks_usec()
		var elapsed := now-started
		var gap := now-last_usec
		if gap>int(max_gap.usec): max_gap={"usec":gap,"fromStage":last_stage,"toStage":stage}
		counts[stage]=int(counts.get(stage,0))+1
		if timeline.is_empty() or timeline.back().stage!=stage:
			timeline.append({"stage":stage,"firstUsec":elapsed,"countAtTransition":counts[stage]})
		last_usec=now; last_stage=stage
		return elapsed<LIMIT_USEC
	var compile_started := Time.get_ticks_usec()
	var compiled := Preparation.compile_physical_group_packet(base,GROUP_IDS,continuation)
	var compile_usec := Time.get_ticks_usec()-compile_started
	checks.compiler_returned=compiled is Dictionary
	checks.bounded_terminal=compiled.get("ready",false) or compiled.get("reason","")=="cancelled"
	report.baseUsec=base_usec
	report.compile={"ready":compiled.get("ready",false),"reason":compiled.get("reason",""),"elapsedUsec":compile_usec,
		"lastStage":last_stage,"callbackCounts":counts,"transitions":timeline,"maxCallbackGap":max_gap,
		"packetPreparationUsec":compiled.packet.preparation_usec if compiled.get("packet")!=null else 0}
	report.complete=checks.values().all(func(value): return value == true)
	return report
