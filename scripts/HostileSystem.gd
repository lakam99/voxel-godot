extends Node3D
class_name HostileSystem

const HostileProjectileSystemScript := preload("res://scripts/HostileProjectileSystem.gd")
const HostileRulesScript := preload("res://scripts/HostileRules.gd")
const HostileVisualFactoryScript := preload("res://scripts/HostileVisualFactory.gd")
const HostileMotionCombatSystemScript := preload("res://scripts/combat/runtime/HostileMotionCombatSystem.gd")
const CombatTargetPolicyScript := preload("res://scripts/combat/CombatTargetPolicy.gd")
const CELL := 1.35
const HOSTILE_SPACING_RADIUS := CELL * 0.95
const HOSTILE_RIFT_SPACING_RADIUS := CELL * 1.25
const HOSTILE_UPDATE_BUDGET := 2
const HOSTILE_ACCUMULATED_DELTA_CAP := 4.0
const TUTORIAL_SPAWN_ATTEMPTS_PER_UPDATE := 4
const TUTORIAL_SPAWN_ATTEMPT_LIMIT := 24
const HOSTILE_RUNTIME_BODY_META_KEYS: Array[StringName] = [
    &"hostile_target_kind",
    &"hostile_target_name",
    &"hostile_frenzy",
    &"hostile_scripted_encounter",
    &"hostile_scripted_phase",
    &"hostile_damageable",
    &"hostile_can_attack",
    &"hostile_scripted_battle_started_by",
    &"hostile_scripted_slot_id",
    &"hostile_scripted_leash_returning"
]

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
var hostile_motion_combat
var npc_target_attacks := 0
var npc_target_projectiles := 0
var scripted_battle_starts := 0
var scripted_leash_returns := 0
var scripted_leash_max_distance := 0.0
var hostile_update_cursor := 0
var tutorial_spawn_attempts_remaining := 0
var hostile_body_pool := {}
var native_collision_admission_required := false

func set_native_collision_admission_required(required: bool) -> void:
    native_collision_admission_required = required

func setup(main_node, player_node: CharacterBody3D, survival_system, inventory_system) -> void:
    main = main_node
    native_collision_admission_required = main != null and main.has_method("native_collision_admission_bound") \
        and bool(main.call("native_collision_admission_bound"))
    player = player_node
    survival = survival_system
    inventory = inventory_system
    visual_factory = HostileVisualFactoryScript.new()
    projectile_system = HostileProjectileSystemScript.new()
    projectile_system.name = "HostileProjectiles"
    add_child(projectile_system)
    projectile_system.setup(main, player, survival)
    projectiles = projectile_system.projectiles
    hostile_motion_combat = HostileMotionCombatSystemScript.new()
    hostile_motion_combat.name = "HostileMotionCombat"
    hostile_motion_combat.motion_contact_resolved.connect(_on_hostile_motion_contact_resolved)
    add_child(hostile_motion_combat)
    hostile_motion_combat.setup(main.get("runtime_perf_monitor") if main != null else null)

func prewarm_visuals_staged() -> Dictionary:
    if visual_factory == null or not is_inside_tree():
        return {"variantCount": 0, "elapsedMs": 0.0}
    var started_usec := Time.get_ticks_usec()
    var pool_counts := {"shadow": 6, "frost": 2, "seer": 2, "rift": 1, "skitter": 1}
    var warmed := 0
    for variant_value in pool_counts.keys():
        var variant := String(variant_value)
        var pool: Array = hostile_body_pool.get(variant, []) if hostile_body_pool.get(variant, []) is Array else []
        while pool.size() < int(pool_counts[variant]):
            var body := StaticBody3D.new()
            body.name = "HostileVisualPool_%s_%d" % [variant, pool.size()]
            body.position = Vector3(0.0, -10000.0, 0.0)
            var spec: Dictionary = visual_factory.build_visual(body, variant)
            body.set_meta("hostile_pool_variant", variant)
            body.set_meta("hostile_pool_spec", spec)
            body.visible = false
            add_child(body)
            await get_tree().process_frame
            pool.append(body)
            warmed += 1
        hostile_body_pool[variant] = pool
    return {
        "variantCount": pool_counts.size(),
        "bodyCount": warmed,
        "elapsedMs": float(Time.get_ticks_usec() - started_usec) / 1000.0
    }

func acquire_hostile_body(variant: String) -> StaticBody3D:
    var pool: Array = hostile_body_pool.get(variant, []) if hostile_body_pool.get(variant, []) is Array else []
    while not pool.is_empty():
        var body := pool.pop_back() as StaticBody3D
        if body != null and is_instance_valid(body):
            hostile_body_pool[variant] = pool
            body.visible = true
            return body
    hostile_body_pool[variant] = pool
    return null

func reset_hostile_runtime_body_state(body: StaticBody3D) -> void:
    if body == null or not is_instance_valid(body):
        return
    for key in HOSTILE_RUNTIME_BODY_META_KEYS:
        if body.has_meta(key):
            body.remove_meta(key)

func recycle_hostile_body(body: Node) -> bool:
    var body_3d := body as StaticBody3D
    if body_3d == null or not is_instance_valid(body_3d):
        return false
    if hostile_motion_combat != null and hostile_motion_combat.has_method("cancel_for_body"):
        hostile_motion_combat.cancel_for_body(body_3d)
    var variant := String(body_3d.get_meta("hostile_pool_variant", ""))
    if variant == "":
        return false
    reset_hostile_runtime_body_state(body_3d)
    if not hostile_placement_admitted(body_3d, Vector3(0.0, -10000.0, 0.0)):
        return false
    body_3d.visible = false
    body_3d.position = Vector3(0.0, -10000.0, 0.0)
    body_3d.rotation = Vector3.ZERO
    var pool: Array = hostile_body_pool.get(variant, []) if hostile_body_pool.get(variant, []) is Array else []
    if not pool.has(body_3d):
        pool.append(body_3d)
    hostile_body_pool[variant] = pool
    return true

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
            if not recycle_hostile_body(body):
                body.queue_free()
    enemies.clear()
    if projectile_system:
        projectile_system.clear()

func clear_combat_transients() -> void:
    # Enemies themselves remain owned by hostile lifecycle/world state. Only
    # active motion and projectile windows are transient across save restore.
    if hostile_motion_combat != null and hostile_motion_combat.has_method("clear_transient_state"):
        hostile_motion_combat.clear_transient_state()
    if projectile_system != null and projectile_system.has_method("clear"):
        projectile_system.clear()

func clear_scripted_encounter(encounter_id: String, drop := false) -> int:
    if encounter_id == "":
        return 0
    var removed := 0
    for enemy_value in enemies.duplicate():
        var enemy: Dictionary = enemy_value if enemy_value is Dictionary else {}
        if String(enemy.get("scriptedEncounter", "")) != encounter_id:
            continue
        remove_enemy(enemy, drop)
        removed += 1
    return removed

func update_hostiles(delta: float, day_factor: float, biome: String, sanctuary_established := false) -> void:
    if player == null or main == null:
        return
    var monitor = main.get("runtime_perf_monitor")
    if sanctuary_established:
        if not enemies.is_empty() or (projectile_system and not projectile_system.projectiles.is_empty()):
            clear()
        spawn_cooldown = maxf(spawn_cooldown, 4.0)
        return
    if projectile_system:
        var projectiles_started: int = monitor.begin_section("hostile_projectiles") if monitor != null else Time.get_ticks_usec()
        projectile_system.update_projectiles(delta)
        if monitor != null:
            monitor.end_section("hostile_projectiles", projectiles_started)
    var context_started: int = monitor.begin_section("hostile_context") if monitor != null else Time.get_ticks_usec()
    var night_factor := hostile_night_factor(day_factor)
    var player_safety: float = main.light_safety_at(player.global_position, sanctuary_established)
    var tutorial_profile := tutorial_danger_profile(night_factor)
    var tutorial_pressure := not tutorial_profile.is_empty()
    var exclusive_encounter_active := exclusive_scripted_encounter_active()
    var enemy_capacity := tutorial_hostile_capacity(tutorial_profile) if tutorial_pressure else 3
    spawn_cooldown = maxf(0.0, spawn_cooldown - delta)
    if monitor != null:
        monitor.end_section("hostile_context", context_started)
    var spawn_started: int = monitor.begin_section("hostile_spawn") if monitor != null else Time.get_ticks_usec()
    if exclusive_encounter_active:
        clear_non_scripted_hostiles()
        spawn_cooldown = maxf(spawn_cooldown, 2.0)
    elif tutorial_pressure and spawn_cooldown <= 0.0 and enemies.size() < enemy_capacity:
        if spawn_tutorial_perimeter(tutorial_profile, biome) != null:
            spawn_cooldown = (2.0 + randf() * 2.5) if bool(tutorial_profile.get("finalNight", false)) else (6.0 + randf() * 6.0)
        elif tutorial_spawn_attempts_remaining > 0:
            spawn_cooldown = 0.05
        else:
            spawn_cooldown = 3.0 + randf() * 2.0
    elif night_factor > 0.34 and player_safety < 0.82 and spawn_cooldown <= 0.0 and enemies.size() < enemy_capacity:
        if player_is_in_underground_air():
            spawn_underground_near_player()
        else:
            spawn_near_player(biome)
        spawn_cooldown = 16.0 + randf() * 12.0
    if monitor != null:
        monitor.end_section("hostile_spawn", spawn_started)
    var enemies_started: int = monitor.begin_section("hostile_enemy_updates") if monitor != null else Time.get_ticks_usec()
    update_enemy_budgeted(delta, night_factor)
    if monitor != null:
        monitor.end_section("hostile_enemy_updates", enemies_started)

func update_enemy_budgeted(delta: float, night_factor: float) -> void:
    var active_enemies: Array = enemies.duplicate()
    if active_enemies.is_empty():
        hostile_update_cursor = 0
        return
    if active_enemies.size() <= HOSTILE_UPDATE_BUDGET:
        hostile_update_cursor = 0
        for enemy in active_enemies:
            if enemy is Dictionary:
                (enemy as Dictionary)["hostileAccumulatedDelta"] = 0.0
                update_enemy(enemy, delta, night_factor)
        return
    for enemy in active_enemies:
        if enemy is Dictionary:
            (enemy as Dictionary)["hostileAccumulatedDelta"] = minf(
                float((enemy as Dictionary).get("hostileAccumulatedDelta", 0.0)) + delta,
                delta * HOSTILE_ACCUMULATED_DELTA_CAP
            )
    hostile_update_cursor = hostile_update_cursor % active_enemies.size()
    var processed := 0
    var scanned := 0
    while scanned < active_enemies.size() and processed < HOSTILE_UPDATE_BUDGET:
        var enemy = active_enemies[(hostile_update_cursor + scanned) % active_enemies.size()]
        scanned += 1
        if not (enemy is Dictionary):
            continue
        var enemy_delta := float((enemy as Dictionary).get("hostileAccumulatedDelta", delta))
        (enemy as Dictionary)["hostileAccumulatedDelta"] = 0.0
        update_enemy(enemy, enemy_delta, night_factor)
        processed += 1
    hostile_update_cursor = (hostile_update_cursor + max(1, scanned)) % max(1, active_enemies.size())

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

func exclusive_scripted_encounter_active() -> bool:
    for enemy_value in enemies:
        var enemy: Dictionary = enemy_value if enemy_value is Dictionary else {}
        if String(enemy.get("scriptedEncounter", "")) != "" and bool(enemy.get("exclusiveWorldSpawns", false)):
            return true
    return false

func tutorial_hostile_capacity(profile: Dictionary) -> int:
    return 3 if profile.is_empty() else (8 if bool(profile.get("finalNight", false)) else (4 if bool(profile.get("readyForWilds", false)) else 6))

func clear_non_scripted_hostiles() -> int:
    var removed := 0
    for enemy_value in enemies.duplicate():
        var enemy: Dictionary = enemy_value if enemy_value is Dictionary else {}
        if String(enemy.get("scriptedEncounter", "")) != "":
            continue
        remove_enemy(enemy, false)
        removed += 1
    return removed

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
    enemy["scriptedSlotId"] = String(options.get("slotId", enemy.get("scriptedSlotId", "")))
    enemy["scriptedTargetNpcIds"] = options.get("targetNpcIds", enemy.get("scriptedTargetNpcIds", [])).duplicate() if options.get("targetNpcIds", enemy.get("scriptedTargetNpcIds", [])) is Array else []
    enemy["scriptedTargetPlayer"] = bool(options.get("targetPlayer", enemy.get("scriptedTargetPlayer", true)))
    enemy["playerCanStartBattle"] = bool(options.get("playerCanStartBattle", enemy.get("playerCanStartBattle", true)))
    enemy["battleSourceRequiresAnchor"] = bool(options.get("battleSourceRequiresAnchor", enemy.get("battleSourceRequiresAnchor", false)))
    enemy["battleSourceRadius"] = float(options.get("battleSourceRadius", enemy.get("battleSourceRadius", 0.0)))
    if options.has("leashAnchor"):
        enemy["scriptedLeashAnchor"] = options.get("leashAnchor")
    enemy["scriptedLeashRadius"] = maxf(0.0, float(options.get("leashRadius", enemy.get("scriptedLeashRadius", 0.0))))
    enemy["scriptedLeashReleaseRadius"] = maxf(0.0, float(options.get("leashReleaseRadius", enemy.get("scriptedLeashReleaseRadius", 0.0))))
    enemy["scriptedLeashReturning"] = false
    enemy["scriptedLeashReturnCount"] = 0
    enemy["scriptedLeashMaxDistance"] = 0.0
    enemy["exclusiveWorldSpawns"] = bool(options.get("exclusiveWorldSpawns", enemy.get("exclusiveWorldSpawns", false)))
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
    body.set_meta("hostile_scripted_slot_id", String(enemy.get("scriptedSlotId", "")))
    body.set_meta("hostile_scripted_leash_returning", bool(enemy.get("scriptedLeashReturning", false)))

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
        return bool(enemy.get("playerCanStartBattle", true))
    var expected_npc_id := String(enemy.get("battleSourceNpcId", ""))
    if expected_npc_id == "":
        return false
    if scripted_battle_source_id(source, source_kind) != expected_npc_id:
        return false
    if bool(enemy.get("battleSourceRequiresAnchor", false)):
        return scripted_source_near_anchor(enemy, source)
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

func scripted_source_near_anchor(enemy: Dictionary, source: Node) -> bool:
    var source_3d := source as Node3D
    if source_3d == null or not is_instance_valid(source_3d):
        return false
    return scripted_origin_near_anchor(enemy, source_3d.global_position)

func scripted_origin_near_anchor(enemy: Dictionary, origin: Vector3) -> bool:
    var anchor: Vector3 = enemy.get("circleAnchor", enemy.get("spawnOrigin", origin))
    var radius := maxf(CELL * 2.2, float(enemy.get("circleRadius", CELL * 3.8)))
    var configured_radius := float(enemy.get("battleSourceRadius", 0.0))
    var threshold := configured_radius if configured_radius > 0.0 else maxf(CELL * 8.5, radius + CELL * 3.0)
    return flat_distance_squared(origin, anchor) <= threshold * threshold

func scripted_leash_state(enemy: Dictionary, origin: Vector3) -> Dictionary:
    var encounter_id := String(enemy.get("scriptedEncounter", ""))
    var radius := float(enemy.get("scriptedLeashRadius", 0.0))
    if encounter_id == "" or String(enemy.get("scriptedPhase", "")) != "battle" or radius <= 0.0:
        return {"enabled": false, "returning": false}
    var anchor_value = enemy.get("scriptedLeashAnchor", enemy.get("circleAnchor", enemy.get("spawnOrigin", origin)))
    if not (anchor_value is Vector3):
        return {"enabled": false, "returning": false}
    var anchor: Vector3 = anchor_value
    var distance := sqrt(flat_distance_squared(origin, anchor))
    var previous_max := float(enemy.get("scriptedLeashMaxDistance", 0.0))
    enemy["scriptedLeashMaxDistance"] = maxf(previous_max, distance)
    scripted_leash_max_distance = maxf(scripted_leash_max_distance, distance)
    var release_radius := float(enemy.get("scriptedLeashReleaseRadius", 0.0))
    if release_radius <= 0.0 or release_radius >= radius:
        release_radius = radius * 0.72
    var was_returning := bool(enemy.get("scriptedLeashReturning", false))
    var returning := was_returning
    if not returning and distance >= radius * 0.92:
        returning = true
        enemy["scriptedLeashReturnCount"] = int(enemy.get("scriptedLeashReturnCount", 0)) + 1
        scripted_leash_returns += 1
    elif returning and distance <= release_radius:
        returning = false
    enemy["scriptedLeashReturning"] = returning
    var direction := anchor - origin
    direction.y = 0.0
    if direction.length_squared() > 0.001:
        direction = direction.normalized()
    if returning != was_returning:
        publish_scripted_hostile_meta(enemy)
    return {
        "enabled": true,
        "returning": returning,
        "anchor": anchor,
        "radius": radius,
        "releaseRadius": release_radius,
        "distance": distance,
        "direction": direction
    }

func hostile_available_for_npc_combat(body: Node, origin: Vector3) -> bool:
    var enemy := enemy_for_body(body)
    if enemy.is_empty():
        return true
    return hostile_is_active_combat_threat(enemy, origin)

func hostile_is_active_combat_threat(enemy: Dictionary, origin: Vector3) -> bool:
    var scripted_phase := String(enemy.get("scriptedPhase", ""))
    if scripted_phase != "":
        return scripted_phase == "battle"
    if bool(enemy.get("daylightImmune", false)):
        return true
    return hostile_night_factor() > 0.18

func hostile_night_factor(day_factor := -1.0) -> float:
    var resolved_day_factor := day_factor
    if resolved_day_factor < 0.0 and main != null and main.has_method("clock_day_factor"):
        resolved_day_factor = float(main.call("clock_day_factor"))
    if resolved_day_factor < 0.0:
        return 1.0
    return clampf((1.0 - clampf(resolved_day_factor, 0.0, 1.0) - 0.30) / 0.55, 0.0, 1.0)

func nearest_scripted_encounter_hostile_for_npc(source: Node, origin: Vector3, radius := 42.0, encounter_id := "") -> Node3D:
    var best: Node3D = null
    var best_distance := radius
    for enemy in enemies:
        var body := enemy.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            continue
        var enemy_encounter := String(enemy.get("scriptedEncounter", ""))
        if enemy_encounter == "":
            continue
        if encounter_id != "" and enemy_encounter != encounter_id:
            continue
        if not scripted_battle_source_allowed(enemy, source, "npc_scripted_combat"):
            continue
        var distance := origin.distance_to(body.global_position)
        if distance < best_distance:
            best_distance = distance
            best = body
    return best

func spawn_tutorial_perimeter(profile: Dictionary, biome: String) -> StaticBody3D:
    if main == null or player == null or profile.is_empty():
        return null
    var center: Vector3 = profile.get("center", player.global_position)
    var safe_radius := float(profile.get("safeRadius", CELL * 15.0))
    var outer_radius := maxf(float(profile.get("outerRadius", CELL * 36.0)), safe_radius + CELL * 8.0)
    if tutorial_spawn_attempts_remaining <= 0:
        tutorial_spawn_attempts_remaining = TUTORIAL_SPAWN_ATTEMPT_LIMIT
    var attempts_this_update := mini(TUTORIAL_SPAWN_ATTEMPTS_PER_UPDATE, tutorial_spawn_attempts_remaining)
    for _attempt in range(attempts_this_update):
        tutorial_spawn_attempts_remaining -= 1
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
        tutorial_spawn_attempts_remaining = 0
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
        var roam_direction := hostile_spawn_roam_direction(position, variant)
        if roam_direction.length_squared() <= 0.001:
            continue
        var body := spawn_enemy(position, variant)
        var enemy := enemy_for_body(body)
        if not enemy.is_empty():
            enemy["aware"] = false
            enemy["awarenessDelay"] = 1.2 + randf() * 2.2
            enemy["naturalSpawn"] = true
            enemy["roamDirection"] = roam_direction
            enemy["roamTimer"] = maxf(float(enemy.get("roamTimer", 0.0)), 1.0)
        return body
    return null

func hostile_spawn_roam_direction(position: Vector3, variant: String) -> Vector3:
    var directions: Array[Vector3] = [
        Vector3(1.0, 0.0, 0.0),
        Vector3(-1.0, 0.0, 0.0),
        Vector3(0.0, 0.0, 1.0),
        Vector3(0.0, 0.0, -1.0),
        Vector3(1.0, 0.0, 1.0).normalized(),
        Vector3(-1.0, 0.0, 1.0).normalized(),
        Vector3(1.0, 0.0, -1.0).normalized(),
        Vector3(-1.0, 0.0, -1.0).normalized()
    ]
    var start_index := 0
    if main != null and main.has_method("hash_string"):
        start_index = abs(int(main.call("hash_string", "%d:%d:%s" % [roundi(position.x * 10.0), roundi(position.z * 10.0), variant]))) % directions.size()
    for offset in range(directions.size()):
        var direction: Vector3 = directions[(start_index + offset) % directions.size()]
        if hostile_spawn_can_roam(position, direction, variant):
            return direction
    return Vector3.ZERO

func hostile_spawn_can_roam(position: Vector3, direction: Vector3, variant: String) -> bool:
    if main == null or direction.length_squared() <= 0.001:
        return false
    var candidate := position + direction.normalized() * CELL * 1.15
    var previous_ground: float = ground_y_near_position(position)
    var next_ground: float = ground_y_near_position(candidate)
    if next_ground < main.WATER_LEVEL + 0.35:
        return false
    var max_step := CELL * (1.38 if variant == "rift" else 0.92)
    if absf(next_ground - previous_ground) > max_step:
        return false
    if hostile_obstacle_between(null, position, candidate, variant):
        return false
    if hostile_body_overlaps_block(candidate, variant):
        return false
    return true

func player_is_in_underground_air() -> bool:
    if player == null:
        return false
    return position_is_underground_air(player.global_position)

func position_is_underground_air(position: Vector3) -> bool:
    if main == null:
        return false
    var world_generation = main.get("world_generation_system")
    if world_generation == null or not world_generation.has_method("sample_world"):
        return false
    var sample: Dictionary = world_generation.call("sample_world", position)
    return String(sample.get("biome", "")) == "underground_air" and not bool(sample.get("solid", true)) and String(sample.get("fluid", "")) == ""

func spawn_underground_near_player() -> StaticBody3D:
    if main == null or player == null:
        return null
    var world_generation = main.get("world_generation_system")
    if world_generation == null or not world_generation.has_method("walkable_surface_cell_near"):
        return null
    var player_cell := Vector3i(main.world_to_cell(player.global_position.x), main.world_to_cell(player.global_position.y), main.world_to_cell(player.global_position.z))
    if tutorial_spawn_attempts_remaining <= 0:
        tutorial_spawn_attempts_remaining = TUTORIAL_SPAWN_ATTEMPT_LIMIT
    var attempts_this_update := mini(TUTORIAL_SPAWN_ATTEMPTS_PER_UPDATE, tutorial_spawn_attempts_remaining)
    for _attempt in range(attempts_this_update):
        tutorial_spawn_attempts_remaining -= 1
        var angle := randf() * TAU
        var distance_cells := randi_range(8, 22)
        var probe := player_cell + Vector3i(roundi(cos(angle) * float(distance_cells)), randi_range(-4, 5), roundi(sin(angle) * float(distance_cells)))
        var projection: Dictionary = world_generation.call("walkable_surface_cell_near", probe, 8, 16)
        if projection.is_empty() or not bool(projection.get("found", false)) or not bool(projection.get("walkable", false)):
            continue
        var occupancy: Dictionary = projection.get("occupancy", {}) if projection.get("occupancy", {}) is Dictionary else {}
        if String(occupancy.get("biome", "")) != "underground_air":
            continue
        if String(occupancy.get("fluid", "")) != "":
            continue
        var position: Vector3 = projection.get("position", player.global_position)
        position.y += 0.72
        if position.distance_to(player.global_position) < CELL * 7.0:
            continue
        if main.light_safety_at(position, false) > 0.18:
            continue
        var variant := "skitter" if randf() > 0.54 else ("seer" if randf() > 0.88 else "shadow")
        var body := spawn_enemy(position, variant)
        var enemy := enemy_for_body(body)
        if not enemy.is_empty():
            enemy["aware"] = false
            enemy["awarenessDelay"] = 1.2 + randf() * 2.0
            enemy["naturalSpawn"] = true
            enemy["undergroundSpawn"] = true
        tutorial_spawn_attempts_remaining = 0
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
    var body := acquire_hostile_body(variant)
    var spec: Dictionary = {}
    if body == null:
        body = StaticBody3D.new()
        body.position = Vector3(0.0, -10000.0, 0.0)
        spec = visual_factory.build_visual(body, variant)
        add_child(body)
    else:
        spec = body.get_meta("hostile_pool_spec", {}) if body.get_meta("hostile_pool_spec", {}) is Dictionary else {}
    reset_hostile_runtime_body_state(body)
    body.add_to_group(&"world_moving_physics_actor")
    body.name = "Hostile_%s_%d" % [variant, enemies.size()]
    body.rotation = Vector3.ZERO
    var placement_admitted := hostile_placement_admitted(body, position)
    if placement_admitted:
        body.position = position
    else:
        body.visible = false
    body.set_meta("kind", "hostile")
    body.set_meta("variant", variant)
    enemies.append({
        "body": body,
        "variant": variant,
        "health": float(spec.get("health", 18.0)),
        "aware": false,
        "cooldown": 1.0,
        "wobble": randf() * TAU,
        "spawnOrigin": position,
        "pendingSpawn": not placement_admitted,
        "pendingSpawnPosition": position,
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

func hostile_placement_admitted(body: StaticBody3D, position: Vector3) -> bool:
    if not native_collision_admission_required:
        return true
    if main == null or not main.has_method("native_collision_register_moving_actor") \
            or not main.has_method("native_collision_admit_placement") \
            or not bool(main.call("native_collision_register_moving_actor", body)):
        return false
    var proposed: Transform3D = (body.get_parent() as Node3D).global_transform \
        * Transform3D(body.transform.basis, position)
    return bool(main.call("native_collision_admit_placement", body, proposed))

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
    var underground_move := position_is_underground_air(previous) or position_is_underground_air(candidate)
    if not underground_move and next_ground < main.WATER_LEVEL + 0.35:
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
    if native_collision_admission_required and (main == null or not main.has_method("native_collision_admit_motion")):
        return 0.0
    if main != null and main.has_method("native_collision_admit_motion") \
            and not main.call("native_collision_admit_motion", body, candidate - previous):
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
        if body != null:
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
    if kind == "prop" or kind == "npc":
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
    if bool(enemy.get("pendingSpawn", false)):
        var spawn_position: Vector3 = enemy.get("pendingSpawnPosition", body.position)
        if not hostile_placement_admitted(body, spawn_position):
            return
        body.position = spawn_position
        body.visible = true
        enemy["pendingSpawn"] = false
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
    var scripted_leash := scripted_leash_state(enemy, body.global_position)
    var leash_returning := bool(scripted_leash.get("returning", false))
    var active_threat: bool = scripted_phase == "battle" or night_factor > 0.18 or bool(enemy.get("daylightImmune", false))
    var aware: bool = bool(enemy.get("aware", false))
    var awareness_delay: float = maxf(0.0, float(enemy.get("awarenessDelay", 0.0)) - delta)
    enemy["awarenessDelay"] = awareness_delay
    if not active_threat:
        aware = false
    elif leash_returning:
        aware = true
    elif aware and scripted_phase == "" and distance > HostileRulesScript.leash_radius(enemy):
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
    var motion_active: bool = hostile_motion_combat != null and hostile_motion_combat.has_method("is_motion_active") and bool(hostile_motion_combat.is_motion_active(body))
    if aware and active_threat and not motion_active:
        var move_direction: Vector3 = scripted_leash.get("direction", direction) if leash_returning else direction
        var speed: float = 2.35 + night_factor * 0.95
        if variant == "rift":
            speed = 1.85 + night_factor * 0.70
        elif variant == "skitter":
            speed = 2.85 + night_factor * 0.90
        if not leash_returning and variant == "seer" and distance < 9.0:
            move_direction *= -1.0
        elif not leash_returning and variant == "seer" and distance <= 28.0:
            speed *= 0.18
        if not leash_returning and separation_direction.length_squared() > 0.001:
            move_direction = (move_direction + separation_direction * 1.45).normalized()
        move_distance = horizontal_move(body, move_direction * speed * delta, variant, frenzy)
        if move_distance <= 0.001 and leash_returning:
            for steering_angle in [PI * 0.22, -PI * 0.22, PI * 0.42, -PI * 0.42]:
                var steered_direction := move_direction.rotated(Vector3.UP, steering_angle)
                move_distance = horizontal_move(body, steered_direction * speed * delta * 0.9, variant, frenzy)
                if move_distance > 0.001:
                    move_direction = steered_direction
                    break
        elif move_distance <= 0.001 and separation_direction.length_squared() > 0.001:
            move_distance = horizontal_move(body, separation_direction * speed * delta * 0.9, variant, frenzy)
        if move_direction.length_squared() > 0.001:
            facing_direction = move_direction.normalized()
        var light_safety: float = main.light_safety_at(body.global_position, false)
        if not leash_returning and light_safety > 0.34 and variant != "rift" and not frenzy:
            move_distance += horizontal_move(body, -direction * delta * (5.0 + light_safety * 4.0), variant, frenzy)
            if direction.length_squared() > 0.001:
                facing_direction = -direction
            if light_safety > 0.82:
                enemy["aware"] = false
    elif active_threat and not motion_active:
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
    var next_y := ground_y + hover + sin(float(enemy.get("wobble", 0.0))) * bob
    var vertical_admitted := not native_collision_admission_required
    if main != null and main.has_method("native_collision_admit_motion"):
        vertical_admitted = bool(main.call("native_collision_admit_motion", body,
            Vector3(0.0, next_y - body.global_position.y, 0.0)))
    if vertical_admitted:
        body.global_position.y = next_y
    if facing_direction.length_squared() > 0.001:
        body.rotation.y = atan2(facing_direction.x, facing_direction.z)

    var trap_damage: float = main.trap_damage_at(body.global_position, delta)
    if trap_damage > 0.0 and damage_hostile(body, trap_damage):
        return

    var can_attack := bool(enemy.get("canAttack", true))
    if variant == "seer" and can_attack and aware and active_threat and distance >= 8.0 and distance <= 28.0 and float(enemy.get("cooldown", 0.0)) <= 0.0:
        projectile_system.spawn_projectile(body.global_position + Vector3(0.0, 1.25, 0.0), target_aim_position, 8.0, body, target_node, target_kind)
        if target_kind == "npc":
            register_hostile_npc_attack(target_node, body, variant, "projectile")
            npc_target_projectiles += 1
        enemy["cooldown"] = 2.2
    elif can_attack and not motion_active and distance < (2.85 if variant == "rift" else 2.1) and aware and active_threat and float(enemy.get("cooldown", 0.0)) <= 0.0:
        var damage := hostile_melee_damage(variant, night_factor)
        var seed := next_hostile_motion_seed(enemy, body.global_position, variant)
        # The hostile owns target/damage/cooldown policy. The shared recipe path
        # independently derives a bounded plane and readable wind-up from this
        # stable entity/world/serial seed.
        var started: bool = hostile_motion_combat != null and bool(hostile_motion_combat.begin_arc_motion(body, target_node, target_kind, damage, variant, seed, "seeded", true))
        if started:
            # Starting the generic motion spends the existing attack cooldown;
            # the consequence arrives only if its contact volume resolves.
            enemy["cooldown"] = 1.85 if variant == "rift" else 1.25
        else:
            # Keep the old authority available only if the composed runtime
            # consumer is unavailable during an incomplete startup teardown.
            apply_hostile_melee_consequence(body, target_node, target_kind, damage, variant)
            enemy["cooldown"] = 1.85 if variant == "rift" else 1.25

    if body.global_position.distance_to(player.global_position) > 112.0:
        remove_enemy(enemy, false)

func hostile_melee_damage(variant: String, night_factor: float) -> float:
    return 21.0 + night_factor * 5.0 if variant == "rift" else 8.0 + night_factor * 4.0

func next_hostile_motion_seed(enemy: Dictionary, position: Vector3, variant: String) -> int:
    var serial := int(enemy.get("motionSerial", 0)) + 1
    enemy["motionSerial"] = serial
    var world_seed := int(main.get("seed_hash")) if main != null else 1
    var salt := 0
    for index in range(variant.length()):
        salt = posmod(salt * 131 + variant.unicode_at(index) + 1, 2147483629)
    var coordinate_hash := roundi(position.x * 10.0) * 73856093 + roundi(position.z * 10.0) * 19349663
    return posmod(world_seed + coordinate_hash + salt + serial * 7919, 2147483629)

func _on_hostile_motion_contact_resolved(source_body: Node3D, target: Node3D, target_kind: String, damage: float, variant: String, _resolution: Dictionary) -> void:
    if source_body == null or target == null or not is_instance_valid(source_body) or not is_instance_valid(target):
        return
    if enemy_for_body(source_body).is_empty():
        return
    apply_hostile_melee_consequence(source_body, target, target_kind, damage, variant)

func apply_hostile_melee_consequence(source_body: Node3D, target: Node3D, target_kind: String, damage: float, variant: String) -> void:
    if not CombatTargetPolicyScript.can_damage("hostile", target_kind):
        return
    if target_kind == "player" and target == player and survival:
        var label: String = "Hit by Rift Colossus" if variant == "rift" else "Hit by Shadow Stalker"
        survival.apply_damage(damage, label, "hostile")
    elif target_kind == "npc":
        register_hostile_npc_attack(target, source_body, variant, "melee")

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
    var next_y := ground_y + hover + sin(float(enemy.get("wobble", 0.0))) * bob
    var vertical_admitted := not native_collision_admission_required
    if main != null and main.has_method("native_collision_admit_motion"):
        vertical_admitted = bool(main.call("native_collision_admit_motion", body,
            Vector3(0.0, next_y - body.global_position.y, 0.0)))
    if vertical_admitted:
        body.global_position.y = next_y
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
    if player != null and is_instance_valid(player) and bool(enemy.get("scriptedTargetPlayer", true)):
        best = hostile_target_row(player, "player", origin, player.global_position, player.global_position + Vector3(0.0, 0.8, 0.0), "player")
    var target_npc_ids: Array = enemy.get("scriptedTargetNpcIds", []) if enemy.get("scriptedTargetNpcIds", []) is Array else []
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
        if kind != "npc":
            continue
        var npc_id := String(entry.get("id", npc_body.name))
        if not target_npc_ids.is_empty() and not target_npc_ids.has(npc_id):
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
        if not recycle_hostile_body(body):
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
    var scripted_count := 0
    for enemy in enemies:
        if String(enemy.get("scriptedEncounter", "")) != "":
            scripted_count += 1
    var spacing := hostile_spacing_summary()
    var result := {
        "enemies": enemies.size(),
        "scriptedEnemies": scripted_count,
        "nonScriptedEnemies": maxi(0, enemies.size() - scripted_count),
        "hostileSpacingMinDistance": spacing.get("minDistance", 0.0),
        "hostileSpacingViolations": spacing.get("violations", 0),
        "defeated": defeated,
        "defeatedVariants": defeated_variants.duplicate(),
        "hostileNpcTargetAttacks": npc_target_attacks,
        "hostileNpcTargetProjectiles": npc_target_projectiles,
        "scriptedBattleStarts": scripted_battle_starts,
        "scriptedLeashReturns": scripted_leash_returns,
        "scriptedLeashMaxDistance": scripted_leash_max_distance,
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
