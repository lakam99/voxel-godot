extends SceneTree
## Synthetic startup dependencies, real tutorial reservation/restore, Admission,
## Runtime.build_generation_state and native context. No gameplay or Source.
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Queue = preload("res://scripts/world/CitadelSiteBuildQueue.gd")
const World = preload("res://scripts/WorldGenerationSystem.gd")
const Runtime = preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
const Readiness = preload("res://scripts/world/StartupReadinessResult.gd")
const REGION := Vector2i(1,-3)
const TOWN := Vector2i(1,0)
const POLICY := {"regionCells":140,"spawnChance":0.26}
class Structures extends RefCounted:
	var citadel_terrain_admission
class Owner extends "res://scripts/terrain/VoxelWorldGenerationContext.gd":
	var world_generation_system
	var structure_system
	var startup_loading_active := true
	var runtime_loading_active := false
	func town_region(x: int,z: int) -> Dictionary:
		return town_region_cache.get(Vector2i(x,z),{})
class TutorialFixture extends "res://scripts/TutorialSystem.gd":
	var prepared_modes: Array = []
	var events: Array = []
	func clear_scene() -> void: pass
	func configure_starting_inventory() -> void: events.append("inventory")
	func sync_crafting_unlocks_from_tutorial() -> void: pass
	func ensure_rescue_system() -> bool: return false
	func prepare_tutorial_world_staged(restoring: bool) -> Dictionary:
		prepared_modes.append("continue" if restoring else "new_game")
		events.append("prepare:continue" if restoring else "prepare:new_game")
		return Readiness.ready({}, {"syntheticStopBeforeTownAndActors":true})
class CaptureQueue extends Queue:
	var capture_mutex := Mutex.new()
	var captured: Array = []
	func _prepare_site(request: Dictionary, _continuation: Callable) -> Dictionary:
		capture_mutex.lock(); captured.append(request); capture_mutex.unlock()
		return {"status":"absent","reason":"synthetic_town_input_capture"}
	func captures() -> Array:
		capture_mutex.lock(); var value := captured.duplicate(); capture_mutex.unlock(); return value
var checks: Dictionary = {}
var cases: Dictionary = {}
func _initialize() -> void: call_deferred("_run")
func check(label: String, value: bool) -> void:
	checks[label]=value
	if not value: print("CONTRACT FAILURE ",label)
func _town(x: int,z: int,radius: int) -> Dictionary:
	return {"regionX":x,"regionZ":z,"centerX":x*280,"centerZ":z*280,"radius":radius,"level":24.3}
func _shutdown(a, label: String) -> void:
	a.request_shutdown(); var deadline := Time.get_ticks_msec()+3000
	while not a.advance().shutdownComplete and Time.get_ticks_msec()<deadline: await process_frame
	check(label+"_shutdown_clean",a.stats().shutdownComplete)
func _run() -> void:
	for mode: String in ["new_game","continue"]:
		var owner := Owner.new(); owner.seed_text="atlas-1492"; owner.seed_hash=owner.hash_string(owner.seed_text); owner.setup_noise()
		owner.town_region_cache[TOWN]=_town(1,0,34)
		var town_alias: Dictionary = owner.town_region(1,0)
		var a := Admission.new(); var queue := CaptureQueue.new(); a._queue=queue
		a.configure(owner.seed_text,owner.town_region_cache,POLICY)
		var pre_key: String = Queue._canonical_request(owner.seed_text,REGION,owner.town_region_cache,POLICY).sourceKey
		var structures := Structures.new(); structures.citadel_terrain_admission=a; owner.structure_system=structures
		var world := World.new(); world.setup(owner); owner.world_generation_system=world; owner.set_generator(world)
		var tutorial := TutorialFixture.new(); tutorial.main=owner
		var runtime := Runtime.new(); runtime.main=owner
		var capture := {"state":{},"calls":0,"radiusAtEntry":0}
		check(mode+"_early_admission_copy_was_old",a._towns[TOWN].radius==34)
		if mode=="new_game":
			var before_preparation := func() -> Dictionary:
				capture.calls+=1; capture.radiusAtEntry=town_alias.radius
				tutorial.events.append("callback_started")
				await process_frame
				capture.state=runtime.build_generation_state()
				tutorial.events.append("callback_finished")
				return Readiness.ready({}) if capture.state.get("ok",false) else Readiness.failed(String(capture.state.get("reason","generation_failed")))
			var start: Dictionary = await tutorial.start_new_world_staged(before_preparation)
			check(mode+"_actual_staged_start",start.status=="ready" and tutorial.prepared_modes==["new_game"])
			check(mode+"_actual_callback_after_reserve",capture.calls==1 and capture.radiusAtEntry==25)
			check(mode+"_callback_awaited_before_construction",tutorial.events==["callback_started","callback_finished","inventory","prepare:new_game"])
		else:
			tutorial.restore({"started":true,"completedSteps":[],"interacted":[]})
			check(mode+"_actual_restore_deferred",tutorial.restore_world_setup_pending)
			var restored: Dictionary = await tutorial.complete_restore_world_staged()
			check(mode+"_actual_staged_restore",restored.status=="ready" and tutorial.prepared_modes==["continue"])
		check(mode+"_town_alias_radius25",town_alias.radius==25 and owner.town_region_cache[TOWN].radius==25 and town_alias.homeExclusionRings[0].radius==25)
		var state: Dictionary = capture.state if mode=="new_game" else runtime.build_generation_state()
		check(mode+"_real_generation_state_ready",state.get("ok",false))
		if not state.get("ok",false):
			await _shutdown(a,mode); tutorial.main=null; tutorial.free(); runtime.main=null; runtime.free(); owner.world_generation_system=null; continue
		var context = state.generator.context_template
		var finalized: Dictionary = a.finalize_town_inputs(owner.town_region_cache).towns
		var frozen_bytes := var_to_bytes(finalized)
		check(mode+"_canonical_readonly",finalized.is_read_only() and finalized[TOWN].is_read_only() and finalized[TOWN].radius==25 and not finalized[TOWN].has("homeExclusionRings"))
		check(mode+"_native_same_finalized_town",context.pinned_town_regions==finalized and context.clone_for_worker().town_region(1,0).radius==25)
		var generation: int = a.stats().generation
		var store = a.profile_store
		a.request_source(REGION)
		var deadline := Time.get_ticks_msec()+3000
		while a.request_source(REGION).status=="pending" and Time.get_ticks_msec()<deadline:
			a.advance(); await process_frame
		var records: Array = queue.captures()
		check(mode+"_source_worker_received_once",records.size()==1)
		var source_key := ""
		if records.size()==1:
			source_key=records[0].sourceKey
			check(mode+"_source_native_towns_exact",var_to_bytes(records[0].towns)==frozen_bytes and records[0].towns[TOWN].radius==25)
			check(mode+"_source_key_finalized_not_early",source_key!=pre_key and source_key==Queue._canonical_request(owner.seed_text,REGION,finalized,POLICY).sourceKey)
		# Ordinary lazy cache accumulation must neither reconfigure admission nor
		# change an already published generation's pinned town inputs/source key.
		owner.town_region_cache[Vector2i(2,0)]=_town(2,0,38)
		var again: Dictionary = runtime.build_generation_state()
		check(mode+"_ordinary_cache_rebuild_ready",again.ok)
		check(mode+"_ordinary_cache_no_generation_reset",a.stats().generation==generation and a.profile_store==store and a._decisions[REGION].sourceKey==source_key)
		check(mode+"_ordinary_cache_not_new_input",var_to_bytes(a.finalize_town_inputs(owner.town_region_cache).towns)==frozen_bytes and again.generator.context_template.pinned_town_regions==finalized)
		check(mode+"_ordinary_cache_no_redispatch",a.request_source(REGION).status=="absent" and queue.captures().size()==1)
		town_alias.radius=41
		check(mode+"_postcapture_alias_isolated",a._towns[TOWN].radius==25 and context.clone_for_worker().town_region(1,0).radius==25 and var_to_bytes(records[0].towns)==frozen_bytes)
		cases[mode]={"events":tutorial.events.duplicate(),"preparedModes":tutorial.prepared_modes,"sourceKey":source_key,"earlyKey":pre_key,"finalizedTowns":finalized,"nativePinnedTowns":context.pinned_town_regions,"generation":generation}
		await _shutdown(a,mode)
		tutorial.main=null; tutorial.free(); runtime.main=null; runtime.free(); owner.world_generation_system=null; owner.structure_system=null
	var late := Admission.new(); late.configure("atlas-1492",{TOWN:_town(1,0,34)},POLICY)
	# Defensive late-finalization invariant, now unreachable through guarded
	# public requests. Explicit synthetic state injection preserves this check.
	late._requests[REGION]={"priority":true,"receipt":{}}
	check("late_first_finalization_fails_exact",late.finalize_town_inputs({TOWN:_town(1,0,25)})=={"status":"failed","reason":"citadel_town_inputs_already_used"})
	check("late_finalization_is_fatal",late.request_source(REGION)=={"status":"failed","reason":"citadel_town_inputs_already_used"})
	await _shutdown(late,"late_finalize")
	await _callback_failure_controls()
	await _empty_finalized_snapshot()
	var passed := false not in checks.values()
	var report := {"schema":"citadel-town-inputs-contract/v1","evidenceLevel":"synthetic_startup_dependencies_real_tutorial_reservation_admission_runtime_context","passed":passed,"complete":true,"checks":checks,"cases":cases,
		"doesNotProve":"No full Main boot or Main.start_new_game_staged flow, actual Site.prepare, native scheduling/physics guards, scene/NPC/tutorial gameplay or headed acceptance. Tutorial downstream generation/actor work is stubbed; unchanged production start/restore/reserve and Runtime.build_generation_state execute. New Game callback ordering is proven at the Tutorial source boundary, not the full host flow."}
	var f := FileAccess.open(OS.get_environment("CITADEL_TOWN_INPUTS_OUTPUT").path_join("report.json"),FileAccess.WRITE); f.store_string(JSON.stringify(report,"\t")); f.close()
	print("TOWN INPUTS RESULT ",JSON.stringify({"passed":passed,"checks":checks.size()})); quit(0 if passed else 1)
func _callback_failure_controls() -> void:
	for mode: String in ["failed","invalid"]:
		var owner := Owner.new(); owner.town_region_cache[TOWN]=_town(1,0,34)
		var tutorial := TutorialFixture.new(); tutorial.main=owner
		var observed := {"radius":0,"calls":0}
		var callback := func() -> Dictionary:
			observed.calls+=1; observed.radius=owner.town_region_cache[TOWN].radius
			tutorial.events.append("callback_started")
			await process_frame
			tutorial.events.append("callback_failed")
			return Readiness.failed("synthetic_authority_failure",{},[],{"fixture":"callback"}) if mode=="failed" else {"malformed":true}
		var result: Dictionary = await tutorial.start_new_world_staged(callback)
		check("callback_"+mode+"_after_actual_reserve",observed.radius==25 and observed.calls==1)
		check("callback_"+mode+"_no_inventory_or_construction",tutorial.events==["callback_started","callback_failed"] and tutorial.prepared_modes.is_empty() and not tutorial.started)
		check("callback_"+mode+"_structured_failure",Readiness.validate(result).ok and result.status=="failed" and result.reason==("synthetic_authority_failure" if mode=="failed" else "invalid_world_preparation_result"))
		if mode=="failed": check("callback_failure_preserved_exact",var_to_bytes(result)==var_to_bytes(Readiness.failed("synthetic_authority_failure",{},[],{"fixture":"callback"})))
		cases["callback_"+mode]={"events":tutorial.events.duplicate(),"result":result,"radiusAtCallback":observed.radius}
		tutorial.main=null; tutorial.free()
func _empty_finalized_snapshot() -> void:
	var owner := Owner.new(); owner.seed_text="atlas-1492"; owner.seed_hash=owner.hash_string(owner.seed_text); owner.setup_noise()
	var a := Admission.new(); var queue := CaptureQueue.new(); a._queue=queue; a.configure(owner.seed_text,{},POLICY)
	var structures := Structures.new(); structures.citadel_terrain_admission=a; owner.structure_system=structures
	var world := World.new(); world.setup(owner); owner.world_generation_system=world; owner.set_generator(world)
	var runtime := Runtime.new(); runtime.main=owner
	var first: Dictionary = runtime.build_generation_state()
	check("empty_generation_state_ready",first.ok)
	var finalized: Dictionary = a.finalize_town_inputs({}).towns
	check("empty_finalized_readonly",finalized.is_empty() and finalized.is_read_only())
	check("empty_native_context_pins_empty",first.generator.context_template.pinned_town_regions.is_empty())
	var initial_key: String = Queue._canonical_request(owner.seed_text,REGION,finalized,POLICY).sourceKey
	var generation: int = a.stats().generation; var store = a.profile_store
	owner.town_region_cache[TOWN]=_town(1,0,34)
	var second: Dictionary = runtime.build_generation_state()
	check("empty_after_cache_growth_stays_empty",second.ok and a._towns.is_empty() and second.generator.context_template.pinned_town_regions.is_empty() and second.generator.context_template.clone_for_worker().pinned_town_regions.is_empty())
	check("empty_growth_no_generation_reset",a.stats().generation==generation and a.profile_store==store)
	a.request_source(REGION)
	var deadline := Time.get_ticks_msec()+3000
	while a.request_source(REGION).status=="pending" and Time.get_ticks_msec()<deadline:
		a.advance(); await process_frame
	var received: Array = queue.captures()
	check("empty_growth_worker_receives_empty",received.size()==1 and received[0].towns.is_empty() and received[0].towns.is_read_only())
	check("empty_growth_source_key_unchanged",received.size()==1 and received[0].sourceKey==initial_key)
	check("empty_old_snapshot_unchanged",finalized.is_empty() and first.generator.context_template.pinned_town_regions.is_empty())
	cases.empty_finalized={"sourceKey":initial_key,"liveCacheTownCount":owner.town_region_cache.size(),"finalizedTownCount":finalized.size(),"generation":generation}
	await _shutdown(a,"empty_finalized")
	runtime.main=null; runtime.free(); owner.world_generation_system=null; owner.structure_system=null
