extends Node
class_name StoryDialogueRouter

const NpcKnowledgeScopeScript := preload("res://scripts/story/data/NpcKnowledgeScope.gd")

var main
var story_director
var last_response := {}

func setup(main_node, director_node) -> void:
    main = main_node
    story_director = director_node

func interact_with_node(node: Node) -> Dictionary:
    if node == null or not node.has_meta("kind") or String(node.get_meta("kind")) != "npc":
        return {}
    var npc_name := String(node.get_meta("npc_name", node.name))
    var npc_role := String(node.get_meta("npc_role", "Resident"))
    var npc_id := npc_id_for_node(node, npc_name)
    var response := response_for_npc(npc_id, npc_name, npc_role, "")
    if response.is_empty() or not bool(response.get("handled", false)):
        return {}
    emit_story_npc_event(node, response)
    last_response = response.duplicate(true)
    return response

func response_for_npc(npc_id: String, npc_name: String, npc_role: String, fallback_line: String) -> Dictionary:
    var quest := first_quest()
    if quest.is_empty():
        return { "handled": false, "text": fallback_line }
    var facts: Dictionary = quest.get("facts", {})
    var scopes := NpcKnowledgeScopeScript.scopes_for(npc_id, npc_role, quest)
    var text := line_for(npc_id, npc_role, String(quest.get("stage", "")), facts, scopes, fallback_line)
    return {
        "handled": text != "",
        "speaker": npc_name,
        "role": npc_role,
        "npcId": npc_id,
        "text": text,
        "knowledgeScopes": scopes,
        "hiddenTruthKnown": NpcKnowledgeScopeScript.can_know_hidden_truth(quest)
    }

func first_quest() -> Dictionary:
    if story_director == null or story_director.quest_system == null:
        return {}
    if story_director.quest_system.has_method("first_quest"):
        return story_director.quest_system.first_quest()
    return {}

func line_for(npc_id: String, role: String, stage: String, facts: Dictionary, scopes: Array, fallback_line: String) -> String:
    var ordinary_count := int(facts.get("ordinaryCluesFound", 0))
    var history_known := bool(facts.get("historyClueFound", false))
    match npc_id:
        "mira":
            if stage == "speak_with_sera":
                return "Sera has watched the lantern line longer than anyone. Ask them what the storm is avoiding."
            if ordinary_count > 0:
                return "Bring back signs, not guesses. I will believe what the land itself repeats."
            return "The storm is staying where it should move on. Start with what people saw, then test it against the ground."
        "sera":
            if stage == "travel_to_affected_region":
                return "The old road bends toward the ringing rain. Keep a ward light ready and mark your path back."
            if stage == "find_ordinary_clues":
                return "Do not hunt the Hart yet. Find what changed around the lantern line first."
            return "A storm that waits is a guard post. Something taught it where to stand."
        "rowan":
            if ordinary_count >= 2:
                return "Two signs make a pattern. Bring me what you find next and we can talk about tools, not rumors."
            return "Stone remembers pressure. If the boundary markers ring, treat them like strained beams."
        "niko":
            if history_known:
                return "That compact sounds kinder than the stories. Maybe the old lights were a promise before they became a cage."
            if ordinary_count > 0:
                return "I can share what you found, but I will not guess at the old cause until you bring proof."
            return "Foragers hear rumors first. The public story says the Hart hates lanterns, but stories get trimmed for comfort."
    if scopes.has(NpcKnowledgeScopeScript.ROLE_SPECIFIC_KNOWLEDGE):
        var lower_role := String(role).to_lower()
        if lower_role == "guard":
            return "Public word says a Hart-shaped storm is holding the boundary. I know patrol signs, not hidden causes."
        if lower_role == "forager":
            return "The rain has pushed forage trails away from the old stones. That is observation, not prophecy."
        if lower_role == "carpenter" or lower_role == "mason":
            return "If stones are ringing, they are under strain. Ask someone who has seen the region."
    if fallback_line != "":
        return fallback_line
    return "People call it the Gloam Hart, but public rumor is not the same as truth."

func npc_id_for_node(node: Node, npc_name: String) -> String:
    if node.has_meta("npc_id"):
        return String(node.get_meta("npc_id", ""))
    return String(npc_name).to_lower().replace(" ", "_")

func emit_story_npc_event(node: Node, response: Dictionary) -> void:
    if main == null or not main.has_method("emit_story_event"):
        return
    var position := (node as Node3D).global_position if node is Node3D and node.is_inside_tree() else Vector3.INF
    var region_id: String = main.story_region_id_for_world_position(position) if main.has_method("story_region_id_for_world_position") else ""
    var npc_id := String(response.get("npcId", "npc"))
    var quest := first_quest()
    main.emit_story_event("npc_spoken_to", "npc:%s" % npc_id, region_id, "story_npc_spoken:%s:%s" % [npc_id, String(quest.get("stage", ""))], position, {
        "npcId": npc_id,
        "name": String(response.get("speaker", "")),
        "role": String(response.get("role", "")),
        "knowledgeScopes": response.get("knowledgeScopes", [])
    })
