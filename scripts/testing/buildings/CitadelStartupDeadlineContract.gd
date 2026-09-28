extends SceneTree
## Synthetic changing-scene authority; exercises the real, unchanged startup
## deadline and yields. Does not prove ordinary New Game or player traversal.
class MainFixture:
	extends "res://scripts/MainCore.gd"
	var voxel_terrain_runtime: Node
	func _ready() -> void: pass
class TerrainFixture:
	extends Node
	func collision_mesh_ready_for_body_position(_position: Vector3, _radius: float) -> Dictionary:
		return {"passed":true}
class StructureFixture:
	extends RefCounted
	var queries := 0
	func citadel_physical_publication_state(_bounds: Rect2i) -> Dictionary:
		queries += 1
		return {"status":"ready","required":true,"reason":"synthetic_scene_churn","sceneInstanceIds":[queries]}
	func advance_citadel_publication() -> void: pass
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var output := OS.get_environment("CITADEL_STARTUP_DEADLINE_OUTPUT")
	if output.is_empty(): quit(2); return
	var main := MainFixture.new()
	root.add_child(main)
	main.voxel_terrain_runtime = TerrainFixture.new()
	main.add_child(main.voxel_terrain_runtime)
	var structures := StructureFixture.new()
	main.structure_system = structures
	main.player = CharacterBody3D.new()
	main.player.set_physics_process(false)
	main.add_child(main.player)
	var original := main.player.global_transform
	var started := Time.get_ticks_usec()
	var result: Dictionary = await main.wait_for_initial_player_collision_publication()
	var elapsed := float(Time.get_ticks_usec()-started)/1000000.0
	var checks := {
		"failed_at_original_deadline":result.get("status","") == "failed" and result.get("reason","") == "player_collision_publication_timeout",
		"no_timeout_override":main.INITIAL_READINESS_TIMEOUT_SECONDS == 120.0,
		"bounded_elapsed":elapsed >= 120.0 and elapsed < 130.0,
		"many_scene_replacements":structures.queries > 100,
		"loading_feedback_retained":not main.startup_loading_timeline.is_empty(),
		"no_player_motion":main.player.global_transform == original,
		"no_false_collision_success":not main.player.has_meta("startup_terrain_collision_proof")}
	main.free()
	await process_frame
	var passed: bool = not checks.values().has(false)
	var report := {"passed":passed,"checks":checks,"result":result,"elapsedSeconds":elapsed,"sceneQueries":structures.queries,
		"sourceSha256":FileAccess.get_sha256("res://scripts/MainCore.gd"),
		"evidenceLevel":"synthetic changing-scene and terrain authorities; actual Main startup wait, real frames and original 120s deadline; not gameplay"}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("CITADEL STARTUP DEADLINE ",passed)
	quit(0 if passed else 1)
