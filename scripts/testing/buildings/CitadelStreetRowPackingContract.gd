extends SceneTree
## Actual producer records, source-only. Never visual/physics/gameplay acceptance.
const Composer = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
var checks := {}
var evidence := {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var input := OS.get_environment("CITADEL_PACKING_SOURCE")
	var digest := OS.get_environment("CITADEL_PACKING_SOURCE_SHA")
	var report := OS.get_environment("CITADEL_PACKING_REPORT")
	if not input.is_absolute_path() or digest.length()!=64 or FileAccess.get_sha256(input)!=digest or not report.is_absolute_path():
		quit(2); return
	var file := FileAccess.open(input,FileAccess.READ)
	var source: Dictionary = file.get_var(false)
	file.close()
	var layout: Dictionary = source.recipe.urbanPoc
	var frozen := var_to_bytes(source)
	var geometry := Composer.street_row_geometry(layout.frontZ,layout.keepFrontZ,layout)
	checks.packing_ready = geometry.get("ready",false)
	if checks.packing_ready:
		var original := _houses(source,geometry,false)
		var packed := _houses(source,geometry,true)
		checks.source_unchanged = var_to_bytes(source)==frozen
		checks.same_eight_houses = original.size()==8 and packed.size()==8
		var original_overlaps := _overlaps(original)
		var packed_overlaps := _overlaps(packed)
		checks.original_generated_structural_overlap_reproduced = not original_overlaps.is_empty()
		checks.packed_actual_foundations_and_shells_clear = packed_overlaps.is_empty()
		var changed: Array = geometry.structuralPacking.changedRowIds
		checks.required_conflicting_rows_changed = changed.has("2") and changed.has("3")
		checks.clear_rows_preserved = true
		checks.complete_house_counts_preserved = true
		checks.source_envelopes_contain_actual_records = true
		checks.original_actual_geometry_matches_captured_failure = true
		checks.door_and_threshold_records_unchanged = true
		var baseline := {}
		for record: Dictionary in source.parts: baseline[record.id]=record
		var depths := []
		var uncontained := []
		for index in range(8):
			var before: Dictionary = original[index]
			var after: Dictionary = packed[index]
			if not changed.has(str(after.row)):
				checks.clear_rows_preserved = checks.clear_rows_preserved and var_to_bytes(before.snapshot)==var_to_bytes(after.snapshot)
			checks.complete_house_counts_preserved = checks.complete_house_counts_preserved and before.snapshot.parts.size()==after.snapshot.parts.size() and before.snapshot.rooms.size()==after.snapshot.rooms.size()
			for suffix in ["_door","_door_threshold"]:
				var before_records: Array = before.snapshot.parts.filter(func(part): return part.id==before.id+suffix)
				var after_records: Array = after.snapshot.parts.filter(func(part): return part.id==after.id+suffix)
				checks.door_and_threshold_records_unchanged = checks.door_and_threshold_records_unchanged and before_records.size()==1 and after_records.size()==1 and var_to_bytes(before_records)==var_to_bytes(after_records)
			for record: Dictionary in before.snapshot.parts:
				if not _structural(record): continue
				if not baseline.has(record.id): checks.original_actual_geometry_matches_captured_failure=false; continue
				for key in ["position","size","rotation","collision","material","kind"]:
					checks.original_actual_geometry_matches_captured_failure = checks.original_actual_geometry_matches_captured_failure and var_to_bytes(record[key])==var_to_bytes(baseline[record.id][key])
			for record: Dictionary in after.snapshot.parts:
				if not _structural(record): continue
				var allowed := false
				var section_evidence := []
				for section: Dictionary in Composer._street_house_packing_sections(after.center.x,after.width,after.side):
					var represented_size := Vector3(0,0,after.depth+section.zOverhang*2.0).z
					var vector_box := AABB(Vector3(0,0,after.center.z)-Vector3(0,0,represented_size)*0.5,Vector3(1,1,represented_size))
					# Independently reconstruct the declared envelope: nominal,
					# stored scalar, and vector/AABB faces. No tolerance waiver.
					var extent_low := minf(float(after.center.z)-after.depth*0.5-section.zOverhang,minf(float(after.center.z)-float(represented_size)*0.5,vector_box.position.z))
					var extent_high := maxf(float(after.center.z)+after.depth*0.5+section.zOverhang,maxf(float(after.center.z)+float(represented_size)*0.5,vector_box.end.z))
					if section.boundaryThickness>0.0:
						for end_side in [-1.0,1.0]:
							var slab := Vector3(0,0,section.boundaryThickness)
							var slab_center := Vector3(0,0,after.center.z+end_side*(after.depth*0.5+section.zOverhang-section.boundaryThickness*0.5))
							var slab_box := AABB(slab_center-slab*0.5,slab)
							extent_low=minf(extent_low,minf(float(slab_center.z)-float(slab.z)*0.5,slab_box.position.z))
							extent_high=maxf(extent_high,maxf(float(slab_center.z)+float(slab.z)*0.5,slab_box.end.z))
					var low_x := float(record.position.x)-float(record.size.x)*0.5
					var high_x := float(record.position.x)+float(record.size.x)*0.5
					var low_z := float(record.position.z)-float(record.size.z)*0.5
					var high_z := float(record.position.z)+float(record.size.z)*0.5
					section_evidence.append({"minX":section.minimumX,"maxX":section.maximumX,"minZ":extent_low,"maxZ":extent_high})
					if low_x>=section.minimumX and high_x<=section.maximumX and low_z>=extent_low and high_z<=extent_high: allowed=true
				if not allowed: uncontained.append({"id":record.id,"position":record.position,"size":record.size,"sections":section_evidence})
				checks.source_envelopes_contain_actual_records = checks.source_envelopes_contain_actual_records and allowed
			depths.append({"house":after.id,"before":before.depth,"after":after.depth,"parts":after.snapshot.parts.size(),"rooms":after.snapshot.rooms.size()})
		var civic := Composer.civic_commons_layout(layout.frontZ,layout.keepFrontZ,float(source.recipe.foundationHeight),layout)
		checks.civic_and_house_depths_identical = civic.get("ready",false) and var_to_bytes(civic.rowGeometry)==var_to_bytes(geometry)
		evidence={"depths":depths,"originalOverlaps":original_overlaps,"packedOverlaps":packed_overlaps,"packing":geometry.structuralPacking,"uncontained":uncontained}
	var passed := not checks.values().has(false)
	var out := FileAccess.open(report,FileAccess.WRITE)
	if out==null: quit(2); return
	out.store_string(JSON.stringify({"passed":passed,"checks":checks,"evidence":evidence,"sourceSha256":digest,
		"sourceHashes":{"composer":FileAccess.get_sha256("res://scripts/buildings/CitadelUrbanPocComposer.gd"),"packing":FileAccess.get_sha256("res://scripts/buildings/StreetRowDepthPacking.gd"),"contract":FileAccess.get_sha256("res://scripts/testing/buildings/CitadelStreetRowPackingContract.gd")},
		"evidenceLevel":"source-bound generated house geometry contract","doesNotProve":"Furniture planning, complete physical gate, rendered preservation, live collision or gameplay."},"\t"))
	out.close()
	print("Citadel street packing contract passed=",passed," checks=",checks)
	quit(0 if passed else 1)

func _houses(source: Dictionary,geometry: Dictionary,packed: bool) -> Array:
	var layout: Dictionary = source.recipe.urbanPoc
	var palette := ["painted_brick_cream","painted_brick_sage","painted_brick_rose","painted_brick_ochre","painted_brick_azure","painted_brick_plum"]
	var result: Array = []
	for row in range(4):
		for side in [-1,1]:
			var width := 7.4+float((row+side+5)%3)*0.9+float(layout.rowWidthBiases[row])
			var depth := float(geometry.rowDepths[row]) if packed else float(geometry.segmentDepth)*(0.82 if row==1 else 0.90)
			var height := 3.1*float(2+((row+(1 if side>0 else 0))%2)+int(layout.rowStoreyBonuses[row]))
			var center := Vector3(float(layout.laneCenters[row])+side*((5.8 if row!=2 else 16.0)*0.5+width*0.5),0,geometry.centers[row])
			var ground := float(source.recipe.foundationHeight)+(0.0 if row<2 else float(layout.marketTerraceRise)*float(row-1))
			var id := "urban_row_%02d_%s"%[row,"right" if side>0 else "left"]
			var blueprint = Blueprint.new("row_geometry",source.seed,source.style)
			Composer.add_street_house(blueprint,id,center,width,depth,height,float(-side),ground,palette[(row*2+(1 if side>0 else 0))%6],float(source.seed%19)/100.0-0.09+float(row)*0.012)
			result.append({"id":id,"row":row,"center":center,"width":width,"depth":depth,"side":float(-side),"snapshot":blueprint.snapshot()})
	return result

func _structural(record: Dictionary) -> bool:
	return record.id.ends_with("_foundation") or record.id.contains("_upper_shell_") or record.id.contains("_stone_shell_")

func _overlaps(houses: Array) -> Array:
	var result: Array = []
	for i in range(houses.size()):
		for j in range(i+1,houses.size()):
			if houses[i].row==houses[j].row: continue
			for a: Dictionary in houses[i].snapshot.parts:
				if not _structural(a): continue
				for b: Dictionary in houses[j].snapshot.parts:
					if not _structural(b): continue
					var overlap := Vector3.ZERO
					for axis in range(3): overlap[axis]=minf(a.position[axis]+a.size[axis]*0.5,b.position[axis]+b.size[axis]*0.5)-maxf(a.position[axis]-a.size[axis]*0.5,b.position[axis]-b.size[axis]*0.5)
					if overlap.x>0.0 and overlap.y>0.0 and overlap.z>0.0: result.append({"a":a.id,"b":b.id,"positiveOverlap":overlap})
	return result
