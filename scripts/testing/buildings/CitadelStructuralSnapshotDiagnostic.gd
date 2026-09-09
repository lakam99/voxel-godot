extends SceneTree
## Read-only exact source inventory for reported structural defects.
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var source_path := "res://artifacts/citadel-runtime-integration/candidate-recipe-25/source.bin"
	var output := OS.get_environment("CITADEL_STRUCTURE_REPORT")
	if FileAccess.get_sha256(source_path)!="3a324e02b9c61d5249ea97b119caed19a98bce3d0158ec8d0f23c113682dc34f" or not output.is_absolute_path(): quit(2); return
	var source: Dictionary=FileAccess.open(source_path,FileAccess.READ).get_var(false)
	var report := {"passed":true,"checks":{"pinned_source":true},"scope":"Read-only source inventory, not structural or gameplay acceptance", "parts":source.blueprint.parts,
		"sourceSha256":FileAccess.get_sha256(source_path),"rooms":source.blueprint.get("rooms",[]),"recipe":source.blueprint.recipe,"furnishingPlan":source.furnishingPlan,"accessReservations":source.accessReservations}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close(); quit(0)
