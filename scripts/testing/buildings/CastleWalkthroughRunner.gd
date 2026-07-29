extends "res://scripts/testing/buildings/FurnishedCottageWalkthroughRunner.gd"

## Interactive exterior/interior gate for the castle PoC. It reuses the
## established real player, BuildingPartPublisher collision and
## DoorPortalService; this fixture contributes only a larger review world and
## a deterministic castle recipe.

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const CastleFurnishingPlannerScript := preload("res://scripts/buildings/CastleFurnishingPlanner.gd")

var registered_door_count := 0
var selected_citadel_scale := 6.0
var walkthrough_ground_body: StaticBody3D
var walkthrough_ground_shape: CollisionShape3D
var walkthrough_ground_mesh: PlaneMesh


func _ready() -> void:
	read_arguments()
	build_world()
	build_hud()
	await rebuild_fixture(false)
	spawn_player()
	update_hud()
	if not report_path.is_empty():
		call_deferred("write_automated_report")


func read_arguments() -> void:
	selected_seed = 208158
	selected_style = "masonry"
	super.read_arguments()
	var args := OS.get_cmdline_user_args()
	for index in range(args.size()):
		if String(args[index]) == "--citadel-scale" and index + 1 < args.size():
			selected_citadel_scale = clampf(float(String(args[index + 1])), 0.0, 6.0)
	# Castle compounds always use their masonry construction grammar.
	selected_style = "masonry"
	capture_path = OS.get_environment("VOXEL_CASTLE_WALKTHROUGH_CAPTURE")
	report_path = OS.get_environment("VOXEL_CASTLE_WALKTHROUGH_REPORT")


func build_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.24, 0.37, 0.47)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.55, 0.63, 0.74)
	environment.ambient_light_energy = 0.72
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -36.0, 0.0)
	sun.light_color = Color(1.0, 0.82, 0.61)
	sun.light_energy = 1.52
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 240.0
	add_child(sun)
	walkthrough_ground_body = StaticBody3D.new()
	walkthrough_ground_body.name = "CastleWalkthroughGround"
	walkthrough_ground_shape = CollisionShape3D.new()
	var ground_box := BoxShape3D.new()
	ground_box.size = Vector3(240.0, 0.50, 240.0)
	walkthrough_ground_shape.shape = ground_box
	walkthrough_ground_shape.position.y = -0.25
	walkthrough_ground_body.add_child(walkthrough_ground_shape)
	add_child(walkthrough_ground_body)
	var ground := MeshInstance3D.new()
	walkthrough_ground_mesh = PlaneMesh.new()
	walkthrough_ground_mesh.size = Vector2(240.0, 240.0)
	ground.mesh = walkthrough_ground_mesh
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.22, 0.36, 0.20)
	ground_material.roughness = 0.96
	ground.material_override = ground_material
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)


func rebuild_fixture(reset_player := true) -> void:
	if is_rebuilding:
		return
	is_rebuilding = true
	if player != null and is_instance_valid(player):
		player.set_physics_process(false)
	set_loading("Clearing previous castle")
	await get_tree().process_frame
	if cottage_root != null and is_instance_valid(cottage_root):
		cottage_root.queue_free()
	if furnishing_root != null and is_instance_valid(furnishing_root):
		furnishing_root.queue_free()
	cottage_root = null
	furnishing_root = null
	front_door = null
	door_service = null
	registered_door_count = 0
	await get_tree().process_frame

	set_loading("Sampling castle recipe for seed %d" % selected_seed)
	# Give the loading text one visible frame before the deterministic recipe
	# builder performs its bounded synchronous sampling work.
	await get_tree().process_frame
	blueprint = CastleCompoundBlueprintBuilderScript.build(selected_seed, {
		"biome": "forest",
		# Match the exterior Castle PoC context so a seed identifies the same
		# compound in both review modes rather than a walkthrough-only variant.
		"siteKey": "river-citadel",
		"citadelScale": selected_citadel_scale
	})
	configure_walkthrough_ground()
	await get_tree().process_frame

	set_loading("Publishing castle collision and materials (%d records)" % blueprint.parts.size())
	cottage_root = Node3D.new()
	cottage_root.name = "PublishedCastleWalkthrough"
	add_child(cottage_root)
	building_publisher = BuildingPartPublisherScript.new()
	await building_publisher.publish_incremental(blueprint, cottage_root, loading_frame_budget(blueprint.parts.size()))

	set_loading("Planning seeded courtyard residences")
	# Each courtyard home is furnished by the same source family grammar that
	# constructed it.  The castle planner only applies the residence transform
	# and namespace, then the shared publisher owns visual/collision publication.
	await get_tree().process_frame
	furnishing_plan = CastleFurnishingPlannerScript.build(blueprint, selected_seed * 7919 + 37)
	furnishing_root = Node3D.new()
	furnishing_root.name = "PublishedCastleWalkthroughFurnishings"
	add_child(furnishing_root)
	furnishing_publisher = FurnishingPublisherScript.new()
	set_loading("Publishing seeded courtyard furnishings (%d records)" % furnishing_plan.parts.size())
	await furnishing_publisher.publish_incremental(furnishing_plan, furnishing_root, loading_frame_budget(furnishing_plan.parts.size()))

	set_loading("Registering gate and building doors")
	door_service = DoorPortalServiceScript.new()
	door_service.setup(self, self)
	registered_door_count = register_castle_doors()
	front_door = find_front_door()
	await get_tree().process_frame
	if reset_player and player != null and is_instance_valid(player):
		place_player_at_entry()
		player.set_physics_process(true)
	is_rebuilding = false
	set_loading_visible(false)
	update_hud()


func configure_walkthrough_ground() -> void:
	if blueprint == null:
		return
	# The gate entry sits outside the curtain wall. The walkable review plane
	# must therefore grow with the same compound recipe as the city, or a large
	# citadel would begin beyond the only real ground/collision surface.
	var span := maxf(float(blueprint.recipe.get("width", 80.0)), float(blueprint.recipe.get("depth", 80.0))) + 56.0
	if walkthrough_ground_shape != null and walkthrough_ground_shape.shape is BoxShape3D:
		(walkthrough_ground_shape.shape as BoxShape3D).size = Vector3(span, 0.50, span)
	if walkthrough_ground_mesh != null:
		walkthrough_ground_mesh.size = Vector2(span, span)


func loading_frame_budget(record_count: int) -> int:
	# Keep the worst citadel fixture below roughly a dozen loading-screen seconds
	# without reverting to synchronous publication. The same real publisher still
	# yields between chunks, so loading text and the OS window continue updating.
	return clampi(ceili(float(maxi(1, record_count)) / 720.0), 6, 64)


func register_castle_doors() -> int:
	if cottage_root == null or door_service == null:
		return 0
	var count := 0
	for child in cottage_root.get_children():
		if child is StaticBody3D and String((child as StaticBody3D).get_meta("building_part_kind", "")) == "door":
			door_service.register_door(child)
			count += 1
	return count


func place_player_at_entry() -> void:
	if player == null or blueprint == null:
		return
	var grammar: Dictionary = (blueprint.recipe.get("castleGrammar", {}) as Dictionary)
	var courtyard_depth := float(grammar.get("courtyardDepth", 58.0))
	var gate_depth := float(grammar.get("gateDepth", 10.0))
	# The gatehouse projects almost a full gate-depth outside the curtain wall.
	# Start beyond its actual exterior gate face, on the shared entry steps.
	var exterior_gate_z := -courtyard_depth * 0.5 - gate_depth * 0.92
	player.position = Vector3(0.0, 0.04, exterior_gate_z - 2.65)
	player.rotation.y = PI
	if player.camera_pitch != null:
		player.camera_pitch.rotation.x = 0.0


func find_front_door() -> StaticBody3D:
	if cottage_root == null:
		return null
	for child in cottage_root.get_children():
		if child is StaticBody3D and String((child as StaticBody3D).get_meta("building_part_id", "")) == "castle_gatehouse_portcullis":
			return child as StaticBody3D
	return null


func request_focused_door_use() -> void:
	var door := focused_door()
	if door == null or door_service == null or player == null:
		interaction_text = "Look at the portcullis or a painted building door to use it"
		return
	var portal = door_service.portal_for_door(door)
	var is_open := portal != null and String(portal.state) == "open"
	var result = door_service.request_door_state(door, not is_open, player, "player", {"actors": [player]})
	interaction_text = "Door %s" % String(result.reason).replace("_", " ") if result != null else "Door request was unavailable"


func _process(delta: float) -> void:
	if is_rebuilding:
		loading_elapsed += delta
		update_loading_label()
		return
	if door_service != null and player != null:
		door_service.process(delta, [player])
	var door := focused_door()
	if door != null and door_service != null:
		var portal = door_service.portal_for_door(door)
		interaction_text = "[E] Close door" if portal != null and String(portal.state) == "open" else "[E] Open door"
	else:
		interaction_text = "Open the portcullis, then walk through the gatehouse"
	update_hud()


func update_loading_label() -> void:
	if loading_label == null:
		return
	var dot_count := int(floor(loading_elapsed * 4.0)) % 4
	loading_label.text = "LOADING SEEDED CASTLE\n%s%s\n\nPublishing through frame-sized batches" % [loading_message, ".".repeat(dot_count)]


func update_hud() -> void:
	if status_label == null:
		return
	var gate_state := "UNAVAILABLE"
	if door_service != null and front_door != null:
		var portal = door_service.portal_for_door(front_door)
		if portal != null:
			gate_state = String(portal.state).to_upper()
	var recipe: Dictionary = blueprint.recipe if blueprint != null else {}
	var grammar: Dictionary = recipe.get("castleGrammar", {}) as Dictionary
	var courtyard_program: Array = grammar.get("courtyardProgram", []) as Array
	status_label.text = "CASTLE WALKTHROUGH  |  %s\nseed %d  -  %.1fm x %.1fm  -  scale %.2fx  -  %d city buildings  -  %d doors registered  |  Gate: %s\n[WASD] move  [Shift] sprint  [Space] jump  [E] use gate/door  [R] next seed  [Shift+R] previous  [Esc] release mouse\nClimb the generated stone steps, raise the portcullis, then explore the shared Golden-Lane streets and spacious keep district. %s" % [String(grammar.get("profile", "fortress")).replace("_", " ").to_upper(), selected_seed, float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0)), float(grammar.get("grandScale", 1.0)), courtyard_program.size(), registered_door_count, gate_state, interaction_text]


func write_automated_report() -> void:
	# The headed capture proves publication/focus.  This direct service check
	# covers the shared gate's logical open/close contract only; manual movement
	# through the real steps and gate remains the acceptance evidence.
	for _frame in range(4):
		await get_tree().process_frame
	var gate_portal_check := await verify_gate_portal_contract()
	var courtyard_entry_check := verify_published_courtyard_entry_orientation()
	var expected_residences := (blueprint.recipe.get("courtyardResidences", []) as Array).size() if blueprint != null else 0
	var courtyard_furnishing := CastleFurnishingPlannerScript.summary(furnishing_plan, expected_residences)
	var report := {
		"runnerId": "castle_walkthrough",
		"evidenceLevel": "headed-fixture-startup + published-door transform audit + direct door-service contract",
		"status": "passed" if blueprint != null and front_door != null and registered_door_count >= 2 and bool(gate_portal_check.get("passed", false)) and bool(courtyard_entry_check.get("passed", false)) and bool(courtyard_furnishing.get("allResidencesFurnished", false)) and not is_rebuilding else "failed",
		"seed": selected_seed,
		"recipe": blueprint.recipe if blueprint != null else {},
		"buildingPublication": building_publisher.summary() if building_publisher != null else {},
		"furnishingPublication": furnishing_publisher.summary() if furnishing_publisher != null else {},
		"courtyardFurnishing": courtyard_furnishing,
		"registeredDoorCount": registered_door_count,
		"gatePortalCheck": gate_portal_check,
		"courtyardEntryCheck": courtyard_entry_check,
		"loadingVisible": loading_overlay.visible if loading_overlay != null else false,
		"notes": "Confirms startup of shared castle collision, published inward-facing courtyard doors, real gate steps, portcullis publication and deterministic transformed furnishings for every composed courtyard residence. It does not automate player movement or player input."
	}
	if not capture_path.is_empty():
		get_viewport().get_texture().get_image().save_png(capture_path)
		report["capturePath"] = capture_path
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	get_tree().quit(0 if String(report.get("status", "failed")) == "passed" else 1)


func verify_published_courtyard_entry_orientation() -> Dictionary:
	if cottage_root == null or blueprint == null:
		return {"passed": false, "reason": "missing_castle_publication"}
	var grammar: Dictionary = blueprint.recipe.get("castleGrammar", {}) as Dictionary
	var expected_count := (grammar.get("courtyardProgram", []) as Array).size()
	var errors: Array[String] = []
	var planned_residences_by_id := {}
	for spec_value in blueprint.recipe.get("courtyardResidences", []) as Array:
		if spec_value is Dictionary:
			var spec: Dictionary = spec_value as Dictionary
			planned_residences_by_id[String(spec.get("id", ""))] = spec
	var entry_count := 0
	for child in cottage_root.get_children():
		if not child is StaticBody3D:
			continue
		var door := child as StaticBody3D
		if String(door.get_meta("building_semantic", "")) != "castle_courtyard_building_door":
			continue
		entry_count += 1
		var owner_id := String(door.get_meta("building_part_id", "")).get_slice("__", 0)
		if owner_id.begins_with("castle_"):
			owner_id = owner_id.trim_prefix("castle_")
		var owner_spec: Dictionary = planned_residences_by_id.get(owner_id, {}) as Dictionary
		var front_direction := String(owner_spec.get("frontDirection", ""))
		var inward_direction := Vector3(-signf(door.global_position.x), 0.0, 0.0)
		match front_direction:
			"north":
				inward_direction = Vector3(0.0, 0.0, -1.0)
			"south":
				inward_direction = Vector3(0.0, 0.0, 1.0)
			"east":
				inward_direction = Vector3(1.0, 0.0, 0.0)
			"west":
				inward_direction = Vector3(-1.0, 0.0, 0.0)
		var rendered_forward := -door.global_transform.basis.z.normalized()
		if inward_direction.length_squared() < 0.01 or rendered_forward.dot(inward_direction) <= 0.98:
			errors.append(String(door.get_meta("building_part_id", door.name)))
	return {
		"passed": entry_count == expected_count and errors.is_empty(),
		"expectedCount": expected_count,
		"publishedCount": entry_count,
		"misorientedDoorIds": errors
	}


func verify_gate_portal_contract() -> Dictionary:
	if front_door == null or door_service == null or player == null:
		return {"passed": false, "reason": "missing_gate_or_service"}
	var pivot := front_door.get_node_or_null("DoorPivot") as Node3D
	var collision: CollisionShape3D = null
	for child in front_door.get_children():
		if child is CollisionShape3D:
			collision = child as CollisionShape3D
			break
	if pivot == null or collision == null:
		return {"passed": false, "reason": "missing_gate_leaf_geometry", "pivotPresent": pivot != null, "collisionPresent": collision != null}
	var closed_position := pivot.position
	var opened = door_service.request_door_state(front_door, true, player, "player", {"actors": [player]})
	var raised_position := pivot.position
	var raised := raised_position.y > closed_position.y + 0.10
	var collision_clear := collision.disabled
	var opened_ok := opened != null and String(opened.reason) in ["opened", "already_open"]
	# Let PhysicsServer consume the disabled leaf before asking the same live
	# collision world whether a player capsule can occupy the gate passage.
	await get_tree().physics_frame
	var physics_blockers := open_gate_collision_blockers()
	var physics_clear := physics_blockers.is_empty()
	var traversal_blocker := await open_gate_traversal_blocker()
	var traversal_clear := traversal_blocker.is_empty()
	var closed = door_service.request_door_state(front_door, false, player, "player", {"actors": [player]})
	var restored := is_equal_approx(pivot.position.y, closed_position.y)
	var collision_restored := not collision.disabled
	var closed_ok := closed != null and String(closed.reason) in ["closed", "already_closed"]
	return {
		"passed": opened_ok and raised and collision_clear and physics_clear and traversal_clear and closed_ok and restored and collision_restored,
		"opened": opened_ok,
		"raised": raised,
		"collisionClear": collision_clear,
		"physicsClear": physics_clear,
		"physicsBlockers": physics_blockers,
		"traversalClear": traversal_clear,
		"traversalBlocker": traversal_blocker,
		"closed": closed_ok,
		"restored": restored,
		"collisionRestored": collision_restored
	}


func open_gate_collision_blockers() -> Array[String]:
	if front_door == null or get_world_3d() == null:
		return ["missing_gate_collision_world"]
	var shape := CapsuleShape3D.new()
	shape.radius = 0.30
	shape.height = 1.70
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var gate_size := Vector3.ONE
	for child in front_door.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is BoxShape3D:
			gate_size = ((child as CollisionShape3D).shape as BoxShape3D).size
			break
	var capsule_center_y := front_door.global_position.y - gate_size.y * 0.5 + shape.height * 0.5
	# Probe just inside the raised grille, halfway through the gatehouse, and at
	# the exit into the courtyard.  These are physics-world probes, not a
	# metadata assertion, so every returned named part is a real blocker.
	var probe_zs: Array[float] = [front_door.global_position.z + 0.36, front_door.global_position.z + 4.20, front_door.global_position.z + 9.20]
	var blockers: Array[String] = []
	for probe_z in probe_zs:
		query.transform = Transform3D(Basis.IDENTITY, Vector3(front_door.global_position.x, capsule_center_y, probe_z))
		for hit in get_world_3d().direct_space_state.intersect_shape(query, 24):
			var body := hit.get("collider") as Node
			if body == null or body == front_door:
				continue
			var kind := String(body.get_meta("building_part_kind", ""))
			if kind in ["foundation", "floor", "ramp"]:
				continue # Walking support contacts are not passage blockers.
			var identifier := String(body.get_meta("building_part_id", body.name))
			if not blockers.has(identifier):
				blockers.append(identifier)
	return blockers


func open_gate_traversal_blocker() -> String:
	if player == null or front_door == null:
		return "missing_player_or_gate"
	var gate_size := Vector3.ONE
	for child in front_door.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is BoxShape3D:
			gate_size = ((child as CollisionShape3D).shape as BoxShape3D).size
			break
	var original_transform := player.global_transform
	# Test a real CharacterBody3D sweep from just inside the lifted grille all
	# the way through the gatehouse.  It is deliberately test-only: this reports
	# the actual blocking collider without moving the visible player fixture.
	player.global_position = Vector3(front_door.global_position.x, front_door.global_position.y - gate_size.y * 0.5 + 0.07, front_door.global_position.z + 0.28)
	await get_tree().physics_frame
	var hit := player.move_and_collide(Vector3(0.0, 0.0, 15.0), true)
	player.global_transform = original_transform
	await get_tree().physics_frame
	if hit == null:
		return ""
	var collider := hit.get_collider() as Node
	return String(collider.get_meta("building_part_id", collider.name)) if collider != null else "unnamed_gate_passage_collision"
