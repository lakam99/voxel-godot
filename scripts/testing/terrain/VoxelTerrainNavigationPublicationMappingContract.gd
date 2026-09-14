extends SceneTree

## Static/service contract for the native 28-cell terrain publication boundary.
## It does not launch Main, publish native collision, or prove gameplay routes.
const Runtime := preload("res://scripts/terrain/VoxelTerrainRuntime.gd")

class RecordingNpcSystem extends RefCounted:
	var loaded: Array[Vector2i] = []
	var unloaded: Array[Vector2i] = []
	func notify_navigation_chunk_loaded(tile_key: Vector2i) -> void:
		loaded.append(tile_key)
	func notify_navigation_chunk_unloaded(tile_key: Vector2i) -> void:
		unloaded.append(tile_key)

class Host extends RefCounted:
	var npc_system

var checks := {}

func _initialize() -> void:
	call_deferred("_run")

func check(name: String, passed: bool) -> void:
	checks[name] = passed
	if not passed:
		printerr("VOXEL TERRAIN NAVIGATION PUBLICATION MAPPING FAILED: ", name)

func _run() -> void:
	check("origin_chunk_maps_four_tiles", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(0, 0)) == [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)
	])
	check("positive_unaligned_chunk_maps_three_by_two", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(1, 0)) == [
		Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0),
		Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)
	])
	check("negative_x_uses_floor_division", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(-1, 0)) == [
		Vector2i(-2, 0), Vector2i(-1, 0), Vector2i(-2, 1), Vector2i(-1, 1)
	])
	check("negative_unaligned_chunk_maps_three_by_two", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(-2, 0)) == [
		Vector2i(-4, 0), Vector2i(-3, 0), Vector2i(-2, 0),
		Vector2i(-4, 1), Vector2i(-3, 1), Vector2i(-2, 1)
	])
	check("negative_xy_preserves_deterministic_row_order", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(-1, -1)) == [
		Vector2i(-2, -2), Vector2i(-1, -2), Vector2i(-2, -1), Vector2i(-1, -1)
	])
	check("aligned_positive_boundary_has_no_extra_tile", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(4, 4)) == [
		Vector2i(7, 7), Vector2i(8, 7), Vector2i(7, 8), Vector2i(8, 8)
	])

	var recorder := RecordingNpcSystem.new()
	var host := Host.new()
	host.npc_system = recorder
	var runtime := Runtime.new()
	runtime.main = host
	runtime.notify_navigation_chunk_loaded(Vector2i(1, -2))
	var expected: Array[Vector2i] = [
		Vector2i(1, -4), Vector2i(2, -4), Vector2i(3, -4),
		Vector2i(1, -3), Vector2i(2, -3), Vector2i(3, -3),
		Vector2i(1, -2), Vector2i(2, -2), Vector2i(3, -2)
	]
	check("loaded_forwards_every_intersecting_navigation_tile", recorder.loaded == expected)
	check("loaded_forwards_each_tile_once", _unique_count(recorder.loaded) == recorder.loaded.size())
	runtime.notify_navigation_chunk_unloaded(Vector2i(1, -2))
	check("unloaded_forwards_same_tiles_in_same_order", recorder.unloaded == expected)
	check("unloaded_forwards_each_tile_once", _unique_count(recorder.unloaded) == recorder.unloaded.size())
	runtime.free()

	var passed := not checks.is_empty() and false not in checks.values()
	var report := {
		"passed": passed,
		"checks": checks,
		"gameChunkSize": Runtime.GAME_CHUNK_SIZE,
		"navigationTileCellSize": Runtime.NAVIGATION_TILE_CELL_SIZE,
		"evidenceLevel": "static mapping and service forwarding contract",
		"doesNotProve": "No native terrain collision, Main scene, route publication, NPC movement, visuals, or gameplay acceptance."
	}
	var output := OS.get_environment("VOXEL_TERRAIN_NAV_MAPPING_REPORT")
	if not output.is_empty():
		DirAccess.make_dir_recursive_absolute(output.get_base_dir())
		var file := FileAccess.open(output, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	print("VOXEL TERRAIN NAVIGATION PUBLICATION MAPPING RESULT ", passed, " checks=", checks.size())
	quit(0 if passed else 1)

func _unique_count(values: Array[Vector2i]) -> int:
	var unique := {}
	for value in values:
		unique[value] = true
	return unique.size()
