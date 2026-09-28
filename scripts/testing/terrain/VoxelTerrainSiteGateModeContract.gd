extends SceneTree
## Synthetic gate contract. It checks attachment and loading policy, not voxel generation.
const Gate = preload("res://scripts/terrain/VoxelTerrainSiteGate.gd")

class TerrainStub extends Node:
	var automatic_loading_enabled := true

class AdmissionStub extends RefCounted:
	var profile_store := RefCounted.new()
	func advance() -> void: pass
	func request_bounds(_bounds: Rect2i) -> Dictionary: return {"status": "ready"}

class WorldStub extends RefCounted:
	func refresh_generated_site_profiles() -> void: pass

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var checks := {}
	for manual_data_mode in [false, true]:
		var runtime := Node3D.new()
		root.add_child(runtime)
		var terrain := TerrainStub.new()
		runtime.add_child(terrain)
		var gate = Gate.new()
		if manual_data_mode:
			gate.setup(runtime, terrain, AdmissionStub.new(), WorldStub.new(), true)
		else:
			gate.setup(runtime, terrain, AdmissionStub.new(), WorldStub.new())
		var viewer := VoxelViewer.new()
		var position := Vector3(135.0, 0.0, 135.0)
		var admitted := gate.request_viewer(viewer, position, 16)
		gate.advance()
		var mode := "manual" if manual_data_mode else "default"
		checks[mode + "_viewer_attached"] = admitted and viewer.get_parent() == runtime and viewer.global_position == position
		checks[mode + "_loading_policy"] = terrain.automatic_loading_enabled == not manual_data_mode
		var foreign := VoxelViewer.new()
		root.add_child(foreign)
		checks[mode + "_foreign_fails_closed"] = gate.failure_reason() == "unowned_voxel_viewer" and not terrain.automatic_loading_enabled
		gate.advance()
		checks[mode + "_foreign_remains_closed"] = not terrain.automatic_loading_enabled
		gate.stop()
		root.remove_child(foreign)
		foreign.free()
		viewer.free()
		runtime.queue_free()
		await process_frame
	for name in checks:
		if not checks[name]: printerr("SITE GATE MODE FAILED: ", name)
	var report := {"passed": false not in checks.values(), "checks": checks,
		"evidenceLevel": "synthetic_gate_contract"}
	var path := OS.get_environment("VWB_SITE_GATE_MODE_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	quit(0 if report.passed else 1)
