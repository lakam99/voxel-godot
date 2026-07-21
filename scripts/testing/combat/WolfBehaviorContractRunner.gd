extends Node

const HostileBehaviorProfileCatalogScript := preload("res://scripts/combat/hostile/HostileBehaviorProfileCatalog.gd")
const HostileBehaviorPolicyScript := preload("res://scripts/combat/hostile/HostileBehaviorPolicy.gd")
const MotionRecipeBuilderScript := preload("res://scripts/combat/motion/MotionRecipeBuilder.gd")
const MotionPrimitiveScript := preload("res://scripts/combat/motion/MotionPrimitive.gd")
const MotionVolumeRecipeBuilderScript := preload("res://scripts/combat/contact/MotionVolumeRecipeBuilder.gd")
const MotionVolumeSamplerScript := preload("res://scripts/combat/contact/MotionVolumeSampler.gd")

## Focused deterministic evidence for the wolf profile/policy. It explicitly
## does not claim visual readability or live-world acceptance.

func _ready() -> void:
	var failures: Array[String] = []
	var checks: Dictionary = {}
	var profile = HostileBehaviorProfileCatalogScript.profile_for("wolf.gray")
	checks["profile_resolves"] = profile != null and profile.id == "wolf.gray" and profile.supports_motion("arc") and profile.supports_motion("forward_surge")
	check(failures, checks, "profile_resolves")
	checks["profile_replay_stable"] = JSON.stringify(profile.snapshot()) == JSON.stringify(HostileBehaviorProfileCatalogScript.profile_for("wolf.gray").snapshot())
	check(failures, checks, "profile_replay_stable")

	var common := {
		"stateElapsed": 0.0,
		"motionActive": false,
		"threatViable": false,
		"evadeReady": false,
		"orbitDirection": 1.0,
		"actionSerial": 0
	}
	checks["outside_band_approaches"] = HostileBehaviorPolicyScript.decide(profile, merged(common, {"state": "approach", "distance": 7.0})).kind == "approach"
	check(failures, checks, "outside_band_approaches")
	checks["inside_band_retreats"] = HostileBehaviorPolicyScript.decide(profile, merged(common, {"state": "orbit", "distance": 1.4})).kind == "retreat"
	check(failures, checks, "inside_band_retreats")
	checks["orbit_transitions_to_probe"] = HostileBehaviorPolicyScript.decide(profile, merged(common, {"state": "orbit", "stateElapsed": profile.orbit_duration + 0.01, "distance": profile.preferred_distance})).kind == "probe"
	check(failures, checks, "orbit_transitions_to_probe")
	var lunge_intent = HostileBehaviorPolicyScript.decide(profile, merged(common, {"state": "probe", "stateElapsed": profile.probe_duration + 0.01, "distance": 4.2}))
	checks["probe_selects_forward_surge"] = lunge_intent.kind == "commit" and lunge_intent.motion_kind == "forward_surge"
	check(failures, checks, "probe_selects_forward_surge")
	var claw_intent = HostileBehaviorPolicyScript.decide(profile, merged(common, {"state": "probe", "stateElapsed": profile.probe_duration + 0.01, "distance": 2.75}))
	checks["probe_selects_arc_when_close"] = claw_intent.kind == "commit" and claw_intent.motion_kind == "arc"
	check(failures, checks, "probe_selects_arc_when_close")
	checks["predicted_threat_enters_evade"] = HostileBehaviorPolicyScript.decide(profile, merged(common, {"state": "orbit", "distance": 4.0, "threatViable": true, "evadeReady": true})).kind == "evade"
	check(failures, checks, "predicted_threat_enters_evade")
	checks["recovery_remains_punishable"] = HostileBehaviorPolicyScript.decide(profile, merged(common, {"state": "recovery", "stateElapsed": 0.10, "distance": 4.0, "threatViable": true, "evadeReady": true})).kind == "retreat"
	check(failures, checks, "recovery_remains_punishable")

	var recipe = MotionRecipeBuilderScript.build_forward_surge(1543)
	var volume_recipe = MotionVolumeRecipeBuilderScript.build_capsule_segment(1543, {"activePhases": ["surge"]})
	var windup_sample = MotionPrimitiveScript.sample(recipe, 0.12, 1.0, Vector3.ZERO, "surge", "contract")
	var surge_sample = MotionPrimitiveScript.sample(recipe, float(recipe.parameters.get("windupFraction", 0.27)) + 0.12, 1.0, Vector3.ZERO, "surge", "contract")
	checks["forward_surge_has_windup_then_surge"] = windup_sample.phase == "windup" and surge_sample.phase == "surge"
	check(failures, checks, "forward_surge_has_windup_then_surge")
	checks["surge_volume_uses_shared_contact_recipe"] = not MotionVolumeSamplerScript.sample(volume_recipe, windup_sample).active and MotionVolumeSamplerScript.sample(volume_recipe, surge_sample).active
	check(failures, checks, "surge_volume_uses_shared_contact_recipe")

	var report := {
		"runnerId": "wolf_behavior_contract",
		"evidenceLevel": "pure-contract",
		"status": "passed" if failures.is_empty() else "failed",
		"checks": checks,
		"failures": failures,
		"profile": profile.snapshot(),
		"notes": "This proves data/profile, intent, recovery, evade-gating and forward-surge sampling determinism. It does not prove headed arena readability or normal-world integration."
	}
	write_report(report)
	get_tree().quit(0 if failures.is_empty() else 1)


func merged(base: Dictionary, additions: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	for key in additions:
		result[key] = additions[key]
	return result


func check(failures: Array[String], checks: Dictionary, key: String) -> void:
	if not bool(checks.get(key, false)):
		failures.append(key)


func write_report(report: Dictionary) -> void:
	var path := OS.get_environment("VOXEL_WOLF_BEHAVIOR_CONTRACT_REPORT")
	if path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
