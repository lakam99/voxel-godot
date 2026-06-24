extends RefCounted
class_name NpcKnowledgeScope

const PERSONAL_OBSERVATIONS := "personal_observations"
const PUBLIC_TOWN_RUMOR := "public_town_rumor"
const FOUND_PLAYER_SHARED_CLUES := "found_player_shared_clues"
const ROLE_SPECIFIC_KNOWLEDGE := "role_specific_knowledge"
const POST_RESOLUTION_MEMORY := "post_resolution_memory"

static func scopes_for(npc_id: String, role: String, quest: Dictionary) -> Array[String]:
    var result: Array[String] = []
    if npc_id in ["mira", "sera", "rowan", "niko"]:
        result.append(PERSONAL_OBSERVATIONS)
    result.append(PUBLIC_TOWN_RUMOR)
    var facts: Dictionary = quest.get("facts", {})
    if int(facts.get("ordinaryCluesFound", 0)) > 0 or bool(facts.get("historyClueFound", false)):
        result.append(FOUND_PLAYER_SHARED_CLUES)
    if npc_id in ["mira", "sera", "rowan", "niko"] or String(role).to_lower() in ["guard", "carpenter", "forager", "trader"]:
        result.append(ROLE_SPECIFIC_KNOWLEDGE)
    if worldmark_resolved(quest):
        result.append(POST_RESOLUTION_MEMORY)
    return result

static func can_know_hidden_truth(quest: Dictionary) -> bool:
    var facts: Dictionary = quest.get("facts", {})
    return bool(facts.get("historyClueFound", false))

static func worldmark_resolved(quest: Dictionary) -> bool:
    var facts: Dictionary = quest.get("facts", {})
    return bool(facts.get("worldmarkResolved", false)) or String(quest.get("resolution", "")) != ""
