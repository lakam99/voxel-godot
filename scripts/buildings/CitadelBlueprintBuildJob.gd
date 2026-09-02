extends RefCounted
class_name CitadelBlueprintBuildJob

const CitadelRecipePreparationScript := preload("res://scripts/buildings/CitadelRecipePreparation.gd")

var mutex := Mutex.new()
var blueprint
var furnishing_plan
var interior_program: Dictionary = {}
var build_diagnostics: Dictionary = {}
var envelope_validation: Dictionary = {}
var recipe_context_signature := ""
var finished := false
var running := false
var failure_reason := ""


func run(seed: int, context: Dictionary) -> void:
	# Callers own the input until dispatch; all later reads use this one copy.
	var source_context := context.duplicate(true)
	# One owner per job; clear completed state before preparing the next source.
	# Pollers must never see a previous revision as this run's completed result.
	mutex.lock()
	if running:
		mutex.unlock()
		push_error("Citadel recipe job already running")
		return
	running = true
	finished = false
	blueprint = null
	furnishing_plan = null
	interior_program = {}
	build_diagnostics = {}
	envelope_validation = {}
	failure_reason = ""
	recipe_context_signature = String(source_context.get("recipeContextSignature", ""))
	mutex.unlock()
	var build_result: Dictionary = CitadelRecipePreparationScript.prepare(seed, source_context)
	var built = build_result.get("blueprint")
	var built_diagnostics: Dictionary = build_result.duplicate()
	for key in ["blueprint", "furnishingPlan", "interiorProgram"]:
		built_diagnostics.erase(key)
	var built_envelope_validation := validate_blueprint_envelope(built, source_context)
	if built != null and not bool(built_envelope_validation.get("passed", false)):
		built = null
	var built_furnishings = build_result.get("furnishingPlan") if built != null else null
	var built_interior: Dictionary = build_result.get("interiorProgram", {}) if built != null else {}
	mutex.lock()
	blueprint = built
	furnishing_plan = built_furnishings
	interior_program = built_interior
	build_diagnostics = built_diagnostics
	envelope_validation = built_envelope_validation
	recipe_context_signature = String(source_context.get("recipeContextSignature", ""))
	failure_reason = "blueprint_envelope_exceeded" if not bool(built_envelope_validation.get("passed", false)) else String(build_result.get("reason", "blueprint_build_failed")) if built == null else ""
	running = false
	finished = true
	mutex.unlock()


func result_snapshot() -> Dictionary:
	mutex.lock()
	var result := {
		"finished": finished,
		"ready": finished and failure_reason.is_empty() and blueprint != null and furnishing_plan != null,
		"blueprint": blueprint,
		"furnishingPlan": furnishing_plan,
		"interiorProgram": interior_program.duplicate(true),
		"buildDiagnostics": build_diagnostics.duplicate(true),
		"envelopeValidation": envelope_validation.duplicate(true),
		"recipeContextSignature": recipe_context_signature,
		"failureReason": failure_reason
	}
	mutex.unlock()
	return result

func validate_blueprint_envelope(built, context: Dictionary) -> Dictionary:
	if built == null:
		return {"passed": true, "reason": "blueprint_unavailable"}
	var cell_size := float(context.get("cellSize", 0.0))
	var declared_cells := int(context.get("blueprintEnvelopeRadiusCells", 0))
	if cell_size <= 0.0 or declared_cells <= 0:
		return {"passed": false, "reason": "missing_blueprint_envelope"}
	var maximum_extent := 0.0
	var maximum_part_id := ""
	for part in built.parts:
		if part == null or not bool(part.collision_enabled):
			continue
		var basis := Basis.from_euler(part.rotation)
		var half_x: float = absf(basis.x.x) * float(part.size.x) * 0.5 + absf(basis.y.x) * float(part.size.y) * 0.5 + absf(basis.z.x) * float(part.size.z) * 0.5
		var half_z: float = absf(basis.x.z) * float(part.size.x) * 0.5 + absf(basis.y.z) * float(part.size.y) * 0.5 + absf(basis.z.z) * float(part.size.z) * 0.5
		var extent: float = maxf(absf(float(part.position.x)) + half_x, absf(float(part.position.z)) + half_z)
		if extent > maximum_extent:
			maximum_extent = extent
			maximum_part_id = String(part.id)
	var declared_world_radius := float(declared_cells) * cell_size
	return {"passed": maximum_extent <= declared_world_radius + 0.001, "declaredRadiusCells": declared_cells, "declaredWorldRadius": declared_world_radius, "builtCollisionExtent": maximum_extent, "maximumPartId": maximum_part_id}
