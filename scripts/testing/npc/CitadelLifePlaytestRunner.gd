extends Node

## Interactive visual composition of a seeded citadel with the production NPC
## registry, CharacterBody3D agents, collision-backed route authority and door
## portals. The fixture owns only its seed, civic orders and presentation.
## It does not introduce a citadel-specific movement, door or home system.

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const CastleFurnishingPlannerScript := preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const FurnishingPublisherScript := preload("res://scripts/buildings/FurnishingPublisher.gd")
const CitadelResidenceManifestBuilderScript := preload("res://scripts/buildings/CitadelResidenceManifestBuilder.gd")
const PlaytestSurvivalPolicyScript := preload("res://scripts/testing/PlaytestSurvivalPolicy.gd")
const NpcBipedRecipeBuilderScript := preload("res://scripts/characters/NpcBipedRecipeBuilder.gd")
const NpcBipedVisualFactoryScript := preload("res://scripts/characters/NpcBipedVisualFactory.gd")

const CELL := 1.35
const WATER_LEVEL := 11.1
const DEFAULT_SEED := 208158
const DEFAULT_CITADEL_SCALE := 1.25
const NAV_PUBLICATION_SETTLE_FRAMES := 180

var main: Node3D
var player: CharacterBody3D
var npc_system: Node
var citadel_root: Node3D
var furnishing_root: Node3D
var building_publisher
var furnishing_publisher
var blueprint
var furnishing_plan
var residence_manifest: Dictionary = {}
var fixture_origin := Vector3.ZERO
var fixture_center := Vector2i.ZERO
var fixture_level := 0.0
var selected_seed := DEFAULT_SEED
var selected_citadel_scale := DEFAULT_CITADEL_SCALE
var observed_world_phase := ""
var civic_order_elapsed := 0.0
var civic_order_round := 0
var rebuilding := false
var citizens: Array[Dictionary] = []
var status_label: Label
var loading_overlay: Control
var loading_label: Label
var loading_elapsed := 0.0
var loading_message := "Preparing Citadel Life"


func _ready() -> void:
	read_arguments()
	build_overlay()
	call_deferred("bootstrap")


func read_arguments() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size()):
		var argument := String(args[index])
		if argument == "--seed" and index + 1 < args.size():
			selected_seed = int(String(args[index + 1]))
		elif argument == "--citadel-scale" and index + 1 < args.size():
			selected_citadel_scale = clampf(float(String(args[index + 1])), 0.75, 2.25)


func bootstrap() -> void:
	set_loading("Starting the ordinary game scene")
	OS.set_environment("VOXEL_TEST_SEED", "citadel-life-world-%d" % selected_seed)
	OS.set_environment("VOXEL_PLAYTEST", "1")
	main = MAIN_SCENE.instantiate() as Node3D
	add_child(main)
	await get_tree().process_frame
	bind_scene_nodes()
	if main == null or player == null or npc_system == null:
		set_loading("Citadel Life could not bind the production player or NPC system")
		return
	configure_live_fixture()
	await wait_physics_frames(36)
	await rebuild_citadel()


func bind_scene_nodes() -> void:
	if main == null:
		return
	player = main.get("player") as CharacterBody3D
	npc_system = main.get("npc_system") as Node


func configure_live_fixture() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if main.has_method("apply_runtime_setting"):
		main.call("apply_runtime_setting", "headBob", false, false)
		main.call("apply_runtime_setting", "handSway", false, false)
	var hud = main.get("hud")
	if hud != null and hud.get("hud_root") is Control:
		(hud.get("hud_root") as Control).visible = false
	var tutorial = main.get("tutorial_system")
	if tutorial != null:
		tutorial.set("intro_bed_used", true)
		tutorial.set("intro_repair_active", false)
		tutorial.set("intro_repair_complete", true)
		tutorial.set("final_night_active", false)
		tutorial.set("final_night_complete", true)
	PlaytestSurvivalPolicyScript.enable_player_god_mode(main, "citadel_life_playtest")
	enable_interactive_player()


func enable_interactive_player() -> void:
	# This is an interactive fixture layered over Main's staged startup. Its real
	# CharacterBody3D is deliberately returned to normal player authority after
	# fixture setup; no synthetic movement path is introduced.
	if player == null:
		return
	player.set("automated_input", false)
	player.set("automated_move", Vector3.ZERO)
	player.set("automated_sprint", false)
	player.set("automated_jump", false)
	player.set_physics_process(true)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func rebuild_citadel() -> void:
	if rebuilding:
		return
	rebuilding = true
	observed_world_phase = ""
	set_loading("Retiring the previous published citadel")
	if npc_system != null and npc_system.has_method("clear"):
		npc_system.call("clear")
	citizens.clear()
	if citadel_root != null and is_instance_valid(citadel_root):
		citadel_root.queue_free()
	if furnishing_root != null and is_instance_valid(furnishing_root):
		furnishing_root.queue_free()
	citadel_root = null
	furnishing_root = null
	await get_tree().process_frame

	set_loading("Sampling seed %d castle and residence recipes" % selected_seed)
	await get_tree().process_frame
	blueprint = CastleCompoundBlueprintBuilderScript.build(selected_seed, {
		"biome": "forest",
		"siteKey": "citadel-life",
		"citadelScale": selected_citadel_scale
	})
	var recipe: Dictionary = blueprint.recipe if blueprint != null else {}
	var span := maxf(float(recipe.get("width", 80.0)), float(recipe.get("depth", 80.0)))
	fixture_center = find_dry_fixture_center(span)
	fixture_level = maxf(float(main.call("surface_y_at_cell", Vector3i(fixture_center.x, 0, fixture_center.y))), WATER_LEVEL + 3.0)
	fixture_origin = Vector3(float(fixture_center.x) * CELL, fixture_level, float(fixture_center.y) * CELL)
	var terrain_radius := ceili(span / CELL * 0.60) + 12

	set_loading("Flattening a real terrain site for collision (%dm radius)" % terrain_radius)
	await flatten_fixture_incremental(fixture_center, fixture_level, terrain_radius)
	clear_blocks_near_cell(fixture_center, terrain_radius)
	clear_props_near_cell(fixture_center, terrain_radius + 8)
	move_player_for_streaming(span)
	if main.has_method("update_chunks"):
		main.call("update_chunks", true)
	await wait_physics_frames(18)
	await claim_fixture_population_ownership()

	set_loading("Publishing the seeded castle shell (%d records)" % blueprint.parts.size())
	citadel_root = Node3D.new()
	citadel_root.name = "CitadelLifePublishedShell"
	citadel_root.position = fixture_origin
	add_child(citadel_root)
	building_publisher = BuildingPartPublisherScript.new()
	await building_publisher.publish_incremental(blueprint, citadel_root, loading_frame_budget(blueprint.parts.size()))

	set_loading("Planning and publishing seeded interiors")
	await get_tree().process_frame
	furnishing_plan = CastleFurnishingPlannerScript.build(blueprint, selected_seed * 7919 + 37)
	furnishing_root = Node3D.new()
	furnishing_root.name = "CitadelLifePublishedFurnishings"
	furnishing_root.position = fixture_origin
	add_child(furnishing_root)
	furnishing_publisher = FurnishingPublisherScript.new()
	await furnishing_publisher.publish_incremental(furnishing_plan, furnishing_root, loading_frame_budget(furnishing_plan.parts.size()))

	set_loading("Publishing ordinary structure and door facts to NPC systems")
	publish_structure_navigation_fact(span)
	register_published_doors()
	if npc_system.has_method("flush_navigation_change_bus"):
		npc_system.call("flush_navigation_change_bus")
	await wait_physics_frames(8)

	set_loading("Resolving every bed into a deterministic citizen home")
	residence_manifest = CitadelResidenceManifestBuilderScript.build(blueprint, furnishing_plan, CELL, fixture_origin)
	set_loading("Allowing published terrain, doors and collision-backed navigation to settle")
	await wait_physics_frames(NAV_PUBLICATION_SETTLE_FRAMES)
	spawn_manifest_citizens()
	place_player_at_gate(recipe)
	enable_interactive_player()
	rebuilding = false
	set_world_display_hour(11.0)
	refresh_world_phase(true)
	set_loading_visible(false)
	print("[Citadel Life] Ready: seed %d, %d citizens, %d furnished beds" % [selected_seed, citizens.size(), (residence_manifest.get("citizens", []) as Array).size()])


func publish_structure_navigation_fact(span: float) -> void:
	if npc_system == null or not npc_system.has_method("notify_navigation_structure_metadata_changed"):
		return
	var height := maxf(float(blueprint.recipe.get("wallHeight", 16.0)), 12.0)
	var bounds := AABB(
		fixture_origin + Vector3(-span * 0.5, 0.0, -span * 0.5),
		Vector3(span, height + 8.0, span)
	)
	npc_system.call("notify_navigation_structure_metadata_changed", String(blueprint.id), bounds, {
		"source": "citadel_life_playtest",
		"family": "castle",
		"published": true
	})


func register_published_doors() -> void:
	if citadel_root == null or npc_system == null or not npc_system.has_method("notify_navigation_door_registered"):
		return
	for child in citadel_root.get_children():
		if not (child is StaticBody3D):
			continue
		var body := child as StaticBody3D
		if String(body.get_meta("building_part_kind", "")) != "door":
			continue
		npc_system.call("notify_navigation_door_registered", body)


func claim_fixture_population_ownership() -> void:
	# Main may still finish publishing its ordinary tutorial/town roster after the
	# first setup frames. Claiming those generic population domains is the public
	# scenario composition contract; the fixture then registers exactly the
	# bed-derived Citadel Life citizens through the same production NpcSystem.
	if npc_system == null:
		return
	if npc_system.has_method("clear"):
		npc_system.call("clear")
	if npc_system.has_method("claim_town_population"):
		var structure_system = main.get("structure_system") if main != null else null
		if structure_system != null and structure_system.has_method("town_home_records_snapshot"):
			var records_by_town: Dictionary = structure_system.call("town_home_records_snapshot")
			for town_key_value in records_by_town.keys():
				npc_system.call("claim_town_population", String(town_key_value), "citadel_life_fixture")
		npc_system.call("claim_town_population", "citadel-life-fixture", "citadel_life_fixture")
	await wait_physics_frames(2)
func spawn_manifest_citizens() -> void:
	if npc_system == null:
		return
	var citizen_records: Array = residence_manifest.get("citizens", []) as Array
	for index in range(citizen_records.size()):
		var citizen: Dictionary = citizen_records[index] as Dictionary
		var spawn_position := civic_anchor_for(index, 0)
		spawn_position.y = float(citizen.get("level", fixture_level)) + 0.04
		var body := spawn_citizen(citizen, spawn_position, index)
		if body == null:
			continue
		citizens.append({"body": body, "manifest": citizen, "index": index})

		citizens[citizens.size() - 1]["locomotion"] = body.get_node_or_null("NpcBipedVisual/NpcBipedLocomotionPresenter")

func spawn_citizen(citizen: Dictionary, position: Vector3, index: int) -> CharacterBody3D:
	var body := npc_system.call("create_npc_body", "CitadelCitizen%02d" % (index + 1), "npc") as CharacterBody3D
	if body == null:
		return null
	npc_system.call("add_npc_collider", body)
	var npc_root := npc_system.get("npc_root") as Node3D
	if npc_root != null:
		npc_root.add_child(body)
	else:
		npc_system.add_child(body)
	# Attach the visual only after the real CharacterBody3D enters the tree so its
	# presentation node can initialise its world-facing yaw without a transform warning.
	var profile_id := String(citizen.get("id", "citadel_citizen_%d" % index))
	var appearance_recipe := NpcBipedRecipeBuilderScript.build(selected_seed + index * 104729, profile_id)
	NpcBipedVisualFactoryScript.add_biped(body, appearance_recipe, "Citizen %02d" % (index + 1))

	npc_system.call("safe_place_npc", body, position, null, "citadel_life_day_spawn")
	var profile := citizen.duplicate(true)
	profile.merge({
		"name": "Citizen %02d" % (index + 1),
		"displayRole": "Citizen",
		"townKey": "citadel-life:%s" % String(blueprint.id),
		"job": "civic",
		"canFight": false,
		"nightGuard": false
	}, true)
	npc_system.call("register_npc", body, profile)
	return body


func begin_civic_day() -> void:
	civic_order_elapsed = 0.0
	issue_civic_orders()


func issue_civic_orders() -> void:
	civic_order_round += 1
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		var index := int(citizen_entry.get("index", 0))
		var target := civic_anchor_for(index, civic_order_round)
		target.y = float((citizen_entry.get("manifest", {}) as Dictionary).get("level", fixture_level)) + 0.04
		npc_system.call("order_go_to", body, target, "citadel_life_civic_day", CELL * 1.10)


func begin_civic_night() -> void:
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body != null and is_instance_valid(body):
			npc_system.call("order_go_home", body, "citadel_life_world_clock_return")


func set_world_display_hour(hour: float) -> void:
	if main == null:
		return
	main.set("time_of_day", fposmod((hour / 24.0) - 0.25, 1.0))
	if main.has_method("update_sky"):
		main.call("update_sky", 0.0)


func world_phase() -> String:
	# Keep the fixture's scenario composition aligned with the production
	# schedule service: daytime civic orders may exist only during the ordinary
	# day window. Dusk, night and dawn all let the existing home schedule win.
	if main != null and main.has_method("clock_phase"):
		var phase := float(main.call("clock_phase"))
		return "day" if phase >= 7.0 / 24.0 and phase < 18.25 / 24.0 else "night"
	return "day"


func refresh_world_phase(force := false) -> void:
	if rebuilding or main == null or citizens.is_empty():
		return
	var next_phase := world_phase()
	if not force and next_phase == observed_world_phase:
		return
	observed_world_phase = next_phase
	if observed_world_phase == "day":
		begin_civic_day()
	else:
		begin_civic_night()


func civic_anchor_for(index: int, round_index: int) -> Vector3:
	var anchors := civic_street_anchors()
	if anchors.is_empty():
		var recipe: Dictionary = blueprint.recipe if blueprint != null else {}
		var grammar: Dictionary = recipe.get("castleGrammar", {}) as Dictionary
		var width := float(recipe.get("width", 72.0))
		var depth := float(recipe.get("depth", 64.0))
		var gate_depth := float(grammar.get("gateDepth", 9.0))
		var keep_depth := float(grammar.get("keepDepth", depth * 0.24))
		var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
		var keep_z := depth * float(keep_offset.get("z", 0.14))
		var route_start := -depth * 0.5 + gate_depth + CELL * 1.5
		var route_end := keep_z - keep_depth * 0.5 - CELL * 1.5
		for fraction in [0.16, 0.36, 0.56, 0.76]:
			anchors.append(fixture_origin + Vector3(0.0, fixture_level, lerpf(route_start, route_end, fraction)))
	var pick := posmod(index * 3 + round_index * 5 + selected_seed, anchors.size())
	return anchors[pick]


func civic_street_anchors() -> Array[Vector3]:
	var anchors: Array[Vector3] = []
	if blueprint == null:
		return anchors
	var recipe: Dictionary = blueprint.recipe
	var grammar: Dictionary = recipe.get("castleGrammar", {}) as Dictionary
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var records: Array = (grid.get("streetRecords", []) as Array).duplicate()
	records.sort_custom(func(left, right) -> bool:
		var left_id := String((left as Dictionary).get("id", "")) if left is Dictionary else ""
		var right_id := String((right as Dictionary).get("id", "")) if right is Dictionary else ""
		return left_id < right_id
	)
	for value in records:
		if not (value is Dictionary):
			continue
		var record: Dictionary = value as Dictionary
		var width := float(record.get("width", 0.0))
		var depth := float(record.get("depth", 0.0))
		if width < CELL * 1.5 or depth < CELL * 1.5:
			continue
		var center := fixture_origin + Vector3(float(record.get("x", 0.0)), fixture_level, float(record.get("z", 0.0)))
		var offset_span := maxf(0.0, maxf(width, depth) * 0.24 - CELL * 0.75)
		for offset in [0.0, -offset_span, offset_span]:
			var candidate := center
			if width >= depth:
				candidate.x += offset
			else:
				candidate.z += offset
			anchors.append(candidate)
	return anchors


func place_player_at_gate(recipe: Dictionary) -> void:
	if player == null:
		return
	var depth := float(recipe.get("depth", 72.0))
	var gate_depth := float((recipe.get("castleGrammar", {}) as Dictionary).get("gateDepth", 10.0))
	# PlayerController's capsule feet sit at its root origin. Use the same
	# collision-safe surface placement as the established walkthrough fixtures;
	# spawning a metre in the air can make terrain motion proof reject input
	# before gravity gets a valid landing frame.
	player.global_position = fixture_origin + Vector3(0.0, 0.15, -depth * 0.5 - gate_depth * 0.82 - 3.0)
	player.velocity = Vector3.ZERO
	player.rotation.y = PI
	var camera_pitch := player.get("camera_pitch") as Node3D
	if camera_pitch != null:
		camera_pitch.rotation.x = 0.0


func move_player_for_streaming(span: float) -> void:
	if player == null:
		return
	player.global_position = fixture_origin + Vector3(0.0, 0.15, -span * 0.5 - 5.0)
	player.velocity = Vector3.ZERO


func find_dry_fixture_center(span: float) -> Vector2i:
	var candidates: Array[Vector2i] = [
		Vector2i(240, -220), Vector2i(-240, 220), Vector2i(300, 180), Vector2i(-300, -180)
	]
	var radius_cells := ceili(span / CELL * 0.60) + 12
	for candidate in candidates:
		var height := float(main.call("surface_y_at_cell", Vector3i(candidate.x, 0, candidate.y)))
		if height > WATER_LEVEL + 2.5 and abs(candidate.x) > radius_cells and abs(candidate.y) > radius_cells:
			return candidate
	return candidates[0]


func flatten_fixture_incremental(center: Vector2i, level: float, radius: int) -> void:
	var edits: Dictionary = main.get("volume_edit_markers")
	var affected_cells: Array = []
	for z in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			edits[Vector2i(x, z)] = level
			affected_cells.append(Vector2i(x, z))
		if posmod(z - (center.y - radius), 2) == 0:
			set_loading("Flattening a real terrain site for collision (%d%%)" % roundi(100.0 * float(z - (center.y - radius) + 1) / float(radius * 2 + 1)))
			await get_tree().process_frame
	for offset in [Vector2i.ZERO, Vector2i(radius, 0), Vector2i(-radius, 0), Vector2i(0, radius), Vector2i(0, -radius)]:
		if main.has_method("rebuild_chunks_around_cell"):
			main.call("rebuild_chunks_around_cell", center + offset)
	if npc_system != null and npc_system.has_method("notify_navigation_terrain_cells_edited"):
		npc_system.call("notify_navigation_terrain_cells_edited", affected_cells)


func clear_blocks_near_cell(center: Vector2i, radius: int) -> void:
	var blocks: Dictionary = main.get("blocks")
	for key in blocks.keys():
		var cell: Vector3i = key
		if abs(cell.x - center.x) > radius or abs(cell.z - center.y) > radius:
			continue
		var body := blocks[key] as Node
		if body != null:
			body.queue_free()
		blocks.erase(key)


func clear_props_near_cell(center: Vector2i, radius: int) -> void:
	for root_value in [main.get("chunk_root"), main.get("prop_root")]:
		clear_props_recursive(root_value as Node, center, radius)


func clear_props_recursive(node: Node, center: Vector2i, radius: int) -> void:
	if node == null:
		return
	for child in node.get_children():
		if child is Node3D and String(child.get_meta("kind", "")) == "prop":
			var prop := child as Node3D
			var cell := flat_cell(prop.global_position)
			if abs(cell.x - center.x) <= radius and abs(cell.y - center.y) <= radius:
				child.queue_free()
				continue
		clear_props_recursive(child, center, radius)


func loading_frame_budget(record_count: int) -> int:
	return clampi(ceili(float(maxi(record_count, 1)) / 540.0), 5, 36)


func wait_physics_frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().physics_frame


func flat_cell(position: Vector3) -> Vector2i:
	return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))


func _process(delta: float) -> void:
	if loading_overlay != null and loading_overlay.visible:
		loading_elapsed += delta
		update_loading_label()
	if rebuilding:
		return
	if player != null and not player.is_physics_processing():
		# Main's normal staged boot can finish on a later frame than this fixture's
		# first presentation pass. Keep the real player interactive once fixture
		# publication has completed instead of leaving a visible but inert avatar.
		enable_interactive_player()
	if main == null or citizens.is_empty():
		return
	refresh_world_phase()
	if observed_world_phase == "day":
		civic_order_elapsed += delta
		if civic_order_elapsed >= 8.0:
			civic_order_elapsed = 0.0
			issue_civic_orders()
	update_biped_presenters(delta)
	update_status()


func update_biped_presenters(delta: float) -> void:
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		var locomotion = citizen_entry.get("locomotion")
		if body == null or not is_instance_valid(body) or locomotion == null or not is_instance_valid(locomotion):
			continue
		locomotion.apply_velocity(body.velocity, delta)



func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_R:
			selected_seed += 1
			call_deferred("rebuild_citadel")
			get_viewport().set_input_as_handled()
		KEY_F6:
			set_world_display_hour(11.0)
			get_viewport().set_input_as_handled()
		KEY_F7:
			set_world_display_hour(21.0)
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 30
	add_child(layer)
	status_label = Label.new()
	status_label.position = Vector2(18, 16)
	status_label.size = Vector2(720, 114)
	status_label.add_theme_font_size_override("font_size", 18)
	status_label.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layer.add_child(status_label)
	loading_overlay = ColorRect.new()
	loading_overlay.color = Color(0.015, 0.025, 0.05, 0.94)
	loading_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(loading_overlay)
	loading_label = Label.new()
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	loading_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	loading_label.add_theme_font_size_override("font_size", 28)
	loading_label.add_theme_color_override("font_color", Color(0.93, 0.96, 1.0))
	loading_overlay.add_child(loading_label)
	update_loading_label()


func set_loading(message: String) -> void:
	loading_message = message
	set_loading_visible(true)
	update_loading_label()


func set_loading_visible(visible: bool) -> void:
	if loading_overlay != null:
		loading_overlay.visible = visible


func update_loading_label() -> void:
	if loading_label == null:
		return
	var dots := ".".repeat(int(floor(loading_elapsed * 4.0)) % 4)
	loading_label.text = "CITADEL LIFE PLAYTEST\n%s%s\n\nThe loading display continues updating while recipe, terrain, collision and resident publication are staged." % [loading_message, dots]


func update_status() -> void:
	if status_label == null:
		return
	var inside_count := 0
	var route_states := {}
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		if bool(body.get_meta("npc_inside_home", false)):
			inside_count += 1
		var entry: Dictionary = npc_system.call("npc_entry_for_actor", body)
		var state := String(entry.get("routeStatus", "idle"))
		route_states[state] = int(route_states.get(state, 0)) + 1
	var phase_name := "DAY ? civic wandering" if observed_world_phase == "day" else "NIGHT ? returning home"
	var player_ready := player != null and player.is_physics_processing() and not bool(player.get("automated_input"))
	status_label.text = "CITADEL LIFE  |  %s\nseed %d  ?  %.2fx citadel  ?  %d citizens / %d furnished beds  ?  %d strictly indoors  ?  player %s\n[WASD] move  [F6] set daylight  [F7] set night  [R] next seed  [Esc] release mouse\nWorld clock drives the citizen phase. Production NPC bodies, real collision, registered door portals and ordinary public civic/home orders. Route states: %s" % [phase_name, selected_seed, selected_citadel_scale, citizens.size(), (residence_manifest.get("citizens", []) as Array).size(), inside_count, "interactive" if player_ready else "not-ready", JSON.stringify(route_states)]
