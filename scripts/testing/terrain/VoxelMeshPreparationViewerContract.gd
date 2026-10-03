extends SceneTree
## Synthetic native-viewer ownership contract. No generated terrain or gameplay.
const Runtime = preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
const Gate = preload("res://scripts/terrain/VoxelTerrainSiteGate.gd")
const REPORT := "res://artifacts/native-world-backend/mesh-preparation-runtime-contract.json"

class AdmissionStub extends RefCounted:
	var profile_store := RefCounted.new()
	var status := "ready"
	func advance() -> void: pass
	func request_bounds(_bounds: Rect2i) -> Dictionary:
		return {"status":status,"reason":"synthetic_"+status}

class WorldStub extends RefCounted:
	func refresh_generated_site_profiles() -> void: pass

class TerrainStub extends Node:
	var automatic_loading_enabled := true

class MainStub extends Node:
	var player: Node3D
	var startup_loading_active := true
	var runtime_loading_active := false
	var shutdown_requested := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var checks := {}
	var runtime := Runtime.new()
	runtime.set_process(false)
	runtime.set_physics_process(false)
	root.add_child(runtime)
	var main := MainStub.new()
	root.add_child(main)
	main.player = Node3D.new()
	main.add_child(main.player)
	runtime.main = main
	var terrain := TerrainStub.new()
	runtime.add_child(terrain)
	var admission := AdmissionStub.new()
	var gate = Gate.new()
	gate.setup(runtime,terrain,admission,WorldStub.new())
	runtime.site_gate = gate
	var primary := VoxelViewer.new()
	primary.requires_visuals = true
	primary.requires_collisions = true
	checks["primary_admitted"] = gate.request_viewer(primary,Vector3.ZERO,96)
	runtime.viewer = primary
	runtime.authority_ready = true
	runtime.advance_mesh_preparation_viewer()
	checks["loading_does_not_attach"] = runtime.mesh_preparation_viewer == null
	main.startup_loading_active = false
	admission.status = "failed"
	runtime.advance_mesh_preparation_viewer()
	checks["optional_failure_does_not_poison_gate"] = gate.failure_reason().is_empty() \
		and (runtime.mesh_preparation_viewer == null or (is_instance_valid(runtime.mesh_preparation_viewer) \
		and not runtime.mesh_preparation_viewer.is_inside_tree()))
	admission.status = "ready"
	runtime.advance_mesh_preparation_viewer()
	var prepared: VoxelViewer = runtime.mesh_preparation_viewer
	checks["preparation_only_attached"] = is_instance_valid(prepared) and prepared.is_inside_tree() \
		and prepared.view_distance == 112 and not prepared.requires_visuals \
		and not prepared.requires_collisions and bool(prepared.get("requires_mesh_preparation"))
	var old_position := prepared.global_position if is_instance_valid(prepared) else Vector3.INF
	main.player.position = Vector3(14.0,0.0,0.0)
	admission.status = "pending"
	runtime.advance_mesh_preparation_viewer()
	checks["pending_move_retains_old_position"] = is_instance_valid(prepared) \
		and prepared.is_inside_tree() and prepared.global_position == old_position
	admission.status = "ready"
	runtime.advance_mesh_preparation_viewer()
	checks["small_step_rebase"] = is_instance_valid(prepared) and prepared.is_inside_tree() \
		and prepared.global_position.x > old_position.x and prepared.global_position.x <= 21.6
	checks["primary_still_visual_collision_owner"] = primary.is_inside_tree() \
		and primary.requires_visuals and primary.requires_collisions and primary.view_distance == 96
	runtime._retire_mesh_preparation_viewer()
	checks["retirement_detaches_optional"] = runtime.mesh_preparation_viewer == null \
		and not prepared.is_inside_tree() and gate.failure_reason().is_empty()
	gate.stop()
	primary.queue_free()
	runtime.queue_free()
	main.queue_free()
	var report := {"schema":"voxel-mesh-preparation-runtime-contract/v1",
		"evidenceLevel":"synthetic_native_viewer_contract", "checks":checks,
		"passed":not checks.values().has(false)}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts/native-world-backend"))
	var file := FileAccess.open(REPORT,FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(report,"\t"))
	print(JSON.stringify(report))
	quit(0 if report.passed else 1)
