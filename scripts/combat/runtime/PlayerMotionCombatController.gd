extends Node3D
class_name PlayerMotionCombatController

const MotionRecipeBuilderScript := preload("res://scripts/combat/motion/MotionRecipeBuilder.gd")
const MotionInstanceScript := preload("res://scripts/combat/motion/MotionInstance.gd")
const MotionStackScript := preload("res://scripts/combat/motion/MotionStack.gd")
const MotionSampleSpaceTransformerScript := preload("res://scripts/combat/motion/MotionSampleSpaceTransformer.gd")
const MotionVolumeRecipeBuilderScript := preload("res://scripts/combat/contact/MotionVolumeRecipeBuilder.gd")
const MotionVolumeSamplerScript := preload("res://scripts/combat/contact/MotionVolumeSampler.gd")
const MotionContactResolverScript := preload("res://scripts/combat/contact/MotionContactResolver.gd")
const MotionAfterimageRendererScript := preload("res://scripts/combat/presentation/MotionAfterimageRenderer.gd")
const LiveHostileContactTargetAdapterScript := preload("res://scripts/combat/runtime/LiveHostileContactTargetAdapter.gd")

## The first live consumer of the motion PoC. It owns temporal playback and
## turns real hostile collider data into passive inputs for the shared resolver.
## It deliberately does not own input routing, item identity, damage values,
## drops, XP, HUD feedback, enemy AI, or world collision.

signal motion_started(summary: Dictionary)
signal hostile_contact_resolved(body, variant: String, defeated: bool, position: Vector3, resolution: Dictionary)
signal motion_finished(summary: Dictionary)

const MOTION_DURATION_SECONDS := 0.46
const TRAIL_SAMPLE_COUNT := 17
const PLAYER_CONTACT_ANCHOR_HEIGHT := 0.46
const FIRST_PERSON_PRESENTATION_OFFSET := Vector3(0.18, -0.34, -1.10)
const FIRST_PERSON_PRESENTATION_SCALE := 0.32

var player: CharacterBody3D
var hostile_system
var deterministic_seed := 1543
var motion_serial := 0
var elapsed_seconds := 0.0
var active_stack
var motion_recipe
var volume_recipe
var requested_damage := 0.0
var previous_volumes_by_instance: Dictionary = {}
var resolved_target_ids: Dictionary = {}
var resolved_count := 0
var afterimage_renderer


func setup(player_node: CharacterBody3D, hostile_owner, base_seed: int) -> void:
	player = player_node
	hostile_system = hostile_owner
	deterministic_seed = maxi(1, abs(base_seed))
	afterimage_renderer = MotionAfterimageRendererScript.new()
	afterimage_renderer.name = "PlayerMotionAfterimage"
	var camera = player.get("camera") as Camera3D if player != null else null
	if camera != null and is_instance_valid(camera):
		camera.add_child(afterimage_renderer)
	else:
		add_child(afterimage_renderer)
	set_physics_process(true)


func begin_side_arc_motion(damage: float) -> bool:
	if player == null or not is_instance_valid(player) or is_motion_active():
		return false
	motion_serial += 1
	var seed := motion_seed(motion_serial)
	motion_recipe = MotionRecipeBuilderScript.build_side_arc(seed)
	volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(seed)
	var direction := -1.0 if motion_serial % 2 == 0 else 1.0
	var instance = MotionInstanceScript.new({
		"instanceId": "player_side_arc_%d" % motion_serial,
		"recipe": motion_recipe,
		"anchorId": "player_combat_anchor",
		"direction": direction
	})
	active_stack = MotionStackScript.new("player_motion_stack_%d" % motion_serial, [instance])
	requested_damage = maxf(0.0, damage)
	elapsed_seconds = 0.0
	previous_volumes_by_instance.clear()
	resolved_target_ids.clear()
	resolved_count = 0
	render_current_motion()
	motion_started.emit(summary())
	return true


func is_motion_active() -> bool:
	return active_stack != null and elapsed_seconds < MOTION_DURATION_SECONDS


func _physics_process(delta: float) -> void:
	if not is_motion_active():
		return
	var previous_time := normalized_time()
	elapsed_seconds = minf(MOTION_DURATION_SECONDS, elapsed_seconds + maxf(0.0, delta))
	var current_time := normalized_time()
	resolve_contacts(previous_time, current_time)
	render_current_motion()
	if elapsed_seconds >= MOTION_DURATION_SECONDS:
		finish_motion()


func normalized_time() -> float:
	return clampf(elapsed_seconds / MOTION_DURATION_SECONDS, 0.0, 1.0)


func motion_seed(serial: int) -> int:
	return posmod(deterministic_seed + serial * 7919, 2147483629)


func player_contact_space() -> Transform3D:
	if player == null or not is_instance_valid(player):
		return Transform3D.IDENTITY
	# Player yaw, rather than camera pitch, owns the physical sweep plane. The
	# motion recipe supplies its own deterministic non-horizontal angle.
	return Transform3D(player.global_transform.basis.orthonormalized(), player.global_position + Vector3.UP * PLAYER_CONTACT_ANCHOR_HEIGHT)


func player_presentation_space() -> Transform3D:
	# The visual uses the exact local motion samples, but renders in the camera's
	# local coordinate space at a stable offset. A world-space arc surrounds the
	# first-person camera and therefore projects as a screen-filling diagonal.
	# This is a presentation-space adapter, not a second motion, hitbox, or
	# authored weapon pose; collision remains in player_contact_space().
	return Transform3D(Basis.from_scale(Vector3.ONE * FIRST_PERSON_PRESENTATION_SCALE), FIRST_PERSON_PRESENTATION_OFFSET)


func local_motion_samples(global_time: float) -> Array:
	return active_stack.samples_at(global_time) if active_stack != null else []


func world_motion_samples(global_time: float) -> Array:
	var result: Array = []
	var space := player_contact_space()
	for local_sample in local_motion_samples(global_time):
		result.append(MotionSampleSpaceTransformerScript.transform_sample(local_sample, space))
	return result


func resolve_contacts(previous_time: float, current_time: float) -> void:
	if volume_recipe == null or hostile_system == null:
		return
	var targets: Array = LiveHostileContactTargetAdapterScript.targets_from_hostile_system(hostile_system)
	if targets.is_empty():
		return
	var current_volumes: Array = []
	for world_sample in world_motion_samples(current_time):
		var volume = MotionVolumeSamplerScript.sample(volume_recipe, world_sample)
		if volume.active:
			current_volumes.append(volume)
	for current_volume in current_volumes:
		var previous_volume = previous_volumes_by_instance.get(current_volume.instance_id, null)
		for target in targets:
			var target_id := String(target.get("targetId", ""))
			if target_id == "" or resolved_target_ids.has(target_id):
				continue
			var geometry = target.get("geometry", null)
			var resolution = MotionContactResolverScript.resolve_transition(previous_volume, current_volume, geometry)
			if not resolution.resolved:
				continue
			resolved_target_ids[target_id] = resolution.event_key()
			resolved_count += 1
			resolve_hostile_consequence(target, resolution)
		previous_volumes_by_instance[current_volume.instance_id] = current_volume


func resolve_hostile_consequence(target: Dictionary, resolution) -> void:
	var body = target.get("body", null)
	if body == null or not is_instance_valid(body) or hostile_system == null:
		return
	var defeated: bool = bool(hostile_system.damage_hostile(body, requested_damage, true, player, "player_melee"))
	var position: Vector3 = body.global_position + Vector3.UP * 0.82 if body is Node3D else Vector3.INF
	hostile_contact_resolved.emit(body, String(target.get("variant", "shadow")), defeated, position, resolution.snapshot())


func render_current_motion() -> void:
	if afterimage_renderer == null or active_stack == null:
		return
	var trails: Array = active_stack.trails_until(normalized_time(), TRAIL_SAMPLE_COUNT)
	var world_trails: Array = MotionSampleSpaceTransformerScript.transform_trails(trails, player_presentation_space())
	afterimage_renderer.render_trails(world_trails)


func finish_motion() -> void:
	if afterimage_renderer != null:
		afterimage_renderer.clear_visuals()
	var finished_summary := summary()
	active_stack = null
	motion_recipe = null
	volume_recipe = null
	previous_volumes_by_instance.clear()
	motion_finished.emit(finished_summary)


func summary() -> Dictionary:
	return {
		"active": is_motion_active(),
		"serial": motion_serial,
		"normalizedTime": normalized_time(),
		"damage": requested_damage,
		"resolvedTargets": resolved_count,
		"motion": motion_recipe.snapshot() if motion_recipe != null else {},
		"volume": volume_recipe.snapshot() if volume_recipe != null else {}
	}
