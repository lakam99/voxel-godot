extends SceneTree

const MotionRecipeBuilderScript := preload("res://scripts/combat/motion/MotionRecipeBuilder.gd")
const MotionInstanceScript := preload("res://scripts/combat/motion/MotionInstance.gd")
const MotionStackScript := preload("res://scripts/combat/motion/MotionStack.gd")
const MotionVolumeRecipeBuilderScript := preload("res://scripts/combat/contact/MotionVolumeRecipeBuilder.gd")
const MotionVolumeSamplerScript := preload("res://scripts/combat/contact/MotionVolumeSampler.gd")
const MotionVolumeSampleScript := preload("res://scripts/combat/contact/MotionVolumeSample.gd")
const PassiveContactSphereScript := preload("res://scripts/combat/contact/PassiveContactSphere.gd")
const MotionContactResolverScript := preload("res://scripts/combat/contact/MotionContactResolver.gd")
const MotionAfterimageRendererScript := preload("res://scripts/combat/presentation/MotionAfterimageRenderer.gd")

var report_path := ""
var results: Array[Dictionary] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	report_path = OS.get_environment("VOXEL_PROCEDURAL_MOTION_CONTRACT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/combat/procedural-motion-contract.json")
	test_same_seed_replays_exactly()
	test_seed_variation_stays_bounded()
	test_multi_plane_recipes_replay_exactly_and_stay_bounded()
	test_seeded_multi_plane_profiles_cover_all_supported_planes()
	test_multi_plane_profiles_keep_a_standard_hostile_actor_corridor_contactable()
	test_lateral_arc_preserves_legacy_side_arc_trajectory()
	test_stack_retains_independent_motions()
	test_contact_volume_derives_from_motion_sample()
	test_contact_volume_respects_phase_window()
	test_contact_volume_preview_geometry_covers_windup()
	test_contact_volume_stack_and_sweep_are_independent()
	test_passive_geometry_resolves_from_shared_capsule_sample()
	test_passive_geometry_does_not_resolve_during_windup()
	test_sweep_resolves_transient_crossing()
	test_window_resolution_is_idempotent_per_motion_geometry_pair()
	test_stacked_motion_window_keeps_resolution_contributors_independent()
	test_afterimage_renderer_reuses_one_ribbon_per_motion()
	test_afterimage_renderer_stacked_playback_keeps_node_count_constant()
	test_runtime_uses_shared_presentation_authority()
	test_motion_layer_has_no_scene_or_combat_dependency()
	write_report()
	quit(0 if failure_count() == 0 else 1)


func test_same_seed_replays_exactly() -> void:
	var first = MotionRecipeBuilderScript.build_side_arc(1543)
	var second = MotionRecipeBuilderScript.build_side_arc(1543)
	var first_instance = MotionInstanceScript.new({"instanceId": "first", "recipe": first, "anchorId": "a"})
	var second_instance = MotionInstanceScript.new({"instanceId": "second", "recipe": second, "anchorId": "a"})
	var exact := true
	for time in [0.0, 0.13, 0.27, 0.48, 0.76, 1.0]:
		var a = first_instance.sample(time)
		var b = second_instance.sample(time)
		exact = exact and a.phase == b.phase and a.tip.is_equal_approx(b.tip) and a.facing.is_equal_approx(b.facing)
	add_result("same_seed_recipe_replays_identical_samples", exact, {"seed": 1543})


func test_seed_variation_stays_bounded() -> void:
	var first = MotionRecipeBuilderScript.build_side_arc(1543)
	var second = MotionRecipeBuilderScript.build_side_arc(7651)
	var reach_a := float(first.parameters.get("reach", 0.0))
	var reach_b := float(second.parameters.get("reach", 0.0))
	var arc_a := float(first.parameters.get("arcDegrees", 0.0))
	var arc_b := float(second.parameters.get("arcDegrees", 0.0))
	var plane_a := float(first.parameters.get("attackPlaneTiltDegrees", 0.0))
	var plane_b := float(second.parameters.get("attackPlaneTiltDegrees", 0.0))
	var different := not is_equal_approx(reach_a, reach_b) or not is_equal_approx(arc_a, arc_b) or not is_equal_approx(plane_a, plane_b)
	# The motion recipe intentionally keeps every plane non-horizontal while
	# bounding its elevation strongly enough to remain legible in first person.
	var bounded := reach_a >= 0.25 and reach_a <= 8.0 and reach_b >= 0.25 and reach_b <= 8.0 and arc_a >= 18.0 and arc_a <= 220.0 and arc_b >= 18.0 and arc_b <= 220.0 and absf(plane_a) >= 12.0 and absf(plane_a) <= 26.0 and absf(plane_b) >= 12.0 and absf(plane_b) <= 26.0
	add_result("seed_variation_is_visible_and_bounded", different and bounded, {"first": first.snapshot(), "second": second.snapshot()})


func test_multi_plane_recipes_replay_exactly_and_stay_bounded() -> void:
	var profiles: Array[String] = ["lateral", "rising", "falling", "overhead"]
	var exact := true
	var bounded := true
	var trajectories: Dictionary = {}
	for profile in profiles:
		var first = MotionRecipeBuilderScript.build_arc(1543, {"planeProfile": profile})
		var second = MotionRecipeBuilderScript.build_arc(1543, {"planeProfile": profile})
		var first_instance = MotionInstanceScript.new({"instanceId": "first_%s" % profile, "recipe": first, "anchorId": "multi_plane"})
		var second_instance = MotionInstanceScript.new({"instanceId": "second_%s" % profile, "recipe": second, "anchorId": "multi_plane"})
		for time in [0.0, 0.18, 0.42, 0.67, 1.0]:
			var a = first_instance.sample(time)
			var b = second_instance.sample(time)
			exact = exact and a.phase == b.phase and a.tip.is_equal_approx(b.tip) and a.facing.is_equal_approx(b.facing)
		var parameters: Dictionary = first.parameters
		var pitch := float(parameters.get("centralPitchDegrees", INF))
		var roll := float(parameters.get("sweepRollDegrees", INF))
		bounded = bounded and absf(pitch) <= 80.0 and absf(roll) <= 68.0 and float(parameters.get("reach", 0.0)) >= 0.25 and float(parameters.get("reach", 9.0)) <= 8.0
		trajectories[profile] = first_instance.sample(0.50).snapshot()
	var lateral_tip: Vector3 = (trajectories.get("lateral", {}) as Dictionary).get("tip", Vector3.ZERO)
	var rising_tip: Vector3 = (trajectories.get("rising", {}) as Dictionary).get("tip", Vector3.ZERO)
	var falling_tip: Vector3 = (trajectories.get("falling", {}) as Dictionary).get("tip", Vector3.ZERO)
	var overhead_tip: Vector3 = (trajectories.get("overhead", {}) as Dictionary).get("tip", Vector3.ZERO)
	var distinct := not lateral_tip.is_equal_approx(rising_tip) and not rising_tip.is_equal_approx(falling_tip) and not rising_tip.is_equal_approx(overhead_tip)
	add_result("multi_plane_arc_recipes_are_deterministic_bounded_and_distinct", exact and bounded and distinct, {"seed": 1543, "trajectories": trajectories})


func test_seeded_multi_plane_profiles_cover_all_supported_planes() -> void:
	var observed: Dictionary = {}
	for seed in range(1, 2049):
		var recipe = MotionRecipeBuilderScript.build_arc(seed)
		observed[String(recipe.parameters.get("planeProfile", ""))] = seed
		if observed.size() == MotionRecipeBuilderScript.PLANE_PROFILES.size():
			break
	var covered := true
	for profile in MotionRecipeBuilderScript.PLANE_PROFILES:
		covered = covered and observed.has(profile)
	add_result("seeded_multi_plane_selection_covers_each_supported_plane_profile", covered, {"observedSeeds": observed, "profiles": MotionRecipeBuilderScript.PLANE_PROFILES})


func test_multi_plane_profiles_keep_a_standard_hostile_actor_corridor_contactable() -> void:
	# Match the live hostile/player anchor relationship: a hovering hostile's
	# shared contact anchor sits 0.32m above the target capsule's centre, and the
	# enemy enters the normal 1.72m melee threshold. A profile can look diagonal
	# or overhead, but it may not curve entirely outside this real actor corridor.
	var target_geometries := [
		PassiveContactSphereScript.new({"geometryId": "actor:lower", "center": Vector3(0.0, -0.76, -1.72), "radius": 0.42}),
		PassiveContactSphereScript.new({"geometryId": "actor:middle", "center": Vector3(0.0, -0.32, -1.72), "radius": 0.42}),
		PassiveContactSphereScript.new({"geometryId": "actor:upper", "center": Vector3(0.0, 0.12, -1.72), "radius": 0.42})
	]
	var seeds: Array = [1, 1543, 7651, 557693527, 1201775400, 2147480000]
	for index in range(1, 129):
		seeds.append(index * 7919)
	var misses: Array = []
	for profile in MotionRecipeBuilderScript.PLANE_PROFILES:
		for seed_value in seeds:
			var seed := int(seed_value)
			var recipe = MotionRecipeBuilderScript.build_arc(seed, {"planeProfile": profile})
			var instance = MotionInstanceScript.new({"instanceId": "%s_%d" % [profile, seed], "recipe": recipe, "anchorId": "hostile_actor_corridor"})
			var volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(seed)
			var previous = null
			var resolved := false
			var nearest_margin := INF
			for index in range(73):
				var time := float(index) / 72.0
				var current = MotionVolumeSamplerScript.sample(volume_recipe, instance.sample(time))
				if current.active:
					for geometry in target_geometries:
						var closest: Vector3 = MotionContactResolverScript.closest_point_on_segment(geometry.center, current.segment_start, current.segment_end)
						nearest_margin = minf(nearest_margin, closest.distance_to(geometry.center) - (float(current.radius) + float(geometry.radius)))
						if MotionContactResolverScript.resolve_transition(previous, current, geometry).resolved:
							resolved = true
							break
					previous = current
				if resolved:
					break
			if not resolved:
				misses.append({"profile": profile, "seed": seed, "nearestMargin": nearest_margin, "parameters": recipe.parameters})
	add_result(
		"multi_plane_profiles_keep_the_standard_hostile_actor_corridor_contactable",
		misses.is_empty(),
		{"sampleCount": seeds.size() * MotionRecipeBuilderScript.PLANE_PROFILES.size(), "misses": misses}
	)


func test_lateral_arc_preserves_legacy_side_arc_trajectory() -> void:
	var legacy = MotionRecipeBuilderScript.build_side_arc(7651)
	var lateral = MotionRecipeBuilderScript.build_arc(7651, {"planeProfile": "lateral"})
	var legacy_instance = MotionInstanceScript.new({"instanceId": "legacy", "recipe": legacy, "anchorId": "legacy_anchor"})
	var lateral_instance = MotionInstanceScript.new({"instanceId": "lateral", "recipe": lateral, "anchorId": "legacy_anchor"})
	var preserved := true
	for time in [0.0, 0.13, 0.29, 0.51, 0.78, 1.0]:
		var old_sample = legacy_instance.sample(time)
		var new_sample = lateral_instance.sample(time)
		preserved = preserved and old_sample.phase == new_sample.phase and old_sample.tip.is_equal_approx(new_sample.tip) and old_sample.facing.is_equal_approx(new_sample.facing)
	add_result("explicit_lateral_arc_preserves_the_legacy_side_arc_trajectory", preserved, {"seed": 7651, "legacy": legacy.snapshot(), "lateral": lateral.snapshot()})


func test_stack_retains_independent_motions() -> void:
	var recipe = MotionRecipeBuilderScript.build_side_arc(1543)
	var left = MotionInstanceScript.new({
		"instanceId": "left_arc",
		"recipe": recipe,
		"anchorId": "left_anchor",
		"anchorOffset": Vector3(-0.68, 0.0, 0.0),
		"direction": 1.0
	})
	var right = MotionInstanceScript.new({
		"instanceId": "right_arc",
		"recipe": MotionRecipeBuilderScript.build_side_arc(7651),
		"anchorId": "right_anchor",
		"anchorOffset": Vector3(0.68, 0.0, 0.0),
		"direction": -1.0,
		"startOffset": 0.14,
		"timeScale": 0.82
	})
	var stack = MotionStackScript.new("independent_stack", [left, right])
	var samples: Array = stack.samples_at(0.50)
	var snapshot: Dictionary = stack.snapshot()
	var ids: Array = []
	for sample in samples:
		ids.append(sample.instance_id)
	add_result("motion_stack_keeps_contributors_independent", samples.size() == 2 and ids.has("left_arc") and ids.has("right_arc") and (snapshot.get("instances", []) as Array).size() == 2, snapshot)


func test_contact_volume_derives_from_motion_sample() -> void:
	var motion_recipe = MotionRecipeBuilderScript.build_side_arc(1543)
	var volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(1543)
	var instance = MotionInstanceScript.new({"instanceId": "sample_arc", "recipe": motion_recipe, "anchorId": "sample_anchor"})
	var motion_sample = instance.sample(0.50)
	var volume_sample = MotionVolumeSamplerScript.sample(volume_recipe, motion_sample)
	var span_start := float(volume_recipe.value("spanStart", 0.0))
	var span_end := float(volume_recipe.value("spanEnd", 1.0))
	var expected_start: Vector3 = motion_sample.origin.lerp(motion_sample.tip, span_start)
	var expected_end: Vector3 = motion_sample.origin.lerp(motion_sample.tip, span_end)
	var correct: bool = volume_sample.active and volume_sample.segment_start.is_equal_approx(expected_start) and volume_sample.segment_end.is_equal_approx(expected_end) and volume_sample.radius > 0.0
	add_result("contact_volume_derives_from_the_shared_motion_sample", correct, {"motion": motion_sample.snapshot(), "volume": volume_sample.snapshot(), "recipe": volume_recipe.snapshot()})


func test_contact_volume_respects_phase_window() -> void:
	var recipe = MotionRecipeBuilderScript.build_side_arc(1543)
	var volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(1543)
	var instance = MotionInstanceScript.new({"instanceId": "phase_arc", "recipe": recipe, "anchorId": "phase_anchor"})
	var windup_volume = MotionVolumeSamplerScript.sample(volume_recipe, instance.sample(0.10))
	var arc_volume = MotionVolumeSamplerScript.sample(volume_recipe, instance.sample(0.50))
	add_result("contact_volume_is_active_only_in_its_declared_motion_phase", not windup_volume.active and arc_volume.active, {"windup": windup_volume.snapshot(), "arc": arc_volume.snapshot()})


func test_contact_volume_preview_geometry_covers_windup() -> void:
	var recipe = MotionRecipeBuilderScript.build_side_arc(1543)
	var volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(1543)
	var instance = MotionInstanceScript.new({"instanceId": "preview_arc", "recipe": recipe, "anchorId": "preview_anchor"})
	var windup_preview = MotionVolumeSamplerScript.sample_geometry(volume_recipe, instance.sample(0.10))
	var has_geometry: bool = windup_preview.segment_end.distance_to(windup_preview.segment_start) > 0.01 and windup_preview.radius > 0.0
	add_result("contact_volume_preview_geometry_is_available_during_windup_without_becoming_active", has_geometry and not windup_preview.active, {"windupPreview": windup_preview.snapshot()})


func test_contact_volume_stack_and_sweep_are_independent() -> void:
	var volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(1543)
	var left = MotionInstanceScript.new({"instanceId": "left_volume", "recipe": MotionRecipeBuilderScript.build_side_arc(1543), "anchorId": "left"})
	var right = MotionInstanceScript.new({"instanceId": "right_volume", "recipe": MotionRecipeBuilderScript.build_side_arc(7651), "anchorId": "right", "direction": -1.0, "startOffset": 0.14, "timeScale": 0.82})
	var stack = MotionStackScript.new("volume_stack", [left, right])
	var previous = MotionVolumeSamplerScript.samples_for_stack(stack, volume_recipe, 0.46)
	var current = MotionVolumeSamplerScript.samples_for_stack(stack, volume_recipe, 0.50)
	var sweeps: Array = []
	for current_sample in current:
		var previous_sample = null
		for candidate in previous:
			if candidate.instance_id == current_sample.instance_id:
				previous_sample = candidate
				break
		sweeps.append(MotionVolumeSamplerScript.sweep(previous_sample, current_sample))
	var ids: Array = []
	var sweep_is_active := true
	for sweep_sample in sweeps:
		ids.append(sweep_sample.instance_id)
		sweep_is_active = sweep_is_active and sweep_sample.active and sweep_sample.radius > 0.0
	add_result("contact_volume_stack_keeps_contributors_and_sweeps_independent", current.size() == 2 and ids.has("left_volume") and ids.has("right_volume") and sweep_is_active, {"previous": snapshots_for(previous), "current": snapshots_for(current), "sweeps": snapshots_for(sweeps)})


func test_passive_geometry_resolves_from_shared_capsule_sample() -> void:
	var recipe = MotionRecipeBuilderScript.build_side_arc(1543)
	var volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(1543)
	var instance = MotionInstanceScript.new({"instanceId": "resolution_arc", "recipe": recipe, "anchorId": "resolution_anchor"})
	var volume = MotionVolumeSamplerScript.sample(volume_recipe, instance.sample(0.50))
	var geometry = PassiveContactSphereScript.new({"geometryId": "passive_orb", "center": volume.segment_start.lerp(volume.segment_end, 0.5), "radius": 0.16})
	var resolution = MotionContactResolverScript.resolve_volume(volume, geometry)
	var correct: bool = resolution.resolved and resolution.geometry_id == "passive_orb" and resolution.instance_id == "resolution_arc" and resolution.source_id == "capsule_segment" and resolution.overlap_depth > 0.0
	add_result("passive_geometry_resolves_from_shared_capsule_sample", correct, {"volume": volume.snapshot(), "geometry": geometry.snapshot(), "resolution": resolution.snapshot()})


func test_passive_geometry_does_not_resolve_during_windup() -> void:
	var recipe = MotionRecipeBuilderScript.build_side_arc(1543)
	var volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(1543)
	var instance = MotionInstanceScript.new({"instanceId": "windup_resolution_arc", "recipe": recipe, "anchorId": "windup_resolution_anchor"})
	var windup_volume = MotionVolumeSamplerScript.sample(volume_recipe, instance.sample(0.10))
	var geometry = PassiveContactSphereScript.new({"geometryId": "windup_orb", "center": Vector3.ZERO, "radius": 4.0})
	var resolution = MotionContactResolverScript.resolve_volume(windup_volume, geometry)
	add_result("passive_geometry_does_not_resolve_outside_declared_contact_phase", not windup_volume.active and not resolution.resolved, {"volume": windup_volume.snapshot(), "resolution": resolution.snapshot()})


func test_sweep_resolves_transient_crossing() -> void:
	var previous = MotionVolumeSampleScript.new({
		"instanceId": "sweep_arc",
		"normalizedTime": 0.40,
		"phase": "arc",
		"active": true,
		"segmentStart": Vector3(-1.0, 0.0, -1.0),
		"segmentEnd": Vector3(-1.0, 0.0, 1.0),
		"radius": 0.12
	})
	var current = MotionVolumeSampleScript.new({
		"instanceId": "sweep_arc",
		"normalizedTime": 0.50,
		"phase": "arc",
		"active": true,
		"segmentStart": Vector3(1.0, 0.0, -1.0),
		"segmentEnd": Vector3(1.0, 0.0, 1.0),
		"radius": 0.12
	})
	var geometry = PassiveContactSphereScript.new({"geometryId": "sweep_orb", "center": Vector3(0.0, 0.05, 0.0), "radius": 0.12})
	var sweep = MotionVolumeSamplerScript.sweep(previous, current)
	var resolution = MotionContactResolverScript.resolve_sweep(sweep, geometry)
	var transition = MotionContactResolverScript.resolve_transition(previous, current, geometry)
	var correct: bool = resolution.resolved and resolution.source_id == "sweep_sheet" and transition.resolved and transition.source_id == "sweep_sheet"
	add_result("swept_sheet_resolves_a_transient_crossing_between_discrete_capsules", correct, {"sweep": sweep.snapshot(), "geometry": geometry.snapshot(), "resolution": resolution.snapshot(), "transition": transition.snapshot()})


func test_window_resolution_is_idempotent_per_motion_geometry_pair() -> void:
	var recipe = MotionRecipeBuilderScript.build_side_arc(1543)
	var volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(1543)
	var instance = MotionInstanceScript.new({"instanceId": "window_arc", "recipe": recipe, "anchorId": "window_anchor"})
	var stack = MotionStackScript.new("window_stack", [instance])
	var sample = MotionVolumeSamplerScript.sample(volume_recipe, instance.sample(0.50))
	var geometry = PassiveContactSphereScript.new({"geometryId": "window_orb", "center": sample.segment_start.lerp(sample.segment_end, 0.5), "radius": 0.16})
	var resolutions: Array = MotionContactResolverScript.resolve_window(stack, volume_recipe, [geometry], 0.30, 0.80, 28)
	var correct: bool = resolutions.size() == 1 and resolutions[0].resolved and resolutions[0].event_key() == "window_arc:window_orb"
	add_result("resolution_window_emits_one_fact_per_motion_geometry_pair", correct, {"geometry": geometry.snapshot(), "resolutions": snapshots_for(resolutions)})


func test_stacked_motion_window_keeps_resolution_contributors_independent() -> void:
	var volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(1543)
	var left = MotionInstanceScript.new({"instanceId": "stack_left", "recipe": MotionRecipeBuilderScript.build_side_arc(1543), "anchorId": "left_anchor", "anchorOffset": Vector3(-4.0, 0.0, 0.0)})
	var right = MotionInstanceScript.new({"instanceId": "stack_right", "recipe": MotionRecipeBuilderScript.build_side_arc(7651), "anchorId": "right_anchor", "anchorOffset": Vector3(4.0, 0.0, 0.0), "direction": -1.0})
	var stack = MotionStackScript.new("independent_resolution_stack", [left, right])
	var samples: Array = MotionVolumeSamplerScript.samples_for_stack(stack, volume_recipe, 0.50)
	var left_volume = null
	var right_volume = null
	for sample in samples:
		if sample.instance_id == "stack_left":
			left_volume = sample
		elif sample.instance_id == "stack_right":
			right_volume = sample
	if left_volume == null or right_volume == null:
		add_result("stacked_motion_window_keeps_resolution_contributors_independent", false, {"reason": "Expected both active stack contributors", "samples": snapshots_for(samples)})
		return
	var geometries := [
		PassiveContactSphereScript.new({"geometryId": "left_orb", "center": left_volume.segment_start.lerp(left_volume.segment_end, 0.5), "radius": 0.04}),
		PassiveContactSphereScript.new({"geometryId": "right_orb", "center": right_volume.segment_start.lerp(right_volume.segment_end, 0.5), "radius": 0.04})
	]
	var resolutions: Array = MotionContactResolverScript.resolve_window(stack, volume_recipe, geometries, 0.30, 0.80, 28)
	var keys: Array = []
	for resolution in resolutions:
		keys.append(resolution.event_key())
	var correct: bool = resolutions.size() == 2 and keys.has("stack_left:left_orb") and keys.has("stack_right:right_orb")
	add_result("stacked_motion_window_keeps_resolution_contributors_independent", correct, {"geometries": snapshots_for(geometries), "resolutions": snapshots_for(resolutions)})


func test_afterimage_renderer_reuses_one_ribbon_per_motion() -> void:
	var left := MotionInstanceScript.new({"instanceId": "left_ribbon", "recipe": MotionRecipeBuilderScript.build_side_arc(1543), "anchorId": "left"})
	var right := MotionInstanceScript.new({"instanceId": "right_ribbon", "recipe": MotionRecipeBuilderScript.build_side_arc(7651), "anchorId": "right", "direction": -1.0})
	var stack := MotionStackScript.new("ribbon_reuse_stack", [left, right])
	var renderer := MotionAfterimageRendererScript.new()
	root.add_child(renderer)
	renderer.render_trails(stack.trails_until(0.50, 13))
	var initial_children: Array = renderer.get_children()
	var initial_ids: Array = []
	var initial_mesh_ids: Array = []
	for child in initial_children:
		initial_ids.append(child.get_instance_id())
		var ribbon := child as MeshInstance3D
		initial_mesh_ids.append(ribbon.mesh.get_instance_id() if ribbon != null and ribbon.mesh != null else -1)
	renderer.render_trails(stack.trails_until(0.56, 13))
	var next_children: Array = renderer.get_children()
	var next_ids: Array = []
	var next_mesh_ids: Array = []
	for child in next_children:
		next_ids.append(child.get_instance_id())
		var ribbon := child as MeshInstance3D
		next_mesh_ids.append(ribbon.mesh.get_instance_id() if ribbon != null and ribbon.mesh != null else -1)
	var reused := initial_children.size() == 2 and next_children.size() == 2 and initial_ids == next_ids and initial_mesh_ids == next_mesh_ids
	renderer.clear_visuals()
	var cleared := renderer.get_child_count() == 0
	renderer.queue_free()
	add_result("afterimage_renderer_reuses_one_ribbon_node_per_independent_motion", reused and cleared, {"initialIds": initial_ids, "nextIds": next_ids, "initialMeshIds": initial_mesh_ids, "nextMeshIds": next_mesh_ids, "cleared": cleared})


func test_afterimage_renderer_stacked_playback_keeps_node_count_constant() -> void:
	var instances: Array = []
	for index in range(8):
		instances.append(MotionInstanceScript.new({
			"instanceId": "stress_%d" % index,
			"recipe": MotionRecipeBuilderScript.build_side_arc(1543 + index * 7919),
			"anchorId": "stress_anchor",
			"anchorOffset": Vector3((float(index) - 3.5) * 0.24, 0.0, 0.0),
			"direction": -1.0 if index % 2 == 0 else 1.0,
			"startOffset": float(index % 3) * 0.04
		}))
	var stack := MotionStackScript.new("ribbon_stress_stack", instances)
	var renderer := MotionAfterimageRendererScript.new()
	root.add_child(renderer)
	var elapsed_usec: Array = []
	var counts: Array = []
	for frame in range(120):
		var started_usec := Time.get_ticks_usec()
		# Keep every contributor inside its readable sweep window so this measures
		# steady stacked playback rather than initial empty-trail setup.
		var playback_time := 0.45 + float(frame % 60) / 59.0 * 0.20
		renderer.render_trails(stack.trails_until(playback_time, 15))
		elapsed_usec.append(Time.get_ticks_usec() - started_usec)
		counts.append(renderer.get_child_count())
	var peak_usec := 0
	var total_usec := 0
	for elapsed_value in elapsed_usec:
		var elapsed := int(elapsed_value)
		peak_usec = maxi(peak_usec, elapsed)
		total_usec += elapsed
	var constant_nodes := true
	for count_value in counts:
		constant_nodes = constant_nodes and int(count_value) == instances.size()
	renderer.clear_visuals()
	renderer.queue_free()
	add_result(
		"afterimage_renderer_stacked_playback_keeps_node_count_constant",
		constant_nodes,
		{
			"motionCount": instances.size(),
			"frameCount": elapsed_usec.size(),
			"averageUsec": float(total_usec) / float(maxi(1, elapsed_usec.size())),
			"peakUsec": peak_usec,
			"nodeCounts": counts.slice(0, 8)
		}
	)


func test_runtime_uses_shared_presentation_authority() -> void:
	var source_paths := [
		"res://scripts/combat/runtime/PlayerMotionCombatController.gd",
		"res://scripts/combat/runtime/HostileMotionCombatSystem.gd",
		"res://scripts/testing/combat/ProceduralMotionPocRunner.gd"
	]
	var canonical := "res://scripts/combat/presentation/MotionAfterimageRenderer.gd"
	var legacy := "res://scripts/combat/poc/MotionAfterimageRenderer.gd"
	var correct := true
	var mismatches: Array = []
	for source_path in source_paths:
		var file := FileAccess.open(source_path, FileAccess.READ)
		var source := file.get_as_text() if file != null else ""
		if not source.contains(canonical) or source.contains(legacy):
			correct = false
			mismatches.append(source_path)
	add_result("runtime_and_poc_share_the_canonical_afterimage_presentation_authority", correct, {"canonical": canonical, "mismatches": mismatches})


func test_motion_layer_has_no_scene_or_combat_dependency() -> void:
	var source_paths := [
		"res://scripts/combat/motion/MotionRecipe.gd",
		"res://scripts/combat/motion/MotionSample.gd",
		"res://scripts/combat/motion/MotionRecipeBuilder.gd",
		"res://scripts/combat/motion/MotionPrimitive.gd",
		"res://scripts/combat/motion/MotionInstance.gd",
		"res://scripts/combat/motion/MotionStack.gd",
		"res://scripts/combat/contact/MotionVolumeRecipe.gd",
		"res://scripts/combat/contact/MotionVolumeRecipeBuilder.gd",
		"res://scripts/combat/contact/MotionVolumeSample.gd",
		"res://scripts/combat/contact/MotionVolumeSweepSample.gd",
		"res://scripts/combat/contact/MotionVolumeSampler.gd",
		"res://scripts/combat/contact/PassiveContactSphere.gd",
		"res://scripts/combat/contact/MotionContactResolution.gd",
		"res://scripts/combat/contact/MotionContactResolver.gd"
	]
	var forbidden := ["extends Node", "Node3D", "SceneTree", "Physics", "Area3D", "ShapeCast3D", "CharacterBody3D", "Skeleton3D", "Hitbox", "Damage", "Hostile", "Npc", "Player"]
	var clean := true
	var matches: Array = []
	for source_path in source_paths:
		var file := FileAccess.open(source_path, FileAccess.READ)
		if file == null:
			clean = false
			matches.append("missing:%s" % source_path)
			continue
		var source := file.get_as_text()
		for term in forbidden:
			if source.contains(term):
				clean = false
				matches.append("%s:%s" % [source_path, term])
	add_result("pure_motion_layer_has_no_scene_physics_or_combat_dependency", clean, {"matches": matches})


func add_result(name: String, passed: bool, details: Dictionary = {}) -> void:
	results.append({"name": name, "passed": passed, "details": details})


func snapshots_for(samples: Array) -> Array:
	var snapshots: Array = []
	for sample in samples:
		if sample != null and sample.has_method("snapshot"):
			snapshots.append(sample.snapshot())
	return snapshots


func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count


func write_report() -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var report := {
		"schemaVersion": 1,
		"runnerId": "procedural_motion_contract",
		"evidenceLevel": "contract",
		"passed": failure_count() == 0,
		"resultCount": results.size(),
		"failureCount": failure_count(),
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
