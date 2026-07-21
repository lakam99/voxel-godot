extends SceneTree

const CombatTargetPolicyScript := preload("res://scripts/combat/CombatTargetPolicy.gd")

var report_path := ""
var results: Array[Dictionary] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	report_path = OS.get_environment("VOXEL_COMBAT_TARGET_POLICY_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/combat/combat-target-policy-contract.json")
	test_damage_matrix()
	test_friendly_fire_rejected()
	test_arena_alias_uses_the_player_contract()
	write_report()
	quit(0 if failure_count() == 0 else 1)


func test_damage_matrix() -> void:
	var expected := {
		"hostile->player": true,
		"hostile->npc": true,
		"player->hostile": true,
		"npc->hostile": true,
		"player->story_worldmark": true,
		"player->npc": false,
		"npc->player": false,
		"hostile->story_worldmark": false,
		"unknown->hostile": false
	}
	var actual := {}
	var correct := true
	for relation_value in expected.keys():
		var relation := String(relation_value)
		var split := relation.split("->", false, 1)
		var allowed := CombatTargetPolicyScript.can_damage(String(split[0]), String(split[1]))
		actual[relation] = allowed
		correct = correct and allowed == bool(expected[relation])
	add_result("combat_target_policy_allows_only_declared_hostile_pairs", correct, {"expected": expected, "actual": actual, "policy": CombatTargetPolicyScript.snapshot()})


func test_friendly_fire_rejected() -> void:
	var factions := ["player", "npc", "hostile", "story_worldmark"]
	var rejected := true
	for faction_value in factions:
		var faction := String(faction_value)
		rejected = rejected and not CombatTargetPolicyScript.can_damage(faction, faction) and CombatTargetPolicyScript.is_friendly(faction, faction)
	add_result("combat_target_policy_rejects_friendly_fire", rejected, {"factions": factions})


func test_arena_alias_uses_the_player_contract() -> void:
	var matches_player := CombatTargetPolicyScript.can_damage("hostile", "arena_player") == CombatTargetPolicyScript.can_damage("hostile", "player")
	add_result("combat_target_policy_normalizes_arena_player_without_a_special_case", matches_player, {"arenaTarget": "arena_player"})


func add_result(name: String, passed: bool, details: Dictionary) -> void:
	results.append({"name": name, "passed": passed, "details": details})


func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count


func write_report() -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write combat target policy report: %s" % report_path)
		return
	file.store_string(JSON.stringify({
		"runnerId": "combat_target_policy_contract",
		"evidenceLevel": "pure_contract",
		"passed": failure_count() == 0,
		"results": results
	}, "\t"))
	file.close()
