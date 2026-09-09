extends "res://scripts/testing/buildings/CitadelSourceValueDiff.gd"
func _initialize() -> void:
	var runtime_dir := "res://artifacts/citadel-runtime-integration/candidate-teleport-36-02/"
	var recipe_dir := "res://artifacts/citadel-runtime-integration/candidate-recipe-36/"
	var live_report: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(runtime_dir+"report.json"))
	var recipe_report: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(recipe_dir+"report.json"))
	if FileAccess.get_sha256(runtime_dir+"accepted-source.bin")!=live_report.evidence.sceneAudit.sourceCapture.sha256 or FileAccess.get_sha256(recipe_dir+"source.bin")!=recipe_report.receipt.sourceSha256: quit(2); return
	var a: Dictionary=FileAccess.open(recipe_dir+"source.bin",FileAccess.READ).get_var(false)
	var b: Dictionary=FileAccess.open(runtime_dir+"accepted-source.bin",FileAccess.READ).get_var(false)
	a.furnishingPlan["accessReservations"]=a.accessReservations
	var expected := {"blueprint":a.blueprint,"furnishingPlan":a.furnishingPlan}
	var actual := {"blueprint":b.blueprint,"furnishingPlan":b.furnishingPlan}
	compare(expected,actual,"")
	var exact := var_to_bytes(expected)==var_to_bytes(actual)
	var file := FileAccess.open(OS.get_environment("SOURCE_DIFF_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed":true,"checks":{"comparison_completed":true},"byteExact":exact,"differences":differences,"scope":"Exact accepted runtime source versus source-only artifact, not gameplay acceptance."},"\t"));file.close()
	quit()
