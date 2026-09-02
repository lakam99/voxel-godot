extends SceneTree
## Source/service contract: real volume and native generator samples, not play.
const Profile := preload("res://scripts/world/BuildingTerrainProfile.gd")
const World := preload("res://scripts/WorldGenerationSystem.gd")
const Context := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const Generator := preload("res://scripts/terrain/VoxelTerrainGenerator.gd")
var checks := {}
class FixtureContext extends "res://scripts/terrain/VoxelWorldGenerationContext.gd":
	var world_generation_system
func _initialize() -> void:
	call_deferred("run")
func check(label: String, passed: bool) -> void:
	checks[label] = bool(checks.get(label, true)) and passed
func run() -> void:
	var report_path := OS.get_environment("VOXEL_BUILDING_TERRAIN_REPORT")
	if report_path.is_empty() or FileAccess.file_exists(report_path):
		printerr("Fresh report path required")
		quit(2)
		return
	var context := FixtureContext.new()
	context.seed_text = "atlas-1492"
	context.seed_hash = context.hash_string(context.seed_text)
	context.setup_noise()
	var world := World.new()
	world.setup(context)
	context.set_generator(world)
	context.world_generation_system = world
	# Synthetic manifest is explicit; actual source geometry has a separate test.
	var manifest := {"ready": true, "cellSize": Context.CELL, "sourceSignature": "synthetic-profile-contract",
		"groundY": 0.0, "localBounds": AABB(Vector3(-2, 0, -2), Vector3(4, 1, 4)),
		"footprintCells": Rect2i(-2, -2, 5, 5),
		"groundRoots": [{"partId":"synthetic-root", "corners": [Vector3(-2,0,-2), Vector3(2,0,-2), Vector3(2,0,2), Vector3(-2,0,2)]}]}
	var origin := Vector2i(1300, -1500)
	var natural: float = world.natural_surface_y_for_cell(Vector3i(origin.x,0,origin.y))
	var level: float = roundf(natural / Context.CELL) * Context.CELL + Context.CELL * 2.0
	var made := Profile.create(manifest, context.seed_text, "synthetic-site", origin, level, 18)
	check("profile_created", made.ready)
	if not made.ready:
		printerr("Profile failed: ", made)
		context.world_generation_system = null
		quit(1)
		return
	var profile: Dictionary = made.profile
	var wrong_grid := manifest.duplicate(true)
	wrong_grid.cellSize = 2.0
	check("mismatched_manifest_grid_rejected", not Profile.create(wrong_grid, context.seed_text, "bad", origin, level, 18).ready)
	check("overflow_origin_rejected", not Profile.create(manifest, context.seed_text, "bad", Vector2i(2147483647,2147483647), level, 18).ready)
	var invalid := profile.duplicate(true)
	invalid.coreCells = Rect2i(2147483640,0,500,2)
	check("overflow_core_rejected", not Profile.valid(invalid, context.seed_text, Context.CELL))
	invalid = profile.duplicate(true)
	invalid.groundRootPoints[0].x += 100.0
	check("outlying_root_rejected", not Profile.valid(invalid, context.seed_text, Context.CELL))
	var natural_before := world.base_surface_y_for_cell(Vector3i(origin.x,0,origin.y))
	var admitted := world.configure_generated_site_profiles([profile])
	check("profile_admitted", admitted.ready)
	check("cached_base_recomputed", world.base_surface_y_for_cell(Vector3i(origin.x,0,origin.y)) == level and natural_before != level)
	check("soil_support_policy", world.minimum_overburden_cells_for_position(Vector3(origin.x * Context.CELL,level,origin.y * Context.CELL)) == 8.0)
	var edge: Vector2i = profile.coreCells.position - Vector2i(18, 0)
	check("outer_apron_exactly_natural", Profile.surface_y(profile, edge, natural) == natural)
	var far := origin + Vector2i(100,100)
	check("outside_unchanged", world.base_surface_y_for_cell(Vector3i(far.x,0,far.y)) == world.natural_surface_y_for_cell(Vector3i(far.x,0,far.y)))
	var snapshot := world.generated_site_profiles_snapshot()
	var input_mask_alias: Array = profile.supportMask
	var input_distance_alias: Array = profile.distanceCells
	var exported_mask_alias: Array = snapshot[0].supportMask
	var exported_distance_alias: Array = snapshot[0].distanceCells
	input_mask_alias.fill(0)
	input_distance_alias.fill(18.0)
	exported_mask_alias.fill(0)
	exported_distance_alias.fill(18.0)
	var retained := world.generated_site_profile_for_cell(origin)
	check("raster_input_and_export_alias_isolation", Profile.contains_core(retained,origin) and Profile.surface_y(retained,origin,level+100.0) == level)
	check("retained_raster_aliases_enforce_readonly", retained.supportMask.is_read_only() and retained.distanceCells.is_read_only())
	profile.level += 100.0
	snapshot[0].level += 200.0
	check("snapshot_input_isolation", world.base_surface_y_for_cell(Vector3i(origin.x+1,0,origin.y)) == level)
	var overlapping: Dictionary = world.generated_site_profiles_snapshot()[0].duplicate(true)
	overlapping.siteId = "overlap"
	check("overlap_rejected", world.configure_generated_site_profiles([world.generated_site_profiles_snapshot()[0],overlapping]).get("reason") == "overlapping_generated_site_profiles")
	check("bad_seed_rejected", not world.configure_generated_site_profiles([{"version":1,"worldSeed":"wrong"}]).ready)
	check("failed_admission_preserves_previous", world.generated_site_profiles_snapshot().size() == 1 and world.base_surface_y_for_cell(Vector3i(origin.x,0,origin.y)) == level)
	var edit_cell := Vector3i(origin.x, floori(level/Context.CELL)-1, origin.y)
	world.terrain_volume_service.set_cell_state(edit_cell, {"material":"air","solid":false,"density":-Context.CELL,"biome":"plains","fluid":"","metadata":{"saveDelta":true,"terrainMeshAffects":true}}, "contract_durable_edit", false)
	var edits_before: PackedByteArray = var_to_bytes(world.terrain_volume_service.edited_cells)
	world.configure_generated_site_profiles(world.generated_site_profiles_snapshot())
	check("durable_edits_unchanged", var_to_bytes(world.terrain_volume_service.edited_cells) == edits_before and not world.terrain_volume_service.get_cell_state(edit_cell).solid)
	var template := Context.new()
	template.setup_from_main(context)
	check("native_profile_snapshot_deep_immutable", template.generated_site_profiles.is_read_only() and template.generated_site_profiles[0].is_read_only() and template.generated_site_profiles[0].groundRootPoints.is_read_only())
	check("native_raster_aliases_enforce_readonly", template.generated_site_profiles[0].supportMask.is_read_only() and template.generated_site_profiles[0].distanceCells.is_read_only())
	var worker := World.new()
	var clone = template.clone_for_worker()
	worker.setup(clone)
	clone.set_generator(worker)
	for z in range(origin.y-21,origin.y+22):
		for x in range(origin.x-21,origin.x+22):
			check("main_worker_height_identity", world.base_surface_y_for_cell(Vector3i(x,0,z)) == worker.base_surface_y_for_cell(Vector3i(x,0,z)))
	var generator := Generator.new()
	generator.setup(template)
	var buffer := VoxelBuffer.new()
	buffer.create(4,4,4)
	var block_origin := edit_cell - Vector3i(1,1,1)
	generator._generate_block(buffer, block_origin, 0)
	for z in range(4):
		for y in range(4):
			for x in range(4):
				var cell := block_origin + Vector3i(x,y,z)
				var position := Vector3(cell) * Context.CELL
				var base := world.terrain_reference_surface_y_at(position)
				var density := world.density_from_components(position, base, base)
				if cell == edit_cell: density = -Context.CELL
				check("native_density_identity", absf(buffer.get_voxel_f(x,y,z,VoxelBuffer.CHANNEL_SDF) + density/Context.CELL) < 0.01)
	check("native_preserves_edit", buffer.get_voxel_f(1,1,1,VoxelBuffer.CHANNEL_SDF) > 0.0)
	# A retained native snapshot must not change when the main generation source
	# installs a later snapshot. This is data isolation, not live admission safety.
	world.configure_generated_site_profiles([])
	check("retained_worker_revision_unchanged", worker.base_surface_y_for_cell(Vector3i(origin.x+2,0,origin.y+2)) == level and template.generated_site_profiles.size() == 1)
	_real_geometry_profile(context.seed_text)
	_grounding_contract(manifest)
	var passed := not checks.values().has(false)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"evidenceLevel":"synthetic_manifest_production_volume_service_contract","passed":passed,"checks":checks,"doesNotProve":"No live terrain mesh, player collision, visual, or Citadel placement acceptance."}, "\t"))
	context.world_generation_system = null # fixture-only owning back-reference
	print("TERRAIN PROFILE CONTRACT ", passed, " ", checks)
	quit(0 if passed else 1)

func _grounding_contract(manifest: Dictionary) -> void:
	var normal := Profile.create(manifest,"unit","unit",Vector2i.ZERO,0.0,18)
	var decorative := manifest.duplicate(true)
	decorative.footprintCells = Rect2i(-100,-100,201,201)
	decorative.localBounds = AABB(Vector3(-135,0,-135),Vector3(270,100,270))
	decorative.trees = [{"position":Vector3(50,1,50),"canopyRadius":80.0}]
	var enlarged := Profile.create(decorative,"unit","unit",Vector2i.ZERO,0.0,18)
	check("decorative_bounds_do_not_change_terrain", enlarged.ready and normal.profile.coreCells == enlarged.profile.coreCells and normal.profile.envelopeCells == enlarged.profile.envelopeCells and normal.profile.supportMask == enlarged.profile.supportMask and normal.profile.distanceCells == enlarged.profile.distanceCells)
	check("reservation_extent_is_separate", enlarged.profile.reservationCells != normal.profile.reservationCells)
	var two_roots := manifest.duplicate(true)
	two_roots.groundRoots = []
	for offset in [-35.0,35.0]:
		var root: Dictionary = manifest.groundRoots[0].duplicate(true)
		for index in range(4): root.corners[index].x += offset
		two_roots.groundRoots.append(root)
	two_roots.footprintCells = Rect2i(-40,-4,81,9)
	var gap := Profile.create(two_roots,"unit","gap",Vector2i.ZERO,0.0,18)
	check("root_union_does_not_fill_enclosing_rectangle", gap.ready and not Profile.contains_core(gap.profile,Vector2i.ZERO) and Profile.surface_y(gap.profile,Vector2i.ZERO,10.0) == 10.0)
	two_roots.accessReservations = [AABB(Vector3(-3,0,-2),Vector3(6,3,4))]
	var clear := Profile.create(two_roots,"unit","gap",Vector2i.ZERO,0.0,18)
	check("declared_void_clears_terrain_without_fake_support", clear.ready and Profile.surface_y(clear.profile,Vector2i.ZERO,10.0) == 0.0 and not Profile.contains_core(clear.profile,Vector2i.ZERO))
	two_roots.accessReservations = [AABB(Vector3(-3,-1,-2),Vector3(6,3,4))]
	check("unsupported_below_ground_void_rejected", Profile.create(two_roots,"unit","gap",Vector2i.ZERO,0.0,18).get("reason") == "unsupported_below_ground_clearance")
	# Independent brute-force oracle for the compact Euclidean distance field.
	var size := Vector2i(13,11)
	var mask := PackedByteArray()
	mask.resize(size.x*size.y)
	var sites := [Vector2i(0,0),Vector2i(8,2),Vector2i(1,9),Vector2i(12,10)]
	for site in sites: mask[site.y*size.x+site.x] = 1
	var actual: PackedFloat32Array = Profile.GroundMask._distance_field(mask,size)
	for z in range(size.y):
		for x in range(size.x):
			var expected := INF
			for site in sites: expected = minf(expected,Vector2(site).distance_to(Vector2(x,z)))
			check("distance_field_matches_brute_force", absf(actual[z*size.x+x]-expected) < 0.00001)

func _real_geometry_profile(world_seed: String) -> void:
	var result: Dictionary = preload("res://scripts/testing/buildings/BuildingSiteManifestContract.gd").run()
	check("real_source_manifest_verified", result.passed)
	if not result.passed: return
	var manifest: Dictionary = result.reference.manifest
	# Fixture source is intentionally reused only to verify real root geometry;
	# it is NOT a seed-correct runtime citadel spawn or source-generation test.
	var profile := Profile.create(manifest, world_seed, "frozen-source-diagnostic", Vector2i(1300,-1500), 40.5, 18)
	check("real_geometry_profile_created", profile.ready)
	if not profile.ready:
		print("Real geometry profile rejection: ", profile)
		return
	check("real_ground_roots_preserved", profile.profile.groundRootPoints.size() == manifest.groundRoots.size() * 4)
	for point: Vector3 in profile.profile.groundRootPoints:
		var floor_cell := Vector2i(floori(point.x / Context.CELL), floori(point.z / Context.CELL))
		for offset in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]:
			check("real_root_interpolation_support_inside_plateau", Profile.contains_core(profile.profile, floor_cell + offset) and Profile.surface_y(profile.profile, floor_cell + offset, 91.0) == 40.5)
