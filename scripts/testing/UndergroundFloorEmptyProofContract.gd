extends SceneTree

const VolumeScript := preload("res://scripts/TerrainVolumeService.gd")

class CaveGenerator extends RefCounted:
	var intersects := false
	var last_center := Vector3.INF
	var last_radius := 0.0
	func generated_cave_near_surface_footprint(center: Vector3, radius: float) -> bool:
		last_center = center
		last_radius = radius
		return intersects


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var generation := CaveGenerator.new()
	var volume = VolumeScript.new()
	volume.setup(null, generation)
	var key := Vector2i(2, -3)
	var state: Dictionary = volume.begin_exposed_underground_floor_scan(key, 28)
	var empty: Dictionary = volume.advance_exposed_underground_floor_scan(state, 8, 1.35)
	var corner := Vector2(float(key.x * 28), float(key.y * 28)) * volume.cell_size()
	var center := Vector2(generation.last_center.x, generation.last_center.z)
	var checks := {
		"unmodified_caveless_source_finishes_empty": bool(empty.get("complete", false))
			and (empty.get("newCandidates", []) as Array).is_empty()
			and int(empty.get("processed", -1)) == 0
			and String(empty.get("emptyProof", "")) == "no_cave_recipe_or_local_edits",
		"footprint_includes_far_corner": center.distance_to(corner)
			< generation.last_radius,
		"completed_cursor_covers_whole_chunk": int((empty.state as Dictionary).get(
			"columnIndex", -1)) == 28 * 28
	}
	generation.intersects = true
	checks["cave_recipe_requires_real_scan"] = not volume.generated_underground_floor_source_proven_empty(key, 28)
	generation.intersects = false
	volume.edited_cells[Vector3i(key.x * 28 + 1, -6, key.y * 28 + 1)] = {
		"solid": false, "biome": "underground_air"}
	checks["edited_air_requires_real_scan"] = not volume.generated_underground_floor_source_proven_empty(key, 28)
	volume.edited_cells.clear()
	volume.scene_block_cells[Vector3i(key.x * 28 + 1, -6, key.y * 28 + 1)] = {
		"solid": false, "biome": "underground_air"}
	checks["scene_overlay_requires_real_scan"] = not volume.generated_underground_floor_source_proven_empty(key, 28)
	volume.scene_block_cells.clear()
	volume.scene_block_cells[Vector3i(key.x * 28 + 1, 15, key.y * 28 + 1)] = {
		"solid": true, "biome": "plains"}
	checks["solid_town_overlay_cannot_invent_air_floor"] = volume.generated_underground_floor_source_proven_empty(key, 28)
	var passed := true
	for value in checks.values(): passed = passed and bool(value)
	print(JSON.stringify({"schema": "underground-floor-empty-proof-contract/v1",
		"evidenceLevel": "synthetic_volume_service_contract", "passed": passed,
		"checks": checks}))
	quit(0 if passed else 1)
