extends SceneTree

const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Survey = preload("res://scripts/world/CitadelSiteSurvey.gd")
const Source = preload("res://scripts/buildings/CitadelRecipePreparation.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var candidate: Dictionary = Field.candidate_for_region("atlas-1492", Vector2i(-1, -1))
	var center: Vector2i = candidate.centerCell
	var survey = Survey.new()
	var result: Dictionary = survey.begin("atlas-1492", Vector2i(-1, -1), Rect2i(center, Vector2i.ONE), {})
	while result.get("status") == "pending_budget":
		result = survey.advance()
	var biome := String((result.biomeCounts.keys() as Array)[0])
	var source: Dictionary = Source.prepare(int(candidate.recipeSeed), {"biome": biome, "siteKey": candidate.siteId, "citadelScale": 1.25})
	var failure: Dictionary = source.get("shopFailure", {})
	print(JSON.stringify({"candidate": candidate, "biome": biome, "ready": source.get("ready"), "reason": source.get("reason"), "shopFailure": failure}))
	quit(0 if source.get("ready", false) else 1)
