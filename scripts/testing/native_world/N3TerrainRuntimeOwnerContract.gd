extends SceneTree

const OWNER = preload("res://scripts/terrain/NativeTerrainRuntimeOwner.gd")
const MAIN = preload("res://scripts/MainCore.gd")
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
	main.world_generation_system.terrain_volume_service = VOLUME.new()
	main.world_generation_system.terrain_volume_service.setup(main, null)
	main.world_generation_system.terrain_volume_service.set_cell_state(Vector3i(-17,-1,-1), {
		"material":"stone", "biome":"deep_underground", "solid":true,
		"density":1.25, "fluid":"", "blockId":"owner-contract-edit",
		"light":{"sky":3,"block":11},
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
		var stale: Dictionary = owner.commit_durable_cells("owner:stale", native_revision - 1,
			[{"kind":"set", "cell":edit_cell, "state":edit_state}])
		check(stale.get("reason") == "native_edit_revision_mismatch",
			"stale edit rejected before native commit")
		var committed: Dictionary = owner.commit_durable_cells("owner:edit-1", native_revision,
			[{"kind":"set", "cell":edit_cell, "state":edit_state}])
		check(committed.get("status") == "ready"
			and int(committed.get("nativeRevision", -1)) == native_revision + 1
			and committed.get("physicalReady") == false
			and committed.get("publicationPlan", {}).get("status") == "ready"
			and committed.get("publicationPlan", {}).get("barrier", {}).get("activationEligible") == true,
			"durable edit returns physical republication plan without readiness")
		var after_edit: Dictionary = owner.export_terrain_volume_v2()
		check(after_edit.get("status") == "ready"
			and int(after_edit.get("nativeRevision", -1)) == native_revision + 1
			and after_edit.get("terrainVolume") != saved.get("terrainVolume"),
			"save facade sees the committed native edit")
		var edited: Dictionary = owner.read_cell(edit_cell)
		check(edited.get("status") == "ready"
			and edited.get("state", {}).get("blockId") == "owner-new-edit",
			"gameplay cell facade sees committed native edit")
		check(owner.commit_durable_cells("owner:stale-2", native_revision,
			[{"kind":"clear", "cell":edit_cell}]).get("reason") == "native_edit_revision_mismatch",
			"second stale edit rejected")
		var cleared: Dictionary = owner.commit_durable_cells("owner:clear-2", native_revision + 1,
			[{"kind":"clear", "cell":edit_cell}])
		check(cleared.get("status") == "ready"
			and int(cleared.get("nativeRevision", -1)) == native_revision + 2,
			"clear uses the same typed durable authority")
		var cleared_read: Dictionary = owner.read_cell(edit_cell)
		check(cleared_read.get("status") == "ready"
			and cleared_read.get("state", {}).get("blockId") != "owner-new-edit"
			and cleared_read.get("state", {}).get("edited") == false,
			"clear removes durable edit from gameplay cell source")
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
	check(owner.export_terrain_volume_v2().get("reason") == "owner_not_active",
		"drained owner cannot export stale save data")
	check(owner.commit_durable_cells("owner:drained", 0, []).get("reason") == "owner_not_active",
		"drained owner rejects edits")
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
