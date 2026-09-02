extends SceneTree
## Real WGS/context/native-buffer invocation; no live terrain or Source rebuild.
const World = preload("res://scripts/WorldGenerationSystem.gd")
const Context = preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const Generator = preload("res://scripts/terrain/VoxelTerrainGenerator.gd")
const Store = preload("res://scripts/world/GeneratedSiteProfileStore.gd")
const Profile = preload("res://scripts/world/BuildingTerrainProfile.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"
class Owner extends Context:
	var world_generation_system
var checks: Dictionary = {}
var report := {"schema":"citadel-profile-snapshot-contract/v1","evidenceLevel":"actual_frozen_profile_real_WGS_context_native_block_service","complete":false,"passed":false,
	"doesNotProve":"No Source rebuild, native scheduling/reset gate, live meshes/collisions, player approach, headed, NPC or gameplay acceptance."}
var owner_context: Owner
var world
func _initialize() -> void: call_deferred("_run")
func check(label: String, passed: bool) -> void:
	var first_failure: bool = not passed and checks.get(label,true)
	checks[label] = bool(checks.get(label,true)) and passed
	if first_failure: print("CONTRACT FAILURE ",label)
static func _load_and_validate() -> Dictionary:
	if FileAccess.get_sha256(INPUT)!=SHA: return {"ready":false,"reason":"fixture_sha"}
	var f := FileAccess.open(INPUT,FileAccess.READ)
	if f==null or f.get_length()>16777216: return {"ready":false,"reason":"fixture_bounds"}
	var value: Variant = f.get_var(false)
	if f.get_error()!=OK or f.get_position()!=f.get_length() or not value is Dictionary or value.get("status")!="prepared": return {"ready":false,"reason":"fixture_envelope"}
	f.close()
	var p: Dictionary = value.profile
	var started := Time.get_ticks_usec()
	if not Profile.valid(p,"atlas-1492",Context.CELL): return {"ready":false,"reason":"full_profile_invalid"}
	# Deliberately derived control, not a second actual Source result. Changes
	# only the admitted plane by two cells to expose equal-count store rebinding.
	var replacement := p.duplicate(true)
	replacement.level += 2.0*Context.CELL
	replacement.origin.y = replacement.level
	for i in range(replacement.groundRootPoints.size()): replacement.groundRootPoints[i].y = replacement.level
	if not Profile.valid(replacement,"atlas-1492",Context.CELL): return {"ready":false,"reason":"replacement_control_invalid"}
	Profile.freeze_profiles([p,replacement])
	return {"ready":true,"profile":p,"replacement":replacement,"validationUsec":Time.get_ticks_usec()-started,"threadId":OS.get_thread_caller_id()}
func _world_for(context):
	var result := World.new(); result.setup(context); context.set_generator(result); return result
func _template():
	var result := Context.new(); result.setup_from_main(owner_context); return result
func _native(context, origin: Vector3i, size := Vector3i(3,3,3)) -> Array:
	var generator := Generator.new(); generator.setup(context)
	var buffer := VoxelBuffer.new(); buffer.create(size.x,size.y,size.z)
	generator._generate_block(buffer,origin,0)
	var result: Array = []
	for z in range(size.z):
		for y in range(size.y):
			for x in range(size.x):
				result.append([buffer.get_voxel_f(x,y,z,VoxelBuffer.CHANNEL_SDF),buffer.get_voxel(x,y,z,VoxelBuffer.CHANNEL_INDICES),buffer.get_voxel(x,y,z,VoxelBuffer.CHANNEL_DATA5)])
	return result
func _check_native(label: String, actual: Array, source_world, origin: Vector3i, edits: Dictionary) -> void:
	var generator := Generator.new()
	# Compare the represented 16-bit SDF, not unencoded world density. The
	# engine's public channel conversion is part of native buffer semantics.
	var encoded := VoxelBuffer.new(); encoded.create(1,1,1)
	encoded.set_channel_depth(VoxelBuffer.CHANNEL_SDF,VoxelBuffer.DEPTH_16_BIT)
	var differences: Array = []
	var i := 0
	for z in range(3):
		for y in range(3):
			for x in range(3):
				var cell := origin+Vector3i(x,y,z); var position := Vector3(cell)*Context.CELL
				var base: float = source_world.terrain_reference_surface_y_at(position)
				var surface: float = source_world.terrain_deformed_surface_y_at(position)
				var density: float = source_world.density_from_components(position,surface,base)
				var material: String = generator.material_for_generated_density(source_world,cell,position,base,density)
				if edits.has(cell): density = edits[cell].density; material = edits[cell].material
				encoded.set_voxel_f(-density/Context.CELL,0,0,0,VoxelBuffer.CHANNEL_SDF)
				var expected_sdf := encoded.get_voxel_f(0,0,0,VoxelBuffer.CHANNEL_SDF)
				check(label+"_density",actual[i][0]==expected_sdf)
				if actual[i][0]!=expected_sdf and differences.size()<3: differences.append({"cell":cell,"rawDensity":density,"expectedEncodedSdf":expected_sdf,"actualEncodedSdf":actual[i][0]})
				check(label+"_materials",actual[i][1]==Generator.MATERIAL_IDS[material] and actual[i][2]==Generator.MATERIAL_IDS[material])
				i += 1
	if not report.has("densityDifferences"): report.densityDifferences={}
	report.densityDifferences[label]=differences
func _run() -> void:
	var thread := Thread.new(); var error := thread.start(_load_and_validate)
	check("validation_worker_started",error==OK)
	if error!=OK: _finish(); return
	while thread.is_alive(): await process_frame
	var loaded: Dictionary = thread.wait_to_finish()
	check("actual_fixture_full_validation",loaded.get("ready",false))
	if not loaded.get("ready",false): report.loadFailure=loaded; _finish(); return
	check("validation_off_owner_thread",loaded.threadId!=OS.get_thread_caller_id())
	report.fixtureSha256=SHA; report.validationUsec=loaded.validationUsec
	var p: Dictionary = loaded.profile; var profile_bytes := var_to_bytes(p)
	check("fixture_deep_frozen",p.is_read_only() and p.supportMask.is_read_only() and p.distanceCells.is_read_only() and p.groundRootPoints.is_read_only())
	var cell2: Vector2i = p.coreCells.get_center()
	var found := false
	for z in range(p.coreCells.position.y,p.coreCells.end.y):
		for x in range(p.coreCells.position.x,p.coreCells.end.x):
			var candidate := Vector2i(x,z)
			if Profile.contains_core(p,candidate) and Profile.contains_core(p,candidate+Vector2i.ONE) and Profile.contains_core(p,candidate+Vector2i.RIGHT) and Profile.contains_core(p,candidate+Vector2i.DOWN): cell2=candidate; found=true; break
		if found: break
	check("actual_support_sample_found",found)
	owner_context=Owner.new(); owner_context.seed_text="atlas-1492"; owner_context.seed_hash=owner_context.hash_string(owner_context.seed_text); owner_context.setup_noise()
	world=_world_for(owner_context); owner_context.world_generation_system=world
	var store := Store.new("atlas-1492"); world.bind_generated_site_profile_store(store)
	var edit_cell := Vector3i(cell2.x,floori(p.level/Context.CELL)-1,cell2.y)
	var edit := {"material":"air","solid":false,"density":-Context.CELL,"biome":"plains","fluid":"","metadata":{"saveDelta":true,"terrainMeshAffects":true}}
	world.terrain_volume_service.set_cell_state(edit_cell,edit,"contract_saved_edit",false)
	var saved_before := var_to_bytes(world.terrain_volume_service.edited_cells)
	var template = _template(); var old_clone = template.clone_for_worker(); var old_world = _world_for(old_clone)
	var sample_cell := Vector3i(cell2.x,0,cell2.y)
	var natural: float = world.base_surface_y_for_cell(sample_cell)
	var origin := edit_cell-Vector3i(1,1,1)
	var old_native := _native(old_clone,origin)
	var far := Vector3i(p.envelopeCells.end.x+32,0,p.envelopeCells.end.y+32)
	var far_height: float = world.base_surface_y_for_cell(far)
	var far_origin := Vector3i(far.x,floori(far_height/Context.CELL),far.z)
	var far_native := _native(old_clone,far_origin,Vector3i.ONE)
	check("append_actual_profile",store.append_prepared_profile(p)); world.refresh_generated_site_profiles()
	check("main_refresh_changes_cached_height",is_equal_approx(world.base_surface_y_for_cell(sample_cell),p.level) and not is_equal_approx(natural,p.level))
	var newer_clone = template.clone_for_worker(); var newer_world = _world_for(newer_clone)
	check("new_clone_captures_append",newer_clone.generated_site_profiles.size()==1 and is_equal_approx(newer_world.base_surface_y_for_cell(sample_cell),p.level))
	check("old_clone_unchanged",old_clone.generated_site_profiles.is_empty() and old_world.base_surface_y_for_cell(sample_cell)==natural and _native(old_clone,origin)==old_native)
	var current_native := _native(template,origin)
	_check_native("new_native_main",current_native,world,origin,world.terrain_volume_service.edited_cells)
	check("saved_edit_native_air",current_native[13][0]>0.0 and current_native[13][1]==0)
	check("saved_edit_main_preserved",not world.terrain_volume_service.get_cell_state(edit_cell).solid and var_to_bytes(world.terrain_volume_service.edited_cells)==saved_before)
	check("unrelated_terrain_unchanged",world.base_surface_y_for_cell(far)==far_height and _native(template,far_origin,Vector3i.ONE)==far_native)
	# Destroy and reconstruct context/generator consumers only. This models a
	# block consumer re-entry, not native runtime unload scheduling (main-owned).
	newer_world=null; newer_clone=null
	var reentry = _template()
	check("consumer_reentry_same_frozen_profile",var_to_bytes(reentry.clone_for_worker().generated_site_profiles[0])==profile_bytes and _native(reentry,origin)==current_native)
	var replacement: Dictionary = loaded.replacement; var store_b := Store.new("atlas-1492")
	check("replacement_store_same_count",store_b.append_prepared_profile(replacement) and store_b.snapshot().size()==store.snapshot().size())
	world.bind_generated_site_profile_store(store_b)
	var rebound = _template(); var rebound_clone = rebound.clone_for_worker(); var rebound_world = _world_for(rebound_clone)
	var main_height: float = world.base_surface_y_for_cell(sample_cell)
	var clone_height: float = rebound_world.base_surface_y_for_cell(sample_cell)
	check("rebind_same_count_replaces_main_values",var_to_bytes(world.generated_site_profiles[0])==var_to_bytes(replacement) and is_equal_approx(main_height,replacement.level))
	check("rebind_main_new_clone_agree",is_equal_approx(main_height,clone_height))
	check("rebind_new_clone_uses_new_store",is_equal_approx(clone_height,replacement.level))
	var rebound_native := _native(rebound,origin)
	_check_native("rebound_native_main",rebound_native,world,origin,world.terrain_volume_service.edited_cells)
	_check_native("rebound_native_clone",rebound_native,rebound_world,origin,rebound.initial_terrain_edits)
	check("old_template_retains_old_store",_native(template,origin)==current_native)
	check("rebind_saved_edit_preserved",rebound_native[13][1]==0 and var_to_bytes(world.terrain_volume_service.edited_cells)==saved_before)
	check("rebind_unrelated_terrain_unchanged",world.base_surface_y_for_cell(far)==far_height and _native(rebound,far_origin,Vector3i.ONE)==far_native)
	check("actual_input_profile_immutable",var_to_bytes(p)==profile_bytes and FileAccess.get_sha256(INPUT)==SHA)
	report.samples={"sampleCell":sample_cell,"oldNaturalHeight":natural,"actualLevel":p.level,"replacementControlLevel":replacement.level,"reboundMainHeight":main_height,"reboundCloneHeight":clone_height,
		"oldBlock":old_native,"appendedBlock":current_native,"reboundBlock":rebound_native,"replacementPolicy":"Derived actual profile shifted up two cells solely to test equal-count fresh-store rebinding."}
	_finish()
func _finish() -> void:
	if owner_context!=null: owner_context.world_generation_system=null
	report.checks=checks; report.complete=true; report.passed=not checks.is_empty() and false not in checks.values()
	var f := FileAccess.open(OS.get_environment("CITADEL_PROFILE_OUTPUT").path_join("report.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"\t")); f.close()
	print("PROFILE SNAPSHOT RESULT ",JSON.stringify({"passed":report.passed,"checks":checks.size(),"complete":true}))
	quit(0 if report.passed else 1)
