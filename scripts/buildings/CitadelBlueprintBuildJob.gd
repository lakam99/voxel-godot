extends RefCounted
class_name CitadelBlueprintBuildJob

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const CastleFurnishingPlannerScript := preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const CitadelResidenceManifestBuilderScript := preload("res://scripts/buildings/CitadelResidenceManifestBuilder.gd")

var mutex := Mutex.new()
var blueprint
var furnishing_plan
var residence_manifest: Dictionary = {}
var residence_validation: Dictionary = {}
var build_diagnostics: Dictionary = {}
var envelope_validation: Dictionary = {}
var recipe_context_signature := ""
var finished := false
var failure_reason := ""


func run(seed: int, context: Dictionary) -> void:
	var build_result: Dictionary = CastleCompoundBlueprintBuilderScript.build_with_diagnostics(seed, context)
	var built = build_result.get("blueprint")
	var built_diagnostics: Dictionary = build_result.get("diagnostics", {}) if build_result.get("diagnostics", {}) is Dictionary else {}
	var built_envelope_validation := validate_blueprint_envelope(built, context)
	if built != null and not bool(built_envelope_validation.get("passed", false)):
		built = null
	var built_furnishings = CastleFurnishingPlannerScript.build(built, seed * 7919 + 37, context.get("worldOrigin", Vector3.ZERO)) if built != null else null
	var built_residences: Dictionary = CitadelResidenceManifestBuilderScript.build(built, built_furnishings, float(context.get("cellSize", 1.35)), context.get("worldOrigin", Vector3.ZERO)) if built != null and built_furnishings != null else {}
	var built_residence_validation: Dictionary = CitadelResidenceManifestBuilderScript.validate_semantic_completeness(built_residences)
	mutex.lock()
	blueprint = built
	furnishing_plan = built_furnishings
	residence_manifest = built_residences
	residence_validation = built_residence_validation
	build_diagnostics = built_diagnostics
	envelope_validation = built_envelope_validation
	recipe_context_signature = String(context.get("recipeContextSignature", ""))
	failure_reason = "blueprint_envelope_exceeded" if not bool(built_envelope_validation.get("passed", false)) else "blueprint_build_failed" if built == null else "furnishing_plan_build_failed" if built_furnishings == null else "residence_manifest_incomplete" if not bool(built_residence_validation.get("passed", false)) else ""
	finished = true
	mutex.unlock()


func result_snapshot() -> Dictionary:
	mutex.lock()
	var result := {
		"finished": finished,
		"blueprint": blueprint,
		"furnishingPlan": furnishing_plan,
		"residenceManifest": residence_manifest.duplicate(true),
		"residenceValidation": residence_validation.duplicate(true),
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
