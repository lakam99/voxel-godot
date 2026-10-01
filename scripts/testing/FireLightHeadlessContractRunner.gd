extends SceneTree

# Direct component contract. This proves the FireLight3D logical owner remains
# configured in a dummy-renderer process while renderer-facing animation is
# disabled. It does not replace headed light/shadow visual acceptance.
const FireLightScript := preload("res://scripts/FireLight3D.gd")
const LocalLightRigScript := preload("res://scripts/LocalLightRig.gd")

var checks: Array[Dictionary] = []

func _initialize() -> void:
    call_deferred("run_contract")

func check(name: String, passed: bool, details: Dictionary = {}) -> void:
    checks.append({"name": name, "passed": passed, "details": details})

func run_contract() -> void:
    check("contract_runs_with_dummy_headless_display", DisplayServer.get_name().to_lower() == "headless", {
        "displayServer": DisplayServer.get_name()
    })
    check("display_classifier_rejects_headless_case_and_padding",
        not FireLightScript.visual_light_updates_supported("headless")
        and not FireLightScript.visual_light_updates_supported(" HEADLESS "))
    check("display_classifier_preserves_headed_renderers",
        FireLightScript.visual_light_updates_supported("windows")
        and FireLightScript.visual_light_updates_supported("x11")
        and FireLightScript.visual_light_updates_supported("macos"))

    var preconfigure_light = FireLightScript.new()
    preconfigure_light.set_meta("casts_shadow_when_enabled", true)
    preconfigure_light.set_visual_light_cull_mask(7)
    preconfigure_light.set_lod_shadow_enabled(true)
    check("new_light_is_safe_before_configuration_or_tree_entry",
        not preconfigure_light.visual_updates_enabled
        and preconfigure_light.visual_light_cull_mask == 7
        and preconfigure_light.lod_shadow_enabled
        and int(preconfigure_light.get_meta("light_cull_mask", -1)) == 7)
    preconfigure_light.free()

    var light = FireLightScript.new()
    light.configure(
        Color(1.0, 0.72, 0.36),
        3.25,
        9.5,
        true,
        0.62,
        0.17,
        2.4,
        0.22,
        1.31,
        0.58,
        "source",
        true
    )
    root.add_child(light)
    await process_frame
    check("headless_ready_disables_fire_light_processing",
        not light.visual_updates_enabled and not light.is_processing())
    check("headless_configuration_retains_logical_authority",
        is_equal_approx(light.base_energy, 3.25)
        and is_equal_approx(light.base_range, 9.5)
        # The production light widens flicker enough to reach the configured
        # minimum energy scale; retain that exact logical rule headlessly.
        and is_equal_approx(light.flicker_amount, 0.78)
        and is_equal_approx(light.range_amount, 0.17)
        and is_equal_approx(light.flicker_speed, 2.4)
        and is_equal_approx(light.min_energy_scale, 0.22)
        and is_equal_approx(light.max_energy_scale, 1.31), {
            "baseEnergy": light.base_energy,
            "baseRange": light.base_range,
            "flickerAmount": light.flicker_amount
        })
    check("headless_configuration_retains_groups_and_metadata",
        light.is_in_group("fire_lights")
        and bool(light.get_meta("fire_light", false))
        and bool(light.get_meta("casts_shadow_when_enabled", false))
        and String(light.get_meta("light_role", "")) == "source"
        and bool(light.get_meta("local_light_rig", false)))

    light.set_day_suppressed(true)
    light.set_day_factor(0.8)
    light.set_lod_visible(false)
    light.set_lod_shadow_enabled(true)
    var phase_before_process: float = light.phase
    light._process(1.0)
    check("headless_process_returns_before_animation_or_visual_writes",
        is_equal_approx(light.phase, phase_before_process)
        and not light.is_processing(), {
            "phaseBefore": phase_before_process,
            "phaseAfter": light.phase
        })
    check("headless_nonvisual_state_updates_remain_available",
        light.day_suppressed
        and is_equal_approx(light.day_factor, 0.8)
        and not light.lod_visible)

    var rig_parent := Node3D.new()
    root.add_child(rig_parent)
    var rig: Dictionary = LocalLightRigScript.add_rig(rig_parent, "wardLantern", {
        "context": "placed",
        "shadows": true
    })
    await process_frame
    var rig_nodes_are_logical_and_idle := rig.size() == 1
    var expected_rig := {
        "source": {"energy": 2.31, "range": 13.0, "group": "local_light_rig_source", "casts": true}
    }
    var rig_role_details := {}
    for role in expected_rig:
        var rig_light_value = rig.get(role)
        var rig_light := rig_light_value as Light3D
        var expected: Dictionary = expected_rig[role]
        var exact_fire_light: bool = rig_light != null and rig_light.get_script() == FireLightScript
        var role_ok: bool = exact_fire_light \
            and not rig_light.visual_updates_enabled \
            and not rig_light.is_processing() \
            and bool(rig_light.get_meta("local_light_rig", false)) \
            and String(rig_light.get_meta("light_role", "")) == role \
            and rig_light.is_in_group(String(expected.group)) \
            and is_equal_approx(rig_light.base_energy, float(expected.energy)) \
            and is_equal_approx(rig_light.base_range, float(expected.range)) \
            and bool(rig_light.get_meta("casts_shadow_when_enabled", false)) == bool(expected.casts) \
            and rig_light.lod_shadow_enabled == bool(expected.casts) \
            and rig_light.visual_light_cull_mask == LocalLightRigScript.WORLD_VISUAL_LIGHT_MASK \
            and int(rig_light.get_meta("light_cull_mask", -1)) == LocalLightRigScript.WORLD_VISUAL_LIGHT_MASK
        rig_nodes_are_logical_and_idle = rig_nodes_are_logical_and_idle \
            and role_ok
        rig_role_details[role] = {
            "exactFireLight": exact_fire_light,
            "baseEnergy": rig_light.base_energy if rig_light != null else null,
            "baseRange": rig_light.base_range if rig_light != null else null,
            "group": String(expected.group),
            "roleOk": role_ok
        }
    check("production_local_light_rig_is_headless_safe", rig_nodes_are_logical_and_idle, {
        "roles": rig.keys(),
        "childCount": rig_parent.get_child_count(),
        "roleDetails": rig_role_details
    })

    light.queue_free()
    rig_parent.queue_free()
    await process_frame
    finish()

func finish() -> void:
    var failures := checks.filter(func(item: Dictionary) -> bool: return not bool(item.passed))
    var report := {
        "passed": failures.is_empty(),
        "evidenceLevel": "direct-component-headless-contract",
        "scope": "FireLight3D logical configuration and dummy-renderer update suppression; excludes headed visual quality",
        "checks": checks,
        "failures": failures.size()
    }
    var report_path := OS.get_environment("VOXEL_FIRE_LIGHT_HEADLESS_REPORT").strip_edges()
    if report_path != "":
        DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
        var file := FileAccess.open(report_path, FileAccess.WRITE)
        if file != null:
            file.store_string(JSON.stringify(report, "  "))
            file.close()
    print("FIRE LIGHT HEADLESS CONTRACT ", JSON.stringify({"passed": report.passed, "checks": checks.size()}))
    quit(0 if report.passed else 1)
