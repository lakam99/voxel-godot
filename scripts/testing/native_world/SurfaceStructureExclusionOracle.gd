extends SceneTree
## Direct StructureSystem exclusion-query oracle with synthetic Citadel source states.
## The 28 coordinates are an ordered decision fixture, not a live RNG replay.

const Structures = preload("res://scripts/StructureSystem.gd")
const RealAdmission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const ChunkSnapshot = preload("res://scripts/world/ActiveStructureExclusionChunkSnapshot.gd")
const REPORT_ENV := "VOXEL_SURFACE_STRUCTURE_EXCLUSION_REPORT"
const CELLS := [
	Vector2i(-5,-5), Vector2i(-4,-4), Vector2i(-3,-3), Vector2i(-2,-2),
	Vector2i(-1,-1), Vector2i(0,0), Vector2i(1,1), Vector2i(2,2),
	Vector2i(3,3), Vector2i(4,4), Vector2i(5,5), Vector2i(6,6),
	Vector2i(7,7), Vector2i(8,8), Vector2i(9,9), Vector2i(10,10),
	Vector2i(11,11), Vector2i(12,12), Vector2i(13,13), Vector2i(14,14),
	Vector2i(15,15), Vector2i(16,16), Vector2i(17,17), Vector2i(18,18),
	Vector2i(2046,2046), Vector2i(2047,2047), Vector2i(2048,2048), Vector2i(-2049,-2049),
]

class Admission extends RefCounted:
	var states := {}
	var pending_bounds := false
	var generation := 1
	func stats() -> Dictionary:
		return {"worldSeed":"oracle-seed", "generation":generation}
	func request_bounds(_bounds: Rect2i) -> Dictionary:
		return {"status":"pending" if pending_bounds else "ready",
			"reason":"preparing_citadel_terrain" if pending_bounds else ""}
	func source_state(region: Vector2i) -> Dictionary:
		return states.get(region, {"status":"absent","reason":"source_not_requested"})

var checks: Dictionary = {}

func _init() -> void:
	call_deferred("run")

func check(name: String, condition: bool) -> void:
	checks[name] = condition

func decision_rows(structures: StructureSystem) -> Array:
	var rows := []
	for index in range(CELLS.size()):
		var cell: Vector2i = CELLS[index]
		rows.append({"attempt":index,"cell":[cell.x,cell.y],
			"blocked":structures.blocks_natural_prop_at_cell(cell.x,cell.y)})
	return rows

func canonical_content(structures: StructureSystem, admission: Admission) -> String:
	var records: Array[String] = []
	for record in structures.natural_prop_exclusion_records.values():
		records.append("natural|%s|%d|%d|%d|%d" % [record.id,record.minX,record.maxX,record.minZ,record.maxZ])
	for record in structures.terrain_footprint_records.values():
		records.append("terrain|%s|%d|%d|%d|%d" % [record.id,record.minCell.x,record.maxCell.x,record.minCell.z,record.maxCell.z])
	for region in admission.states.keys():
		var state: Dictionary = admission.states[region]
		if state.get("status") not in ["ready","prepared"]:
			continue
		var rect: Rect2i = state.reservationCells
		records.append("citadel|%d|%d|%s|%s|%d|%d|%d|%d" % [region.x,region.y,
			state.sourceKey,state.sourceSignature,rect.position.x,rect.position.y,rect.size.x,rect.size.y])
	records.sort()
	return ("\n".join(records)).sha256_text()

func source(status: String, rect: Rect2i) -> Dictionary:
	return {"status":status,"sourceKey":"oracle-citadel","sourceSignature":"oracle-v1",
		"binding":{"siteId":"oracle-site","sourceKey":"oracle-citadel","generation":1},
		"reservationCells":rect}

func run() -> void:
	var real_structures := Structures.new()
	var real_admission := RealAdmission.new()
	real_admission.configure("admission-context-oracle", {}, {"regionCells":384, "spawnChance":0.0})
	check("real_admission_town_inputs_finalized", real_admission.finalize_town_inputs({}).status == "ready")
	real_structures.citadel_terrain_admission = real_admission
	real_structures.regional_source_generation = 1
	var real_irrelevant := real_structures.capture_surface_tree_exclusion_halo(0,0,0,0)
	check("real_unrequested_region_is_ready_after_exact_bounds", real_irrelevant.ready
		and real_irrelevant.boundsAdmission.status == "ready"
		and real_irrelevant.content.citadel[0].reason == "source_not_requested"
		and real_structures.surface_tree_exclusion_halo_is_current(real_irrelevant))
	var real_chunk := ChunkSnapshot.capture(real_structures, Vector2i.ZERO)
	check("real_ready_chunk_captures_unrequested_region", real_chunk.ok
		and real_chunk.boundsAdmission.status == "ready"
		and real_chunk.content.citadel[0].reason == "source_not_requested"
		and ChunkSnapshot.is_current(real_structures, real_chunk))
	real_admission.configure("admission-context-oracle", {}, {"regionCells":384, "spawnChance":0.0})
	check("admission_reconfigure_rejects_old_chunk", not ChunkSnapshot.is_current(real_structures, real_chunk))
	check("reconfigured_admission_finalized", real_admission.finalize_town_inputs({}).status == "ready")
	real_admission._fail(Vector2i.ZERO, "failed_site_outside_requested_bounds")
	var real_failed_elsewhere := real_structures.capture_surface_tree_exclusion_halo(0,0,0,0)
	check("real_failed_irrelevant_source_keeps_exact_bounds_ready", real_failed_elsewhere.ready
		and real_failed_elsewhere.boundsAdmission.status == "ready"
		and real_failed_elsewhere.content.citadel[0].status == "failed"
		and real_structures.surface_tree_exclusion_halo_is_current(real_failed_elsewhere))
	var real_failed_chunk := ChunkSnapshot.capture(real_structures, Vector2i.ZERO)
	check("real_ready_chunk_captures_irrelevant_failed_region", real_failed_chunk.ok
		and real_failed_chunk.content.citadel[0].status == "failed"
		and not ChunkSnapshot.is_current(real_structures, real_chunk))
	var structures := Structures.new()
	structures.regional_source_generation = 1
	var admission := Admission.new()
	structures.citadel_terrain_admission = admission
	var revision_before := structures.surface_prop_exclusion_records_revision()
	structures.reserve_natural_prop_exclusion(-4,-4,3,3,"natural") # inclusive [-4,-2]
	var revision_after_natural := structures.surface_prop_exclusion_records_revision()
	structures.record_structure_terrain_footprint(9,9,0.0,3,3,2,"terrain","stone",0) # inclusive [8,12]
	var revision_after_terrain := structures.surface_prop_exclusion_records_revision()
	check("owner_exclusion_revision_tracks_both_record_families",
		revision_before == 0 and revision_after_natural == 1 and revision_after_terrain == 2)
	structures.reserve_natural_prop_exclusion(-4,-4,3,3,"natural")
	check("identical_natural_record_keeps_revision",
		structures.surface_prop_exclusion_records_revision() == revision_after_terrain)
	admission.states[Vector2i.ZERO] = source("ready",Rect2i(15,15,3,3)) # half-open [15,18)
	admission.states[Vector2i(1,1)] = source("prepared",Rect2i(2048,2048,2,2))
	admission.states[Vector2i(-2,-2)] = source("ready",Rect2i(-2049,-2049,1,1))
	var chunk_snapshot := ChunkSnapshot.capture(structures, Vector2i.ZERO)
	check("chunk_snapshot_admits_canonical_local_records", chunk_snapshot.ok
		and chunk_snapshot.bounds == Rect2i(0,0,28,28)
		and chunk_snapshot.content.natural.is_empty()
		and chunk_snapshot.content.terrain.size() == 1
		and chunk_snapshot.content.citadel.size() == 1
		and ChunkSnapshot.is_current(structures, chunk_snapshot))
	var tampered_chunk := chunk_snapshot.duplicate(true)
	tampered_chunk.content.terrain[0].maxX = 100
	check("chunk_snapshot_nested_tamper_rejected", not ChunkSnapshot.is_current(structures, tampered_chunk))
	admission.pending_bounds = true
	check("chunk_snapshot_pending_bounds_rejected", not ChunkSnapshot.capture(structures, Vector2i.ZERO).ok
		and not ChunkSnapshot.is_current(structures, chunk_snapshot))
	admission.pending_bounds = false
	structures.regional_source_generation += 1
	check("chunk_snapshot_owner_generation_change_rejected", not ChunkSnapshot.is_current(structures, chunk_snapshot))
	structures.regional_source_generation -= 1
	var negative_chunk := ChunkSnapshot.capture(structures, Vector2i(-1,-1))
	check("negative_chunk_captures_natural_record", negative_chunk.ok
		and negative_chunk.content.natural.size() == 1
		and negative_chunk.content.terrain.is_empty()
		and ChunkSnapshot.is_current(structures, negative_chunk))
	var rows := decision_rows(structures)
	var expected := [false,true,true,true,false,false,false,false,false,false,false,false,false,true,true,true,true,true,false,false,true,true,true,false,false,false,true,true]
	check("all_28_ordered_decisions",rows.size()==28)
	for index in range(rows.size()):
		check("attempt_%02d"%index,rows[index].blocked==expected[index])
	check("natural_inclusive_min_max",structures.blocks_natural_prop_at_cell(-4,-4) and structures.blocks_natural_prop_at_cell(-2,-2) and not structures.blocks_natural_prop_at_cell(-1,-1))
	check("terrain_inclusive_min_max",structures.blocks_natural_prop_at_cell(8,8) and structures.blocks_natural_prop_at_cell(12,12) and not structures.blocks_natural_prop_at_cell(13,13))
	check("citadel_half_open_max",structures.blocks_natural_prop_at_cell(17,17) and not structures.blocks_natural_prop_at_cell(18,18))
	check("prepared_blocks",structures.blocks_natural_prop_at_cell(2048,2048))
	check("negative_region_floor",structures.blocks_natural_prop_at_cell(-2049,-2049) and not structures.blocks_natural_prop_at_cell(-2048,-2048))
	check("unrequested_absent_does_not_block",not structures.blocks_natural_prop_at_cell(2047,2047))
	admission.states[Vector2i(1,1)] = source("pending",Rect2i(2048,2048,2,2))
	check("pending_is_not_exclusion",not structures.blocks_natural_prop_at_cell(2048,2048))
	admission.states[Vector2i(1,1)] = source("prepared",Rect2i(2048,2048,2,2))
	admission.pending_bounds = true
	var missing_halo := structures.capture_surface_tree_exclusion_halo(2047,2047,0,1)
	check("pending_bounds_fail_closed",not missing_halo.ready and missing_halo.content.citadel.size()==4
		and not structures.surface_tree_exclusion_halo_is_current(missing_halo))
	admission.pending_bounds = false
	var irrelevant_halo := structures.capture_surface_tree_exclusion_halo(2047,2047,0,1)
	check("ready_bounds_admit_unrequested_irrelevant_regions",irrelevant_halo.ready
		and structures.surface_tree_exclusion_halo_is_current(irrelevant_halo)
		and irrelevant_halo.content.citadel.size()==4)
	admission.states[Vector2i(0,1)] = source("absent",Rect2i())
	admission.states[Vector2i(1,0)] = source("absent",Rect2i())
	var seam_halo := structures.capture_surface_tree_exclusion_halo(2047,2047,0,1)
	check("four_region_seam_admitted",seam_halo.ready and structures.surface_tree_exclusion_halo_is_current(seam_halo))
	admission.states[Vector2i(1,0)] = source("pending",Rect2i())
	check("crossed_region_pending_stales",not structures.surface_tree_exclusion_halo_is_current(seam_halo))
	admission.states[Vector2i(1,0)] = source("absent",Rect2i())
	var tampered_halo: Dictionary = seam_halo.duplicate(true)
	tampered_halo.content.citadel[0].status = "failed"
	check("copied_citadel_tamper_rejected",not structures.surface_tree_exclusion_halo_is_current(tampered_halo))
	var tampered_cell: Dictionary = seam_halo.duplicate(true)
	tampered_cell.cell = Vector2i(2046,2046)
	check("capture_cell_tamper_rejected",not structures.surface_tree_exclusion_halo_is_current(tampered_cell))
	admission.states[Vector2i(-1,-1)] = source("absent",Rect2i())
	admission.states[Vector2i(-1,0)] = source("absent",Rect2i())
	admission.states[Vector2i(0,-1)] = source("absent",Rect2i())
	var negative_halo := structures.capture_surface_tree_exclusion_halo(-1,-1,0,1)
	check("negative_zero_region_seam",negative_halo.ready and negative_halo.content.citadel.size()==4
		and structures.surface_tree_exclusion_halo_is_current(negative_halo))
	structures.reserve_natural_prop_exclusion(-31,-1,1,1,"outside-28-source")
	var outside_halo := structures.capture_surface_tree_exclusion_halo(-28,-1,3,0)
	check("outside_chunk_natural_record_captured",outside_halo.content.natural.size()==1
		and outside_halo.content.natural[0].source=="outside-28-source")
	structures.natural_prop_exclusion_records["outside-28-source:-31,-1:1x1"].maxX = -30
	check("direct_record_mutation_stales_halo",not structures.surface_tree_exclusion_halo_is_current(outside_halo))
	check("owner_revision_stales_halo",not structures.surface_tree_exclusion_halo_is_current(seam_halo))
	structures.record_structure_terrain_footprint(-32,-1,0.0,1,1,0,"outside-terrain","stone",0)
	var terrain_halo := structures.capture_surface_tree_exclusion_halo(-28,-1,0,3)
	check("outside_chunk_terrain_record_captured",terrain_halo.content.terrain.size()==1)
	var widest_halo := structures.capture_surface_tree_exclusion_halo(-28,-1,3,0)
	check("widest_coverage_includes_both_families",widest_halo.content.natural.size()==1 and widest_halo.content.terrain.size()==1)
	check("invalid_margins_fail_closed",not structures.capture_surface_tree_exclusion_halo(0,0,-1,0).ready
		and not structures.capture_surface_tree_exclusion_halo(0,0,0,4097).ready)
	var saved_binding: Variant = admission.states[Vector2i(1,1)].binding
	admission.states[Vector2i(1,1)].binding = "malformed"
	check("malformed_binding_fails_closed",not structures.capture_surface_tree_exclusion_halo(2048,2048,0,0).ready)
	admission.states[Vector2i(1,1)].binding = saved_binding
	var initial_digest := canonical_content(structures,admission)
	var initial_rows := decision_rows(structures)
	admission.states[Vector2i.ZERO].status = "prepared"
	check("ready_to_prepared_same_decisions",decision_rows(structures)==initial_rows)
	check("ready_to_prepared_same_content",canonical_content(structures,admission)==initial_digest)
	structures.reserve_natural_prop_exclusion(40,40,2,2,"a")
	structures.reserve_natural_prop_exclusion(50,50,2,2,"b")
	var ordered_digest := canonical_content(structures,admission)
	var a: Dictionary = structures.natural_prop_exclusion_records["a:40,40:2x2"]
	structures.natural_prop_exclusion_records.erase("a:40,40:2x2")
	structures.natural_prop_exclusion_records["a:40,40:2x2"] = a
	check("insertion_order_independent",canonical_content(structures,admission)==ordered_digest)
	var replacement: Dictionary = a.duplicate(true)
	replacement.maxX = 42
	structures.natural_prop_exclusion_records["a:40,40:2x2"] = replacement
	check("content_change_identity",canonical_content(structures,admission)!=ordered_digest)
	check("direct_map_mutation_requires_content_recheck",
		structures.surface_prop_exclusion_records_revision() == revision_after_terrain + 4)
	check("natural_reservation_does_not_advance_regional_revision",structures.regional_source_revision==2)
	var before_same_terrain := structures.surface_prop_exclusion_records_revision()
	structures.record_structure_terrain_footprint(9,9,0.0,3,3,2,"terrain","stone",0)
	check("identical_terrain_record_keeps_exclusion_revision",
		structures.surface_prop_exclusion_records_revision() == before_same_terrain)
	structures.natural_prop_exclusion_records["malformed-natural"] = {"id":"malformed-natural","minX":4}
	check("malformed_natural_fails_closed",not structures.capture_surface_tree_exclusion_halo(50,50,0,0).ready)
	structures.natural_prop_exclusion_records.erase("malformed-natural")
	structures.terrain_footprint_records["malformed-terrain"] = {"id":"malformed-terrain",
		"minCell":Vector3i(5,0,5),"maxCell":Vector3i(4,0,4)}
	check("reversed_terrain_fails_closed",not structures.capture_surface_tree_exclusion_halo(50,50,0,0).ready)
	structures.terrain_footprint_records.erase("malformed-terrain")
	admission.states[Vector2i(1,1)].binding.generation = 0
	check("zero_admission_generation_fails_closed",not structures.capture_surface_tree_exclusion_halo(2048,2048,0,0).ready)
	admission.states[Vector2i(1,1)].binding.generation = 1
	# reset() requires a configured main. Test the exact reset clearing effect by
	# comparing the record stores, without invoking unrelated world setup.
	structures.natural_prop_exclusion_records.clear()
	structures.terrain_footprint_records.clear()
	admission.states.clear()
	check("manually_cleared_source_unblocks",decision_rows(structures).all(func(row): return not row.blocked))
	check("manually_cleared_source_changes_identity",canonical_content(structures,admission)!=initial_digest)
	var passed := not checks.values().has(false)
	var path := OS.get_environment(REPORT_ENV).strip_edges()
	if path.is_empty(): path = ProjectSettings.globalize_path("res://artifacts/native-world-backend/surface-structure-exclusion-oracle.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var report := {"runnerId":"surface_structure_exclusion_oracle","finished":true,"passed":passed,
		"scope":"direct_structure_exclusion_and_chunk_capture_real_admission_plus_synthetic_states_not_live_gameplay",
		"checks":checks,"orderedDecisions":rows,"expectedBlocked":expected,
		"initialContentDigest":initial_digest,"permutedContentDigest":ordered_digest}
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file == null:
		push_error("Could not write oracle report: "+path)
		quit(2)
		return
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print(JSON.stringify({"report":path,"passed":passed,"checks":checks.size()}))
	quit(0 if passed else 1)
