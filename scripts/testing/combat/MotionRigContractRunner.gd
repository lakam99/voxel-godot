extends SceneTree

const MotionRecipeBuilderScript := preload("res://scripts/combat/motion/MotionRecipeBuilder.gd")
const MotionInstanceScript := preload("res://scripts/combat/motion/MotionInstance.gd")
const MotionStackScript := preload("res://scripts/combat/motion/MotionStack.gd")
const MotionRigProfileScript := preload("res://scripts/combat/rig/MotionRigProfile.gd")
const MotionPoseSignalBuilderScript := preload("res://scripts/combat/rig/MotionPoseSignalBuilder.gd")
const MotionPoseSolverScript := preload("res://scripts/combat/rig/MotionPoseSolver.gd")
const MotionRigVisualFactoryScript := preload("res://scripts/combat/rig/MotionRigVisualFactory.gd")
const HostileVisualFactoryScript := preload("res://scripts/HostileVisualFactory.gd")
const MotionEquipmentProfileScript := preload("res://scripts/combat/equipment/MotionEquipmentProfile.gd")
const MotionEquipmentAdapterScript := preload("res://scripts/combat/equipment/MotionEquipmentAdapter.gd")
const MotionVolumeRecipeBuilderScript := preload("res://scripts/combat/contact/MotionVolumeRecipeBuilder.gd")
const MotionContactResolverScript := preload("res://scripts/combat/contact/MotionContactResolver.gd")
const PassiveContactSphereScript := preload("res://scripts/combat/contact/PassiveContactSphere.gd")

var report_path := ""
var results: Array[Dictionary] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	report_path = OS.get_environment("VOXEL_MOTION_RIG_CONTRACT_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/combat/motion-rig-contract.json")
	test_pose_signals_replay_deterministically()
	test_sweep_axis_is_continuous_across_motion_reversals()
	test_stacked_motions_keep_separate_pose_contributors()
	test_quadruped_and_biped_profiles_validate()
	test_generated_shadow_stalker_mesh_and_rig_validate()
	test_generated_frost_predator_mesh_and_rig_validate()
	test_declared_locomotion_gait_uses_velocity_without_moving_the_body()
	test_declared_gaze_tracks_target_without_turning_the_body()
	test_movement_gaze_releases_target_tracking_smoothly()
	test_missing_required_role_is_rejected_explicitly()
	test_same_arc_selects_anatomy_by_profile()
	test_pose_driver_never_moves_parent_body()
	test_equipped_contact_segment_follows_selected_lead_socket()
	test_equipped_item_is_prepared_on_the_selected_swinging_arm()
	test_equipped_blade_crosses_the_arena_target_corridor()
	write_report()
	quit(0 if failure_count() == 0 else 1)


func test_pose_signals_replay_deterministically() -> void:
	var first_stack = arc_stack(1543, 1.0)
	var second_stack = arc_stack(1543, 1.0)
	var first = MotionPoseSignalBuilderScript.build_for_stack(first_stack, 0.49)
	var second = MotionPoseSignalBuilderScript.build_for_stack(second_stack, 0.49)
	var exact := first.size() == 1 and second.size() == 1
	if exact:
		var a = first[0]
		var b = second[0]
		exact = a.phase == b.phase and is_equal_approx(a.side, b.side) and a.local_direction.is_equal_approx(b.local_direction) and a.role_weights == b.role_weights
	add_result("shared_motion_samples_produce_deterministic_body_neutral_pose_signals", exact, {"first": snapshots(first), "second": snapshots(second)})


func test_sweep_axis_is_continuous_across_motion_reversals() -> void:
	var stack = arc_stack(1543, 1.0)
	var recipe = stack.instances[0].recipe
	var strike_start := float(recipe.parameters.get("windupFraction", 0.25))
	var recovery_start := strike_start + float(recipe.parameters.get("strikeFraction", 0.40))
	var before_strike = MotionPoseSignalBuilderScript.build_for_stack(stack, strike_start - 0.001)[0]
	var after_strike = MotionPoseSignalBuilderScript.build_for_stack(stack, strike_start + 0.001)[0]
	var before_recovery = MotionPoseSignalBuilderScript.build_for_stack(stack, recovery_start - 0.001)[0]
	var after_recovery = MotionPoseSignalBuilderScript.build_for_stack(stack, recovery_start + 0.001)[0]
	var strike_angle := rad_to_deg(before_strike.motion_direction.angle_to(after_strike.motion_direction))
	var recovery_angle := rad_to_deg(before_recovery.motion_direction.angle_to(after_recovery.motion_direction))
	var continuous := strike_angle < 8.0 and recovery_angle < 8.0
	add_result("sweep_axis_stays_continuous_when_the_path_reverses", continuous, {"strikeBoundaryDegrees": strike_angle, "recoveryBoundaryDegrees": recovery_angle, "beforeStrike": before_strike.snapshot(), "afterStrike": after_strike.snapshot(), "beforeRecovery": before_recovery.snapshot(), "afterRecovery": after_recovery.snapshot()})


func test_stacked_motions_keep_separate_pose_contributors() -> void:
	var left = MotionInstanceScript.new({"instanceId": "left", "recipe": MotionRecipeBuilderScript.build_arc(1543, {"planeProfile": "lateral"}), "anchorId": "shared", "direction": -1.0})
	var right = MotionInstanceScript.new({"instanceId": "right", "recipe": MotionRecipeBuilderScript.build_arc(7651, {"planeProfile": "rising"}), "anchorId": "shared", "direction": 1.0, "startOffset": 0.08})
	var signals = MotionPoseSignalBuilderScript.build_for_stack(MotionStackScript.new("stack", [left, right]), 0.52)
	var ids: Array[String] = []
	for pose_signal in signals:
		ids.append(String(pose_signal.instance_id))
	add_result("stacked_motions_keep_independent_pose_signal_contributors", signals.size() == 2 and ids.has("left") and ids.has("right"), {"signals": snapshots(signals)})


func test_quadruped_and_biped_profiles_validate() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var wolf := Node3D.new()
	root.add_child(wolf)
	var construct := Node3D.new()
	root.add_child(construct)
	var fur := material(Color("4e5552"))
	var accent := material(Color("293331"))
	var eye := material(Color("ffd06a"))
	var wolf_result: Dictionary = MotionRigVisualFactoryScript.add_ash_wolf(wolf, 1.0, fur, accent, eye)
	var construct_result: Dictionary = MotionRigVisualFactoryScript.add_training_construct(construct, 1.0, fur, accent, eye)
	var wolf_valid: Dictionary = wolf_result.get("validation", {}) as Dictionary
	var construct_valid: Dictionary = construct_result.get("validation", {}) as Dictionary
	add_result("unlike_quadruped_and_biped_profiles_validate_the_same_semantic_contract", bool(wolf_valid.get("valid", false)) and bool(construct_valid.get("valid", false)), {"wolf": wolf_valid, "construct": construct_valid})
	root.free()


func test_generated_shadow_stalker_mesh_and_rig_validate() -> void:
	# This exercises the registry-backed mesh path used by the arena rather than
	# a hand-built stand-in. The capsule remains a collision child only; all
	# visible anatomy must come from the five generated Stalker parts.
	var root := Node3D.new()
	get_root().add_child(root)
	var stalker := Node3D.new()
	root.add_child(stalker)
	var factory = HostileVisualFactoryScript.new()
	factory.build_visual(stalker, "shadow_stalker")
	var validation: Dictionary = stalker.get_meta("motion_rig_validation", {}) as Dictionary
	var asset_ids: Array = stalker.get_meta("character_asset_parts", []) as Array
	var source := String(stalker.get_meta("visual_source", ""))
	var skeleton := stalker.get_node_or_null("ShadowStalkerMotionSkeleton") as Skeleton3D
	var driver = stalker.get_node_or_null("MotionRigPoseDriver")
	var signals = MotionPoseSignalBuilderScript.build_for_stack(arc_stack(1543, -1.0), 0.52)
	var solution: Dictionary = driver.apply_signals(signals) if driver != null else {}
	var arm_index := skeleton.find_bone("ArmLeft") if skeleton != null else -1
	var arm_direction := skeleton.get_bone_pose_rotation(arm_index) * Vector3.DOWN if arm_index >= 0 else Vector3.ZERO
	var tracks_motion := arm_direction.length_squared() > 0.000001 and arm_direction.normalized().angle_to(signals[0].limb_direction) < deg_to_rad(0.5) if not signals.is_empty() else false
	var expected_assets := ["shadow_stalker_torso", "shadow_stalker_head", "shadow_stalker_arm", "shadow_stalker_leg", "shadow_stalker_tail"]
	var has_all_assets := true
	for asset_id in expected_assets:
		has_all_assets = has_all_assets and asset_ids.has(asset_id)
	var valid := bool(validation.get("valid", false)) and source == "generated_shadow_stalker_mesh" and skeleton != null and has_all_assets and tracks_motion and not (solution.get("contributions", {}) as Dictionary).is_empty()
	add_result("shadow_stalker_uses_generated_anatomy_and_retargets_the_shared_arc_to_its_arm", valid, {"validation": validation, "assetIds": asset_ids, "source": source, "tracksMotion": tracks_motion, "armDirection": arm_direction, "solution": solution})
	root.free()


func test_generated_frost_predator_mesh_and_rig_validate() -> void:
	# The arena must exercise the actual registry-generated cold-predator body,
	# not the older generic frost torso/head path. Both lead signs select their
	# declared forelimb through the same shared pose signal contract.
	var root := Node3D.new()
	get_root().add_child(root)
	var predator := Node3D.new()
	root.add_child(predator)
	var factory = HostileVisualFactoryScript.new()
	factory.build_visual(predator, "frost_predator")
	var validation: Dictionary = predator.get_meta("motion_rig_validation", {}) as Dictionary
	var asset_ids: Array = predator.get_meta("character_asset_parts", []) as Array
	var source := String(predator.get_meta("visual_source", ""))
	var skeleton := predator.get_node_or_null("FrostPredatorMotionSkeleton") as Skeleton3D
	var driver = predator.get_node_or_null("MotionRigPoseDriver")
	var left_signals = MotionPoseSignalBuilderScript.build_for_stack(arc_stack(1543, -1.0), 0.52)
	var left_solution: Dictionary = driver.apply_signals(left_signals) if driver != null else {}
	var left_index := skeleton.find_bone("ForeLeft") if skeleton != null else -1
	var left_direction := skeleton.get_bone_pose_rotation(left_index) * Vector3.DOWN if left_index >= 0 else Vector3.ZERO
	var right_signals = MotionPoseSignalBuilderScript.build_for_stack(arc_stack(7651, 1.0), 0.52)
	var right_solution: Dictionary = driver.apply_signals(right_signals) if driver != null else {}
	var right_index := skeleton.find_bone("ForeRight") if skeleton != null else -1
	var right_direction := skeleton.get_bone_pose_rotation(right_index) * Vector3.DOWN if right_index >= 0 else Vector3.ZERO
	var expected_assets := ["frost_predator_torso", "frost_predator_head", "frost_predator_foreleg", "frost_predator_hindleg", "frost_predator_tail"]
	var has_all_assets := true
	for asset_id in expected_assets:
		has_all_assets = has_all_assets and asset_ids.has(asset_id)
	var left_tracks_motion := left_direction.length_squared() > 0.000001 and left_direction.normalized().angle_to(left_signals[0].limb_direction) < deg_to_rad(0.5) if not left_signals.is_empty() else false
	var right_tracks_motion := right_direction.length_squared() > 0.000001 and right_direction.normalized().angle_to(right_signals[0].limb_direction) < deg_to_rad(0.5) if not right_signals.is_empty() else false
	if driver != null and driver.has_method("reset_pose"):
		driver.reset_pose()
	if driver != null and driver.has_method("apply_locomotion_velocity"):
		driver.apply_locomotion_velocity(Vector3(0.0, 0.0, 4.25), 0.13)
	var gait_left_direction := skeleton.get_bone_pose_rotation(left_index) * Vector3.DOWN if left_index >= 0 else Vector3.ZERO
	var gait_right_direction := skeleton.get_bone_pose_rotation(right_index) * Vector3.DOWN if right_index >= 0 else Vector3.ZERO
	var fore_aft_gait := absf(gait_left_direction.z) > 0.02 and absf(gait_right_direction.z) > 0.02 and gait_left_direction.z * gait_right_direction.z < 0.0 and absf(gait_left_direction.x) < 0.01 and absf(gait_right_direction.x) < 0.01
	var valid := bool(validation.get("valid", false)) and source == "generated_frost_predator_mesh" and skeleton != null and has_all_assets and left_tracks_motion and right_tracks_motion and fore_aft_gait and not (left_solution.get("contributions", {}) as Dictionary).is_empty() and not (right_solution.get("contributions", {}) as Dictionary).is_empty()
	add_result("frost_predator_uses_generated_quadruped_anatomy_forelimb_arcs_and_fore_aft_gait", valid, {"validation": validation, "assetIds": asset_ids, "source": source, "leftTracksMotion": left_tracks_motion, "rightTracksMotion": right_tracks_motion, "leftDirection": left_direction, "rightDirection": right_direction, "gaitLeftDirection": gait_left_direction, "gaitRightDirection": gait_right_direction, "foreAftGait": fore_aft_gait})
	root.free()


func test_declared_locomotion_gait_uses_velocity_without_moving_the_body() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var stalker := Node3D.new()
	stalker.position = Vector3(2.0, 0.0, -3.0)
	root.add_child(stalker)
	var factory = HostileVisualFactoryScript.new()
	factory.build_visual(stalker, "shadow_stalker")
	var driver = stalker.get_node_or_null("MotionRigPoseDriver")
	var skeleton := stalker.get_node_or_null("ShadowStalkerMotionSkeleton") as Skeleton3D
	var initial_transform := stalker.global_transform
	if driver != null and driver.has_method("apply_locomotion_velocity"):
		driver.apply_locomotion_velocity(Vector3(0.0, 0.0, 4.55), 0.13)
	var left_index := skeleton.find_bone("LegLeft") if skeleton != null else -1
	var right_index := skeleton.find_bone("LegRight") if skeleton != null else -1
	var left_direction := skeleton.get_bone_pose_rotation(left_index) * Vector3.DOWN if left_index >= 0 else Vector3.ZERO
	var right_direction := skeleton.get_bone_pose_rotation(right_index) * Vector3.DOWN if right_index >= 0 else Vector3.ZERO
	var legs_swing := left_direction.length_squared() > 0.000001 and right_direction.length_squared() > 0.000001 and absf(left_direction.z) > 0.02 and absf(right_direction.z) > 0.02 and left_direction.z * right_direction.z < 0.0
	var diagnostics: Dictionary = driver.diagnostics() if driver != null and driver.has_method("diagnostics") else {}
	add_result("declared_locomotion_gait_uses_actual_velocity_for_opposed_leg_motion_without_moving_the_collision_body", legs_swing and stalker.global_transform.is_equal_approx(initial_transform), {"leftDirection": left_direction, "rightDirection": right_direction, "diagnostics": diagnostics})
	root.free()


func test_declared_gaze_tracks_target_without_turning_the_body() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var stalker := Node3D.new()
	stalker.position = Vector3(-1.0, 0.0, -2.0)
	root.add_child(stalker)
	var factory = HostileVisualFactoryScript.new()
	factory.build_visual(stalker, "shadow_stalker")
	var driver = stalker.get_node_or_null("MotionRigPoseDriver")
	var skeleton := stalker.get_node_or_null("ShadowStalkerMotionSkeleton") as Skeleton3D
	var initial_transform := stalker.global_transform
	if driver != null and driver.has_method("apply_gaze_target"):
		driver.apply_gaze_target(Vector3(4.0, 1.2, -2.0), 0.18)
	var head_index := skeleton.find_bone("Head") if skeleton != null else -1
	var head_rotation := skeleton.get_bone_pose_rotation(head_index) if head_index >= 0 else Quaternion.IDENTITY
	var diagnostics: Dictionary = driver.diagnostics() if driver != null and driver.has_method("diagnostics") else {}
	var gaze_applied := head_rotation.angle_to(Quaternion.IDENTITY) > deg_to_rad(1.0) and (diagnostics.get("gazeBones", []) as Array).has("Head")
	# The target is to the stalker's local right. Its declared -Z-forward head must
	# therefore yaw right (negative Godot Y yaw), not merely receive any rotation.
	# This distinguishes actual target tracking from an arbitrary visual twitch.
	var head_yaw := head_rotation.get_euler().y
	var gaze_faces_target_side := head_yaw < -deg_to_rad(20.0)
	add_result("declared_gaze_tracks_target_through_the_head_without_turning_the_collision_body", gaze_applied and gaze_faces_target_side and stalker.global_transform.is_equal_approx(initial_transform), {"headRotationDegrees": rad_to_deg(head_rotation.get_angle()), "headYawDegrees": rad_to_deg(head_yaw), "diagnostics": diagnostics})
	root.free()


func test_movement_gaze_releases_target_tracking_smoothly() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var stalker := Node3D.new()
	root.add_child(stalker)
	var factory = HostileVisualFactoryScript.new()
	factory.build_visual(stalker, "shadow_stalker")
	var driver = stalker.get_node_or_null("MotionRigPoseDriver")
	var skeleton := stalker.get_node_or_null("ShadowStalkerMotionSkeleton") as Skeleton3D
	if driver != null and driver.has_method("apply_gaze_target"):
		driver.apply_gaze_target(Vector3(5.0, 1.2, 0.0), 0.35)
	var head_index := skeleton.find_bone("Head") if skeleton != null else -1
	var target_yaw := skeleton.get_bone_pose_rotation(head_index).get_euler().y if head_index >= 0 else 0.0
	# The body is facing world -Z, which is also the retreat direction. The
	# movement gaze must blend the existing target offset back toward its forward
	# rest rather than preserving the player-facing head pose.
	if driver != null and driver.has_method("apply_gaze_direction"):
		driver.apply_gaze_direction(Vector3.FORWARD, 0.35)
	var retreat_yaw := skeleton.get_bone_pose_rotation(head_index).get_euler().y if head_index >= 0 else 0.0
	var diagnostics: Dictionary = driver.diagnostics() if driver != null and driver.has_method("diagnostics") else {}
	var target_tracking_existed := absf(target_yaw) > deg_to_rad(20.0)
	var returned_toward_movement := absf(retreat_yaw) < absf(target_yaw) and absf(retreat_yaw) < deg_to_rad(5.0)
	add_result("movement_gaze_releases_target_tracking_back_to_the_travel_heading", target_tracking_existed and returned_toward_movement and (diagnostics.get("gazeBones", []) as Array).has("Head"), {"targetYawDegrees": rad_to_deg(target_yaw), "retreatYawDegrees": rad_to_deg(retreat_yaw), "diagnostics": diagnostics})
	root.free()


func test_missing_required_role_is_rejected_explicitly() -> void:
	var skeleton := Skeleton3D.new()
	skeleton.add_bone("Root")
	var profile = MotionRigProfileScript.new({"id": "invalid", "roles": {"root": {"bone": "Root"}}})
	var validation: Dictionary = profile.validate(skeleton)
	var recipe = MotionRecipeBuilderScript.build_side_arc(1543)
	var pose_signal = MotionPoseSignalBuilderScript.build_for_stack(MotionStackScript.new("invalid_stack", [MotionInstanceScript.new({"instanceId": "invalid_arc", "recipe": recipe})]), 0.50)[0]
	var solution: Dictionary = MotionPoseSolverScript.solve(profile, [pose_signal])
	var rejected: Array = solution.get("rejected", []) as Array
	add_result("invalid_profile_reports_missing_roles_and_rejects_the_motion_without_fallback", not bool(validation.get("valid", true)) and not rejected.is_empty(), {"validation": validation, "rejected": rejected})
	skeleton.free()


func test_same_arc_selects_anatomy_by_profile() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var wolf := Node3D.new()
	root.add_child(wolf)
	var construct := Node3D.new()
	root.add_child(construct)
	var neutral := material(Color.WHITE)
	var wolf_result: Dictionary = MotionRigVisualFactoryScript.add_ash_wolf(wolf, 1.0, neutral, neutral, neutral)
	var construct_result: Dictionary = MotionRigVisualFactoryScript.add_training_construct(construct, 1.0, neutral, neutral, neutral)
	var signals = MotionPoseSignalBuilderScript.build_for_stack(arc_stack(1543, -1.0), 0.52)
	var wolf_driver = wolf_result.get("driver", null)
	var construct_driver = construct_result.get("driver", null)
	var wolf_solution: Dictionary = wolf_driver.apply_signals(signals) if wolf_driver != null else {}
	var construct_solution: Dictionary = construct_driver.apply_signals(signals) if construct_driver != null else {}
	var wolf_bones: Dictionary = wolf_solution.get("contributions", {}) as Dictionary
	var construct_bones: Dictionary = construct_solution.get("contributions", {}) as Dictionary
	var wolf_skeleton = wolf_result.get("skeleton", null) as Skeleton3D
	var construct_skeleton = construct_result.get("skeleton", null) as Skeleton3D
	var wolf_lead_index := wolf_skeleton.find_bone("FrontLeftLeg") if wolf_skeleton != null else -1
	var construct_lead_index := construct_skeleton.find_bone("ArmLeft") if construct_skeleton != null else -1
	var wolf_posed := wolf_lead_index >= 0 and wolf_skeleton.get_bone_pose_rotation(wolf_lead_index).angle_to(Quaternion.IDENTITY) > 0.01
	var construct_posed := construct_lead_index >= 0 and construct_skeleton.get_bone_pose_rotation(construct_lead_index).angle_to(Quaternion.IDENTITY) > 0.01
	var limb_direction: Vector3 = signals[0].limb_direction if not signals.is_empty() else Vector3.FORWARD
	var construct_arm_direction := construct_skeleton.get_bone_pose_rotation(construct_lead_index) * Vector3.DOWN if construct_lead_index >= 0 else Vector3.ZERO
	var construct_tracks_motion := construct_arm_direction.angle_to(limb_direction) < deg_to_rad(0.5) if construct_arm_direction.length_squared() > 0.000001 else false
	var distinct := wolf_bones.has("FrontLeftLeg") and not wolf_bones.has("ArmLeft") and construct_bones.has("ArmLeft") and not construct_bones.has("FrontLeftLeg") and wolf_posed and construct_posed and construct_tracks_motion
	add_result("one_generated_arc_is_retargeted_by_profile_to_distinct_anatomy", distinct, {"signals": snapshots(signals), "wolfBones": wolf_bones.keys(), "constructBones": construct_bones.keys(), "sameRecipeSeed": 1543, "sameDirection": -1.0, "wolfLeadPosed": wolf_posed, "constructLeadPosed": construct_posed, "constructArmDirection": construct_arm_direction, "limbDirection": limb_direction, "constructTracksMotion": construct_tracks_motion})
	root.free()


func test_pose_driver_never_moves_parent_body() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var wolf := Node3D.new()
	wolf.position = Vector3(3.0, 0.0, -2.0)
	root.add_child(wolf)
	var neutral := material(Color.WHITE)
	var result: Dictionary = MotionRigVisualFactoryScript.add_ash_wolf(wolf, 1.0, neutral, neutral, neutral)
	var driver = result.get("driver", null)
	var skeleton = result.get("skeleton", null) as Skeleton3D
	var start := wolf.global_transform
	var signals = MotionPoseSignalBuilderScript.build_for_stack(arc_stack(1543, 1.0), 0.50)
	var solution: Dictionary = driver.apply_signals(signals) if driver != null else {}
	var leg_index := skeleton.find_bone("FrontRightLeg") if skeleton != null else -1
	var posed := leg_index >= 0 and skeleton.get_bone_pose_rotation(leg_index).angle_to(Quaternion.IDENTITY) > 0.01
	add_result("pose_driver_changes_only_bones_and_never_the_parent_body_transform", wolf.global_transform.is_equal_approx(start) and posed and not (solution.get("contributions", {}) as Dictionary).is_empty(), {"driver": driver.diagnostics() if driver != null else {}})
	root.free()


func test_equipped_contact_segment_follows_selected_lead_socket() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var construct := Node3D.new()
	root.add_child(construct)
	var neutral := material(Color.WHITE)
	var rig_result: Dictionary = MotionRigVisualFactoryScript.add_training_construct(construct, 1.0, neutral, neutral, neutral)
	var profile = rig_result.get("profile", null)
	var skeleton = rig_result.get("skeleton", null) as Skeleton3D
	var adapter = MotionEquipmentAdapterScript.new()
	construct.add_child(adapter)
	var equipment = MotionEquipmentProfileScript.new({
		"id": "contract_blade",
		"itemId": "ironSword",
		"socketOffset": Vector3(0.0, -0.66, 0.0),
		"itemRotation": Vector3(0.0, 0.0, PI),
		"itemGripNodePath": "Grip",
		"itemGripLocal": Vector3(0.0, -0.30, 0.0),
		"contactBaseOffset": Vector3(0.0, -0.06, 0.0),
		"contactTipOffset": Vector3(0.0, -0.92, 0.0),
		"contactRadius": 0.075,
		"activePhases": ["arc"]
	})
	var validation: Dictionary = adapter.configure(construct, skeleton, profile, equipment)
	var signals = MotionPoseSignalBuilderScript.build_for_stack(arc_stack(1543, -1.0), 0.52)
	var driver = rig_result.get("driver", null)
	if driver != null:
		driver.apply_signals(signals)
	var motion_sample = arc_stack(1543, -1.0).samples_at(0.52)[0]
	var volume = adapter.sample_contact_volume(motion_sample, MotionVolumeRecipeBuilderScript.build_capsule_segment(1543))
	var arm_index := skeleton.find_bone("ArmLeft") if skeleton != null else -1
	var arm_direction := skeleton.get_bone_global_pose(arm_index).basis * Vector3.DOWN if arm_index >= 0 else Vector3.ZERO
	var blade_direction: Vector3 = volume.segment_end - volume.segment_start
	var tracks_arm := arm_direction.length_squared() > 0.000001 and blade_direction.length_squared() > 0.000001 and arm_direction.normalized().angle_to(blade_direction.normalized()) < deg_to_rad(0.5)
	var grip_position := adapter.grip_position_for_motion(motion_sample)
	var socket_position := adapter.socket_position_for_motion(motion_sample)
	var hilt_seated := grip_position.distance_to(socket_position) <= 0.01
	var visual_grip_anchor := adapter.has_visual_grip_anchor_for_motion(motion_sample)
	add_result("equipped_item_contact_uses_the_selected_rig_socket_and_not_the_body_motion_volume", bool(validation.get("valid", false)) and volume.active and tracks_arm and hilt_seated and visual_grip_anchor, {"validation": validation, "volume": volume.snapshot(), "armDirection": arm_direction, "bladeDirection": blade_direction, "gripPosition": grip_position, "socketPosition": socket_position, "hiltSeated": hilt_seated, "visualGripAnchor": visual_grip_anchor})
	root.free()


func test_equipped_item_is_prepared_on_the_selected_swinging_arm() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var construct := Node3D.new()
	root.add_child(construct)
	var neutral := material(Color.WHITE)
	var rig_result: Dictionary = MotionRigVisualFactoryScript.add_training_construct(construct, 1.0, neutral, neutral, neutral)
	var profile = rig_result.get("profile", null)
	var skeleton = rig_result.get("skeleton", null) as Skeleton3D
	var adapter = MotionEquipmentAdapterScript.new()
	construct.add_child(adapter)
	var validation: Dictionary = adapter.configure(construct, skeleton, profile, training_blade_profile())
	var selected_roles: Dictionary = {}
	for side in [-1.0, 1.0]:
		var stack = arc_stack(1543, side)
		var motion_sample = stack.samples_at(0.0)[0]
		adapter.prepare_for_motion_side(float(motion_sample.direction))
		selected_roles[str(int(side))] = {
			"expected": profile.resolved_role("lead_appendage", side),
			"visible": adapter.visible_lead_role()
		}
	var left: Dictionary = selected_roles.get("-1", {}) as Dictionary
	var right: Dictionary = selected_roles.get("1", {}) as Dictionary
	var correct := bool(validation.get("valid", false)) \
		and String(left.get("visible", "")) == String(left.get("expected", "")) \
		and String(right.get("visible", "")) == String(right.get("expected", ""))
	add_result("equipped_item_is_visible_on_the_same_semantic_arm_that_starts_each_motion", correct, {"validation": validation, "selectedRoles": selected_roles})
	root.free()

func test_equipped_blade_crosses_the_arena_target_corridor() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var construct := Node3D.new()
	root.add_child(construct)
	construct.look_at(Vector3(0.0, 0.0, 1.55), Vector3.UP)
	var neutral := material(Color.WHITE)
	var rig_result: Dictionary = MotionRigVisualFactoryScript.add_training_construct(construct, 1.0, neutral, neutral, neutral)
	var profile = rig_result.get("profile", null)
	var skeleton = rig_result.get("skeleton", null) as Skeleton3D
	var adapter = MotionEquipmentAdapterScript.new()
	construct.add_child(adapter)
	adapter.configure(construct, skeleton, profile, training_blade_profile())
	var driver = rig_result.get("driver", null)
	var stack = arc_stack(1543, -1.0)
	var volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(1543)
	var targets: Array = [
		PassiveContactSphereScript.new({"geometryId": "arena_player:lower", "center": Vector3(0.0, 0.38, 1.55), "radius": 0.38}),
		PassiveContactSphereScript.new({"geometryId": "arena_player:middle", "center": Vector3(0.0, 0.89, 1.55), "radius": 0.38}),
		PassiveContactSphereScript.new({"geometryId": "arena_player:upper", "center": Vector3(0.0, 1.40, 1.55), "radius": 0.38})
	]
	var previous = null
	var resolved = false
	var closest_distance := INF
	var closest_snapshot: Dictionary = {}
	for step in range(41):
		var time := float(step) / 40.0
		var signals = MotionPoseSignalBuilderScript.build_for_stack(stack, time)
		if driver != null:
			driver.apply_signals(signals)
		var motion_sample = stack.samples_at(time)[0]
		var volume = adapter.sample_contact_volume(motion_sample, volume_recipe)
		for target in targets:
			var closest := MotionContactResolverScript.closest_point_on_segment(target.center, volume.segment_start, volume.segment_end)
			var distance := closest.distance_to(target.center)
			if distance < closest_distance:
				closest_distance = distance
				closest_snapshot = volume.snapshot()
			var resolution = MotionContactResolverScript.resolve_transition(previous, volume, target)
			resolved = resolved or resolution.resolved
		previous = volume
	add_result("equipped_blade_sweep_reaches_the_same_arena_player_corridor_used_by_the_runtime_fixture", resolved, {"resolved": resolved, "closestDistance": closest_distance, "closestVolume": closest_snapshot})
	root.free()


func training_blade_profile():
	return MotionEquipmentProfileScript.new({
		"id": "contract_blade_corridor",
		"itemId": "ironSword",
		"socketOffset": Vector3(0.0, -0.66, 0.0),
		"itemRotation": Vector3(0.0, 0.0, PI),
		"itemGripNodePath": "Grip",
		"itemGripLocal": Vector3(0.0, -0.30, 0.0),
		"contactBaseOffset": Vector3(0.0, -0.06, 0.0),
		"contactTipOffset": Vector3(0.0, -0.92, 0.0),
		"contactRadius": 0.075,
		"activePhases": ["arc"]
	})



func arc_stack(seed: int, direction: float):
	var recipe = MotionRecipeBuilderScript.build_arc(seed, {"planeProfile": "lateral"})
	return MotionStackScript.new("arc_stack", [MotionInstanceScript.new({"instanceId": "arc", "recipe": recipe, "anchorId": "contract", "direction": direction})])


func material(color: Color) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.roughness = 0.82
	return result


func snapshots(signals: Array) -> Array:
	var result: Array = []
	for pose_signal in signals:
		if pose_signal != null and pose_signal.has_method("snapshot"):
			result.append(pose_signal.snapshot())
	return result


func add_result(name: String, passed: bool, details: Dictionary = {}) -> void:
	results.append({"name": name, "passed": passed, "details": details})


func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count


func write_report() -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var report := {"schemaVersion": 1, "runnerId": "motion_rig_contract", "evidenceLevel": "contract", "passed": failure_count() == 0, "resultCount": results.size(), "failureCount": failure_count(), "results": results}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
