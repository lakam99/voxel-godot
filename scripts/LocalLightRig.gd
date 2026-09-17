extends RefCounted
class_name LocalLightRig

const FireLight3DScript := preload("res://scripts/FireLight3D.gd")

const ROLE_SOURCE := "source"
const ROLE_TERRAIN_WASH := "terrain_wash"
const ROLE_BOUNCE_FILL := "bounce_fill"

const FIRE_COLOR := Color(1.0, 0.89, 0.72)
const LANTERN_COLOR := Color(1.0, 0.92, 0.78)
const RIFT_COLOR := Color(0.78, 0.44, 1.0)
const BEACON_COLOR := Color(0.58, 0.86, 1.0)
const TUTORIAL_COLOR := Color(1.0, 0.90, 0.74)
const TORCH_RADIUS_SCALE := 0.55
const WORLD_VISUAL_LIGHT_MASK := 1

static func add_rig(parent: Node3D, profile_id: String, options := {}) -> Dictionary:
    var context := String(options.get("context", "placed"))
    var scale := float(options.get("scale", 1.0))
    var profile := profile_for(profile_id, context, scale)
    if profile.is_empty() or parent == null:
        return {}

    if options.has("source_position"):
        profile["source_position"] = options["source_position"]
    if options.has("terrain_position"):
        profile["terrain_position"] = options["terrain_position"]
    if options.has("bounce_position"):
        profile["bounce_position"] = options["bounce_position"]
    if options.has("source_energy"):
        profile["source_energy"] = float(options["source_energy"])
    if options.has("source_range"):
        profile["source_range"] = float(options["source_range"])
    if options.has("terrain_energy"):
        profile["terrain_energy"] = float(options["terrain_energy"])
    if options.has("terrain_range"):
        profile["terrain_range"] = float(options["terrain_range"])
    if options.has("bounce_energy"):
        profile["bounce_energy"] = float(options["bounce_energy"])
    if options.has("bounce_range"):
        profile["bounce_range"] = float(options["bounce_range"])
    if options.has("shadows"):
        profile["shadows"] = bool(options["shadows"])
    if options.has("day_suppressed"):
        profile["day_suppressed"] = bool(options["day_suppressed"])
    if options.has("fill_lod_distance"):
        profile["fill_lod_distance"] = float(options["fill_lod_distance"])
    if options.has("source_lod_distance"):
        profile["source_lod_distance"] = float(options["source_lod_distance"])

    if is_torch_profile(profile_id):
        apply_torch_radius_scale(profile)

    var prefix := String(options.get("name_prefix", profile.get("name_prefix", profile_id)))
    var result := {}
    result[ROLE_SOURCE] = create_light(parent, prefix, profile_id, context, ROLE_SOURCE, profile)
    result[ROLE_TERRAIN_WASH] = create_light(parent, prefix, profile_id, context, ROLE_TERRAIN_WASH, profile)
    result[ROLE_BOUNCE_FILL] = create_light(parent, prefix, profile_id, context, ROLE_BOUNCE_FILL, profile)
    return result

static func profile_for(profile_id: String, context: String, scale: float) -> Dictionary:
    var id := normalized_profile_id(profile_id)
    var profile := {
        "color": FIRE_COLOR,
        "name_prefix": id,
        "source_energy": 3.0,
        "source_range": 10.0 * scale,
        "terrain_energy": 1.4,
        "terrain_range": 8.0 * scale,
        "bounce_energy": 0.65,
        "bounce_range": 10.0 * scale,
        "source_position": Vector3(0.0, 0.72 * scale, 0.0),
        "terrain_position": Vector3(0.0, 0.36 * scale, 0.0),
        "bounce_position": Vector3(0.0, 1.05 * scale, 0.0),
        "source_attenuation": 0.62,
        "terrain_attenuation": 0.40,
        "bounce_attenuation": 0.34,
        "shadows": true,
        "day_suppressed": false,
        "source_lod_distance": 56.0,
        "fill_lod_distance": 56.0
    }

    if id == "wardLantern":
        profile["color"] = LANTERN_COLOR
        profile["name_prefix"] = "WardLantern"
        profile["day_suppressed"] = true
    elif id == "riftAnchor":
        profile["color"] = RIFT_COLOR
        profile["name_prefix"] = "RiftAnchor"
    elif id == "sanctuaryBeacon":
        profile["color"] = BEACON_COLOR
        profile["name_prefix"] = "SanctuaryBeacon"
    elif id == "tutorial_lantern":
        profile["color"] = TUTORIAL_COLOR
        profile["name_prefix"] = "TutorialLantern"
        profile["day_suppressed"] = true
    elif id == "rescue_torch":
        profile["color"] = FIRE_COLOR
        profile["name_prefix"] = "RescueTorch"
        profile["day_suppressed"] = false
    elif id == "campfire":
        profile["name_prefix"] = "Campfire"
        profile["day_suppressed"] = false
    else:
        profile["name_prefix"] = "Torch"
        profile["day_suppressed"] = false

    if context == "held":
        apply_held_profile(profile, id)
    elif context == "pickup":
        apply_pickup_profile(profile, id, scale)
    else:
        apply_placed_profile(profile, id, scale)
    return profile

static func is_torch_profile(profile_id: String) -> bool:
    var id := normalized_profile_id(profile_id)
    return id == "torch" or id == "rescue_torch"

static func apply_torch_radius_scale(profile: Dictionary) -> void:
    for key in ["source_range", "terrain_range", "bounce_range"]:
        profile[key] = float(profile.get(key, 0.0)) * TORCH_RADIUS_SCALE

static func apply_held_profile(profile: Dictionary, id: String) -> void:
    profile["source_position"] = Vector3(0.0, 0.62, -0.18)
    profile["terrain_position"] = Vector3(-0.34, -0.74, -0.48)
    profile["bounce_position"] = Vector3(-0.18, -0.40, -0.20)
    profile["terrain_attenuation"] = 0.26
    profile["bounce_attenuation"] = 0.20
    profile["fill_lod_distance"] = 9999.0
    if id == "campfire":
        profile["source_energy"] = 3.25
        profile["source_range"] = 12.0
        profile["terrain_energy"] = 3.35
        profile["terrain_range"] = 13.6
        profile["bounce_energy"] = 2.35
        profile["bounce_range"] = 12.4
        profile["source_position"] = Vector3(0.0, 0.22, 0.0)
    elif id == "wardLantern":
        profile["source_energy"] = 1.92
        profile["source_range"] = 11.8
        profile["terrain_energy"] = 2.65
        profile["terrain_range"] = 12.5
        profile["bounce_energy"] = 1.85
        profile["bounce_range"] = 11.4
        profile["source_position"] = Vector3(0.0, 0.38, -0.12)
    elif id == "riftAnchor":
        profile["source_energy"] = 3.95
        profile["source_range"] = 13.2
        profile["terrain_energy"] = 3.45
        profile["terrain_range"] = 14.0
        profile["bounce_energy"] = 2.55
        profile["bounce_range"] = 12.8
        profile["source_position"] = Vector3(0.0, 0.36, -0.12)
    elif id == "sanctuaryBeacon":
        profile["source_energy"] = 4.25
        profile["source_range"] = 13.8
        profile["terrain_energy"] = 3.55
        profile["terrain_range"] = 14.2
        profile["bounce_energy"] = 2.65
        profile["bounce_range"] = 13.2
        profile["source_position"] = Vector3(0.0, 0.38, -0.12)
    else:
        profile["source_energy"] = 3.05
        profile["source_range"] = 11.4
        profile["source_min_scale"] = 0.08
        profile["source_max_scale"] = 1.52
        profile["source_flicker_speed"] = 3.0
        profile["terrain_energy"] = 3.35
        profile["terrain_range"] = 13.6
        profile["bounce_energy"] = 2.35
        profile["bounce_range"] = 12.4

static func apply_pickup_profile(profile: Dictionary, id: String, scale: float) -> void:
    apply_held_profile(profile, id)
    profile["fill_lod_distance"] = 40.0
    profile["source_position"] = Vector3(0.0, 0.50 * scale, -0.12 * scale)
    profile["terrain_position"] = Vector3(0.0, -0.10, 0.0)
    profile["bounce_position"] = Vector3(0.0, 0.58 * scale, 0.0)
    if id == "campfire":
        profile["source_position"] = Vector3(0.0, 0.22 * scale, 0.0)
        profile["source_energy"] = 2.00
        profile["source_range"] = 6.0
        profile["terrain_energy"] = 0.85
        profile["terrain_range"] = 5.8
        profile["bounce_energy"] = 0.42
        profile["bounce_range"] = 6.4
    elif id == "torch":
        profile["source_position"] = Vector3(0.0, 0.62 * scale, -0.18 * scale)
        profile["source_energy"] = 1.90
        profile["source_range"] = 6.0
        profile["terrain_energy"] = 0.80
        profile["terrain_range"] = 5.6
        profile["bounce_energy"] = 0.38
        profile["bounce_range"] = 6.2
    elif id == "wardLantern":
        profile["source_energy"] = 1.17
        profile["source_range"] = 6.4
        profile["terrain_energy"] = 0.62
        profile["terrain_range"] = 5.8
        profile["bounce_energy"] = 0.34
        profile["bounce_range"] = 6.2
    elif id == "riftAnchor":
        profile["source_energy"] = 2.20
        profile["source_range"] = 6.8
        profile["terrain_energy"] = 0.88
        profile["terrain_range"] = 6.0
        profile["bounce_energy"] = 0.50
        profile["bounce_range"] = 6.8
    elif id == "sanctuaryBeacon":
        profile["source_energy"] = 2.35
        profile["source_range"] = 7.0
        profile["terrain_energy"] = 0.92
        profile["terrain_range"] = 6.2
        profile["bounce_energy"] = 0.55
        profile["bounce_range"] = 7.2

static func apply_placed_profile(profile: Dictionary, id: String, scale: float) -> void:
    profile["terrain_position"] = Vector3(0.0, 0.36 * scale, 0.0)
    profile["bounce_position"] = Vector3(0.0, 1.05 * scale, 0.0)
    if id == "campfire":
        profile["source_position"] = Vector3(0.0, 0.32 * scale, 0.0)
        profile["source_energy"] = 3.10
        profile["source_range"] = 12.0 * scale
        profile["terrain_energy"] = 1.75
        profile["terrain_range"] = 10.5 * scale
        profile["bounce_energy"] = 0.78
        profile["bounce_range"] = 12.8 * scale
    elif id == "torch":
        profile["source_position"] = Vector3(0.0, 0.84 * scale, 0.0)
        profile["source_energy"] = 3.35
        profile["source_range"] = 11.2 * scale
        profile["terrain_energy"] = 1.65
        profile["terrain_range"] = 9.8 * scale
        profile["bounce_energy"] = 0.72
        profile["bounce_range"] = 12.0 * scale
    elif id == "wardLantern":
        profile["source_position"] = Vector3(0.0, 0.74 * scale, 0.0)
        profile["source_energy"] = 2.31
        profile["source_range"] = 13.0 * scale
        profile["terrain_energy"] = 1.25
        profile["terrain_range"] = 10.8 * scale
        profile["bounce_energy"] = 0.58
        profile["bounce_range"] = 12.0 * scale
    elif id == "riftAnchor":
        profile["source_position"] = Vector3(0.0, 0.76 * scale, 0.0)
        profile["source_energy"] = 4.95
        profile["source_range"] = 16.0 * scale
        profile["terrain_energy"] = 1.90
        profile["terrain_range"] = 11.8 * scale
        profile["bounce_energy"] = 0.95
        profile["bounce_range"] = 14.0 * scale
    elif id == "sanctuaryBeacon":
        profile["source_position"] = Vector3(0.0, 0.78 * scale, 0.0)
        profile["source_energy"] = 5.40
        profile["source_range"] = 17.0 * scale
        profile["terrain_energy"] = 2.00
        profile["terrain_range"] = 12.2 * scale
        profile["bounce_energy"] = 1.00
        profile["bounce_range"] = 14.4 * scale

static func create_light(parent: Node3D, prefix: String, profile_id: String, context: String, role: String, profile: Dictionary) -> Light3D:
    var key_prefix := "source" if role == ROLE_SOURCE else "terrain" if role == ROLE_TERRAIN_WASH else "bounce"
    var light := FireLight3DScript.new()
    light.name = "%s%s" % [prefix, "Light" if role == ROLE_SOURCE else "TerrainWash" if role == ROLE_TERRAIN_WASH else "BounceFill"]
    light.position = profile.get("%s_position" % key_prefix, Vector3.ZERO)
    var casts_shadows := bool(profile.get("shadows", true)) and role == ROLE_SOURCE
    var flicker := 0.88 if role == ROLE_SOURCE else 0.18 if role == ROLE_TERRAIN_WASH else 0.12
    var range_flicker := 0.28 if role == ROLE_SOURCE else 0.06 if role == ROLE_TERRAIN_WASH else 0.04
    var default_speed := 2.10 if role == ROLE_SOURCE else 1.55 if role == ROLE_TERRAIN_WASH else 1.25
    var speed := float(profile.get("%s_flicker_speed" % key_prefix, default_speed))
    var default_min_scale := -1.0 if role == ROLE_SOURCE else 0.74 if role == ROLE_TERRAIN_WASH else 0.82
    var min_scale := float(profile.get("%s_min_scale" % key_prefix, default_min_scale))
    var default_max_scale := 1.38 if role == ROLE_SOURCE else 1.08 if role == ROLE_TERRAIN_WASH else 1.05
    var max_scale := float(profile.get("%s_max_scale" % key_prefix, default_max_scale))
    light.configure(
        profile.get("color", FIRE_COLOR),
        float(profile.get("%s_energy" % key_prefix, 1.0)),
        float(profile.get("%s_range" % key_prefix, 6.0)),
        casts_shadows,
        flicker,
        range_flicker,
        speed,
        min_scale,
        max_scale,
        float(profile.get("%s_attenuation" % key_prefix, 0.62)),
        role,
        true
    )
    light.set_visual_light_cull_mask(WORLD_VISUAL_LIGHT_MASK)
    if bool(profile.get("day_suppressed", false)) and light.has_method("set_day_suppressed"):
        light.set_day_suppressed(true)
    light.set_meta("local_light_rig", true)
    light.set_meta("light_role", role)
    light.set_meta("rig_profile", profile_id)
    light.set_meta("rig_context", context)
    light.set_meta("casts_shadow_when_enabled", casts_shadows)
    if role == ROLE_SOURCE:
        light.set_meta("rig_lod_distance", float(profile.get("source_lod_distance", 56.0)))
        light.add_to_group("local_light_rig_source")
    else:
        light.set_lod_shadow_enabled(false)
        light.set_meta("ground_fill_light", true)
        light.set_meta("rig_lod_distance", float(profile.get("fill_lod_distance", 56.0)))
        light.add_to_group("local_light_rig_fill")
        if role == ROLE_TERRAIN_WASH:
            light.set_meta("held_fill_forward", 4.2)
            light.set_meta("held_fill_right", 0.12)
            light.set_meta("held_fill_height", 1.65)
        else:
            light.set_meta("held_fill_forward", 0.8)
            light.set_meta("held_fill_right", 0.0)
            light.set_meta("held_fill_height", 2.25)
    parent.add_child(light)
    return light

static func normalized_profile_id(profile_id: String) -> String:
    if profile_id == "ward_lantern":
        return "wardLantern"
    if profile_id == "sanctuary_beacon":
        return "sanctuaryBeacon"
    if profile_id == "rift_anchor":
        return "riftAnchor"
    return profile_id
