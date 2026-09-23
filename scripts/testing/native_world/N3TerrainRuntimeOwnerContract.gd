extends SceneTree

const OWNER = preload("res://scripts/terrain/NativeTerrainRuntimeOwner.gd")
const MAIN = preload("res://scripts/MainCore.gd")
const GAME_MAIN = preload("res://scripts/Main.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const WORLD = preload("res://scripts/WorldGenerationSystem.gd")
const VOLUME = preload("res://scripts/TerrainVolumeService.gd")

var failures: Array[String] = []
var observations: Array[Dictionary] = []

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var main = MAIN.new()
	main.seed_text = "native-owner-source-contract"
	main.structure_system = STRUCTURES.new()
	var admission = main.structure_system.citadel_terrain_admission
	admission.configure(main.seed_text, {}, {"regionCells":main.STRUCTURE_REGION_CELLS,
		"spawnChance":main.STRUCTURE_SPAWN_CHANCE})
	main.town_region_cache = {Vector2i(2, -1): {"centerX":2 * main.TOWN_REGION_CELLS,
		"centerZ":-main.TOWN_REGION_CELLS, "radius":main.TOWN_RADIUS_CELLS,
		"level":main.WATER_LEVEL + 3.0}}
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	main.world_generation_system.terrain_volume_service.set_cell_state(Vector3i(-17,-1,-1), {
		"material":"stone", "biome":"deep_underground", "solid":true,
		"density":1.25, "fluid":"", "blockId":"owner-contract-edit",
		"light":{"sky":3,"block":11},
		"metadata":{"saveDelta":true,"source":"terrain_edit"}}, "contract", false)
	main.world_generation_system.terrain_volume_service.set_cell_state(Vector3i(-17,0,-1), {
		"material":"air", "biome":"underground_air", "solid":false,
		"density":-1.0, "fluid":"", "blockId":"owner-above-air",
		"light":{"sky":0,"block":0},
		"metadata":{"saveDelta":true,"source":"terrain_edit"}}, "contract", false)
	main.world_generation_system.terrain_volume_service.set_cell_state(Vector3i(-17,1,-1), {
		"material":"air", "biome":"underground_air", "solid":false,
		"density":-1.0, "fluid":"", "blockId":"owner-headroom-air",
		"light":{"sky":0,"block":0},
		"metadata":{"saveDelta":true,"source":"terrain_edit"}}, "contract", false)
	main.world_generation_system.terrain_volume_service.set_cell_state(Vector3i(-17,-2,-1), {
		"material":"stone", "biome":"deep_underground", "solid":true,
		"density":1.0, "fluid":"", "blockId":"owner-below-stone",
		"light":{"sky":0,"block":0},
		"metadata":{"saveDelta":true,"source":"terrain_edit"}}, "contract", false)
	var world := Node3D.new()
	root.add_child(world)
	var terrain := VoxelTerrain.new()
	terrain.automatic_loading_enabled = false
	terrain.mesh_block_size = 16
	terrain.scale = Vector3.ONE * main.CELL
	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	terrain.set_format(format)
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	mesher.transitions_enabled = false
	terrain.mesher = mesher
	world.add_child(terrain)

	var invalid = OWNER.new()
	terrain.automatic_loading_enabled = true
	check(invalid.setup(main, terrain, 71, 10).get("reason") == "manual_terrain_required",
		"automatic terrain rejected without fallback")
	check(int(invalid.snapshot().backendInstanceId) == 0, "invalid setup owns no backend")
	terrain.automatic_loading_enabled = false
	var owner = OWNER.new()
	var owner_saved_volume: Dictionary = {}
	var setup: Dictionary = owner.setup(main, terrain, 71, 10)
	check(setup.get("status") == "ready", "atomic native owner setup")
	if setup.get("status") == "ready":
		var snapshot: Dictionary = owner.snapshot()
		check(snapshot.state == "active" and int(snapshot.backendInstanceId) != 0,
			"one live native backend")
		check(snapshot.backend.get("status") == "ready"
			and snapshot.backend.get("sourceIdentity") == setup.get("sourceIdentity"),
			"native source identity shared")
		var saved: Dictionary = owner.export_terrain_volume_v2()
		check(saved.get("status") == "ready"
			and saved.get("terrainVolume") == main.world_generation_system.terrain_volume_service.save_all_section_deltas()
			and saved.get("sourceIdentity") == setup.get("sourceIdentity")
			and saved.get("saveSeedText") == main.seed_text,
			"save facade exports exact native durable volume from shared owner")
		check(snapshot.publisher.get("active") == true
			and int(snapshot.planner.get("consumerId", 0)) == 71,
			"publisher and planner bound")
		var exported: Dictionary = owner.read_cell(Vector3i(-17,-1,-1))
		check(exported.get("status") in ["ready", "pending"],
			"cell source uses native backend without fallback")
		if exported.get("status") == "ready":
			check(exported.get("state", {}).get("blockId") == "owner-contract-edit"
				and exported.get("state", {}).get("solid") == true,
				"current durable edit visible through native cell source")
		var occupied_cell := Vector3i(-17,-1,-1)
		var occupancy: Dictionary = owner.read_occupancy(occupied_cell)
		var old_occupancy: Dictionary = main.world_generation_system.terrain_volume_service.terrain_occupancy_at_cell(occupied_cell)
		var occupancy_fields := ["cell", "solid", "air", "material", "biome", "fluid",
			"light", "floorSolid", "ceilingSolid", "walkableAir"]
		var occupancy_matches: bool = occupancy.get("status") == "ready"
		for field in occupancy_fields:
			occupancy_matches = occupancy_matches and occupancy.get("occupancy", {}).get(field) == old_occupancy.get(field)
		if not occupancy_matches:
			observations.append({"nativeOccupancy":occupancy, "scriptOccupancy":old_occupancy})
		check(occupancy_matches, "three-cell native occupancy matches script source vocabulary")
		var walkable_cell := Vector3i(-17,0,-1)
		var walkable: Dictionary = owner.read_occupancy(walkable_cell)
		var old_walkable: Dictionary = main.world_generation_system.terrain_volume_service.terrain_occupancy_at_cell(walkable_cell)
		var walkable_matches: bool = walkable.get("status") == "ready" and old_walkable.get("walkableAir") == true
		for field in occupancy_fields:
			walkable_matches = walkable_matches and walkable.get("occupancy", {}).get(field) == old_walkable.get(field)
		check(walkable_matches, "edited air over support has exact native walkable occupancy")
		var generated_cell := Vector3i(-20,-3,-3)
		var generated: Dictionary = owner.read_occupancy(generated_cell)
		var old_generated: Dictionary = main.world_generation_system.terrain_volume_service.terrain_occupancy_at_cell(generated_cell)
		var generated_matches: bool = generated.get("status") == "ready"
		for field in occupancy_fields:
			generated_matches = generated_matches and generated.get("occupancy", {}).get(field) == old_generated.get(field)
		if not generated_matches:
			observations.append({"nativeGeneratedOccupancy":generated,
				"scriptGeneratedOccupancy":old_generated})
		check(generated_matches, "same-seed generated triple occupancy parity")
		var numeric: Dictionary = owner.read_numeric_batch(
			[Vector3(-16.5,-0.5,-0.5) * main.CELL], [Vector3i(-17,-1,-1)])
		check(numeric.get("status") in ["ready", "pending"],
			"numeric source shares native backend without fallback")
		if numeric.get("status") == "ready":
			check((numeric.get("worldNumeric", []) as Array).size() == 1
				and (numeric.get("surfaceProjectionNumeric", []) as Array).size() == 1,
				"native numeric channels remain a complete batch")
		var edit_cell := Vector3i(-18, -1, -1)
		var edit_state := {"materialId":3, "biomeId":13, "fluidId":0,
			"solid":true, "density":1.5, "light":Vector2i(2, 9),
			"metadata":{"saveDelta":true,"source":"terrain_edit"},
			"blockId":"owner-new-edit", "editReason":"contract"}
		var native_revision := int(saved.get("nativeRevision", -1))
		var oversized: Array = []
		for index in range(64):
			oversized.append({"kind":"clear", "cell":Vector3i(index * 160, -1, 0)})
		var rejected_plan: Dictionary = owner.commit_durable_cells("owner:oversized",
			native_revision, oversized)
		observations.append({"oversized":rejected_plan.get("reason", ""),
			"ownerState":owner.snapshot().state})
		check(rejected_plan.get("status") == "failed"
			and int(owner.export_terrain_volume_v2().get("nativeRevision", -1)) == native_revision,
			"unadmittable republication plan rejected before native commit")
		var stale: Dictionary = owner.commit_durable_cells("owner:stale", native_revision - 1,
			[{"kind":"set", "cell":edit_cell, "state":edit_state}])
		check(stale.get("reason") == "native_edit_revision_mismatch",
			"stale edit rejected before native commit")
		var committed: Dictionary = owner.commit_durable_cells("owner:edit-1", native_revision,
			[{"kind":"set", "cell":edit_cell, "state":edit_state}])
		observations.append({"commit":committed.get("reason", committed.get("status", "")),
			"ownerState":owner.snapshot().state,
			"affectedSections":str(committed.get("affectedSections", []))})
		check(committed.get("status") == "ready"
			and int(committed.get("nativeRevision", -1)) == native_revision + 1
			and committed.get("physicalReady") == false
			and committed.get("publicationPlan", {}).get("status") == "ready"
			and committed.get("publicationPlan", {}).get("barrier", {}).get("activationEligible") == true,
			"durable edit returns physical republication plan without readiness")
		var sections: Array = committed.get("affectedSections", [])
		var plan: Dictionary = committed.get("publicationPlan", {})
		var edited_section := Vector3i(-2, -1, -1)
		check(OWNER.receipt_matches_plan(sections, plan),
			"real conservative native section receipt covered by preflighted mesh halo")
		var forged_extra := sections.duplicate()
		forged_extra.append(Vector3i(100, 0, 0))
		var forged_missing := sections.duplicate()
		forged_missing.erase(Vector3i(-3, -2, -2))
		var forged_duplicate := sections.duplicate()
		forged_duplicate[0] = forged_duplicate[1]
		check(not OWNER.receipt_matches_plan(forged_extra, plan)
			and not OWNER.receipt_matches_plan(forged_duplicate, plan)
			and not OWNER.receipt_matches_plan(forged_missing, plan),
			"foreign duplicate and missing neighbor sections rejected")
		var barrier: Dictionary = plan.get("barrier", {})
		var window_receipts: Array = []
		for window in plan.get("subwindows", []):
			var mesh_receipts: Array = []
			for mesh_block in window.meshBlocks:
				mesh_receipts.append({"block":mesh_block, "generation":2, "physicalReady":true})
			window_receipts.append({"index":window.index, "token":window.token,
				"nativeRevision":barrier.nativeRevision, "status":"ready",
				"meshBlockReceipts":mesh_receipts})
		var candidate := {"ownerInstanceId":owner.get_instance_id(),
			"sourceIdentity":setup.sourceIdentity, "sourceEpoch":barrier.sourceEpoch,
			"nativeRevision":barrier.nativeRevision, "barrierIdentity":barrier.identity,
			"subwindowReceipts":window_receipts}
		check(owner.inspect_edit_release_candidate(candidate).get("reason")
			== "production_physical_owner_unbound",
			"complete synthetic candidate cannot release physical barrier")
		var wrong_owner := candidate.duplicate(true)
		wrong_owner.ownerInstanceId = 1
		var stale_revision := candidate.duplicate(true)
		stale_revision.nativeRevision = native_revision
		var wrong_source := candidate.duplicate(true)
		wrong_source.sourceEpoch = "foreign"
		check(owner.inspect_edit_release_candidate(wrong_owner).get("reason") == "edit_release_identity_mismatch"
			and owner.inspect_edit_release_candidate(stale_revision).get("reason") == "edit_release_identity_mismatch"
			and owner.inspect_edit_release_candidate(wrong_source).get("reason") == "edit_release_identity_mismatch",
			"owner revision and source epoch mismatches rejected")
		var partial := candidate.duplicate(true)
		partial.subwindowReceipts.pop_back()
		var duplicate := candidate.duplicate(true)
		duplicate.subwindowReceipts.append(window_receipts[0])
		check(owner.inspect_edit_release_candidate(partial).get("status") == "pending"
			and owner.inspect_edit_release_candidate(duplicate).get("status") == "failed",
			"partial candidate waits and duplicate subwindow is rejected")
		var after_edit: Dictionary = owner.export_terrain_volume_v2()
		owner_saved_volume = after_edit.get("terrainVolume", {})
		check(after_edit.get("status") == "ready"
			and int(after_edit.get("nativeRevision", -1)) == native_revision + 1
			and after_edit.get("terrainVolume") != saved.get("terrainVolume"),
			"save facade sees the committed native edit")
		var edited: Dictionary = owner.read_cell(edit_cell)
		check(edited.get("status") == "ready"
			and edited.get("state", {}).get("blockId") == "owner-new-edit",
			"gameplay cell facade sees committed native edit")
		check(owner.commit_durable_cells("owner:second", native_revision + 1,
			[{"kind":"clear", "cell":edit_cell}]).get("reason") == "physical_edit_barrier_pending",
			"second edit retained behind unproven physical barrier")
		check(int(owner.export_terrain_volume_v2().get("nativeRevision", -1)) == native_revision + 1,
			"blocked second edit does not advance save owner")
		var demand: Dictionary = owner.replace_demand(
			{"position":Vector3.ZERO,"distance":0}, [], [], [], Vector2i(0, 0))
		check(demand.get("status") == "ready" and demand.get("desiredDataBlocks") == 27,
			"planner demand admitted into one owner")
		var tick: Dictionary = owner.advance()
		check(tick.get("status") in ["ready", "pending"], "owner advances native demand")
		check(int(owner.snapshot().publisher.get("demanded", 0)) == 27,
			"publisher received same desired union")
		observations.append({"backendInstanceId":snapshot.backendInstanceId,
			"sourceIdentity":setup.get("sourceIdentity"),
			"saveStatus":saved.get("status"), "saveNativeRevision":saved.get("nativeRevision"),
			"cellStatus":exported.get("status"), "numericStatus":numeric.get("status"),
			"tickStatus":tick.get("status"),
			"nativeRevision":snapshot.backend.get("terrainDeltaRevision")})
	var stopped: Dictionary = owner.stop()
	for frame in range(120):
		if stopped.get("status") == "ready": break
		await process_frame
		stopped = owner.drain_step()
	check(stopped.get("status") == "ready" and stopped.get("drained") == true,
		"stop drains owned native work")
	check(owner.snapshot().state == "drained"
		and int(owner.snapshot().backendInstanceId) == 0,
		"no retained backend after drain")
	check(owner.read_cell(Vector3i.ZERO).get("reason") == "owner_not_active",
		"drained owner does not fall back")
	check(owner.read_occupancy(Vector3i.ZERO).get("reason") == "owner_not_active",
		"drained owner rejects occupancy queries")
	check(owner.export_terrain_volume_v2().get("reason") == "owner_not_active",
		"drained owner cannot export stale save data")
	check(owner.commit_durable_cells("owner:drained", 0, []).get("reason") == "owner_not_active",
		"drained owner rejects edits")
	main.world_generation_system = null
	var continued = OWNER.new()
	var continued_setup: Dictionary = continued.setup(main, terrain, 72, 10,
		{"version":2, "seed":main.seed_text, "terrain":[], "terrainVolume":owner_saved_volume})
	check(continued_setup.get("status") == "ready",
		"Continue owner initializes from explicit saved v2 volume without script owner")
	if continued_setup.get("status") == "ready":
		var continued_save: Dictionary = continued.export_terrain_volume_v2()
		check(continued_save.get("status") == "ready"
			and continued_save.get("terrainVolume") == owner_saved_volume,
			"Continue owner round trips exact durable snapshot")
	var continued_stop: Dictionary = continued.stop()
	for frame in range(120):
		if continued_stop.get("status") == "ready": break
		await process_frame
		continued_stop = continued.drain_step()
	check(continued_stop.get("status") == "ready", "Continue owner drains")
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	var new_game = OWNER.new()
	var new_game_setup: Dictionary = new_game.setup(main, terrain, 73, 10)
	check(new_game_setup.get("status") == "ready", "New Game owner initializes from empty durable volume")
	if new_game_setup.get("status") == "ready":
		var new_game_volume: Dictionary = new_game.export_terrain_volume_v2().get("terrainVolume", {})
		check(new_game_volume.get("sections", []) == [], "New Game native save starts with no durable cells")
	var new_game_stop: Dictionary = new_game.stop()
	for frame in range(120):
		if new_game_stop.get("status") == "ready": break
		await process_frame
		new_game_stop = new_game.drain_step()
	check(new_game_stop.get("status") == "ready", "New Game owner drains")
	var legacy_main = GAME_MAIN.new()
	legacy_main.seed_text = "native-owner-legacy-continue"
	legacy_main.seed_hash = legacy_main.hash_string(legacy_main.seed_text)
	legacy_main.setup_noise()
	legacy_main.structure_system = STRUCTURES.new()
	legacy_main.structure_system.citadel_terrain_admission.configure(
		legacy_main.seed_text, {}, {"regionCells":legacy_main.STRUCTURE_REGION_CELLS,
			"spawnChance":legacy_main.STRUCTURE_SPAWN_CHANCE})
	legacy_main.world_generation_system = WORLD.new()
	legacy_main.world_generation_system.setup(legacy_main)
	var legacy_column := Vector2i(-13, -11)
	var legacy_height: float = legacy_main.world_generation_system.surface_y_for_cell(
		Vector3i(legacy_column.x, 0, legacy_column.y)) - 4.0 * legacy_main.CELL
	var legacy_save := {"version":2, "seed":legacy_main.seed_text,
		"terrain":[{"x":legacy_column.x, "z":legacy_column.y, "surfaceY":legacy_height}]}
	var converting = OWNER.new()
	var convert_setup: Dictionary = converting.setup(legacy_main, terrain, 74, 10,
		legacy_save)
	check(convert_setup.get("status") == "pending"
		and converting.snapshot().state == "converting"
		and converting.export_terrain_volume_v2().get("status") != "ready",
		"historical Continue retains loading request and withholds partial save")
	var cancelled_convert = OWNER.new()
	check(cancelled_convert.setup(legacy_main, terrain, 75, 10,
		legacy_save).get("status") == "pending"
		and cancelled_convert.stop().get("status") == "ready"
		and cancelled_convert.snapshot().state == "drained"
		and cancelled_convert.advance().get("status") == "failed",
		"cancelled Continue releases conversion and cannot publish a partial owner")
	var convert_tick: Dictionary = {}
	for frame in range(300):
		convert_tick = converting.advance()
		if converting.snapshot().state == "active" or convert_tick.get("status") == "failed":
			break
		await process_frame
	legacy_main.restore_volume_edits(legacy_save.terrain)
	check(convert_tick.get("status") == "ready"
		and converting.snapshot().state == "active"
		and converting.export_terrain_volume_v2().get("terrainVolume", {})
			== legacy_main.world_generation_system.save_terrain_volume_deltas(),
		"historical Continue activates one native owner with exact v2 snapshot")
	var convert_stop: Dictionary = converting.stop()
	for frame in range(120):
		if convert_stop.get("status") == "ready": break
		await process_frame
		convert_stop = converting.drain_step()
	check(convert_stop.get("status") == "ready", "converted owner drains")
	legacy_main.free()
	world.queue_free()
	main.free()
	var report := {"schema":"n3-terrain-runtime-owner-contract/v1",
		"passed":failures.is_empty(), "evidenceLevel":"real-native-binding-service-contract",
		"productionCutover":false, "failures":failures, "observations":observations}
	var path := OS.get_environment("VWB_TERRAIN_OWNER_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)
