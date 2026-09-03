extends SceneTree
## Pure dimensions and actual house-producer contract, not live acceptance.
const Layout = preload("res://scripts/buildings/StreetHouseOpeningLayout.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Dimensions = preload("res://scripts/buildings/ConstructionBearingDimensions.gd")
const Connection = preload("res://scripts/buildings/OpeningHeadConnectionRecipe.gd")
var checks := {}
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("STREET_OPENING_LAYOUT_REPORT")
	if not output.is_absolute_path(): quit(2); return
	var minimum := Layout.minimum_window_offset()
	var inner := minimum - Layout.WINDOW_WIDTH * 0.5
	var patch_edge := (inner + Layout.DOOR_WIDTH * 0.5) * 0.5 - Dimensions.GRAVITY_PATCH_MAX_HALF
	# Check the actual gravity-seat requirement. Construction padding is extra
	# room, not another validator threshold to reproduce with reordered doubles.
	checks.gravity_patch_outside_access = patch_edge > Layout.protected_half_span() + Blueprint.PHYSICAL_CONTACT_MARGIN
	checks.two_padded_socket_domains_fit = inner - Layout.ACCESS_WIDTH * 0.5 >= 4.0 * (Dimensions.LOWER_CORBEL_SOCKET_HALF.z + Dimensions.CONNECTION_PADDING)
	checks.sweep_below_assembly_excluded = not Layout.bearing_height_overlap(AABB(Vector3(0,0,0),Vector3(1,1,1)),1.5,2.0)
	checks.sweep_touching_assembly_retained = Layout.bearing_height_overlap(AABB(Vector3(0,0,0),Vector3(1,1.5,1)),1.5,2.0)
	checks.sweep_overlapping_assembly_retained = Layout.bearing_height_overlap(AABB(Vector3(0,1.4,0),Vector3(1,0.2,1)),1.5,2.0)
	checks.sweep_above_assembly_excluded = not Layout.bearing_height_overlap(AABB(Vector3(0,2.1,0),Vector3(1,1,1)),1.5,2.0)
	for height in [6.2,6.4,7.2,9.3,12.4]:
		var top := Layout.stone_base_height(height)
		var bottom := top-Dimensions.LOWER_BEARING_HEIGHT
		for end_index in range(2):
			var low := -0.45 if end_index==0 else 0.0
			var high := 0.0 if end_index==0 else 0.45
			var placed := Connection._place_connection([0.0,bottom,low,0.3,top,high],[-0.7,0.0,-1.0,-0.3,3.0,1.0],Vector3(-0.5,(bottom+top)*0.5,(low+high)*0.5),Dimensions.LOWER_CORBEL_SOCKET_HALF,[],{"satPairs":0})
			var key := "corbel_%s_%d_within_sill_y" % [str(height),end_index]
			checks[key]=placed.get("ready",false)
			if checks[key]:
				var actual := Connection._bounds_values(placed.end.position,placed.end.size)
				checks[key]=actual[1]>=bottom and actual[4]<=top
	for depth in [0.0, -1.0, NAN, INF, Layout.minimum_depth() - 0.00001]:
		var b = _blueprint()
		var before := var_to_bytes(b.snapshot())
		checks["invalid_%s_rejected_without_emission" % str(depth)] = not Urban.add_street_house(b,"house",Vector3.ZERO,8.0,depth,6.2,1.0,0.62,"painted_brick_cream",0.0) and before == var_to_bytes(b.snapshot())
	var index := 0
	for depth in [Layout.minimum_depth(), 6.9426, 8.2, 9.45, 12.0]:
		for side in [-1.0, 1.0]:
			var b = _blueprint()
			var center := Vector3(side * 7.0, 0.0, -38.43338)
			var prefix := "case_%02d" % index
			checks[prefix+"_emits"] = Urban.add_street_house(b,"house",center,8.0,depth,6.2,side,0.62,"painted_brick_cream",0.0)
			var selected: Dictionary = Layout.prepare(depth)
			checks[prefix+"_old_offset_preserved_when_sufficient"] = selected.windowOffset == maxf(minf(depth * 0.25,2.2),minimum)
			var left = Urban.StreetHouseStructuralManifestScript.find_part(b,"house_window_01_-1")
			var right = Urban.StreetHouseStructuralManifestScript.find_part(b,"house_window_01_1")
			var box = Urban.StreetHouseStructuralManifestScript.find_part(b,"house_window_box")
			checks[prefix+"_windows_and_box_share_offset"] = left != null and right != null and box != null and left.position.z == Vector3(0,0,center.z-selected.windowOffset).z and right.position.z == Vector3(0,0,center.z+selected.windowOffset).z and box.position.z == left.position.z
			var access: Dictionary = b.rooms[0].accesses[0]
			checks[prefix+"_access_width_preserved"] = access.size == Vector3(1.86,2.18,1.86)
			var door = Urban.StreetHouseStructuralManifestScript.find_part(b,"house_door")
			checks[prefix+"_door_geometry_preserved"] = door != null and door.position.z == center.z and door.size == Vector3(0.14,2.5,1.25)
			var replay = _blueprint()
			checks[prefix+"_deterministic"] = Urban.add_street_house(replay,"house",center,8.0,depth,6.2,side,0.62,"painted_brick_cream",0.0) and var_to_bytes(b.snapshot()) == var_to_bytes(replay.snapshot())
			index += 1
	var report := {"passed":checks.values().all(func(value):return value==true),"checks":checks,"minimumWindowOffset":minimum,"minimumDepth":Layout.minimum_depth(),"scope":"Source-only dimensions and actual producer; no full-source structural or visual/gameplay acceptance."}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t",true,true)); file.flush()
	var saved := file.get_error()==OK; file.close()
	quit(0 if saved and report.passed else 1)
func _blueprint():
	var b = Blueprint.new("opening_layout_contract",541151883,"timber")
	b.set_recipe({"foundationHeight":0.62,"courtyardResidences":[]})
	Urban.reset_street_house_structural_manifest(b)
	return b
