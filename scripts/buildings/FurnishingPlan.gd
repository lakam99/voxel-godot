extends RefCounted
class_name FurnishingPlan

const FurnishingPartScript := preload("res://scripts/buildings/FurnishingPart.gd")
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const NpcConstantsScript := preload("res://scripts/buildings/layout/BuildingLayoutConstants.gd")

const PROTECTED_ACCESS_CLEARANCE := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN

var id := ""
var seed := 0
var source_blueprint_id := ""
var parts: Array = []
# The final plan owns doorway/passage protection. Individual grammars still
# sample against the same lanes, but this prevents direct decoration or a
# transformed sub-plan from bypassing a declared building access.
var protected_access_reservations: Array[AABB] = []
var egress_diagnostics := {}


func _init(plan_id := "", plan_seed := 0, blueprint_id := "") -> void:
	id = plan_id
	seed = plan_seed
	source_blueprint_id = blueprint_id


func add_part(values: Dictionary):
	var part = FurnishingPartScript.new(values)
	if part_occupies_protected_access(part):
		return null
	parts.append(part)
	return part


func set_protected_access_reservations(reservations: Array[AABB]) -> void:
	protected_access_reservations.clear()
	add_protected_access_reservations(reservations)


func add_protected_access_reservations(reservations: Array[AABB]) -> void:
	for reservation in reservations:
		if reservation.size.x <= 0.0 or reservation.size.z <= 0.0:
			continue
		var duplicate := false
		for existing in protected_access_reservations:
			if existing.position.is_equal_approx(reservation.position) and existing.size.is_equal_approx(reservation.size):
				duplicate = true
				break
		if not duplicate:
			protected_access_reservations.append(reservation)


func access_reservations_snapshot() -> Array[AABB]:
	return protected_access_reservations.duplicate()


func part_occupies_protected_access(part) -> bool:
	if part == null:
		return false
	# Floor coverings mark a passage but do not occupy its clearance. Every
	# object with height or a wall/ceiling mount remains excluded, including
	# non-collision frames and banners, so an access cannot be visually or
	# physically sealed by a furnishing record.
	if String(part.archetype) in ["rug", "aisle_runner"]:
		return false
	var bounds := InteriorFurnishingLayoutScript.horizontal_bounds(part.position, part.occupied_size, part.rotation, PROTECTED_ACCESS_CLEARANCE)
	return InteriorFurnishingLayoutScript.intersects_any(bounds, protected_access_reservations)


func snapshot() -> Dictionary:
	var snapshots: Array = []
	for part in parts:
		if part != null and part.has_method("snapshot"):
			snapshots.append(part.snapshot())
	return {
		"id": id,
		"seed": seed,
		"sourceBlueprintId": source_blueprint_id,
		"egressDiagnostics": egress_diagnostics.duplicate(true),
		"parts": snapshots
	}


func deterministic_signature() -> String:
	return JSON.stringify(snapshot())
