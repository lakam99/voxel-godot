extends SceneTree

const NpcBipedRecipeBuilderScript := preload("res://scripts/characters/NpcBipedRecipeBuilder.gd")

var report_path := ""
var results: Array[Dictionary] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	report_path = OS.get_environment("VOXEL_NPC_BIPED_RECIPE_CONTRACT_REPORT").strip_edges()
	test_recipe_replays_exactly()
	test_recipe_variation_is_seeded_and_bounded()
	test_recipe_family_covers_requested_hair_and_skin_range()
	write_report()
	quit(0 if failure_count() == 0 else 1)


func test_recipe_replays_exactly() -> void:
	var first: Dictionary = NpcBipedRecipeBuilderScript.build(209154, "contract")
	var second: Dictionary = NpcBipedRecipeBuilderScript.build(209154, "contract")
	add_result("same_seed_and_profile_replay_the_same_biped_recipe", NpcBipedRecipeBuilderScript.signature(first) == NpcBipedRecipeBuilderScript.signature(second), {"signature": NpcBipedRecipeBuilderScript.signature(first)})


func test_recipe_variation_is_seeded_and_bounded() -> void:
	var first: Dictionary = NpcBipedRecipeBuilderScript.build(209154, "contract")
	var second: Dictionary = NpcBipedRecipeBuilderScript.build(209155, "contract")
	var first_skin: Dictionary = first.get("skin", {}) as Dictionary
	var second_skin: Dictionary = second.get("skin", {}) as Dictionary
	var first_hair: Dictionary = first.get("hair", {}) as Dictionary
	var second_hair: Dictionary = second.get("hair", {}) as Dictionary
	var first_outfit: Dictionary = first.get("outfit", {}) as Dictionary
	var second_outfit: Dictionary = second.get("outfit", {}) as Dictionary
	var distinct := NpcBipedRecipeBuilderScript.signature(first) != NpcBipedRecipeBuilderScript.signature(second)
	var bounded := float(first.get("stature", 0.0)) >= 0.92 and float(first.get("stature", 2.0)) <= 1.10 and float(second.get("stature", 0.0)) >= 0.92 and float(second.get("stature", 2.0)) <= 1.10 and not String(first_skin.get("id", "")).is_empty() and not String(second_skin.get("id", "")).is_empty() and not String(first_hair.get("style", "")).is_empty() and not String(second_hair.get("style", "")).is_empty() and not String(first_outfit.get("design", "")).is_empty() and not String(second_outfit.get("design", "")).is_empty()
	add_result("different_seeds_produce_bounded_appearance_variation", distinct and bounded, {"first": NpcBipedRecipeBuilderScript.signature(first), "second": NpcBipedRecipeBuilderScript.signature(second)})


func test_recipe_family_covers_requested_hair_and_skin_range() -> void:
	var hair_styles: Dictionary = {}
	var skin_ids: Dictionary = {}
	var outfit_designs: Dictionary = {}
	for seed in range(1, 513):
		var recipe: Dictionary = NpcBipedRecipeBuilderScript.build(seed, "coverage")
		hair_styles[String((recipe.get("hair", {}) as Dictionary).get("style", ""))] = seed
		skin_ids[String((recipe.get("skin", {}) as Dictionary).get("id", ""))] = seed
		outfit_designs[String((recipe.get("outfit", {}) as Dictionary).get("design", ""))] = seed
	var supports_hair := hair_styles.has("bald") and hair_styles.has("receding") and hair_styles.has("long")
	var supports_skin_range := skin_ids.has("deep_umber") and skin_ids.has("pale_flesh")
	var supports_outfits := outfit_designs.size() == NpcBipedRecipeBuilderScript.OUTFIT_DESIGNS.size()
	add_result("seed_space_covers_bald_receding_long_hair_dark_to_light_skin_and_each_outfit", supports_hair and supports_skin_range and supports_outfits, {"hairSeeds": hair_styles, "skinSeeds": skin_ids, "outfitSeeds": outfit_designs})


func add_result(name: String, passed: bool, details: Dictionary) -> void:
	results.append({"name": name, "passed": passed, "details": details})


func failure_count() -> int:
	var failures := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failures += 1
	return failures


func write_report() -> void:
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/npcs/npc-biped-recipe-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var report := {
		"runnerId": "npc_biped_recipe_contract",
		"evidenceLevel": "pure-contract",
		"status": "passed" if failure_count() == 0 else "failed",
		"results": results,
		"notes": "This validates pure deterministic recipe data only. It does not prove visual quality or production NPC integration."
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
