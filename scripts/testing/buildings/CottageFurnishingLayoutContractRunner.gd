extends SceneTree

## Focused layout contract for generated cottage furniture. It proves semantic
## room-access preservation and furnishing orientation, not a live player run.

const CottageBlueprintBuilderScript := preload("res://scripts/buildings/CottageBlueprintBuilder.gd")
const CottageFurnishingPlannerScript := preload("res://scripts/buildings/CottageFurnishingPlanner.gd")
const FurnishingPlanScript := preload("res://scripts/buildings/FurnishingPlan.gd")
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")

const SEED := 207154

var report_path := ""
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_COTTAGE_FURNISHING_LAYOUT_CONTRACT_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/cottage-furnishing-layout-contract.json")
	var styles: Array[Dictionary] = []
	for style in ["timber", "masonry"]:
		styles.append(verify_style(style))
	verify_clearance_guard()
	var passed := failures.is_empty()
	var report := {
		"runnerId": "cottage_furnishing_layout_contract",
		"evidenceLevel": "contract+headless-layout",
		"scope": "Deterministic room-aware furnishing layout. It verifies access-lane preservation, solid furnishing separation, and that wall art faces and mounts its back on an interior wall surface; it does not replace manual collision/door walkthrough evidence.",
		"seed": SEED,
		"passed": passed,
		"styles": styles,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if passed else 1)


func verify_style(style: String) -> Dictionary:
	var blueprint = CottageBlueprintBuilderScript.build(SEED, style)
	var plan = CottageFurnishingPlannerScript.build(blueprint, SEED * 7919 + 37)
	var replay = CottageFurnishingPlannerScript.build(blueprint, SEED * 7919 + 37)
	check(plan.deterministic_signature() == replay.deterministic_signature(), "%s furnishing plan is not deterministic" % style)
	var parts_by_id := {}
	var collision_parts: Array = []
	for part in plan.parts:
		if part == null:
			continue
		parts_by_id[String(part.id)] = part
		if part.collision_enabled:
			collision_parts.append(part)
	var accesses := InteriorFurnishingLayoutScript.circulation_reservations(blueprint.rooms)
	var rooms_by_id := {}
	for raw_room in blueprint.rooms:
		if raw_room is Dictionary:
			var room := raw_room as Dictionary
			rooms_by_id[String(room.get("id", ""))] = room
	var furnishing_profile := String(blueprint.recipe.get("furnishingProfile", "hearth_social"))
	for part in plan.parts:
		if part == null:
			continue
		if String(part.archetype) in ["rug", "aisle_runner"]:
			continue
		var candidate := InteriorFurnishingLayoutScript.horizontal_bounds(part.position, part.occupied_size, part.rotation, FurnishingPlanScript.PROTECTED_ACCESS_CLEARANCE)
		check(not InteriorFurnishingLayoutScript.intersects_any(candidate, accesses), "%s furnishing %s occupies a declared access lane" % [style, String(part.id)])
	for first_index in range(collision_parts.size()):
		var first = collision_parts[first_index]
		var first_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(first.position, first.occupied_size, first.rotation)
		for second_index in range(first_index + 1, collision_parts.size()):
			var second = collision_parts[second_index]
			var second_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(second.position, second.occupied_size, second.rotation)
			check(not first_bounds.intersects(second_bounds), "%s solid furnishings %s and %s overlap" % [style, String(first.id), String(second.id)])
	var action_furniture: Array = []
	for part in collision_parts:
		if float(part.recipe.get("interactionClearance", 0.0)) > 0.0:
			action_furniture.append(part)
	check(not action_furniture.is_empty(), "%s plan did not include any actionable furnishing" % style)
	for action_part in action_furniture:
		var access_depth := float(action_part.recipe.get("interactionClearance", 0.0))
		check(access_depth > 0.0, "%s action furniture %s has no interaction clearance" % [style, String(action_part.id)])
		if access_depth <= 0.0:
			continue
		var interaction_bounds := InteriorFurnishingLayoutScript.interaction_bounds(action_part.position, action_part.occupied_size, action_part.rotation, access_depth)
		check(not InteriorFurnishingLayoutScript.intersects_any(interaction_bounds, accesses), "%s action furniture %s overlaps a room access lane" % [style, String(action_part.id)])
		for other in collision_parts:
			if other == action_part:
				continue
			var other_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(other.position, other.occupied_size, other.rotation)
			check(not interaction_bounds.intersects(other_bounds), "%s action furniture %s has blocked front access from %s" % [style, String(action_part.id), String(other.id)])
	for part in plan.parts:
		if part == null or part.archetype != "candle":
			continue
		var mount_surface := String(part.recipe.get("mountSurface", ""))
		check(mount_surface in ["table", "cabinet", "chest", "shelf"], "%s candle %s is not mounted on a safe support" % [style, String(part.id)])
		check(mount_surface != "bed", "%s candle %s is mounted on a bed" % [style, String(part.id)])
	for part in plan.parts:
		if part == null or part.archetype != "wall_art":
			continue
		var wall_id := String(part.recipe.get("supportingWall", ""))
		var mount_height := float(part.recipe.get("mountHeight", 0.0))
		check(not wall_id.is_empty() and mount_height > 0.0, "%s wall art %s lacks an explicit visible mount" % [style, String(part.id)])
		check(String(part.recipe.get("mountMode", "")) == "back_face_on_wall", "%s wall art %s lacks the physical back-face mount contract" % [style, String(part.id)])
		var room: Dictionary = rooms_by_id.get(String(part.room_id), {}) as Dictionary
		check(InteriorFurnishingLayoutScript.wall_mount_back_face_is_on_wall(room, wall_id, part.position, part.rotation, part.occupied_size), "%s wall art %s is not mounted back-face-on-wall" % [style, String(part.id)])
		check(InteriorFurnishingLayoutScript.wall_mount_is_clear(plan.parts, wall_id, part.position, part.rotation, part.occupied_size, mount_height), "%s wall art %s is obscured by supporting-wall furniture" % [style, String(part.id)])
	var room_walkability: Array[Dictionary] = []
	for room in blueprint.rooms:
		if not room is Dictionary:
			continue
		var room_id := String((room as Dictionary).get("id", ""))
		var room_solids: Array = []
		for part in collision_parts:
			if String(part.room_id) == room_id:
				room_solids.append(part)
		var walkability: Dictionary = InteriorFurnishingLayoutScript.room_walkability(room as Dictionary, room_solids, CottageFurnishingPlannerScript.NPC_EGRESS_CLEARANCE)
		check(int(walkability.get("accessSeedCells", 0)) > 0, "%s room %s has no usable access seed" % [style, room_id])
		check(int(walkability.get("accessComponentCount", 0)) == 1, "%s room %s disconnects its declared access lanes" % [style, room_id])
		check(int(walkability.get("unreachableCells", 0)) == 0, "%s room %s leaves inaccessible open floor" % [style, room_id])
		room_walkability.append({"roomId": room_id, "walkability": walkability})
	var table = parts_by_id.get("table", null)
	check(table != null, "%s plan lost its dining table" % style)
	var dining_chairs: Array = []
	for part in plan.parts:
		if part != null and String(part.semantic) == "dining_chair":
			dining_chairs.append(part)
	check(not dining_chairs.is_empty(), "%s table has no dining chair" % style)
	for chair in dining_chairs:
		check(String(chair.recipe.get("tableId", "")) == "table", "%s dining chair %s lacks its table relation" % [style, String(chair.id)])
		if table != null:
			check_chair_faces_table(chair, table, style)
	check(parts_by_id.has("hearth"), "%s plan lost its hearth" % style)
	check(parts_by_id.has("bed"), "%s plan lost its bed" % style)
	check(parts_by_id.size() >= 8 and parts_by_id.size() <= 22, "%s generated an implausible furnishing count %d" % [style, parts_by_id.size()])
	for part in collision_parts:
		if not part.recipe.has("supportingWall"):
			continue
		check_wall_facing(part, style)
	return {
		"style": style,
		"furnishingSignature": hash(plan.deterministic_signature()),
		"furnishingRecords": parts_by_id.size(),
		"solidFurnishings": collision_parts.size(),
		"furnishingProfile": furnishing_profile,
		"reservedAccessLanes": accesses.size(),
		"roomWalkability": room_walkability
	}


func verify_clearance_guard() -> void:
	var plan = FurnishingPlanScript.new("protected-access-clearance", 1, "contract")
	plan.set_protected_access_reservations([AABB(Vector3(-0.5, 0.70, -2.0), Vector3(1.0, 2.0, 4.0))])
	var part = plan.add_part({
		"id": "nearby_table",
		"roomId": "room",
		"archetype": "table",
		"material": "timber_board",
		"position": Vector3(1.0, 0.70, 0.0),
		"occupiedSize": Vector3(0.8, 0.84, 0.8),
		"collision": true
	})
	check(part == null, "furnishing collision clearance can reach a protected access lane")

func check_wall_facing(part, style: String) -> void:
	var supporting_wall := String(part.recipe.get("supportingWall", ""))
	var expected := InteriorFurnishingLayoutScript.wall_facing_rotation(supporting_wall)
	var delta := absf(wrapf(part.rotation.y - expected.y, -PI, PI))
	check(delta < 0.001, "%s %s no longer faces into its supporting wall orientation" % [style, String(part.id)])


func check_chair_faces_table(chair, table, style: String) -> void:
	var toward_table: Vector3 = table.position - chair.position
	toward_table.y = 0.0
	if toward_table.length_squared() <= 0.0001:
		check(false, "%s dining chair %s overlaps its table center" % [style, String(chair.id)])
		return
	var facing := Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, chair.rotation.y)
	check(facing.normalized().dot(toward_table.normalized()) > 0.72, "%s dining chair %s does not face its table" % [style, String(chair.id)])


func check(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
