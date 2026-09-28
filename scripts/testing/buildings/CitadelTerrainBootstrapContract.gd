extends SceneTree
## Synthetic orchestration around real MainCore methods; no scene/game boot.
const Readiness = preload("res://scripts/world/StartupReadinessResult.gd")

class RuntimeStub extends RefCounted:
	var authority_ready := true
	var configured_seed := "atlas-1492"
	var current := true
	var reset_fails := false
	var events: Array = []
	var received_keys: Array = []
	var admission_result := Readiness.failed("synthetic_site_admission_terminal",{},[],{"fixture":"bootstrap_order"})
	func generation_context_current() -> bool:
		events.append("current_check"); return current
	func reset_for_current_seed_staged() -> Dictionary:
		events.append("reset_started")
		await Engine.get_main_loop().process_frame
		events.append("reset_finished")
		if reset_fails: return Readiness.failed("synthetic_reset_failed")
		current=true; authority_ready=true; configured_seed="atlas-1492"
		return Readiness.ready({}, {"syntheticReset":true})
	func wait_for_site_admission(keys: Array) -> Dictionary:
		events.append("site_admission")
		received_keys=keys.duplicate()
		return admission_result

class BootstrapFixture extends "res://scripts/MainCore.gd":
	var voxel_terrain_runtime
	var events: Array = []
	var ensure_succeeds := true
	var ready_called := false
	var chunk_load_calls := 0
	func _ready() -> void: ready_called=true # Never call the gameplay _ready.
	func ensure_voxel_terrain_authority() -> bool:
		events.append("ensure_authority")
		if not ensure_succeeds: return false
		voxel_terrain_runtime=RuntimeStub.new()
		voxel_terrain_runtime.events=events
		voxel_terrain_runtime.configured_seed=seed_text
		return true
	func initial_gameplay_chunk_keys(_urgent_radius := 1) -> Array[Vector2i]:
		events.append("required_keys")
		return [Vector2i(3,-2),Vector2i(4,-2)]
	func queue_chunk_load(_key: Vector2i) -> void:
		chunk_load_calls+=1; events.append("unexpected_chunk_load")

var checks: Dictionary = {}
var cases: Dictionary = {}
func _initialize() -> void: call_deferred("_run")
func check(label: String, passed: bool) -> void:
	checks[label]=passed
	if not passed: print("CONTRACT FAILURE ",label)
func _run() -> void:
	for mode: String in ["null_initialization","initialization_failure","stale_reset","stale_reset_failure"]:
		var fixture := BootstrapFixture.new()
		fixture.player=CharacterBody3D.new()
		fixture.player.position=Vector3(5,0,5)
		fixture.seed_text="atlas-1492"
		if mode=="initialization_failure": fixture.ensure_succeeds=false
		if mode.begins_with("stale"):
			var stub := RuntimeStub.new(); stub.events=fixture.events
			stub.current=false; stub.authority_ready=false; stub.configured_seed="old-seed"
			stub.reset_fails=mode=="stale_reset_failure"
			fixture.voxel_terrain_runtime=stub
		var started := Time.get_ticks_usec()
		# These two orchestration methods are inherited unchanged. The override
		# seams replace only runtime dependencies and the required chunk fixture.
		var result: Dictionary = await fixture.bootstrap_initial_chunks_staged(1)
		var expected_events: Array = ["required_keys","ensure_authority","site_admission"]
		var expected_reason := "synthetic_site_admission_terminal"
		if mode=="initialization_failure":
			expected_events=["required_keys","ensure_authority"]
			expected_reason="voxel_terrain_authority_initialization_failed"
		elif mode.begins_with("stale"):
			expected_events=["required_keys","current_check","reset_started","reset_finished"]
			if mode=="stale_reset": expected_events.append("site_admission")
			else: expected_reason="synthetic_reset_failed"
		check(mode+"_exact_order",fixture.events==expected_events)
		check(mode+"_terminal_reason",result.status=="failed" and result.reason==expected_reason and not result.ok)
		check(mode+"_valid_readiness_envelope",Readiness.validate(result).ok)
		check(mode+"_no_chunk_publication",fixture.chunk_load_calls==0 and fixture.chunks.is_empty())
		check(mode+"_no_scene_boot",not fixture.is_inside_tree() and not fixture.ready_called and not fixture.player.is_inside_tree())
		if mode in ["null_initialization","stale_reset"]:
			check(mode+"_admission_result_exact",var_to_bytes(result)==var_to_bytes(fixture.voxel_terrain_runtime.admission_result))
			check(mode+"_exact_required_keys",fixture.voxel_terrain_runtime.received_keys==[Vector2i(3,-2),Vector2i(4,-2)])
			check(mode+"_authority_ready_at_return",fixture.voxel_terrain_runtime.authority_ready and fixture.voxel_terrain_runtime.configured_seed==fixture.seed_text)
		else:
			check(mode+"_no_admission",not fixture.events.has("site_admission"))
		cases[mode]={"events":fixture.events.duplicate(),"result":result,"elapsedUsec":Time.get_ticks_usec()-started}
		fixture.player.free(); fixture.player=null; fixture.voxel_terrain_runtime=null; fixture.free()
	var passed := false not in checks.values()
	var report := {"schema":"citadel-terrain-bootstrap-contract/v1","evidenceLevel":"synthetic_MainCore_orchestration_only","complete":true,"passed":passed,"checks":checks,"cases":cases,
		"productionMethods":["MainCore.bootstrap_initial_chunks_staged","MainCore.reinitialize_voxel_terrain_authority_staged"],
		"doesNotProve":"No scene/gameplay boot, native runtime, real site worker, chunks, terrain collision, navigation or player acceptance. No historical-code run."}
	var f := FileAccess.open(OS.get_environment("CITADEL_BOOTSTRAP_OUTPUT").path_join("report.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"\t")); f.close()
	print("BOOTSTRAP RESULT ",JSON.stringify({"passed":passed,"checks":checks.size(),"cases":cases.size()}))
	quit(0 if passed else 1)
