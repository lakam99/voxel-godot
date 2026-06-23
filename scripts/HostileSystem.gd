extends Node3D
class_name HostileSystem

const HostileProjectileSystemScript := preload("res://scripts/HostileProjectileSystem.gd")
const HostileRulesScript := preload("res://scripts/HostileRules.gd")
const HostileVisualFactoryScript := preload("res://scripts/HostileVisualFactory.gd")
const CELL := 1.35

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
    var enemy_capacity := tutorial_hostile_capacity(tutorial_profile) if tutorial_pressure else 3
    spawn_cooldown = maxf(0.0, spawn_cooldown - delta)
    if tutorial_pressure and bool(tutorial_profile.get("rescueMission", false)):
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

func tutorial_hostile_capacity(profile: Dictionary) -> int:
    return 3 if profile.is_empty() else (8 if bool(profile.get("finalNight", false)) else (4 if bool(profile.get("readyForWilds", false)) else 6))

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
        var ground_y: float = main.height_at_world(position.x, position.z)
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
        var ground_y: float = main.height_at_world(position.x, position.z)
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
        var ground_y: float = main.height_at_world(position.x, position.z)
        if ground_y < main.WATER_LEVEL + 0.8:
            continue
        position.y = ground_y + 0.72
        if player and position.distance_to(player.global_position) < 8.0:
            continue
        var cell: Vector2i = Vector2i(main.world_to_cell(position.x), main.world_to_cell(position.z))
        var biome: String = main.biome_at_cell(cell.x, cell.y)
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
        var ground_y: float = main.height_at_world(position.x, position.z)
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
        var ground_y: float = main.height_at_world(position.x, position.z)
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
        "roamDirection": HostileRulesScript.random_roam_direction(),
        "roamTimer": 0.6 + randf() * 1.8,
        "lastMoveDistance": 0.0
    })
    return body

func can_spawn_rift_variant() -> bool:
    if main == null:
        return false
    var state: Dictionary = main.objective_state()
    var totals: Dictionary = state.get("totals", {})
    var counts: Dictionary = state.get("structureCounts", {})
    return int(counts.get("sanctuaryBeacon", 0)) > 0 or (int(state.get("level", 1)) >= 6 and int(totals.get("nightShard", 0)) >= 6)

func horizontal_move(body: Node3D, displacement: Vector3, variant: String) -> float:
    if body == null or displacement.length_squared() < 0.000001 or main == null:
        return 0.0
    displacement.y = 0.0
    var previous := body.global_position
    var previous_ground: float = main.height_at_world(previous.x, previous.z)
    var candidate := previous + displacement
    var next_ground: float = main.height_at_world(candidate.x, candidate.z)
    if next_ground < main.WATER_LEVEL + 0.35:
        return 0.0
    var max_step := CELL * (1.38 if variant == "rift" else 0.92)
    if absf(next_ground - previous_ground) > max_step:
        return 0.0
    if tutorial_safe_zone_blocks(previous, candidate, variant):
        return 0.0
    if hostile_obstacle_between(body, previous, candidate, variant):
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

func update_enemy(enemy: Dictionary, delta: float, night_factor: float) -> void:
    var body := enemy.get("body") as StaticBody3D
    if body == null or not is_instance_valid(body):
        enemies.erase(enemy)
        return
    var to_player: Vector3 = player.global_position - body.global_position
    to_player.y = 0.0
    var distance: float = to_player.length()
    var direction: Vector3 = to_player.normalized() if distance > 0.001 else Vector3.ZERO
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
    enemy["cooldown"] = maxf(0.0, float(enemy.get("cooldown", 0.0)) - delta)
    enemy["wobble"] = float(enemy.get("wobble", 0.0)) + delta * 5.0

    var variant := String(enemy.get("variant", "shadow"))
    var facing_direction: Vector3 = direction
    var move_distance := 0.0
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
        move_distance = horizontal_move(body, move_direction * speed * delta, variant)
        if move_direction.length_squared() > 0.001:
            facing_direction = move_direction.normalized()
        var light_safety: float = main.light_safety_at(body.global_position, false)
        if light_safety > 0.34 and variant != "rift":
            move_distance += horizontal_move(body, -direction * delta * (5.0 + light_safety * 4.0), variant)
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
        move_distance = horizontal_move(body, roam_direction * roam_speed * delta, variant)
        if move_distance <= 0.001:
            for attempt in range(4):
                roam_direction = HostileRulesScript.random_roam_direction()
                move_distance = horizontal_move(body, roam_direction * roam_speed * delta, variant)
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

    var ground_y: float = main.height_at_world(body.global_position.x, body.global_position.z)
    var hover: float = 0.78 if variant == "rift" else 0.72
    var bob: float = 0.03 if variant == "rift" else 0.05
    body.global_position.y = ground_y + hover + sin(float(enemy.get("wobble", 0.0))) * bob
    if facing_direction.length_squared() > 0.001:
        body.rotation.y = atan2(facing_direction.x, facing_direction.z)

    var trap_damage: float = main.trap_damage_at(body.global_position, delta)
    if trap_damage > 0.0 and damage_hostile(body, trap_damage):
        return

    if variant == "seer" and aware and active_threat and distance >= 8.0 and distance <= 28.0 and float(enemy.get("cooldown", 0.0)) <= 0.0:
        projectile_system.spawn_projectile(body.global_position + Vector3(0.0, 1.25, 0.0), player.global_position + Vector3(0.0, 0.8, 0.0), 8.0, body)
        enemy["cooldown"] = 2.2
    elif distance < (2.85 if variant == "rift" else 2.1) and aware and active_threat and float(enemy.get("cooldown", 0.0)) <= 0.0:
        if survival:
            var damage: float = 21.0 + night_factor * 5.0 if variant == "rift" else 8.0 + night_factor * 4.0
            var label: String = "Hit by Rift Colossus" if variant == "rift" else "Hit by Shadow Stalker"
            survival.apply_damage(damage, label, "hostile")
        enemy["cooldown"] = 1.85 if variant == "rift" else 1.25

    if distance > 112.0:
        remove_enemy(enemy, false)

func damage_hostile(body: Node, amount: float, drop := true) -> bool:
    var enemy: Dictionary = enemy_for_body(body)
    if enemy.is_empty():
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
func spawn_projectile(start: Vector3, target: Vector3, damage := 8.0, owner: Node = null) -> MeshInstance3D:
    return projectile_system.spawn_projectile(start, target, damage, owner) if projectile_system else null
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
    var result := { "enemies": enemies.size(), "defeated": defeated, "defeatedVariants": defeated_variants.duplicate() }
    for key in projectile_stats.keys():
        result[key] = projectile_stats[key]
    return result
