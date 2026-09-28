extends RefCounted

## Atomic generated-facade completion. Both stages consume ordinary blueprint
## declarations and furnishing reservations; neither stage knows a seed, source
## artifact, validation target, or individual citadel part ID.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const OpeningHeads = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const LowerBearings = preload("res://scripts/buildings/LowerFacadeBearingRecipe.gd")
const REQUIRED_HEADROOM := 1.72

static func prepare(blueprint, policy: Dictionary, continuation: Callable = Callable(), raw_stage_observer: Callable = Callable()) -> Dictionary:
	if continuation.is_valid() and continuation.call("facade_started") != true:
		return {"ready": false, "reason": "cancelled"}
	if blueprint == null or not policy.get("furnitureParts") is Array or not policy.get("reservedVolumes") is Array:
		return {"ready": false, "reason": "invalid_facade_completion_input"}
	var source: Dictionary = blueprint.snapshot()
	var private_source = Copy.copy_blueprint(source)
	var stage_policy := {
		"furnitureParts": policy.furnitureParts,
		"reservedVolumes": policy.reservedVolumes,
		"requiredHeadroom": REQUIRED_HEADROOM
	}
	_time(raw_stage_observer,"facadeOpeningHeads",true)
	var opening := OpeningHeads.prepare_all_first_rows(private_source, stage_policy, continuation)
	_time(raw_stage_observer,"facadeOpeningHeads",false)
	if opening.get("reason", "") == "cancelled": return opening
	if not opening.get("ready", false):
		return {"ready": false, "reason": "opening_head_completion_failed", "detail": opening}
	_time(raw_stage_observer,"facadeLowerBearings",true)
	var lower := LowerBearings.prepare_all_bottom_rows(opening.candidateSnapshot, stage_policy, continuation)
	_time(raw_stage_observer,"facadeLowerBearings",false)
	if lower.get("reason", "") == "cancelled": return lower
	if not lower.get("ready", false) or not lower.get("exhausted", false):
		return {"ready": false, "reason": "lower_facade_completion_failed", "detail": lower}
	if continuation.is_valid() and continuation.call("facade_completed") != true:
		return {"ready": false, "reason": "cancelled"}
	return {"ready": true, "exhausted": true, "fullyResolved": lower.get("fullyResolved", false), "afterSnapshot": lower.afterSnapshot,
		"opening": _without_snapshot(opening), "lower": _without_snapshot(lower),
		"scope": "Private generated-facade recipe result; caller has not committed or published it."}

static func _without_snapshot(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	result.erase("candidateSnapshot")
	result.erase("afterSnapshot")
	return result

static func _time(observer: Callable, stage: String, beginning: bool) -> void:
	if observer.is_valid(): observer.call(stage,beginning)
