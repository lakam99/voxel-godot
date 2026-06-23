extends RefCounted
class_name NpcProfileRules

static func weapon_for_profile(profile: Dictionary, role: String, can_fight: bool) -> String:
    if profile.has("weapon"):
        return String(profile.get("weapon", ""))
    if not can_fight:
        return ""
    var lowered := role.to_lower()
    if lowered.find("archer") >= 0 or lowered.find("watch") >= 0:
        return "hunterBow"
    var key := String(profile.get("id", "")) + ":" + role
    return "woodenSword" if abs(hash(key)) % 3 == 0 else "hunterBow"

static func job_for_role(role: String, can_fight: bool) -> String:
    if can_fight or role.to_lower().find("guard") >= 0 or role.to_lower().find("watch") >= 0:
        return "guard"
    match role.to_lower():
        "forager", "farmer":
            return "forage"
        "carpenter":
            return "wood"
        "mason":
            return "stone"
    return ""

static func resource_for_job(job: String) -> String:
    match job:
        "forage":
            return "berries"
        "wood":
            return "logs"
        "stone":
            return "stones"
    return ""
