extends RefCounted
class_name CombatTargetPolicy

## Pure combat allegiance policy. Motion, projectile, NPC, and hostile systems
## keep their own targeting and consequence owners, but all agree on which
## factions may damage which. This intentionally contains no node, save, RNG,
## animation, or enemy-variant knowledge.

const PLAYER := "player"
const NPC := "npc"
const HOSTILE := "hostile"
const STORY_WORLDMARK := "story_worldmark"


static func normalize_faction(value: String) -> String:
	match value.strip_edges().to_lower():
		"arena_player", PLAYER:
			return PLAYER
		NPC:
			return NPC
		HOSTILE:
			return HOSTILE
		STORY_WORLDMARK:
			return STORY_WORLDMARK
		_:
			return ""


static func can_damage(source_faction: String, target_faction: String) -> bool:
	var source := normalize_faction(source_faction)
	var target := normalize_faction(target_faction)
	if source == "" or target == "" or source == target:
		return false
	if source == HOSTILE:
		return target == PLAYER or target == NPC
	if source == PLAYER or source == NPC:
		return target == HOSTILE or (source == PLAYER and target == STORY_WORLDMARK)
	return false


static func is_friendly(source_faction: String, target_faction: String) -> bool:
	var source := normalize_faction(source_faction)
	var target := normalize_faction(target_faction)
	return source != "" and source == target


static func snapshot() -> Dictionary:
	return {
		"damagePairs": [
			"hostile->player",
			"hostile->npc",
			"player->hostile",
			"player->story_worldmark",
			"npc->hostile"
		],
		"friendlyFire": false
	}
