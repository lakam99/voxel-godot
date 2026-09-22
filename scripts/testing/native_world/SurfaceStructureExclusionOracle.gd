extends SceneTree
## Direct StructureSystem exclusion-query oracle with synthetic Citadel source states.
## The 28 coordinates are an ordered decision fixture, not a live RNG replay.

const Structures = preload("res://scripts/StructureSystem.gd")
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
		"reservationCells":rect}

func run() -> void:
	var structures := Structures.new()
	var admission := Admission.new()
	structures.citadel_terrain_admission = admission
	structures.reserve_natural_prop_exclusion(-4,-4,3,3,"natural") # inclusive [-4,-2]
	structures.record_structure_terrain_footprint(9,9,0.0,3,3,2,"terrain","stone",0) # inclusive [8,12]
	admission.states[Vector2i.ZERO] = source("ready",Rect2i(15,15,3,3)) # half-open [15,18)
	admission.states[Vector2i(1,1)] = source("prepared",Rect2i(2048,2048,2,2))
	admission.states[Vector2i(-2,-2)] = source("ready",Rect2i(-2049,-2049,1,1))
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
	check("natural_reservation_does_not_advance_regional_revision",structures.regional_source_revision==1)
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
		"scope":"direct_structure_query_synthetic_citadel_states_not_live_gameplay",
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
