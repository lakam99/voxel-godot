extends SceneTree
const Survey = preload("res://scripts/world/CitadelSiteSurvey.gd")
class ObservedField extends "res://scripts/world/BiomeRegionField.gd":
	var sample_usec := 0
	var samples := 0
	var site_calls := 0
	var climate_calls := 0
	var site_keys := {}
	var climate_keys := {}
	func sample(seed: String, point: Vector2) -> Dictionary:
		var started := Time.get_ticks_usec()
		var result := super.sample(seed,point)
		sample_usec += Time.get_ticks_usec()-started
		samples += 1
		return result
	func site_position(seed: String, region: Vector2i) -> Vector2:
		site_calls += 1
		site_keys[[seed,region]] = true
		return super.site_position(seed,region)
	func climate_channel(seed: String, region: Vector2i, channel: String) -> float:
		climate_calls += 1
		climate_keys[[seed,region,channel]] = true
		return super.climate_channel(seed,region,channel)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var input_path := "res://artifacts/citadel-runtime-integration/candidate-recipe-34/input.bin"
	if FileAccess.get_sha256(input_path)!="c056db9534a5ad6f2486b4ccc93c9daccc6019762acd5bd63edb9c5b1113a467": quit(2); return
	var input: Dictionary=FileAccess.open(input_path,FileAccess.READ).get_var(false)
	var survey := Survey.new()
	var result := survey.begin(input.worldSeed,input.candidate.region,Rect2i(-3483,-2961,299,291),input.townOverrides)
	var observed := ObservedField.new()
	survey._world.biome_region_field=observed
	while result.status=="pending_budget": result=survey.advance()
	var checks := {"survey_complete":result.status=="surveyed" and result.columnsInspected==87009,"baseline_biomes":result.biomeCounts=={"beach":1029,"tundra":85980},"baseline_heights":is_equal_approx(result.minimumSurfaceY,11.934) and is_equal_approx(result.maximumSurfaceY,71.415)}
	var report := {"passed":not checks.values().has(false),"checks":checks,"scope":"Instrumented current production survey observation; summary comparison, not per-column equality or gameplay acceptance.","survey":result,"sampling":{"calls":observed.samples,"usec":observed.sample_usec,"siteCalls":observed.site_calls,"uniqueSites":observed.site_keys.size(),"climateCalls":observed.climate_calls,"uniqueClimateInputs":observed.climate_keys.size()}}
	var file := FileAccess.open(OS.get_environment("BIOME_SAMPLING_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	quit(1 if checks.values().has(false) else 0)
