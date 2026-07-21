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
const LiveCollisionContactGeometryAdapterScript := preload("res://scripts/combat/runtime/LiveCollisionContactGeometryAdapter.gd")
const CombatTargetPolicyScript := preload("res://scripts/combat/CombatTargetPolicy.gd")

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
var performance_monitor
var contact_target_provider: Callable
var contact_resolution_handler: Callable


func setup(player_node: CharacterBody3D, hostile_owner, base_seed: int, runtime_monitor = null) -> void:
	player = player_node
	hostile_system = hostile_owner
	deterministic_seed = maxi(1, abs(base_seed))
	performance_monitor = runtime_monitor
	afterimage_renderer = MotionAfterimageRendererScript.new()
	afterimage_renderer.name = "PlayerMotionAfterimage"
	var camera = player.get("camera") as Camera3D if player != null else null
	if camera != null and is_instance_valid(camera):
		camera.add_child(afterimage_renderer)
	else:
		add_child(afterimage_renderer)
	set_physics_process(true)


func configure_contact_adapter(target_provider: Callable, resolution_handler: Callable = Callable()) -> void:
	# Optional arena/fixture composition point. Normal gameplay leaves these
	# invalid and continues through HostileSystem exactly as before.
	contact_target_provider = target_provider
	contact_resolution_handler = resolution_handler


func begin_side_arc_motion(damage: float) -> bool:
	# Keep the original explicit lateral entry point for callers that require the
	# established trajectory. Normal gameplay enters through begin_arc_motion()
	# below, where the stable motion seed selects a generic plane profile.
	return begin_arc_motion(damage, "lateral")


func begin_arc_motion(damage: float, plane_profile := "seeded") -> bool:
	if player == null or not is_instance_valid(player) or is_motion_active():
		return false
	motion_serial += 1
	var seed := motion_seed(motion_serial)
	var recipe_started: int = performance_monitor.begin_section("player_motion_recipe") if performance_monitor != null else Time.get_ticks_usec()
	motion_recipe = MotionRecipeBuilderScript.build_arc(seed, {"planeProfile": plane_profile})
	volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(seed)
	if performance_monitor != null:
		performance_monitor.end_section("player_motion_recipe", recipe_started)
	var direction := -1.0 if motion_serial % 2 == 0 else 1.0
	var instance = MotionInstanceScript.new({
		"instanceId": "player_arc_%d" % motion_serial,
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
	var render_started: int = performance_monitor.begin_section("player_motion_render") if performance_monitor != null else Time.get_ticks_usec()
	render_current_motion()
	if performance_monitor != null:
		performance_monitor.end_section("player_motion_render", render_started)
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
	var contact_started: int = performance_monitor.begin_section("player_motion_contact") if performance_monitor != null else Time.get_ticks_usec()
	resolve_contacts(previous_time, current_time)
	if performance_monitor != null:
		performance_monitor.end_section("player_motion_contact", contact_started)
	var render_started: int = performance_monitor.begin_section("player_motion_render") if performance_monitor != null else Time.get_ticks_usec()
	render_current_motion()
	if performance_monitor != null:
		performance_monitor.end_section("player_motion_render", render_started)
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
	if volume_recipe == null:
		return
	var targets: Array = contact_target_provider.call() if contact_target_provider.is_valid() else LiveHostileContactTargetAdapterScript.targets_from_hostile_system(hostile_system)
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
	if body == null or not is_instance_valid(body) or not CombatTargetPolicyScript.can_damage("player", "hostile"):
		return
	if contact_resolution_handler.is_valid():
		var result = contact_resolution_handler.call(target, resolution.snapshot(), requested_damage)
		var consequence: Dictionary = result if result is Dictionary else {}
		var defeated := bool(consequence.get("defeated", false))
		var position: Vector3 = consequence.get("position", body.global_position + Vector3.UP * 0.82) as Vector3
		hostile_contact_resolved.emit(body, String(consequence.get("variant", target.get("variant", "hostile"))), defeated, position, resolution.snapshot())
		return
	if hostile_system == null:
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


func clear_transient_state() -> void:
	# Active motion/contact windows are deliberately not durable save state.
	# Clear the presentation and pending contributors without inventing an
	# equivalent snapshot authority.
	if afterimage_renderer != null:
		afterimage_renderer.clear_visuals()
	active_stack = null
	motion_recipe = null
	volume_recipe = null
	requested_damage = 0.0
	elapsed_seconds = 0.0
	previous_volumes_by_instance.clear()
	resolved_target_ids.clear()
	resolved_count = 0


func active_phase() -> String:
	if not is_motion_active() or active_stack == null:
		return "inactive"
	var samples: Array = active_stack.samples_at(normalized_time())
	return String(samples[0].phase) if not samples.is_empty() and samples[0] != null else "inactive"


func threat_snapshot_for_body(target_body: Node3D, lookahead_seconds := 0.16) -> Dictionary:
	# Read-only projected contact fact for reactive opponents. This samples the
	# existing player motion + volume path; it never observes presentation.
	if target_body == null or not is_instance_valid(target_body):
		return {"viable": false, "reason": "target_unavailable"}
	if not is_motion_active() or volume_recipe == null:
		return {"viable": false, "reason": "player_motion_inactive", "phase": active_phase()}
	var current_time := normalized_time()
	var projected_time := clampf(current_time + maxf(0.0, lookahead_seconds) / MOTION_DURATION_SECONDS, current_time, 1.0)
	var geometry := LiveCollisionContactGeometryAdapterScript.passive_spheres_for_body(target_body, "threat:%d" % target_body.get_instance_id())
	if geometry.is_empty():
		return {"viable": false, "reason": "target_geometry_unavailable", "phase": active_phase()}
	# Evaluate the full bounded look-ahead window rather than one endpoint. A
	# side arc can cross the target between two sampled endpoints; the identical
	# shared resolver catches that swept-sheet contact without consulting visuals.
	var resolutions: Array = MotionContactResolverScript.resolve_window(active_stack, volume_recipe, geometry, current_time, projected_time, 8)
	if not resolutions.is_empty():
		return {
			"viable": true,
			"reason": "predicted_contact_volume",
			"phase": active_phase(),
			"projectedTime": projected_time,
			"resolution": resolutions[0].snapshot()
		}
	return {"viable": false, "reason": "volume_miss", "phase": active_phase(), "projectedTime": projected_time}


func summary() -> Dictionary:
	return {
		"active": is_motion_active(),
		"serial": motion_serial,
		"normalizedTime": normalized_time(),
		"phase": active_phase(),
		"damage": requested_damage,
		"resolvedTargets": resolved_count,
		"motion": motion_recipe.snapshot() if motion_recipe != null else {},
		"volume": volume_recipe.snapshot() if volume_recipe != null else {}
	}
