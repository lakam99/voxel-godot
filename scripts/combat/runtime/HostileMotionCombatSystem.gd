extends Node3D
class_name HostileMotionCombatSystem

const MotionRecipeBuilderScript := preload("res://scripts/combat/motion/MotionRecipeBuilder.gd")
const MotionInstanceScript := preload("res://scripts/combat/motion/MotionInstance.gd")
const MotionStackScript := preload("res://scripts/combat/motion/MotionStack.gd")
const MotionSampleSpaceTransformerScript := preload("res://scripts/combat/motion/MotionSampleSpaceTransformer.gd")
const MotionVolumeRecipeBuilderScript := preload("res://scripts/combat/contact/MotionVolumeRecipeBuilder.gd")
const MotionVolumeSamplerScript := preload("res://scripts/combat/contact/MotionVolumeSampler.gd")
const MotionContactResolverScript := preload("res://scripts/combat/contact/MotionContactResolver.gd")
const MotionAfterimageRendererScript := preload("res://scripts/combat/presentation/MotionAfterimageRenderer.gd")
const MotionTelegraphRendererScript := preload("res://scripts/combat/presentation/MotionTelegraphRenderer.gd")
const LiveCollisionContactGeometryAdapterScript := preload("res://scripts/combat/runtime/LiveCollisionContactGeometryAdapter.gd")

## Hostile-facing runtime adapter for the shared procedural motion layer. It
## samples recipe/contact math and emits a contact fact; HostileSystem keeps
## ownership of damage, NPC consequences, drops, and combat policy.

signal motion_started(source_body, target, target_kind: String, variant: String, summary: Dictionary)
signal motion_contact_resolved(source_body, target, target_kind: String, damage: float, variant: String, resolution: Dictionary)
signal motion_finished(source_body, summary: Dictionary)

const MOTION_DURATION_SECONDS := 0.62
const TRAIL_SAMPLE_COUNT := 15

var active_by_source_id: Dictionary = {}
var performance_monitor


func setup(runtime_monitor = null) -> void:
	performance_monitor = runtime_monitor


func begin_side_arc_motion(source_body: Node3D, target: Node3D, target_kind: String, damage: float, variant: String, recipe_seed: int, show_telegraph := false) -> bool:
	var recipe_started: int = performance_monitor.begin_section("hostile_motion_recipe") if performance_monitor != null else Time.get_ticks_usec()
	var recipe = MotionRecipeBuilderScript.build_side_arc(recipe_seed)
	if performance_monitor != null:
		performance_monitor.end_section("hostile_motion_recipe", recipe_started)
	return begin_recipe_motion(
		source_body,
		target,
		target_kind,
		damage,
		variant,
		recipe,
		show_telegraph
	)


func begin_arc_motion(source_body: Node3D, target: Node3D, target_kind: String, damage: float, variant: String, recipe_seed: int, plane_profile := "seeded", show_telegraph := false) -> bool:
	var recipe_started: int = performance_monitor.begin_section("hostile_motion_recipe") if performance_monitor != null else Time.get_ticks_usec()
	var recipe = MotionRecipeBuilderScript.build_arc(recipe_seed, {"planeProfile": plane_profile})
	if performance_monitor != null:
		performance_monitor.end_section("hostile_motion_recipe", recipe_started)
	return begin_recipe_motion(
		source_body,
		target,
		target_kind,
		damage,
		variant,
		recipe,
		show_telegraph
	)


func begin_forward_surge_motion(source_body: Node3D, target: Node3D, target_kind: String, damage: float, variant: String, recipe_seed: int, show_telegraph := false) -> bool:
	var recipe_started: int = performance_monitor.begin_section("hostile_motion_recipe") if performance_monitor != null else Time.get_ticks_usec()
	var recipe = MotionRecipeBuilderScript.build_forward_surge(recipe_seed)
	if performance_monitor != null:
		performance_monitor.end_section("hostile_motion_recipe", recipe_started)
	# This is not a special combat path. The generic recipe simply follows its
	# source while the caller's real CharacterBody3D motor executes movement.
	return begin_recipe_motion(source_body, target, target_kind, damage, variant, recipe, show_telegraph, true)


func begin_recipe_motion(source_body: Node3D, target: Node3D, target_kind: String, damage: float, variant: String, recipe, show_telegraph := false, follow_source := false) -> bool:
	if source_body == null or target == null or not is_instance_valid(source_body) or not is_instance_valid(target):
		return false
	var source_id := source_body.get_instance_id()
	if active_by_source_id.has(source_id):
		return false
	var recipe_seed := int(recipe.seed) if recipe != null else 1
	var direction := -1.0 if MotionRecipeBuilderScript.hash01(recipe_seed, "side") < 0.5 else 1.0
	var instance = MotionInstanceScript.new({
		"instanceId": "hostile_arc_%d" % source_id,
		"recipe": recipe,
		"anchorId": "hostile_combat_anchor",
		"direction": direction
	})
	var stack = MotionStackScript.new("hostile_motion_stack_%d" % source_id, [instance])
	var renderer = MotionAfterimageRendererScript.new()
	renderer.name = "HostileMotionAfterimage_%d" % source_id
	# Hostile-source ribbons are telegraphs first: keep the same sampled shape
	# legible when it traverses through the originating body from the player's
	# viewpoint. Contact remains exclusively depth-independent physics math.
	renderer.set_draw_over_depth(true)
	add_child(renderer)
	var telegraph = null
	if show_telegraph:
		telegraph = MotionTelegraphRendererScript.new()
		telegraph.name = "HostileMotionTelegraph_%d" % source_id
		add_child(telegraph)
	var contact_anchor := hostile_contact_space(source_body, target)
	# A volume recipe says which shared primitive phase is able to contact. This
	# keeps forward motion generic: it changes the phase name, not the combat
	# resolver, damage path, or collision ownership.
	var active_phases: Array = ["arc"]
	if recipe != null and String(recipe.primitive_id) == "forward_surge_motion":
		active_phases = ["surge"]
	var entry := {
		"source": source_body,
		"target": target,
		"targetKind": target_kind,
		"variant": variant,
		"damage": maxf(0.0, damage),
		"recipe": recipe,
		"volume": MotionVolumeRecipeBuilderScript.build_capsule_segment(recipe_seed, {"activePhases": active_phases}),
		"stack": stack,
		# Contact and presentation consume the exact same local samples. The
		# contact anchor preserves physical reach; the presentation adapter keeps
		# that same curve legible between two actors at first-person melee range.
		"contactAnchor": contact_anchor,
		"presentationAnchor": hostile_presentation_space(contact_anchor, source_body, target, recipe),
		"elapsed": 0.0,
		"previousVolumes": {},
		"resolved": false,
		"renderer": renderer,
		"telegraph": telegraph,
		"followSource": follow_source
	}
	active_by_source_id[source_id] = entry
	render_entry(entry)
	motion_started.emit(source_body, target, target_kind, variant, summary_for(entry))
	return true


func is_motion_active(source_body: Node3D) -> bool:
	return source_body != null and is_instance_valid(source_body) and active_by_source_id.has(source_body.get_instance_id())


func cancel_for_body(source_body: Node3D) -> void:
	if source_body == null:
		return
	finish_entry(source_body.get_instance_id(), false)


func clear_transient_state() -> void:
	for source_id_value in active_by_source_id.keys().duplicate():
		finish_entry(int(source_id_value), false)


func active_motion_count() -> int:
	return active_by_source_id.size()


func summary_for_body(source_body: Node3D) -> Dictionary:
	if source_body == null or not is_instance_valid(source_body):
		return {}
	var entry: Dictionary = active_by_source_id.get(source_body.get_instance_id(), {})
	return summary_for(entry) if not entry.is_empty() else {}


func _physics_process(delta: float) -> void:
	for source_id_value in active_by_source_id.keys().duplicate():
		var source_id := int(source_id_value)
		var entry: Dictionary = active_by_source_id.get(source_id, {})
		var source := entry.get("source") as Node3D
		var target := entry.get("target") as Node3D
		if source == null or target == null or not is_instance_valid(source) or not is_instance_valid(target):
			finish_entry(source_id, false)
			continue
		if bool(entry.get("followSource", false)):
			var updated_anchor := hostile_contact_space(source, target)
			entry["contactAnchor"] = updated_anchor
			entry["presentationAnchor"] = hostile_presentation_space(updated_anchor, source, target, entry.get("recipe", null))
		entry["elapsed"] = minf(MOTION_DURATION_SECONDS, float(entry.get("elapsed", 0.0)) + maxf(0.0, delta))
		var contact_started: int = performance_monitor.begin_section("hostile_motion_contact") if performance_monitor != null else Time.get_ticks_usec()
		resolve_entry_contact(entry)
		if performance_monitor != null:
			performance_monitor.end_section("hostile_motion_contact", contact_started)
		var render_started: int = performance_monitor.begin_section("hostile_motion_render") if performance_monitor != null else Time.get_ticks_usec()
		render_entry(entry)
		if performance_monitor != null:
			performance_monitor.end_section("hostile_motion_render", render_started)
		active_by_source_id[source_id] = entry
		if float(entry.get("elapsed", 0.0)) >= MOTION_DURATION_SECONDS:
			finish_entry(source_id, true)


func hostile_contact_space(source_body: Node3D, target: Node3D) -> Transform3D:
	var scale := 1.0
	var spec: Dictionary = source_body.get_meta("hostile_pool_spec", {}) if source_body.has_meta("hostile_pool_spec") else {}
	if spec is Dictionary:
		scale = float((spec as Dictionary).get("scale", 1.0))
	# MotionPrimitive supplies its own deterministic start height. Use the same
	# lower-body anchor convention as the player so a hostile capsule crosses an
	# actor's real central collision extent instead of beginning above it.
	var origin := source_body.global_position + Vector3.UP * 0.46 * scale
	var target_position := target.global_position
	target_position.y = origin.y
	var horizontal_delta := target_position - origin
	if horizontal_delta.length_squared() <= 0.000001:
		return Transform3D(source_body.global_transform.basis.orthonormalized(), origin)
	# MotionPrimitive defines local forward as -Z. looking_at therefore gives the
	# shared motion frame an unambiguous target-facing direction regardless of a
	# legacy hostile mesh's own front-axis convention.
	return Transform3D(Basis.IDENTITY, origin).looking_at(target_position, Vector3.UP)


func hostile_presentation_space(contact_anchor: Transform3D, source_body: Node3D, target: Node3D, recipe) -> Transform3D:
	# A physical side arc can reach 3+ metres while an enemy begins it roughly
	# two metres from the first-person camera. Rendering that unscaled physical
	# curve therefore places most of the ribbon beyond or behind the viewer.
	# This is the same local motion curve under a generic display transform, not
	# a second animation or hitbox: contacts always use contact_anchor above.
	var source_position := source_body.global_position if source_body != null and is_instance_valid(source_body) else contact_anchor.origin
	var target_position := target.global_position if target != null and is_instance_valid(target) else source_position
	var horizontal_distance := source_position.distance_to(target_position)
	var physical_reach := float(recipe.parameters.get("reach", 3.0)) if recipe != null else 3.0
	# Keep the nearest part of the display roughly a metre from a first-person
	# target. This preserves a readable swing rather than letting a full physical
	# reach pass through the camera and fill the viewport. The scale still derives
	# entirely from the real source-target relationship and recipe.
	var readable_reach := clampf(minf(horizontal_distance * 0.50, maxf(0.40, horizontal_distance - 0.95)), 0.35, 1.15)
	var display_scale := readable_reach / maxf(physical_reach, 0.001)
	return Transform3D(contact_anchor.basis * display_scale, contact_anchor.origin)


func normalized_time(entry: Dictionary) -> float:
	return clampf(float(entry.get("elapsed", 0.0)) / MOTION_DURATION_SECONDS, 0.0, 1.0)


func world_samples(entry: Dictionary) -> Array:
	var stack = entry.get("stack", null)
	if stack == null:
		return []
	var result: Array = []
	var anchor: Transform3D = entry.get("contactAnchor", Transform3D.IDENTITY)
	for sample in stack.samples_at(normalized_time(entry)):
		result.append(MotionSampleSpaceTransformerScript.transform_sample(sample, anchor))
	return result


func resolve_entry_contact(entry: Dictionary) -> void:
	if bool(entry.get("resolved", false)):
		return
	var target := entry.get("target") as Node3D
	var source := entry.get("source") as Node3D
	if target == null or source == null:
		return
	var target_id := "actor:%d" % target.get_instance_id()
	var target_geometry := LiveCollisionContactGeometryAdapterScript.passive_spheres_for_body(target, target_id)
	if target_geometry.is_empty():
		return
	var volume_recipe = entry.get("volume", null)
	var previous_volumes: Dictionary = entry.get("previousVolumes", {})
	for motion_sample in world_samples(entry):
		var current_volume = MotionVolumeSamplerScript.sample(volume_recipe, motion_sample)
		if not current_volume.active:
			continue
		var previous_volume = previous_volumes.get(current_volume.instance_id, null)
		for geometry in target_geometry:
			var resolution = MotionContactResolverScript.resolve_transition(previous_volume, current_volume, geometry)
			if not resolution.resolved:
				continue
			entry["resolved"] = true
			motion_contact_resolved.emit(
				source,
				target,
				String(entry.get("targetKind", "")),
				float(entry.get("damage", 0.0)),
				String(entry.get("variant", "shadow")),
				resolution.snapshot()
			)
			break
		previous_volumes[current_volume.instance_id] = current_volume
		if bool(entry.get("resolved", false)):
			break
	entry["previousVolumes"] = previous_volumes


func render_entry(entry: Dictionary) -> void:
	var renderer = entry.get("renderer", null)
	var stack = entry.get("stack", null)
	if renderer == null or stack == null:
		return
	var trails: Array = stack.trails_until(normalized_time(entry), TRAIL_SAMPLE_COUNT)
	var anchor: Transform3D = entry.get("presentationAnchor", Transform3D.IDENTITY)
	var world_trails: Array = MotionSampleSpaceTransformerScript.transform_trails(trails, anchor)
	renderer.render_trails(world_trails)
	var telegraph = entry.get("telegraph", null)
	var source := entry.get("source") as Node3D
	if telegraph != null and is_instance_valid(telegraph) and telegraph.has_method("render_for"):
		telegraph.render_for(source, entry.get("recipe", null), normalized_time(entry))


func finish_entry(source_id: int, emit_finished: bool) -> void:
	var entry: Dictionary = active_by_source_id.get(source_id, {})
	if entry.is_empty():
		return
	active_by_source_id.erase(source_id)
	var renderer = entry.get("renderer", null)
	if renderer != null and is_instance_valid(renderer):
		renderer.clear_visuals()
		renderer.queue_free()
	var telegraph = entry.get("telegraph", null)
	if telegraph != null and is_instance_valid(telegraph):
		telegraph.queue_free()
	var source := entry.get("source") as Node3D
	if emit_finished and source != null and is_instance_valid(source):
		motion_finished.emit(source, summary_for(entry))


func summary_for(entry: Dictionary) -> Dictionary:
	var recipe = entry.get("recipe", null)
	var volume = entry.get("volume", null)
	var phase := "inactive"
	var stack = entry.get("stack", null)
	if stack != null and stack.has_method("samples_at"):
		var samples: Array = stack.samples_at(normalized_time(entry))
		if not samples.is_empty() and samples[0] != null:
			phase = String(samples[0].phase)
	return {
		"active": true,
		"normalizedTime": normalized_time(entry),
		"phase": phase,
		"targetKind": String(entry.get("targetKind", "")),
		"variant": String(entry.get("variant", "shadow")),
		"damage": float(entry.get("damage", 0.0)),
		"resolved": bool(entry.get("resolved", false)),
		"motion": recipe.snapshot() if recipe != null else {},
		"volume": volume.snapshot() if volume != null else {}
	}
