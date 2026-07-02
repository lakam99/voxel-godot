extends Node3D
class_name HostileSystem

const HostileProjectileSystemScript := preload("res://scripts/HostileProjectileSystem.gd")
const HostileRulesScript := preload("res://scripts/HostileRules.gd")
const HostileVisualFactoryScript := preload("res://scripts/HostileVisualFactory.gd")
const CELL := 1.35
const HOSTILE_SPACING_RADIUS := CELL * 0.95
const HOSTILE_RIFT_SPACING_RADIUS := CELL * 1.25

var main
var player: CharacterBody3D
var survival
var inventory
var enemies: Array = []
var projectiles: Array = []
var spawn_cooldown := 7.5
var raid_serial := 0
var defeated := 0
var defeated_variants := {}
var last_message := ""
var visual_factory
var projectile_system
var npc_target_attacks := 0
var npc_target_projectiles := 0
var scripted_battle_starts := 0

func setup(main_node, player_node: CharacterBody3D, survival_system, inventory_system) -> void:
    main = main_node
    player = player_node
    survival = survival_system
    inventory = inventory_system
    visual_factory = HostileVisualFactoryScript.new()
    projectile_system = HostileProjectileSystemScript.new()
    projectile_system.name = "HostileProjectiles"
    add_child(projectile_system)
    projectile_system.setup(main, player, survival)
    projectiles = projectile_system.projectiles

func surface_y_at_position(position: Vector3) -> float:
    if main != null and main.has_method("surface_y_at_position"):
        return float(main.call("surface_y_at_position", position))
    return position.y

func ground_y_near_position(position: Vector3) -> float:
    if main != null and main.has_method("ground_y_near_position"):
        return float(main.call("ground_y_near_position", position))
    return surface_y_at_position(position)

func surface_biome_at_position(position: Vector3) -> String:
    if main != null and main.has_method("surface_biome_at_cell"):
        return String(main.call("surface_biome_at_cell", Vector3i(main.world_to_cell(position.x), 0, main.world_to_cell(position.z))))
    return "plains"

func clear() -> void:
    for enemy in enemies:
        var body := enemy.get("body") as Node
        if body and is_instance_valid(body):
            body.queue_free()
    enemies.clear()
    if projectile_system:
        projectile_system.clear()

func update_hostiles(delta: float, day_factor: float, biome: String, sanctuary_established := false) -> void:
    if player == null or main == null:
        return
    if sanctuary_established:
        if not enemies.is_empty() or (projectile_system and not projectile_system.projectiles.is_empty()):
            clear()
        spawn_cooldown = maxf(spawn_cooldown, 4.0)
        return
    if projectile_system:
        projectile_system.update_projectiles(delta)
    var night_factor: float = clampf((1.0 - day_factor - 0.30) / 0.55, 0.0, 1.0)
    var player_safety: float = main.light_safety_at(player.global_position, sanctuary_established)
    var tutorial_profile := tutorial_danger_profile(night_factor)
    var tutorial_pressure := not tutorial_profile.is_empty()
    var rescue_mission_active := tutorial_rescue_mission_active()
    var enemy_capacity := tutorial_hostile_capacity(tutorial_profile) if tutorial_pressure else 3
    spawn_cooldown = maxf(0.0, spawn_cooldown - delta)
    if rescue_mission_active or (tutorial_pressure and bool(tutorial_profile.get("rescueMission", false))):
        clear_non_rescue_hostiles()
        spawn_cooldown = maxf(spawn_cooldown, 2.0)
    elif tutorial_pressure and spawn_cooldown <= 0.0 and enemies.size() < enemy_capacity:
        if spawn_tutorial_perimeter(tutorial_profile, biome) != null:
            spawn_cooldown = (2.0 + randf() * 2.5) if bool(tutorial_profile.get("finalNight", false)) else (6.0 + randf() * 6.0)
        else:
            spawn_cooldown = 3.0 + randf() * 2.0
    elif night_factor > 0.34 and player_safety < 0.82 and spawn_cooldown <= 0.0 and enemies.size() < enemy_capacity:
        spawn_near_player(biome)
        spawn_cooldown = 16.0 + randf() * 12.0
    for enemy in enemies.duplicate():
        update_enemy(enemy, delta, night_factor)

func tutorial_danger_profile(night_factor: float) -> Dictionary:
    if night_factor <= 0.34 or main == null or player == null:
        return {}
    var tutorial_system = main.get("tutorial_system")
    if tutorial_system == null or not tutorial_system.has_method("danger_profile"):
        return {}
    var profile: Dictionary = tutorial_system.danger_profile(player.global_position)
    if not bool(profile.get("active", false)):
        return {}
    return profile

func tutorial_rescue_mission_active() -> bool:
    if main == null:
        return false
    var tutorial_system = main.get("tutorial_system")
    if tutorial_system == null:
        return false
    return bool(tutorial_system.get("final_night_active")) and not bool(tutorial_system.get("final_night_complete"))

func tutorial_hostile_capacity(profile: Dictionary) -> int:
    return 3 if profile.is_empty() else (8 if bool(profile.get("finalNight", false)) else (4 if bool(profile.get("readyForWilds", false)) else 6))

func clear_non_rescue_hostiles() -> int:
    var removed := 0
    for enemy in enemies.duplicate():
        if rescue_enemy(enemy):
            continue
        remove_enemy(enemy, false)
        removed += 1
    return removed

func rescue_enemy(enemy: Dictionary) -> bool:
    if bool(enemy.get("tutorialRescue", false)):
        return true
    var body := enemy.get("body") as Node
    return body != null and is_instance_valid(body) and bool(body.get_meta("tutorial_rescue_hostile", false))

func configure_scripted_encounter(body: Node, encounter_id: String, phase: String, options := {}) -> void:
    if body == null or not is_instance_valid(body):
        return
    var enemy := enemy_for_body(body)
    if enemy.is_empty():
        return
    enemy["scriptedEncounter"] = encounter_id
    enemy["scriptedPhase"] = phase
    enemy["scriptedTargetName"] = String(options.get("targetName", enemy.get("scriptedTargetName", "")))
    enemy["scriptedTargetNpcId"] = String(options.get("targetNpcId", enemy.get("scriptedTargetNpcId", "")))
    enemy["battleSourceNpcId"] = String(options.get("battleSourceNpcId", enemy.get("battleSourceNpcId", "")))
    enemy["damageable"] = bool(options.get("damageable", phase == "battle"))
    enemy["canAttack"] = bool(options.get("canAttack", phase == "battle"))
    enemy["frenzy"] = bool(options.get("frenzy", enemy.get("frenzy", false)))
    if options.has("circleAnchor"):
        enemy["circleAnchor"] = options.get("circleAnchor")
    enemy["circleRadius"] = float(options.get("circleRadius", enemy.get("circleRadius", CELL * 3.8)))
    enemy["circleIndex"] = int(options.get("circleIndex", enemy.get("circleIndex", 0)))
    enemy["circleCount"] = maxi(1, int(options.get("circleCount", enemy.get("circleCount", 1))))
    enemy["circlePhase"] = float(options.get("circlePhase", enemy.get("circlePhase", 0.0)))
    enemy["circleAngularSpeed"] = float(options.get("circleAngularSpeed", enemy.get("circleAngularSpeed", 0.16)))
    enemy["scriptedElapsed"] = 0.0
    publish_scripted_hostile_meta(enemy)

func publish_scripted_hostile_meta(enemy: Dictionary) -> void:
    var body := enemy.get("body") as Node
    if body == null or not is_instance_valid(body):
        return
    body.set_meta("hostile_scripted_encounter", String(enemy.get("scriptedEncounter", "")))
    body.set_meta("hostile_scripted_phase", String(enemy.get("scriptedPhase", "")))
    body.set_meta("hostile_damageable", bool(enemy.get("damageable", true)))
    body.set_meta("hostile_can_attack", bool(enemy.get("canAttack", true)))
    body.set_meta("hostile_scripted_battle_started_by", String(enemy.get("scriptedBattleStartedBy", "")))

func maybe_begin_scripted_battle_from_damage(enemy: Dictionary, source: Node, source_kind: String) -> bool:
    var encounter_id := String(enemy.get("scriptedEncounter", ""))
    if encounter_id == "":
        return false
    if String(enemy.get("scriptedPhase", "")) == "battle":
        return true
    if not scripted_battle_source_allowed(enemy, source, source_kind):
        return false
    begin_scripted_battle(encounter_id, source, source_kind)
    return true

func scripted_battle_source_allowed(enemy: Dictionary, source: Node, source_kind: String) -> bool:
    if source == player or source_kind.begins_with("player"):
        return true
    var expected_npc_id := String(enemy.get("battleSourceNpcId", ""))
    if expected_npc_id == "":
        return false
    if scripted_battle_source_id(source, source_kind) != expected_npc_id:
        return false
    if String(enemy.get("scriptedEncounter", "")) == "tutorial_final_rescue":
        return tutorial_rescue_escort_started() and scripted_source_near_anchor(enemy, source)
    return true

func scripted_battle_source_id(source: Node, source_kind: String) -> String:
    if source == player or source_kind.begins_with("player"):
        return "player"
    if source == null or not is_instance_valid(source):
        return source_kind
    if source.has_meta("npc_id"):
        return String(source.get_meta("npc_id"))
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system != null and npc_system.has_method("npc_entry_for_actor"):
        var entry: Dictionary = npc_system.npc_entry_for_actor(source)
        if not entry.is_empty():
            return String(entry.get("id", source.name))
    return source.name

func begin_scripted_battle(encounter_id: String, source: Node, source_kind: String) -> bool:
    var source_id := scripted_battle_source_id(source, source_kind)
    var changed := false
    for enemy in enemies:
        if String(enemy.get("scriptedEncounter", "")) != encounter_id:
            continue
        if String(enemy.get("scriptedPhase", "")) != "battle":
            changed = true
        enemy["scriptedPhase"] = "battle"
        enemy["damageable"] = true
        enemy["canAttack"] = true
        enemy["aware"] = true
        enemy["awarenessDelay"] = 0.0
        enemy["scriptedBattleStartedBy"] = source_id
        publish_scripted_hostile_meta(enemy)
    if changed:
        scripted_battle_starts += 1
        last_message = "Hostiles surged toward the fight"
    return changed

func tutorial_rescue_escort_started() -> bool:
    if main == null:
        return false
    var tutorial_system = main.get("tutorial_system")
    if tutorial_system == null:
        return false
    return bool(tutorial_system.get("rescue_escort_started"))

func scripted_source_near_anchor(enemy: Dictionary, source: Node) -> bool:
    var source_3d := source as Node3D
    if source_3d == null or not is_instance_valid(source_3d):
        return false
    return scripted_origin_near_anchor(enemy, source_3d.global_position)

func scripted_origin_near_anchor(enemy: Dictionary, origin: Vector3) -> bool:
    var anchor: Vector3 = enemy.get("circleAnchor", enemy.get("spawnOrigin", origin))
    var radius := maxf(CELL * 2.2, float(enemy.get("circleRadius", CELL * 3.8)))
    var threshold := maxf(CELL * 8.5, radius + CELL * 3.0)
    return flat_distance_squared(origin, anchor) <= threshold * threshold

func hostile_available_for_npc_combat(body: Node, origin: Vector3) -> bool:
    var enemy := enemy_for_body(body)
    if enemy.is_empty():
        return true
    if String(enemy.get("scriptedEncounter", "")) != "tutorial_final_rescue":
        return true
    if String(enemy.get("scriptedPhase", "")) == "battle":
        return true
    return tutorial_rescue_escort_started() and scripted_origin_near_anchor(enemy, origin)

func spawn_tutorial_perimeter(profile: Dictionary, biome: String) -> StaticBody3D:
    if main == null or player == null or profile.is_empty():
        return null
    var center: Vector3 = profile.get("center", player.global_position)
    var safe_radius := float(profile.get("safeRadius", CELL * 15.0))
    var outer_radius := maxf(float(profile.get("outerRadius", CELL * 36.0)), safe_radius + CELL * 8.0)
    for attempt in range(24):
        var angle: float = randf() * TAU
        var radius: float = safe_radius + CELL * 10.0 + randf() * maxf(CELL * 6.0, outer_radius - safe_radius)
        var position := center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
        if position.distance_to(player.global_position) < CELL * 13.0:
            continue
        var ground_y: float = surface_y_at_position(position)
        if ground_y < main.WATER_LEVEL + 0.8:
            continue
        position.y = ground_y + 0.72
        if main.light_safety_at(position, false) > 0.22:
            continue
        var variant := "seer" if randf() > 0.84 else ("frost" if biome in ["snow", "tundra", "alpine", "taiga"] else "shadow")
        var body := spawn_enemy(position, variant)
        var enemy := enemy_for_body(body)
        if not enemy.is_empty():
            enemy["aware"] = false
            enemy["awarenessDelay"] = 1.0 + randf() * 2.4
            enemy["naturalSpawn"] = true
            enemy["tutorialSpawn"] = true
        return body
    return null

func spawn_near_player(biome: String) -> StaticBody3D:
    for attempt in range(18):
        var angle: float = randf() * TAU
        var distance: float = 48.0 + randf() * 46.0
        var position: Vector3 = player.global_position + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
        var ground_y: float = surface_y_at_position(position)
        if ground_y < main.WATER_LEVEL + 0.8:
            continue
        position.y = ground_y + 0.72
        if position.distance_to(player.global_position) < 44.0:
            continue
        if main.light_safety_at(position, false) > 0.18:
            continue
        var variant: String = "shadow"
        if can_spawn_rift_variant() and randf() > 0.92:
            variant = "rift"
        elif randf() > 0.80:
            variant = "seer"
        elif biome in ["snow", "tundra", "alpine", "taiga"]:
            variant = "frost"
        var body := spawn_enemy(position, variant)
        var enemy := enemy_for_body(body)
        if not enemy.is_empty():
            enemy["aware"] = false
            enemy["awarenessDelay"] = 1.2 + randf() * 2.2
            enemy["naturalSpawn"] = true
        return body
    return null

func spawn_beacon_raid(beacon: Node3D, stage: int = 1) -> int:
    if beacon == null or main == null:
        return 0
    raid_serial += 1
    var rng := RandomNumberGenerator.new()
    rng.seed = main.hash_string("%s:beacon-raid:%d:%d:%d" % [
        main.seed_text,
        stage,
        roundi(beacon.global_position.x),
        roundi(beacon.global_position.z) + raid_serial
    ])
    var target_count := 6 if stage >= 3 else 2 + stage
    var spawned := 0
    var capacity := 9
    for attempt in range(target_count * 6):
        if spawned >= target_count or enemies.size() >= capacity:
            break
        var angle := rng.randf() * TAU
        var radius := 13.0 + rng.randf() * 13.0 + float(stage) * 1.8
        var position := beacon.global_position + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
        var ground_y: float = surface_y_at_position(position)
        if ground_y < main.WATER_LEVEL + 0.8:
            continue
        position.y = ground_y + 0.72
        if player and position.distance_to(player.global_position) < 8.0:
            continue
        var biome: String = surface_biome_at_position(position)
        var is_rift_boss: bool = stage >= 3 and spawned == 0
        var variant: String = "rift" if is_rift_boss else ("seer" if rng.randf() > 0.72 else ("frost" if biome in ["snow", "tundra", "alpine", "taiga"] else "shadow"))
        var body: StaticBody3D = spawn_enemy(position, variant)
        var enemy: Dictionary = enemy_for_body(body)
        if not enemy.is_empty():
            enemy["aware"] = true
            enemy["daylightImmune"] = stage >= 3
        spawned += 1
    if spawned > 0:
        spawn_cooldown = maxf(spawn_cooldown, 4.5)
        last_message = "Rift Colossus awakened" if stage >= 3 else "Rift surge %d" % stage
    return spawned

func spawn_landmark_ambush(origin: Vector3, tier := "ruin") -> int:
    if main == null:
        return 0
    raid_serial += 1
    var rng := RandomNumberGenerator.new()
    rng.seed = main.hash_string("%s:landmark-ambush:%s:%d,%d:%d" % [
        main.seed_text,
        tier,
        roundi(origin.x),
        roundi(origin.z),
        raid_serial
    ])
    var target_count := 2 if tier == "mine" else (3 + rng.randi_range(0, 1) if tier == "camp" else 1 + rng.randi_range(0, 1))
    var capacity := 8 if tier == "camp" else 6
    var spawned := 0
    for attempt in range(target_count * 8):
        if spawned >= target_count or enemies.size() >= capacity:
            break
        var angle := rng.randf() * TAU
        var radius := 7.0 + rng.randf() * 7.0 if tier == "camp" else 5.0 + rng.randf() * 6.0
        var position := origin + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
        var ground_y: float = surface_y_at_position(position)
        if ground_y < main.WATER_LEVEL + 0.8:
            continue
        position.y = ground_y + 0.72
        var variant := "skitter" if tier == "mine" and rng.randf() > 0.34 else ("seer" if tier == "ruin" and rng.randf() > 0.82 else "shadow")
        if tier == "camp":
            variant = "seer" if rng.randf() > 0.78 else ("skitter" if rng.randf() > 0.56 else "shadow")
        var body: StaticBody3D = spawn_enemy(position, variant)
        var enemy: Dictionary = enemy_for_body(body)
        if not enemy.is_empty():
            enemy["aware"] = true
            enemy["daylightImmune"] = true
        spawned += 1
    if spawned > 0:
        spawn_cooldown = maxf(spawn_cooldown, 4.0)
        last_message = "Camp guards alerted" if tier == "camp" else ("Mine guardians stirred" if tier == "mine" else "Ruin guardians stirred")
    return spawned

func spawn_shrine_guardians(origin: Vector3, count := 3) -> int:
    if main == null:
        return 0
    raid_serial += 1
    var rng := RandomNumberGenerator.new()
    rng.seed = main.hash_string("%s:shrine-guardians:%d,%d:%d" % [
        main.seed_text,
        roundi(origin.x),
        roundi(origin.z),
        raid_serial
    ])
    var spawned := 0
    var capacity := 8
    for attempt in range(count * 8):
        if spawned >= count or enemies.size() >= capacity:
            break
        var angle := rng.randf() * TAU
        var radius := 8.0 + rng.randf() * 7.0
        var position := origin + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
        var ground_y: float = surface_y_at_position(position)
        if ground_y < main.WATER_LEVEL + 0.8:
            continue
        position.y = ground_y + 0.72
        var variant := "shadow" if spawned == 0 else ("seer" if rng.randf() > 0.72 else "shadow")
        var body: StaticBody3D = spawn_enemy(position, variant)
        var enemy: Dictionary = enemy_for_body(body)
        if not enemy.is_empty():
            enemy["aware"] = true
            enemy["daylightImmune"] = true
            enemy["shrineGuardian"] = true
        spawned += 1
    if spawned > 0:
        spawn_cooldown = maxf(spawn_cooldown, 6.0)
        last_message = "Shrine guardians awakened"
    return spawned

func spawn_enemy(position: Vector3, variant := "shadow") -> StaticBody3D:
    var body := StaticBody3D.new()
    body.name = "Hostile_%s_%d" % [variant, enemies.size()]
    body.position = position
    body.set_meta("kind", "hostile")
    body.set_meta("variant", variant)

    var spec: Dictionary = visual_factory.build_visual(body, variant)

    add_child(body)
    enemies.append({
        "body": body,
        "variant": variant,
        "health": float(spec.get("health", 18.0)),
        "aware": false,
        "cooldown": 1.0,
        "wobble": randf() * TAU,
        "spawnOrigin": position,
        "frenzy": false,
        "roamDirection": HostileRulesScript.random_roam_direction(),
        "roamTimer": 0.6 + randf() * 1.8,
        "lastMoveDistance": 0.0,
        "damageable": true,
        "canAttack": true,
        "scriptedEncounter": "",
        "scriptedPhase": "",
        "scriptedBattleStartedBy": ""
    })
    return body

func can_spawn_rift_variant() -> bool:
    if main == null:
        return false
    var state: Dictionary = main.objective_state()
    var totals: Dictionary = state.get("totals", {})
    var counts: Dictionary = state.get("structureCounts", {})
    return int(counts.get("sanctuaryBeacon", 0)) > 0 or (int(state.get("level", 1)) >= 6 and int(totals.get("nightShard", 0)) >= 6)

func horizontal_move(body: Node3D, displacement: Vector3, variant: String, ignore_tutorial_safe_zone := false) -> float:
    if body == null or displacement.length_squared() < 0.000001 or main == null:
        return 0.0
    displacement.y = 0.0
    var previous := body.global_position
    var previous_ground: float = ground_y_near_position(previous)
    var candidate := previous + displacement
    var next_ground: float = ground_y_near_position(candidate)
    if next_ground < main.WATER_LEVEL + 0.35:
        return 0.0
    var max_step := CELL * (1.38 if variant == "rift" else 0.92)
    if absf(next_ground - previous_ground) > max_step:
        return 0.0
    if not ignore_tutorial_safe_zone and tutorial_safe_zone_blocks(previous, candidate, variant):
        return 0.0
    if hostile_obstacle_between(body, previous, candidate, variant):
        return 0.0
    if hostile_body_overlaps_block(candidate, variant):
        return 0.0
    if hostile_spacing_blocks(body, previous, candidate, variant):
        return 0.0
    body.global_position.x = candidate.x
    body.global_position.z = candidate.z
    return Vector2(candidate.x - previous.x, candidate.z - previous.z).length()

func tutorial_safe_zone_blocks(previous: Vector3, candidate: Vector3, variant: String) -> bool:
    if main == null or player == null or variant == "rift":
        return false
    var tutorial_system = main.get("tutorial_system")
    if tutorial_system == null or not tutorial_system.has_method("danger_profile"):
        return false
    var profile: Dictionary = tutorial_system.danger_profile(player.global_position)
    if profile.is_empty() or not bool(profile.get("active", false)):
        return false
    var center: Vector3 = profile.get("center", player.global_position)
    var safe_radius: float = float(profile.get("safeRadius", CELL * 15.0))
    var previous_distance := Vector2(previous.x - center.x, previous.z - center.z).length()
    var candidate_distance := Vector2(candidate.x - center.x, candidate.z - center.z).length()
    if candidate_distance >= safe_radius:
        return false
    return previous_distance >= safe_radius or candidate_distance < previous_distance

func hostile_obstacle_between(body: Node3D, previous: Vector3, candidate: Vector3, variant: String) -> bool:
    var delta := candidate - previous
    delta.y = 0.0
    var distance := delta.length()
    if distance < 0.001:
        return false
    var direction := delta / distance
    var side := Vector3(-direction.z, 0.0, direction.x)
    var radius := CELL * (0.45 if variant == "rift" else 0.34)
    var height := 0.92 if variant == "rift" else 0.72
    var offsets := [Vector3.ZERO, side * radius, -side * radius]
    for offset in offsets:
        var start: Vector3 = previous + offset + Vector3(0.0, height, 0.0)
        var end: Vector3 = candidate + offset + Vector3(0.0, height, 0.0)
        var query := PhysicsRayQueryParameters3D.create(start, end)
        query.exclude = [body]
        query.collision_mask = 1 | 4
        query.collide_with_bodies = true
        query.collide_with_areas = false
        var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
        if hit.is_empty():
            continue
        if hostile_movement_obstacle(hit.get("collider") as Node):
            return true
    return false

func hostile_movement_obstacle(collider: Node) -> bool:
    if collider == null:
        return false
    var kind := String(collider.get_meta("kind", ""))
    if kind == "block":
        return String(collider.get_meta("block_type", "")) != "cobblestonePath"
    if kind == "prop" or kind == "tutorial_npc" or kind == "npc":
        return true
    return false

func hostile_body_overlaps_block(candidate: Vector3, variant: String) -> bool:
    if main == null:
        return false
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return false
    var blocks: Dictionary = blocks_value
    var radius := CELL * (0.45 if variant == "rift" else 0.34)
    var half_block := CELL * 0.48
    var search_radius := radius + half_block
    var min_x := floori((candidate.x - search_radius) / CELL)
    var max_x := ceili((candidate.x + search_radius) / CELL)
    var min_z := floori((candidate.z - search_radius) / CELL)
    var max_z := ceili((candidate.z + search_radius) / CELL)
    var ground_y: float = surface_y_at_position(candidate)
    var center_y := floori((ground_y + CELL * 0.48) / CELL) + 1
    for x in range(min_x, max_x + 1):
        for z in range(min_z, max_z + 1):
            for y in range(center_y - 1, center_y + 3):
                var key := Vector3i(x, y, z)
                if not blocks.has(key):
                    continue
                var block := blocks[key] as Node
                if not hostile_movement_obstacle(block):
                    continue
                var block_body := block as Node3D
                if block_body == null:
                    continue
                if absf(block_body.global_position.y - (ground_y + CELL * 0.48)) > CELL * 1.35:
                    continue
                if absf(candidate.x - block_body.global_position.x) <= search_radius and absf(candidate.z - block_body.global_position.z) <= search_radius:
                    return true
    return false

func hostile_spacing_blocks(body: Node3D, previous: Vector3, candidate: Vector3, variant: String) -> bool:
    var radius := hostile_spacing_radius(variant)
    for enemy in enemies:
        var other := enemy.get("body") as Node3D
        if other == null or other == body or not is_instance_valid(other):
            continue
        var other_variant := String(enemy.get("variant", other.get_meta("variant", "")))
        var min_distance := maxf(radius, hostile_spacing_radius(other_variant))
        var previous_distance_sq := flat_distance_squared(previous, other.global_position)
        var candidate_distance_sq := flat_distance_squared(candidate, other.global_position)
        if candidate_distance_sq < min_distance * min_distance and candidate_distance_sq <= previous_distance_sq + 0.0001:
            return true
    return false

func hostile_separation_direction(body: Node3D, variant: String) -> Vector3:
    if body == null:
        return Vector3.ZERO
    var push := Vector3.ZERO
    var radius := hostile_spacing_radius(variant)
    for enemy in enemies:
        var other := enemy.get("body") as Node3D
        if other == null or other == body or not is_instance_valid(other):
            continue
        var other_variant := String(enemy.get("variant", other.get_meta("variant", "")))
        var min_distance := maxf(radius, hostile_spacing_radius(other_variant))
        var delta := body.global_position - other.global_position
        delta.y = 0.0
        var distance_sq := delta.length_squared()
        if distance_sq >= min_distance * min_distance:
            continue
        if distance_sq < 0.0001:
            delta = deterministic_hostile_spread_direction(body)
            distance_sq = 0.0001
        var distance := sqrt(distance_sq)
        push += delta.normalized() * ((min_distance - distance) / min_distance)
    return push.normalized() if push.length_squared() > 0.0001 else Vector3.ZERO

func deterministic_hostile_spread_direction(body: Node) -> Vector3:
    var index := hostile_index_for_body(body)
    var count := maxi(1, enemies.size())
    var angle := TAU * float(maxi(0, index)) / float(count)
    return Vector3(cos(angle), 0.0, sin(angle)).normalized()

func hostile_index_for_body(body: Node) -> int:
    for i in range(enemies.size()):
        var enemy: Dictionary = enemies[i]
        if enemy.get("body") == body:
            return i
    return 0

func hostile_spacing_radius(variant: String) -> float:
    return HOSTILE_RIFT_SPACING_RADIUS if variant == "rift" else HOSTILE_SPACING_RADIUS

func flat_distance_squared(a: Vector3, b: Vector3) -> float:
    var dx := a.x - b.x
    var dz := a.z - b.z
    return dx * dx + dz * dz

func update_enemy(enemy: Dictionary, delta: float, night_factor: float) -> void:
    var body := enemy.get("body") as StaticBody3D
    if body == null or not is_instance_valid(body):
        enemies.erase(enemy)
        return
    var scripted_phase := String(enemy.get("scriptedPhase", ""))
    if scripted_phase != "" and scripted_phase != "battle":
        update_scripted_enemy(enemy, body, delta, night_factor)
        return
    var target_info := closest_hostile_target(body.global_position, enemy)
    var target_node := target_info.get("node") as Node3D
    var target_position: Vector3 = target_info.get("position", player.global_position)
    var target_aim_position: Vector3 = target_info.get("aimPosition", target_position + Vector3(0.0, 0.8, 0.0))
    var target_kind := String(target_info.get("kind", "player"))
    var to_target: Vector3 = target_position - body.global_position
    to_target.y = 0.0
    var distance: float = to_target.length()
    var direction: Vector3 = to_target.normalized() if distance > 0.001 else Vector3.ZERO
    var active_threat: bool = night_factor > 0.18 or bool(enemy.get("daylightImmune", false))
    var aware: bool = bool(enemy.get("aware", false))
    var awareness_delay: float = maxf(0.0, float(enemy.get("awarenessDelay", 0.0)) - delta)
    enemy["awarenessDelay"] = awareness_delay
    if not active_threat:
        aware = false
    elif aware and distance > HostileRulesScript.leash_radius(enemy):
        aware = false
    elif awareness_delay <= 0.0 and not aware and distance <= HostileRulesScript.awareness_radius(enemy):
        aware = true
    enemy["aware"] = aware
    enemy["targetKind"] = target_kind
    enemy["targetName"] = target_node.name if target_node != null and is_instance_valid(target_node) else ""
    enemy["targetDistance"] = distance
    body.set_meta("hostile_target_kind", target_kind)
    body.set_meta("hostile_target_name", String(enemy.get("targetName", "")))
    enemy["cooldown"] = maxf(0.0, float(enemy.get("cooldown", 0.0)) - delta)
    enemy["wobble"] = float(enemy.get("wobble", 0.0)) + delta * 5.0

    var variant := String(enemy.get("variant", "shadow"))
    var facing_direction: Vector3 = direction
    var move_distance := 0.0
    var frenzy := hostile_frenzy_enabled(enemy, body)
    enemy["frenzy"] = frenzy
    body.set_meta("hostile_frenzy", frenzy)
    var separation_direction := hostile_separation_direction(body, variant)
    if aware and active_threat:
        var move_direction: Vector3 = direction
        var speed: float = 2.35 + night_factor * 0.95
        if variant == "rift":
            speed = 1.85 + night_factor * 0.70
        elif variant == "skitter":
            speed = 2.85 + night_factor * 0.90
        if variant == "seer" and distance < 9.0:
            move_direction *= -1.0
        elif variant == "seer" and distance <= 28.0:
            speed *= 0.18
        if separation_direction.length_squared() > 0.001:
            move_direction = (move_direction + separation_direction * 1.45).normalized()
        move_distance = horizontal_move(body, move_direction * speed * delta, variant, frenzy)
        if move_distance <= 0.001 and separation_direction.length_squared() > 0.001:
            move_distance = horizontal_move(body, separation_direction * speed * delta * 0.9, variant, frenzy)
        if move_direction.length_squared() > 0.001:
            facing_direction = move_direction.normalized()
        var light_safety: float = main.light_safety_at(body.global_position, false)
        if light_safety > 0.34 and variant != "rift" and not frenzy:
            move_distance += horizontal_move(body, -direction * delta * (5.0 + light_safety * 4.0), variant, frenzy)
            if direction.length_squared() > 0.001:
                facing_direction = -direction
            if light_safety > 0.82:
                enemy["aware"] = false
    elif active_threat:
        var roam_direction: Vector3 = enemy.get("roamDirection", Vector3.ZERO)
        if roam_direction.length_squared() < 0.001:
            roam_direction = HostileRulesScript.random_roam_direction()
        var roam_timer: float = float(enemy.get("roamTimer", 0.0)) - delta
        var spawn_origin: Vector3 = enemy.get("spawnOrigin", body.global_position)
        var from_origin := body.global_position - spawn_origin
        from_origin.y = 0.0
        var roam_radius := 11.0 if bool(enemy.get("naturalSpawn", false)) else 7.0
        if roam_timer <= 0.0 or from_origin.length() > roam_radius:
            if from_origin.length() > roam_radius:
                roam_direction = -from_origin.normalized()
            else:
                roam_direction = HostileRulesScript.random_roam_direction()
            roam_timer = 1.0 + randf() * 2.4
        var roam_speed: float = 0.62 + night_factor * 0.42
        if variant == "rift":
            roam_speed *= 0.74
        elif variant == "skitter":
            roam_speed *= 1.18
        if separation_direction.length_squared() > 0.001:
            roam_direction = (roam_direction + separation_direction * 1.35).normalized()
        move_distance = horizontal_move(body, roam_direction * roam_speed * delta, variant, frenzy)
        if move_distance <= 0.001:
            for attempt in range(4):
                roam_direction = HostileRulesScript.random_roam_direction()
                if separation_direction.length_squared() > 0.001:
                    roam_direction = (roam_direction + separation_direction * 1.35).normalized()
                move_distance = horizontal_move(body, roam_direction * roam_speed * delta, variant, frenzy)
                if move_distance > 0.001:
                    break
            roam_timer = 0.45 + randf() * 1.0
        else:
            facing_direction = roam_direction.normalized()
        if move_distance > 0.001:
            facing_direction = roam_direction.normalized()
        enemy["roamDirection"] = roam_direction
        enemy["roamTimer"] = roam_timer
    enemy["lastMoveDistance"] = move_distance

    var ground_y: float = ground_y_near_position(body.global_position)
    var hover: float = 0.78 if variant == "rift" else 0.72
    var bob: float = 0.03 if variant == "rift" else 0.05
    body.global_position.y = ground_y + hover + sin(float(enemy.get("wobble", 0.0))) * bob
    if facing_direction.length_squared() > 0.001:
        body.rotation.y = atan2(facing_direction.x, facing_direction.z)

    var trap_damage: float = main.trap_damage_at(body.global_position, delta)
    if trap_damage > 0.0 and damage_hostile(body, trap_damage):
        return

    var can_attack := bool(enemy.get("canAttack", true))
    if variant == "seer" and can_attack and aware and active_threat and distance >= 8.0 and distance <= 28.0 and float(enemy.get("cooldown", 0.0)) <= 0.0:
        projectile_system.spawn_projectile(body.global_position + Vector3(0.0, 1.25, 0.0), target_aim_position, 8.0, body, target_node, target_kind)
        if target_kind in ["npc", "tutorial_npc"]:
            register_hostile_npc_attack(target_node, body, variant, "projectile")
            npc_target_projectiles += 1
        enemy["cooldown"] = 2.2
    elif can_attack and distance < (2.85 if variant == "rift" else 2.1) and aware and active_threat and float(enemy.get("cooldown", 0.0)) <= 0.0:
        if target_kind == "player" and survival:
            var damage: float = 21.0 + night_factor * 5.0 if variant == "rift" else 8.0 + night_factor * 4.0
            var label: String = "Hit by Rift Colossus" if variant == "rift" else "Hit by Shadow Stalker"
            survival.apply_damage(damage, label, "hostile")
        elif target_kind in ["npc", "tutorial_npc"]:
            register_hostile_npc_attack(target_node, body, variant, "melee")
        enemy["cooldown"] = 1.85 if variant == "rift" else 1.25

    if body.global_position.distance_to(player.global_position) > 112.0:
        remove_enemy(enemy, false)

func update_scripted_enemy(enemy: Dictionary, body: StaticBody3D, delta: float, night_factor: float) -> void:
    var variant := String(enemy.get("variant", "shadow"))
    var frenzy := hostile_frenzy_enabled(enemy, body)
    enemy["frenzy"] = frenzy
    body.set_meta("hostile_frenzy", frenzy)
    enemy["scriptedElapsed"] = float(enemy.get("scriptedElapsed", 0.0)) + delta
    var anchor: Vector3 = enemy.get("circleAnchor", enemy.get("spawnOrigin", body.global_position))
    var index := int(enemy.get("circleIndex", 0))
    var count := maxi(1, int(enemy.get("circleCount", 1)))
    var radius := maxf(CELL * 2.2, float(enemy.get("circleRadius", CELL * 3.8)))
    var base_angle := TAU * float(index) / float(count)
    var angle := base_angle + float(enemy.get("circlePhase", 0.0)) + float(enemy.get("scriptedElapsed", 0.0)) * float(enemy.get("circleAngularSpeed", 0.16))
    var desired := anchor + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
    var to_desired := desired - body.global_position
    to_desired.y = 0.0
    var move_distance := 0.0
    if to_desired.length_squared() > 0.014:
        var speed := 1.18 + night_factor * 0.24
        if variant == "seer":
            speed *= 0.85
        move_distance = horizontal_move(body, to_desired.normalized() * minf(speed * delta, to_desired.length()), variant, frenzy)
    enemy["lastMoveDistance"] = move_distance
    var ground_y: float = ground_y_near_position(body.global_position)
    var hover: float = 0.78 if variant == "rift" else 0.72
    var bob: float = 0.03 if variant == "rift" else 0.05
    enemy["wobble"] = float(enemy.get("wobble", 0.0)) + delta * 4.0
    body.global_position.y = ground_y + hover + sin(float(enemy.get("wobble", 0.0))) * bob
    var face := anchor - body.global_position
    face.y = 0.0
    if face.length_squared() > 0.001:
        body.rotation.y = atan2(face.x, face.z)
    enemy["aware"] = false
    enemy["targetKind"] = "script_anchor"
    enemy["targetName"] = String(enemy.get("scriptedTargetName", ""))
    enemy["targetDistance"] = sqrt(flat_distance_squared(body.global_position, anchor))
    body.set_meta("hostile_target_kind", "script_anchor")
    body.set_meta("hostile_target_name", String(enemy.get("targetName", "")))
    publish_scripted_hostile_meta(enemy)

func closest_hostile_target(origin: Vector3, enemy: Dictionary) -> Dictionary:
    var best := {}
    if player != null and is_instance_valid(player):
        best = hostile_target_row(player, "player", origin, player.global_position, player.global_position + Vector3(0.0, 0.8, 0.0), "player")
    var encounter_id := String(enemy.get("scriptedEncounter", ""))
    var battle_source_npc_id := String(enemy.get("battleSourceNpcId", ""))
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return best
    var entries: Array = npc_system.get("npcs")
    for entry_value in entries:
        var entry: Dictionary = entry_value if entry_value is Dictionary else {}
        var npc_body := entry.get("body") as Node3D
        if npc_body == null or not is_instance_valid(npc_body):
            continue
        if bool(npc_body.get_meta("npc_hostile_target_immune", false)) or bool(npc_body.get_meta("hostile_target_immune", false)):
            continue
        if bool(entry.get("insideHome", false)) or bool(npc_body.get_meta("npc_inside_home", false)):
            continue
        var kind := String(npc_body.get_meta("kind", "npc"))
        if not (kind in ["npc", "tutorial_npc"]):
            continue
        var npc_id := String(entry.get("id", npc_body.name))
        if encounter_id == "tutorial_final_rescue" and npc_id != battle_source_npc_id:
            continue
        var row := hostile_target_row(npc_body, kind, origin, npc_body.global_position, npc_body.global_position + Vector3(0.0, 0.95, 0.0), String(entry.get("id", npc_body.name)))
        if best.is_empty() or float(row.get("distance", INF)) < float(best.get("distance", INF)):
            best = row
    return best

func hostile_target_row(node: Node3D, kind: String, origin: Vector3, position: Vector3, aim_position: Vector3, target_id: String) -> Dictionary:
    var flat_delta := Vector2(position.x - origin.x, position.z - origin.z)
    return {
        "node": node,
        "kind": kind,
        "id": target_id,
        "name": node.name if node != null else target_id,
        "position": position,
        "aimPosition": aim_position,
        "distance": flat_delta.length()
    }

func register_hostile_npc_attack(target: Node, hostile: Node3D, variant: String, attack_kind: String) -> void:
    if target == null or not is_instance_valid(target):
        return
    npc_target_attacks += 1
    target.set_meta("npc_hostile_targeted", true)
    target.set_meta("npc_hostile_targeted_count", int(target.get_meta("npc_hostile_targeted_count", 0)) + 1)
    target.set_meta("npc_last_hostile_attack", attack_kind)
    target.set_meta("npc_last_hostile_attacker", hostile.name if hostile != null and is_instance_valid(hostile) else "")
    target.set_meta("npc_last_hostile_variant", variant)
    last_message = "%s attacked %s" % [variant.capitalize(), String(target.get_meta("npc_name", target.name))]

func hostile_frenzy_enabled(enemy: Dictionary, body: Node) -> bool:
    if bool(enemy.get("frenzy", false)):
        return true
    return body != null and is_instance_valid(body) and bool(body.get_meta("hostile_frenzy", false))

func damage_hostile(body: Node, amount: float, drop := true, source: Node = null, source_kind := "") -> bool:
    var enemy: Dictionary = enemy_for_body(body)
    if enemy.is_empty():
        return false
    if not bool(enemy.get("damageable", true)):
        if not maybe_begin_scripted_battle_from_damage(enemy, source, source_kind):
            last_message = "Hostile is circling out of reach"
            return false
    enemy["health"] = float(enemy.get("health", 0.0)) - amount
    if float(enemy.get("health", 0.0)) > 0.0:
        last_message = "Hostile hit: %d" % ceili(float(enemy.get("health", 0.0)))
        return false
    remove_enemy(enemy, drop)
    return true
func remove_projectile(projectile_state: Dictionary) -> void:
    if projectile_system:
        projectile_system.remove_projectile(projectile_state)
func spawn_projectile(start: Vector3, target: Vector3, damage := 8.0, owner: Node = null, target_node: Node = null, target_kind := "") -> MeshInstance3D:
    return projectile_system.spawn_projectile(start, target, damage, owner, target_node, target_kind) if projectile_system else null
func projectile_block_hit(previous: Vector3, next: Vector3) -> Dictionary:
    return projectile_system.projectile_block_hit(previous, next) if projectile_system else {}
func awareness_radius(enemy: Dictionary) -> float:
    return HostileRulesScript.awareness_radius(enemy)
func enemy_for_body(body: Node) -> Dictionary:
    for enemy in enemies:
        if enemy.get("body") == body:
            return enemy
    return {}
func remove_enemy(enemy: Dictionary, drop := true) -> void:
    var body := enemy.get("body") as Node
    if body and is_instance_valid(body):
        body.queue_free()
    enemies.erase(enemy)
    if drop:
        var variant := String(enemy.get("variant", "shadow"))
        defeated += 1
        defeated_variants[variant] = int(defeated_variants.get(variant, 0)) + 1
        if inventory:
            if variant == "rift":
                inventory.add_item("nightShard", 7 + randi_range(0, 3))
                inventory.add_item("rawMeat", 3 + randi_range(0, 2))
                inventory.add_item("riftCore", 1)
            else:
                inventory.add_item("nightShard", 1)
                if variant != "seer" and variant != "frost":
                    inventory.add_item("rawMeat", 1)
        last_message = "Rift Colossus defeated: Rift Core dropped" if variant == "rift" else "Defeated hostile"
    else:
        last_message = "Hostile left"
func stats() -> Dictionary:
    var projectile_stats: Dictionary = projectile_system.stats() if projectile_system else {}
    var rescue_count := 0
    for enemy in enemies:
        if rescue_enemy(enemy):
            rescue_count += 1
    var spacing := hostile_spacing_summary()
    var result := {
        "enemies": enemies.size(),
        "tutorialRescueEnemies": rescue_count,
        "nonRescueEnemies": maxi(0, enemies.size() - rescue_count),
        "hostileSpacingMinDistance": spacing.get("minDistance", 0.0),
        "hostileSpacingViolations": spacing.get("violations", 0),
        "defeated": defeated,
        "defeatedVariants": defeated_variants.duplicate(),
        "hostileNpcTargetAttacks": npc_target_attacks,
        "hostileNpcTargetProjectiles": npc_target_projectiles,
        "scriptedBattleStarts": scripted_battle_starts,
        "scriptedHostilePhases": scripted_hostile_phase_summary()
    }
    for key in projectile_stats.keys():
        result[key] = projectile_stats[key]
    return result

func hostile_spacing_summary() -> Dictionary:
    var min_distance := INF
    var violations := 0
    for i in range(enemies.size()):
        var enemy_a: Dictionary = enemies[i]
        var body_a := enemy_a.get("body") as Node3D
        if body_a == null or not is_instance_valid(body_a):
            continue
        var variant_a := String(enemy_a.get("variant", body_a.get_meta("variant", "")))
        for j in range(i + 1, enemies.size()):
            var enemy_b: Dictionary = enemies[j]
            var body_b := enemy_b.get("body") as Node3D
            if body_b == null or not is_instance_valid(body_b):
                continue
            var variant_b := String(enemy_b.get("variant", body_b.get_meta("variant", "")))
            var distance := sqrt(flat_distance_squared(body_a.global_position, body_b.global_position))
            min_distance = minf(min_distance, distance)
            var min_allowed := maxf(hostile_spacing_radius(variant_a), hostile_spacing_radius(variant_b))
            if distance < min_allowed * 0.82:
                violations += 1
    return {
        "minDistance": 0.0 if min_distance == INF else min_distance,
        "violations": violations
    }

func scripted_hostile_phase_summary() -> Dictionary:
    var result := {}
    for enemy in enemies:
        var encounter := String(enemy.get("scriptedEncounter", ""))
        if encounter == "":
            continue
        var phase := String(enemy.get("scriptedPhase", ""))
        var key := "%s:%s" % [encounter, phase]
        result[key] = int(result.get(key, 0)) + 1
    return result
