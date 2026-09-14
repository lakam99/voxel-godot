extends RefCounted
class_name CitadelRecipePreparation

## Source-only entry point shared by world loading and visual review. Call on
## an owned worker: composition is not a gameplay-frame operation. No scene,
## tree publication, navigation, resident, or save state is created here.
const CastleBuilder := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const UrbanComposer := preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")


static func prepare(seed: int, context: Dictionary, continue_stage: Callable = Callable(), raw_stage_observer: Callable = Callable()) -> Dictionary:
	# Zero (or omission) keeps the established sampler-selected scale policy.
	var scale = context.get("citadelScale", 0.0)
	if not (scale is float or scale is int) or not is_finite(float(scale)) or float(scale) < 0.0 or float(scale) > 6.0:
		return {"ready": false, "reason": "invalid_citadel_scale"}
	var cancellation := {"stopped": false}
	var progress := Callable()
	if continue_stage.is_valid():
		progress = func(stage: String) -> bool:
			var permitted: bool = continue_stage.call(stage) == true
			if not permitted: cancellation.stopped = true
			return permitted
	if progress.is_valid() and not progress.call("compound_started"):
		return {"ready": false, "reason": "cancelled"}
	# Preserve the exact reviewed context and call order. In particular, never
	# run CastleFurnishingPlanner again after compose_prepared: the urban recipe
	# has already prepared its furniture against the final access reservations.
	_time(raw_stage_observer,"compound",true)
	var build_result := CastleBuilder.build_with_diagnostics(seed, context.duplicate(true), progress)
	_time(raw_stage_observer,"compound",false)
	if build_result.get("diagnostics", {}).get("failureReason", "") == "cancelled":
		return {"ready": false, "reason": "cancelled"}
	var built = build_result.get("blueprint")
	if built == null:
		return {"ready": false, "reason": "blueprint_build_failed", "buildDiagnostics": build_result.get("diagnostics",{})}
	if progress.is_valid() and not progress.call("compound_completed"):
		return {"ready": false, "reason": "cancelled"}
	_time(raw_stage_observer,"urbanComposition",true)
	var prepared: Dictionary = UrbanComposer.compose_prepared(built, seed, progress, raw_stage_observer)
	_time(raw_stage_observer,"urbanComposition",false)
	if cancellation.stopped:
		return {"ready": false, "reason": "cancelled"}
	if not bool(prepared.get("ready", false)):
		# A failed composition can retain intermediate objects in its handoff.
		# They must never become publishable source through this public boundary.
		prepared.erase("blueprint")
		prepared.erase("furnishingPlan")
		prepared.erase("interiorProgram")
		return prepared
	if prepared.get("blueprint") == null or prepared.get("furnishingPlan") == null or not prepared.get("interiorProgram") is Dictionary:
		return {"ready": false, "reason": "incomplete_citadel_source"}
	return prepared


static func _time(observer: Callable, stage: String, beginning: bool) -> void:
	if observer.is_valid(): observer.call(stage,beginning)
