extends RefCounted
class_name SurvivalSystem

signal changed

const MAX_HEALTH := 100.0
const MAX_STAMINA := 100.0
const MAX_HUNGER := 100.0

var catalog := {}
var consume_active_item: Callable
var damage_multiplier_provider: Callable
var health_bonus := 0.0
var stamina_bonus := 0.0
var hunger_bonus := 0.0
var health := MAX_HEALTH
var stamina := MAX_STAMINA
var hunger := MAX_HUNGER
var armor := 0.0
var warmth_timer := 0.0
var ward_timer := 0.0
var shelter_comfort := 0.0
var last_danger := "Safe"
var last_message := ""
var test_god_mode := false
var test_god_mode_reason := ""

func setup(catalog_value: Dictionary, consume_active_callable: Callable) -> void:
    catalog = catalog_value
    consume_active_item = consume_active_callable
    reset()

func set_damage_multiplier_provider(provider: Callable) -> void:
    damage_multiplier_provider = provider

func set_test_god_mode(enabled: bool, reason := "playtest") -> void:
    test_god_mode = enabled
    test_god_mode_reason = reason if enabled else ""
    changed.emit()

func test_god_mode_state() -> Dictionary:
    return {
        "enabled": test_god_mode,
        "reason": test_god_mode_reason
    }

func reset() -> void:
    health = max_health()
    stamina = max_stamina()
    hunger = max_hunger()
    armor = 0.0
    warmth_timer = 0.0
    ward_timer = 0.0
    shelter_comfort = 0.0
    last_danger = "Safe"
    last_message = ""
    changed.emit()

func snapshot() -> Dictionary:
    return {
        "health": health,
        "stamina": stamina,
        "hunger": hunger,
        "maxHealth": max_health(),
        "maxStamina": max_stamina(),
        "maxHunger": max_hunger(),
        "armor": armor,
        "warmthTimer": warmth_timer,
        "wardTimer": ward_timer,
        "shelterComfort": shelter_comfort,
        "danger": last_danger
    }

func restore(snapshot_value) -> void:
    var state: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
    health = clampf(float(state.get("health", max_health())), 0.0, max_health())
    stamina = clampf(float(state.get("stamina", max_stamina())), 0.0, max_stamina())
    hunger = clampf(float(state.get("hunger", max_hunger())), 0.0, max_hunger())
    armor = clampf(float(state.get("armor", 0.0)), 0.0, 100.0)
    warmth_timer = maxf(0.0, float(state.get("warmthTimer", 0.0)))
    ward_timer = maxf(0.0, float(state.get("wardTimer", 0.0)))
    shelter_comfort = clampf(float(state.get("shelterComfort", 0.0)), 0.0, 1.0)
    last_danger = String(state.get("danger", "Safe"))
    last_message = "Survival restored"
    changed.emit()

func max_health() -> float:
    return MAX_HEALTH + health_bonus

func max_stamina() -> float:
    return MAX_STAMINA + stamina_bonus

func max_hunger() -> float:
    return MAX_HUNGER + hunger_bonus

func set_bonuses(bonuses: Dictionary) -> void:
    var old_health_max := max_health()
    var old_stamina_max := max_stamina()
    var old_hunger_max := max_hunger()
    health_bonus = maxf(0.0, float(bonuses.get("health", 0.0)))
    stamina_bonus = maxf(0.0, float(bonuses.get("stamina", 0.0)))
    hunger_bonus = maxf(0.0, float(bonuses.get("hunger", 0.0)))
    health = max_health() if health >= old_health_max - 0.01 else clampf(health, 0.0, max_health())
    stamina = max_stamina() if stamina >= old_stamina_max - 0.01 else clampf(stamina, 0.0, max_stamina())
    hunger = max_hunger() if hunger >= old_hunger_max - 0.01 else clampf(hunger, 0.0, max_hunger())
    changed.emit()

func can_sprint() -> bool:
    return stamina > 8.0 and hunger > 2.0 and health > 0.0

func can_use_item(item_id: String) -> bool:
    var spec: Dictionary = catalog.get(item_id, {})
    return float(spec.get("food", 0.0)) != 0.0 or float(spec.get("health", 0.0)) != 0.0 or float(spec.get("stamina", 0.0)) != 0.0 or float(spec.get("warmth", 0.0)) != 0.0 or float(spec.get("ward", 0.0)) != 0.0

func use_active_item(item_id: String) -> bool:
    if item_id == "" or not can_use_item(item_id):
        return false
    var spec: Dictionary = catalog.get(item_id, {})
    var food := float(spec.get("food", 0.0))
    var health_gain := float(spec.get("health", 0.0))
    var stamina_gain := float(spec.get("stamina", 0.0))
    var warmth := float(spec.get("warmth", 0.0))
    var ward := float(spec.get("ward", 0.0))
    var useful := false
    useful = useful or (food > 0.0 and hunger < max_hunger() - 0.5)
    useful = useful or (health_gain > 0.0 and health < max_health() - 0.5)
    useful = useful or (stamina_gain > 0.0 and stamina < max_stamina() - 0.5)
    useful = useful or (warmth > 0.0 and warmth_timer < warmth - 1.0)
    useful = useful or (ward > 0.0 and ward_timer < ward - 1.0)
    useful = useful or health_gain < 0.0
    if not useful:
        last_message = "Already full"
        changed.emit()
        return true
    if consume_active_item.is_null() or not bool(consume_active_item.call(1)):
        last_message = "Could not use item"
        changed.emit()
        return false
    hunger = clampf(hunger + food, 0.0, max_hunger())
    health = clampf(health + food * 0.2 + health_gain, 0.0, max_health())
    stamina = clampf(stamina + stamina_gain, 0.0, max_stamina())
    warmth_timer = maxf(warmth_timer, warmth)
    ward_timer = maxf(ward_timer, ward)
    last_danger = "Safe" if health > 0.0 else "Collapsed"
    if ward > 0.0:
        last_message = "Used: %s (ward)" % String(spec.get("label", item_id))
    elif warmth > 0.0:
        last_message = "Used: %s (warmth)" % String(spec.get("label", item_id))
    else:
        last_message = "Used: %s" % String(spec.get("label", item_id))
    changed.emit()
    return true

func apply_damage(amount: float, label: String, kind := "generic") -> void:
    if amount <= 0.0 or health <= 0.0:
        return
    if test_god_mode:
        last_danger = label
        last_message = label
        changed.emit()
        return
    var armor_multiplier := 1.0 - clampf(armor / 100.0, 0.0, 0.82)
    if damage_multiplier_provider.is_valid():
        armor_multiplier = clampf(float(damage_multiplier_provider.call(kind)), 0.0, 4.0)
    var warded := ward_timer > 0.0 and (kind == "hostile" or kind == "exposure")
    var ward_multiplier := 0.72 if warded else 1.0
    health = maxf(0.0, health - amount * armor_multiplier * ward_multiplier)
    last_danger = "%s (ward)" % label if warded else ("%s (armor)" % label if armor_multiplier < 0.98 else label)
    last_message = label if health > 0.0 else "You collapsed"
    changed.emit()

func rest(rest_quality := 0.0) -> void:
    var quality := clampf(float(rest_quality), 0.0, 1.0)
    health = minf(max_health(), health + lerpf(34.0, max_health(), quality))
    stamina = max_stamina()
    hunger = maxf(1.0, hunger - lerpf(7.0, 3.0, quality))
    warmth_timer = maxf(warmth_timer, quality * 90.0)
    last_danger = "Well rested" if quality >= 0.62 else "Rested"
    last_message = last_danger
    changed.emit()

func update(delta: float, context: Dictionary) -> void:
    var moving := bool(context.get("moving", false))
    var sprinting := bool(context.get("sprinting", false))
    var jumped := bool(context.get("jumped", false))
    var biome := String(context.get("biome", "plains"))
    var day_factor := float(context.get("dayFactor", 1.0))
    var weather: Dictionary = context.get("weather", {})
    var weather_kind := String(weather.get("kind", "clear"))
    var wet := float(weather.get("intensity", 0.0)) if weather_kind == "rain" or weather_kind == "snow" else 0.0
    var light_safety := float(context.get("lightSafety", 0.0))
    var sanctuary_established := bool(context.get("sanctuaryEstablished", false))
    shelter_comfort = clampf(float(context.get("shelterComfort", 0.0)), 0.0, 1.0)
    var night := smoothstep01(1.0 - day_factor, 0.38, 0.84)
    warmth_timer = maxf(0.0, warmth_timer - delta)
    ward_timer = maxf(0.0, ward_timer - delta)
    var warmed := warmth_timer > 0.0
    var sheltered := shelter_comfort >= 0.55
    var effective_wet := wet * (1.0 - shelter_comfort * 0.78)
    var cold := not warmed and shelter_comfort < 0.78 and biome in ["snow", "tundra", "alpine", "taiga"]

    if sprinting and can_sprint():
        stamina = maxf(0.0, stamina - 20.0 * delta)
    else:
        stamina = minf(max_stamina(), stamina + ((14.0 if hunger > 8.0 else 5.0) + shelter_comfort * 5.0) * delta)
    if jumped:
        stamina = maxf(0.0, stamina - 5.0)

    var hunger_drain := 0.035
    if moving:
        hunger_drain += 0.026
    if sprinting:
        hunger_drain += 0.12
    hunger_drain += effective_wet * 0.025
    if cold:
        hunger_drain += 0.018
    hunger_drain = maxf(0.012, hunger_drain * (1.0 - shelter_comfort * 0.42))
    hunger = maxf(0.0, hunger - hunger_drain * delta)

    if hunger <= 0.0:
        apply_damage(1.8 * delta, "Starving", "hunger")
    else:
        if hunger > 35.0 and health < max_health():
            var safety_value := maxf(light_safety, shelter_comfort * 0.92) if not sanctuary_established else 1.0
            var light_bonus := smoothstep01(safety_value, 0.25, 0.9)
            health = minf(max_health(), health + (0.18 + light_bonus * 0.62 + shelter_comfort * 0.18) * delta)
        var effective_light_safety := 1.0 if sanctuary_established else light_safety
        if sanctuary_established:
            last_danger = "Sanctuary secured"
        elif effective_light_safety > 0.35 and night > 0.35:
            last_danger = "Light safe"
        elif night > 0.35:
            last_danger = "Nightfall"
        else:
            last_danger = "Safe"
        if sheltered and not sanctuary_established and last_danger in ["Safe", "Nightfall", "Light safe"]:
            last_danger = "Sheltered"
        if warmed and not cold and last_danger == "Safe":
            last_danger = "Warmed"
        if ward_timer > 0.0:
            last_danger = "%s | Ward %ds" % [last_danger, ceili(ward_timer)]
        changed.emit()

func smoothstep01(value: float, edge0: float, edge1: float) -> float:
    if absf(edge1 - edge0) < 0.0001:
        return 0.0 if value < edge0 else 1.0
    var x := clampf((value - edge0) / (edge1 - edge0), 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)
