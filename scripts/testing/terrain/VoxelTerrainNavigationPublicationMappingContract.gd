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

class LocalityRuntime extends Runtime:
	var fixture_volume := {"revision": 7}
	func generation_context_current() -> bool: return true
	func volume_service(): return fixture_volume

class PassingPublicationRuntime extends Runtime:
	func collision_proof_for_game_chunk(chunk_key: Vector2i) -> Dictionary:
		return {"passed":true,"chunk":chunk_key}

class ProbeWorld extends RefCounted:
	func surface_y_at(_position: Vector3) -> float:
		return 27.0

class SteepProbeVolume extends RefCounted:
	func terrain_mesh_surface_projection_for_cell(cell: Vector3i) -> Dictionary:
		var surface_y := 59.4 if cell.x >= 21 and cell.z >= 21 else 27.0
		return {"found": true, "position": Vector3(0.0, surface_y, 0.0)}

class MissingProbeVolume extends RefCounted:
	func terrain_mesh_surface_projection_for_cell(_cell: Vector3i) -> Dictionary:
		return {"found": false}

class FailingSiteGate extends RefCounted:
	var reason := "synthetic_secondary_site_failure"
	func request_cells(_bounds: Rect2i) -> Dictionary:
		return {"status":"failed","reason":reason}
	func remove_viewer(_viewer: Node3D) -> void:
		pass
	func failure_reason() -> String:
		return reason

var checks := {}

func _initialize() -> void:
	call_deferred("_run")

func check(name: String, passed: bool) -> void:
	checks[name] = passed
	if not passed:
		printerr("VOXEL TERRAIN NAVIGATION PUBLICATION MAPPING FAILED: ", name)

func _run() -> void:
	check("origin_chunk_maps_all_capture_halo_tiles", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(0, 0)) == [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)
	])
	check("positive_unaligned_chunk_maps_three_by_three_with_halo", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(1, 0)) == [
		Vector2i(1, -1), Vector2i(2, -1), Vector2i(3, -1),
		Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0),
		Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)
	])
	check("negative_x_uses_floor_division_with_halo", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(-1, 0)) == [
		Vector2i(-2, -1), Vector2i(-1, -1), Vector2i(0, -1),
		Vector2i(-2, 0), Vector2i(-1, 0), Vector2i(0, 0),
		Vector2i(-2, 1), Vector2i(-1, 1), Vector2i(0, 1)
	])
	check("negative_unaligned_chunk_maps_three_by_three_with_halo", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(-2, 0)) == [
		Vector2i(-4, -1), Vector2i(-3, -1), Vector2i(-2, -1),
		Vector2i(-4, 0), Vector2i(-3, 0), Vector2i(-2, 0),
		Vector2i(-4, 1), Vector2i(-3, 1), Vector2i(-2, 1)
	])
	check("negative_xy_preserves_deterministic_row_order", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(-1, -1)) == [
		Vector2i(-2, -2), Vector2i(-1, -2), Vector2i(0, -2),
		Vector2i(-2, -1), Vector2i(-1, -1), Vector2i(0, -1),
		Vector2i(-2, 0), Vector2i(-1, 0), Vector2i(0, 0)
	])
	check("aligned_positive_boundary_includes_capture_halo_neighbor", Runtime.navigation_tile_keys_for_game_chunk(Vector2i(4, 4)) == [
		Vector2i(6, 6), Vector2i(7, 6), Vector2i(8, 6),
		Vector2i(6, 7), Vector2i(7, 7), Vector2i(8, 7),
		Vector2i(6, 8), Vector2i(7, 8), Vector2i(8, 8)
	])
	var probe_world := ProbeWorld.new()
	var projected_bounds := Runtime.startup_collision_surface_cell_bounds([Vector2i.ZERO], probe_world, SteepProbeVolume.new())
	check("startup_vertical_bounds_include_authoritative_collision_probe_extrema",
		projected_bounds == Vector2i(20, 44))
	var fallback_bounds := Runtime.startup_collision_surface_cell_bounds([Vector2i.ZERO], probe_world, MissingProbeVolume.new())
	check("startup_vertical_bounds_retain_generation_fallback_when_projection_missing",
		fallback_bounds == Vector2i(20, 20))
	check("single_chunk_auxiliary_viewer_includes_native_mesh_block_halo",
		Runtime.collision_publication_view_distance_requirement(0.0) == 54)
	# Start at the centre of an admitted gameplay chunk. A full bounded forecast
	# may safely lead the one primary viewer only while that same footprint keeps
	# the current chunk inside its collision publication margin.
	var player_position := Vector3(Runtime.GAME_CHUNK_SIZE * Runtime.CELL * 0.5,0.0,Runtime.GAME_CHUNK_SIZE * Runtime.CELL * 0.5)
	var bounded_forecast := player_position + Vector3(0.0,0.0,-Runtime.CELL*16.0)
	check("bounded_forecast_leads_single_primary_viewer_while_current_chunk_stays_covered",
		Runtime.foreground_viewer_target(player_position,bounded_forecast,Runtime.FINAL_VIEW_DISTANCE) == bounded_forecast)
	var unsafe_forecast := Vector3(0.0,0.0,-Runtime.CELL*80.0)
	check("unsafe_forecast_falls_back_to_current_player_coverage",
		Runtime.foreground_viewer_target(player_position,unsafe_forecast,Runtime.FINAL_VIEW_DISTANCE) == player_position)
	check("covered_and_published_foreground_allows_native_backpressure_defer",
		Runtime.primary_viewer_request_may_defer(
			Runtime.SECONDARY_VIEWER_MAX_PENDING_NATIVE_TASKS + 1,true,true,true,true))
	check("covered_but_unpublished_foreground_forces_native_viewer_request",
		not Runtime.primary_viewer_request_may_defer(
			Runtime.SECONDARY_VIEWER_MAX_PENDING_NATIVE_TASKS + 1,true,true,true,false)
		and not Runtime.primary_viewer_request_may_defer(
			Runtime.SECONDARY_VIEWER_MAX_PENDING_NATIVE_TASKS + 1,true,true,false,true))
	check("native_backpressure_still_requires_geometric_coverage_and_real_pressure",
		not Runtime.primary_viewer_request_may_defer(
			Runtime.SECONDARY_VIEWER_MAX_PENDING_NATIVE_TASKS + 1,true,false,true,true)
		and not Runtime.primary_viewer_request_may_defer(
			Runtime.SECONDARY_VIEWER_MAX_PENDING_NATIVE_TASKS + 1,false,true,true,true)
		and not Runtime.primary_viewer_request_may_defer(
			Runtime.SECONDARY_VIEWER_MAX_PENDING_NATIVE_TASKS,true,true,true,true))
	check("unchanged_quantization_is_satisfied_only_by_published_collision",
		Runtime.primary_viewer_request_is_satisfied(false,true,true,true,true)
		and not Runtime.primary_viewer_request_is_satisfied(false,true,true,true,false)
		and not Runtime.primary_viewer_request_is_satisfied(false,true,true,false,true)
		and not Runtime.primary_viewer_request_is_satisfied(true,true,true,true,true))
	check("unpublished_exact_request_is_coalesced_only_after_first_forced_request",
		not Runtime.primary_unpublished_request_already_inflight(false,true,false,"13,4|13,4|13,4|96","")
		and Runtime.primary_unpublished_request_already_inflight(false,true,false,
			"13,4|13,4|13,4|96","13,4|13,4|13,4|96")
		and not Runtime.primary_unpublished_request_already_inflight(false,true,true,
			"13,4|13,4|13,4|96","13,4|13,4|13,4|96")
		and not Runtime.primary_unpublished_request_already_inflight(true,true,false,
			"13,4|13,4|13,4|96","13,4|13,4|13,4|96"))
	var request_quantization_runtime := Runtime.new()
	check("primary_request_identity_coalesces_to_gameplay_chunk_not_native_mesh_block",
		request_quantization_runtime._primary_viewer_request_cell_for(Vector3(Runtime.CELL * float(Runtime.GAME_CHUNK_SIZE) - 0.01, 0.0, 0.0)) == Vector2i.ZERO
		and request_quantization_runtime._primary_viewer_request_cell_for(Vector3(Runtime.CELL * float(Runtime.GAME_CHUNK_SIZE) + 0.01, 0.0, 0.0)) == Vector2i(1, 0))
	request_quantization_runtime.free()
	var forecast_runtime := Runtime.new()
	var forecast_viewer := VoxelViewer.new()
	forecast_viewer.view_distance = Runtime.FINAL_VIEW_DISTANCE
	forecast_runtime.viewer = forecast_viewer
	var forecast_background := Vector2i(7, 7)
	var forecast_chunk := Runtime.gameplay_chunk_for_world_position(bounded_forecast)
	forecast_runtime.pending_gameplay_chunks = {forecast_background:true, forecast_chunk:true}
	forecast_runtime.pending_gameplay_chunk_order = [forecast_background, forecast_chunk]
	check("retained_foreground_promotes_existing_collision_receipt_before_motion_wait",
		forecast_runtime.set_foreground_collision_demand(player_position, bounded_forecast)
		and forecast_runtime.pending_gameplay_chunk_order == [forecast_chunk, forecast_background]
		and forecast_runtime.collision_priority_promotions == 1)
	check("foreground_promotion_does_not_invent_collision_demand",
		forecast_runtime.pending_gameplay_chunks.size() == 2
		and not forecast_runtime.pending_gameplay_chunks.has(Vector2i(99, 99)))
	forecast_runtime.viewer = null
	forecast_viewer.free()
	forecast_runtime.free()

	# Secondary handoff age starts when the site gate actually admits and
	# attaches the viewer, not when native demand is first queued. This service
	# check uses explicit frames and does not publish or render terrain.
	var attachment_runtime := Runtime.new()
	var attachment_viewer := VoxelViewer.new()
	var attachment_record := {"viewer":attachment_viewer,"attachedFrame":-1,"primaryHandoff":true}
	attachment_runtime.startup_auxiliary_viewers.append(attachment_record)
	check("queued_secondary_viewer_has_no_attachment_age",
		not Runtime.secondary_viewer_handoff_mature(attachment_record, 40))
	check("successful_secondary_admission_stamps_actual_attachment_frame",
		attachment_runtime._mark_secondary_viewer_attached(attachment_viewer, 40)
		and int(attachment_runtime.startup_auxiliary_viewers[0].attachedFrame) == 40)
	var admitted_record: Dictionary = attachment_runtime.startup_auxiliary_viewers[0]
	check("secondary_handoff_guard_rejects_attachment_frame",
		not Runtime.secondary_viewer_handoff_mature(admitted_record, 40))
	check("secondary_handoff_guard_rejects_first_physics_frame",
		not Runtime.secondary_viewer_handoff_mature(admitted_record, 41))
	check("secondary_handoff_guard_accepts_second_physics_frame",
		Runtime.secondary_viewer_handoff_mature(admitted_record, 42))
	attachment_viewer.free()
	attachment_runtime.free()

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

	# A failed player motion proof may promote only its already-retained collision
	# receipt. This is queue scheduling, not a new terrain request or a weakened
	# collision proof; background order stays deterministic behind the frontier.
	var priority_runtime := Runtime.new()
	var background := Vector2i(7, 7)
	var immediate := Vector2i(1, -1)
	var later := Vector2i(8, 7)
	priority_runtime.pending_gameplay_chunks = {background:true, immediate:true, later:true}
	priority_runtime.pending_gameplay_chunk_order = [background, later, immediate]
	check("motion_collision_dependency_promotes_existing_pending_chunk",
		priority_runtime._promote_pending_gameplay_chunk_for_collision(immediate)
		and priority_runtime.pending_gameplay_chunk_order == [immediate, background, later]
		and priority_runtime.collision_priority_promotions == 1)
	check("motion_collision_promotion_is_idempotent_at_front",
		not priority_runtime._promote_pending_gameplay_chunk_for_collision(immediate)
		and priority_runtime.pending_gameplay_chunk_order == [immediate, background, later]
		and priority_runtime.collision_priority_promotions == 1)
	check("motion_collision_promotion_does_not_invent_terrain_demand",
		not priority_runtime._promote_pending_gameplay_chunk_for_collision(Vector2i(99,99))
		and priority_runtime.pending_gameplay_chunks.size() == 3
		and priority_runtime.pending_gameplay_chunk_order == [immediate, background, later])
	priority_runtime.free()

	# Native mesh retirement revokes every gameplay receipt whose certified mesh
	# area used that block. Retained demand remains retryable, but cannot claim
	# physical readiness from an unloaded native artifact.
	var residency_recorder := RecordingNpcSystem.new()
	var residency_host := Host.new()
	residency_host.npc_system = residency_recorder
	var residency_runtime := Runtime.new()
	residency_runtime.main = residency_host
	var left_chunk := Vector2i(0,0)
	var seam_chunk := Vector2i(1,0)
	var distant_chunk := Vector2i(2,0)
	residency_runtime.desired_gameplay_chunks = {left_chunk:true,seam_chunk:true,distant_chunk:true}
	residency_runtime.retained_gameplay_chunks = {left_chunk:true,seam_chunk:true}
	residency_runtime.published_gameplay_chunks = {
		left_chunk:{"meshArea":AABB(Vector3(0,-4,0),Vector3(28,16,28))},
		seam_chunk:{"meshArea":AABB(Vector3(28,-4,0),Vector3(28,16,28))},
		distant_chunk:{"meshArea":AABB(Vector3(56,-4,0),Vector3(28,16,28))}
	}
	var retired_block := Vector3i(1,0,0)
	check("native_mesh_exit_maps_only_overlapping_gameplay_chunks",
		Runtime.gameplay_chunks_for_native_mesh_block(retired_block) == [left_chunk,seam_chunk])
	check("native_mesh_exit_mapping_uses_floor_division_across_negative_seam",
		Runtime.gameplay_chunks_for_native_mesh_block(Vector3i(-2,0,0)) \
		== [Vector2i(-2,0),Vector2i(-1,0)])
	residency_runtime.published_mesh_blocks[retired_block] = true
	residency_runtime.on_mesh_block_exited(retired_block)
	check("native_mesh_exit_revokes_all_intersecting_gameplay_receipts",
		not residency_runtime.published_gameplay_chunks.has(left_chunk)
		and not residency_runtime.published_gameplay_chunks.has(seam_chunk)
		and residency_runtime.published_gameplay_chunks.has(distant_chunk))
	check("native_mesh_exit_requeues_still_demanded_collision_publication",
		residency_runtime.pending_gameplay_chunks.has(left_chunk)
		and residency_runtime.pending_gameplay_chunks.has(seam_chunk)
		and not residency_runtime.pending_gameplay_chunks.has(distant_chunk)
		and not residency_runtime.published_mesh_blocks.has(retired_block))
	check("native_mesh_exit_notifies_navigation_that_physical_receipts_retired",
		not residency_recorder.unloaded.is_empty())
	residency_runtime.free()

	# A retained chunk remains a collision-publication owner even during the
	# short interval before/after its ordinary gameplay container is present.
	# Mesh retirement and durable edits must therefore stay retryable without
	# relying on desired_gameplay_chunks as a duplicate authority.
	var retained_only_recorder := RecordingNpcSystem.new()
	var retained_only_host := Host.new()
	retained_only_host.npc_system = retained_only_recorder
	var retained_only_runtime := PassingPublicationRuntime.new()
	retained_only_runtime.main = retained_only_host
	root.add_child(retained_only_runtime)
	var retained_only_chunk := Vector2i.ZERO
	retained_only_runtime.retained_gameplay_chunks[retained_only_chunk] = true
	retained_only_runtime.published_gameplay_chunks[retained_only_chunk] = {
		"meshArea":AABB(Vector3(0,-4,0),Vector3(28,16,28))
	}
	retained_only_runtime.queue_edit_change(Vector3i(8, 0, 8), {
		"solid":true, "density":1.0, "material":"stone"
	}, "retained-only-edit")
	check("retained_only_edit_invalidates_and_requeues_collision_receipt",
		retained_only_runtime.gameplay_chunk_publication_owned(retained_only_chunk)
		and not retained_only_runtime.desired_gameplay_chunks.has(retained_only_chunk)
		and not retained_only_runtime.published_gameplay_chunks.has(retained_only_chunk)
		and retained_only_runtime.pending_gameplay_chunks.has(retained_only_chunk))
	retained_only_runtime.pending_gameplay_chunks.clear()
	retained_only_runtime.pending_gameplay_chunk_order.clear()
	retained_only_runtime.pending_edit_sections.clear()
	retained_only_runtime.published_gameplay_chunks[retained_only_chunk] = {
		"meshArea":AABB(Vector3(0,-4,0),Vector3(28,16,28))
	}
	retained_only_runtime.on_mesh_block_exited(Vector3i.ZERO)
	check("retained_only_mesh_exit_keeps_collision_republication_retryable",
		not retained_only_runtime.published_gameplay_chunks.has(retained_only_chunk)
		and retained_only_runtime.pending_gameplay_chunks.has(retained_only_chunk)
		and retained_only_runtime.pending_gameplay_chunk_order.has(retained_only_chunk))
	retained_only_runtime.process_pending_gameplay_chunk_publications()
	check("retained_only_owner_survives_publication_processing_gate",
		retained_only_runtime.published_gameplay_chunks.has(retained_only_chunk)
		and not retained_only_runtime.pending_gameplay_chunks.has(retained_only_chunk))
	retained_only_runtime.free()

	# A terminal SiteGate rejection is not retryable backpressure. Preserve its
	# exact source reason and remove the staged footprint immediately.
	var failed_secondary_runtime := Runtime.new()
	failed_secondary_runtime.site_gate = FailingSiteGate.new()
	var failed_secondary_viewer := VoxelViewer.new()
	failed_secondary_runtime._stage_secondary_viewer(
		"startup:synthetic", "startup", failed_secondary_viewer,
		Vector3.ZERO, Runtime.STARTUP_VIEW_DISTANCE, [Vector2i.ZERO], 1)
	failed_secondary_runtime.advance_secondary_viewer_admissions()
	var secondary_failure := failed_secondary_runtime.secondary_viewer_admission_failure()
	check("terminal_secondary_site_failure_is_structured_and_not_retried",
		secondary_failure.get("status") == "failed"
		and secondary_failure.get("reason") == "synthetic_secondary_site_failure"
		and secondary_failure.get("kind") == "startup"
		and secondary_failure.get("stage") == "cells"
		and failed_secondary_runtime.secondary_viewer_admissions.is_empty())
	failed_secondary_runtime.free()

	# A durable edit in a startup-only auxiliary footprint must remain retryable
	# even though ordinary player demand does not own that distant chunk.
	var auxiliary_edit_runtime := Runtime.new()
	var auxiliary_cell := Vector3i(8, 0, -8)
	var auxiliary_chunk := auxiliary_edit_runtime.game_chunk_for_cell(auxiliary_cell)
	auxiliary_edit_runtime.startup_auxiliary_publication_chunks[auxiliary_chunk] = true
	auxiliary_edit_runtime.published_gameplay_chunks[auxiliary_chunk] = {"passed":true}
	auxiliary_edit_runtime.queue_edit_change(auxiliary_cell, {
		"solid":true, "density":1.0, "material":"stone"
	}, "startup-aux-edit")
	check("startup_auxiliary_edit_invalidates_and_requeues_collision_publication",
		auxiliary_chunk == Vector2i(0,-1)
		and not auxiliary_edit_runtime.desired_gameplay_chunks.has(auxiliary_chunk)
		and not auxiliary_edit_runtime.published_gameplay_chunks.has(auxiliary_chunk)
		and auxiliary_edit_runtime.pending_gameplay_chunks.has(auxiliary_chunk)
		and auxiliary_edit_runtime.pending_gameplay_chunk_order.has(auxiliary_chunk)
		and int(auxiliary_edit_runtime.gameplay_chunk_edit_revisions.get(auxiliary_chunk,0)) == 1)
	auxiliary_edit_runtime.release_startup_auxiliary_publication_chunks()
	check("startup_auxiliary_release_clears_unowned_retry_without_inventing_demand",
		not auxiliary_edit_runtime.startup_auxiliary_publication_chunks.has(auxiliary_chunk)
		and not auxiliary_edit_runtime.pending_gameplay_chunks.has(auxiliary_chunk)
		and not auxiliary_edit_runtime.pending_gameplay_chunk_order.has(auxiliary_chunk)
		and not auxiliary_edit_runtime.desired_gameplay_chunks.has(auxiliary_chunk))
	auxiliary_edit_runtime.free()

	var boundary_edit_runtime := Runtime.new()
	var positive_boundary_chunks: Array[Vector2i] = [
		Vector2i(0,0), Vector2i(0,1), Vector2i(1,0), Vector2i(1,1)
	]
	var negative_boundary_chunks: Array[Vector2i] = [
		Vector2i(-1,-1), Vector2i(-1,0), Vector2i(0,-1), Vector2i(0,0)
	]
	check("positive_boundary_edit_maps_every_collision_halo_owner",
		boundary_edit_runtime.gameplay_chunks_for_edit_cell(Vector3i(27,0,27)) == positive_boundary_chunks)
	check("negative_boundary_edit_uses_floor_division_for_every_collision_halo_owner",
		boundary_edit_runtime.gameplay_chunks_for_edit_cell(Vector3i(-1,0,-1)) == negative_boundary_chunks)
	boundary_edit_runtime.free()

	var auxiliary_abort_runtime := Runtime.new()
	var abort_chunk := Vector2i(-3,4)
	auxiliary_abort_runtime.startup_auxiliary_publication_chunks[abort_chunk] = true
	auxiliary_abort_runtime.pending_gameplay_chunks[abort_chunk] = true
	auxiliary_abort_runtime.pending_gameplay_chunk_order.append(abort_chunk)
	auxiliary_abort_runtime.published_gameplay_chunks[abort_chunk] = {"passed":true}
	auxiliary_abort_runtime.abort_startup_auxiliary_publication_chunks()
	check("startup_failure_aborts_unowned_auxiliary_publication_immediately",
		not auxiliary_abort_runtime.startup_auxiliary_publication_chunks.has(abort_chunk)
		and not auxiliary_abort_runtime.pending_gameplay_chunks.has(abort_chunk)
		and not auxiliary_abort_runtime.pending_gameplay_chunk_order.has(abort_chunk)
		and not auxiliary_abort_runtime.published_gameplay_chunks.has(abort_chunk)
		and auxiliary_abort_runtime.startup_auxiliary_viewers.is_empty())
	auxiliary_abort_runtime.free()

	# Publication depends on terrain edits only where they can affect the
	# requested cells. A native edit waiting outside the current capture must
	# not deadlock unrelated navigation startup, but its capture halo remains
	# deliberately conservative.
	var locality := LocalityRuntime.new()
	locality.authority_ready = true
	locality.last_volume_revision = 7
	var local_bounds := Rect2i(0, 0, Runtime.GAME_CHUNK_SIZE, Runtime.GAME_CHUNK_SIZE)
	for key: Vector2i in WorldStreamingCoordinator.chunks_for_bounds(local_bounds):
		locality.published_gameplay_chunks[key] = true
	locality.pending_edit_sections[Vector3i(8, 0, 8)] = {}
	check("distant_pending_edit_does_not_block_local_publication",
		locality.region_publication_readiness(local_bounds).status == "ready")
	locality.pending_edit_sections.clear()
	locality.pending_edit_sections[Vector3i(0, 0, 0)] = {}
	check("intersecting_pending_edit_blocks_local_publication",
		locality.region_publication_readiness(local_bounds).reason == "terrain_edits_pending")
	locality.pending_edit_sections.clear()
	locality.pending_edit_sections[Vector3i(1, 0, 0)] = {}
	check("navigation_capture_halo_blocks_adjacent_pending_edit",
		locality.region_publication_readiness(Rect2i(16, 0, 28, 28).grow(1)).reason == "terrain_edits_pending")
	locality.free()

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
