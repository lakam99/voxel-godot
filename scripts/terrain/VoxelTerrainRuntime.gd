extends Node3D
class_name VoxelTerrainRuntime

signal visible_mesh_block_revision_changed(block_position: Vector3i, revision: int)

const GENERATOR_SCRIPT := preload("res://scripts/terrain/VoxelTerrainGenerator.gd")
const CONTEXT_SCRIPT := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const SITE_GATE_SCRIPT := preload("res://scripts/terrain/VoxelTerrainSiteGate.gd")
const STARTUP_READINESS_RESULT_SCRIPT := preload("res://scripts/world/StartupReadinessResult.gd")
const NPC_CONSTANTS_SCRIPT := preload("res://scripts/npc_ai/NpcConstants.gd")
const TERRAIN_SHADER := preload("res://shaders/voxel_terrain_authority.gdshader")
const TERRAIN_SECTION_SHADOW_PUBLISHER := preload("res://scripts/terrain/TerrainSectionShadowPublisher.gd")

const CELL := 1.35
const GAME_CHUNK_SIZE := 28
const NAVIGATION_TILE_CELL_SIZE := NPC_CONSTANTS_SCRIPT.NAV_TILE_CELL_SIZE
const TERRAIN_COLLISION_LAYER := 2
# Keep a broad approach view while leaving enough CPU headroom for terrain,
# structure and navigation publication during sprinting. The complete radius is
# settled behind the loading overlay before gameplay starts.
const FINAL_VIEW_DISTANCE := 96
const STARTUP_VIEW_DISTANCE := 80
const RETAINED_VIEW_DISTANCE := STARTUP_VIEW_DISTANCE
const RETAINED_ACTIVATION_INTERVAL_SECONDS := 0.5
const RETAINED_MAX_PENDING_NATIVE_TASKS := 8
# Every extra VoxelViewer owns a complete native footprint.  The voxel plugin
# does not expose a per-viewer queue budget, so this runtime is the one owner
# that admits those footprints.  A retained-only guard is insufficient:
# startup aids and primary handoff viewers otherwise bypass it completely.
const SECONDARY_VIEWER_MAX_PENDING_NATIVE_TASKS := RETAINED_MAX_PENDING_NATIVE_TASKS
# One primary move creates a broad native footprint. Reissuing it at each
# 16-cell mesh-block boundary turns ordinary travel into overlapping native
# generation bursts. Gameplay chunks are the existing semantic collision
# publication unit; coverage below still forces an immediate move at an edge.
const PRIMARY_VIEWER_REQUEST_CELL_SIZE := GAME_CHUNK_SIZE
const MESH_PREPARATION_VIEW_DISTANCE := 112
const MESH_PREPARATION_REBASE_CELLS := 8
const MESH_PREPARATION_MAX_PENDING_NATIVE_TASKS := SECONDARY_VIEWER_MAX_PENDING_NATIVE_TASKS
const VIEW_DISTANCE_EXPANSION_STEP := 16
const VIEW_DISTANCE_EXPANSION_INTERVAL_SECONDS := 2.0
const FINAL_EXPANSION_REQUIRED_QUIET_FRAMES := 4
const STARTUP_VERTICAL_MIN_CELL := -16
const STARTUP_VERTICAL_MAX_CELL := 48
const VERTICAL_BOUNDS_EXPANSION_STEP_CELLS := 16
const NATIVE_MESH_BLOCK_SIZE_CELLS := 16
const SECTION_SIZE := NATIVE_MESH_BLOCK_SIZE_CELLS
const EDIT_SECTIONS_PER_FRAME := 1
const PUBLICATION_PROBES_PER_PHYSICS_FRAME := 2
const COLLISION_SURFACE_TOLERANCE := CELL * 2.5
const COLLISION_MESH_VERTICAL_MARGIN_CELLS := 4
# `is_area_meshed()` requires complete native mesh blocks, not merely the
# geometric gameplay-chunk footprint. Keep the old seam margin plus one whole
# native mesh block so a viewer cannot claim a collision chunk it cannot mesh.
const COLLISION_PUBLICATION_VIEWER_SEAM_MARGIN_CELLS := 4
const COLLISION_PUBLICATION_VIEWER_HALO_CELLS := NATIVE_MESH_BLOCK_SIZE_CELLS
const COLLISION_PUBLICATION_VIEWER_MARGIN_CELLS := COLLISION_PUBLICATION_VIEWER_SEAM_MARGIN_CELLS + COLLISION_PUBLICATION_VIEWER_HALO_CELLS
const GAMEPLAY_CHUNK_COLLISION_PROBE_OFFSETS := [
	Vector2(0.50, 0.50),
	Vector2(0.22, 0.22),
	Vector2(0.78, 0.22),
	Vector2(0.22, 0.78),
	Vector2(0.78, 0.78)
]
const SEED_RESET_TASK_DRAIN_TIMEOUT_SECONDS := 30.0
const SEED_RESET_REQUIRED_QUIET_FRAMES := 2
const SITE_TRAVERSAL_READINESS_POLL_USEC := 100000
const MOTION_PROOF_MAX_SAMPLES := 32
const MOTION_PROOF_SAMPLE_SPACING_CELLS := 0.5
const MATERIAL_IDS := {
	"air": 0, "grass": 1, "dirt": 2, "stone": 3, "sand": 4, "snow": 5,
	"deepStone": 6, "bedrock": 7, "clay": 8, "gravel": 9, "coalOre": 10,
	"ironOre": 11, "crystalOre": 12, "copperOre": 13, "mud": 14, "water": 15
}

var main
var terrain: VoxelTerrain
var viewer: VoxelViewer
var generator
var authority_ready := false
var published_mesh_blocks := {}
var mesh_block_revisions := {}
var mesh_publication_serial := 0
var configured_seed := ""
var last_volume_revision := -1
var applied_edit_signatures := {}
var pending_edit_sections := {}
var edit_batches_applied := 0
var desired_gameplay_chunks := {}
var pending_gameplay_chunks := {}
var pending_gameplay_chunk_order: Array[Vector2i] = []
var published_gameplay_chunks := {}
var gameplay_chunk_edit_revisions := {}
var collision_owner_generation := 0
var collision_probe_attempts := 0
var collision_probe_passes := 0
var collision_priority_promotions := 0
var view_distance_expansion_elapsed := 0.0
var view_distance_expansion_requested := false
var final_expansion_quiet_frames := 0
var startup_auxiliary_viewers: Array[Dictionary] = []
var startup_auxiliary_cleanup_requested := false
var startup_auxiliary_cleanup_frames_remaining := 0
var startup_auxiliary_viewers_created := 0
var site_gate
var terrain_section_shadow_publisher
var retained_gameplay_chunks: Dictionary = {}
var retained_chunk_viewers: Dictionary = {}
var retained_viewer_groups: Dictionary = {}
var retained_viewer_attached_frame: Dictionary = {}
var retained_activation_elapsed := 0.0
var retained_activation_reason := ""
var retained_last_pending_tasks := 0
var startup_required_gameplay_chunks: Array = []
var startup_auxiliary_publication_chunks: Dictionary = {}
var secondary_viewer_admissions: Dictionary = {}
var secondary_viewer_admission_sequence := 0
var secondary_viewer_admission_reason := ""
var secondary_viewer_peak_pending_tasks := 0
var secondary_viewer_attach_counts := {"startup": 0, "retained": 0, "handoff": 0}
var secondary_viewer_runtime_measurement_started := false
var secondary_viewer_runtime_peak_pending_tasks := 0
var secondary_viewer_runtime_attach_counts := {"startup": 0, "retained": 0, "handoff": 0}
var secondary_viewer_terminal_failure: Dictionary = {}
var primary_viewer_request_cell := Vector2i(2147483000,2147483000)
var primary_viewer_request_distance := -1
var primary_unpublished_collision_request_key := ""
var mesh_preparation_viewer: VoxelViewer
var mesh_preparation_extension_checked := false
var mesh_preparation_extension_available := false
var mesh_preparation_request_cell := Vector3i(2147483000,2147483000,2147483000)
var mesh_preparation_admission_reason := "inactive"
var mesh_preparation_last_pending_native_tasks := 0
var mesh_preparation_admission_attempts := 0
var mesh_preparation_admission_accepts := 0
var mesh_preparation_backpressure_deferrals := 0
## Main's retained predicted-traversal request is scheduling input only. The
## primary viewer remains the sole native terrain authority; it may lead only
## while its same admitted footprint still covers the current player chunk.
var foreground_collision_current := Vector3.INF
var foreground_collision_target := Vector3.INF
var foreground_collision_demand_revision := 0
# Voxel Tools owns the actual worker queue.  The runtime can only admit
# whole-viewer footprints, so retain a compact, per-request observation of the
# native work that each accepted footprint causes.  This is diagnostics only:
# it neither creates demand nor changes collision authority.
var native_viewer_workloads: Array[Dictionary] = []
var active_native_viewer_workload_index := -1

func set_retained_gameplay_chunks(keys: Dictionary) -> void:
	if keys == retained_gameplay_chunks: return
	retained_gameplay_chunks = keys.duplicate()
	var groups := {}
	for key: Vector2i in keys:
		var group := Vector2i(floori(float(key.x)/2.0), floori(float(key.y)/2.0))
		if not groups.has(group): groups[group] = []
		groups[group].append(key)
	retained_viewer_groups = groups
	for group in retained_chunk_viewers.keys():
		if groups.has(group): continue
		var old: VoxelViewer = retained_chunk_viewers[group]
		if site_gate != null: site_gate.remove_viewer(old)
		old.queue_free()
		retained_chunk_viewers.erase(group)
		retained_viewer_attached_frame.erase(group)
	_cancel_stale_retained_secondary_admissions(groups)
	# Pending groups remain here until capacity/admission permits activation.
	# Repeated identical demand must not reset their retry interval.

func clear_retained_gameplay_chunks() -> void:
	set_retained_gameplay_chunks({})
	retained_viewer_groups.clear()
	retained_viewer_attached_frame.clear()
	retained_activation_elapsed = 0.0
	retained_activation_reason = ""
	retained_last_pending_tasks = 0
	startup_required_gameplay_chunks.clear()
	_cancel_stale_retained_secondary_admissions({})

func advance_retained_viewers(delta: float) -> void:
	retained_activation_elapsed += maxf(0.0,delta)
	if retained_activation_elapsed < RETAINED_ACTIVATION_INTERVAL_SECONDS: return
	retained_activation_elapsed = 0.0
	if terrain == null or main == null or site_gate == null or not generation_context_current(): return
	if (bool(main.get("startup_loading_active")) or bool(main.get("runtime_loading_active"))) \
			and (startup_required_gameplay_chunks.is_empty() or not gameplay_chunks_published(startup_required_gameplay_chunks)):
		retained_activation_reason = "startup_required_coverage"
		return
	if not view_distance_expansion_requested and not gameplay_chunks_published(startup_required_gameplay_chunks):
		retained_activation_reason = "startup_required_coverage"
		return
	var player_value = main.get("player")
	if not player_value is Node3D or not is_instance_valid(player_value): return
	var player_position: Vector3 = player_value.global_position
	var player_chunk := Vector2i(floori(player_position.x/(GAME_CHUNK_SIZE*CELL)),floori(player_position.z/(GAME_CHUNK_SIZE*CELL)))
	for z in range(-1,2):
		for x in range(-1,2):
			var key := player_chunk+Vector2i(x,z)
			if desired_gameplay_chunks.has(key) and not published_gameplay_chunks.has(key) \
					and is_instance_valid(viewer) and viewer.is_inside_tree() and _viewer_covers_chunk_at(viewer,key,viewer.global_position):
				retained_activation_reason = "player_collision_coverage"
				return
	var groups := _retained_groups_for_secondary(player_position)
	_retire_nonlocal_retained_viewers(groups)
	if groups.is_empty():
		retained_activation_reason = "primary_covers_local_retained_frontier"
		return
	# A retained viewer owns a broad native mesh/collision footprint.  It must
	# share the one secondary admission lane with startup aids and primary
	# handoffs; otherwise each path can independently flood native generation.
	if retained_group_collision_coverage_pending():
		retained_activation_reason = "retained_group_collision_coverage"
		return
	retained_last_pending_tasks = voxel_engine_pending_task_count()
	if retained_last_pending_tasks > SECONDARY_VIEWER_MAX_PENDING_NATIVE_TASKS:
		retained_activation_reason = "native_task_backpressure"
		return
	retained_activation_reason = "covered"
	var world = main.get("world_generation_system")
	for group: Vector2i in groups:
		if retained_chunk_viewers.has(group): continue
		var spec: Dictionary = auxiliary_viewer_spec_for_chunks(retained_viewer_groups[group],world)
		if spec.is_empty(): continue
		var position: Vector3 = spec.position
		var view_distance: int = int(spec.viewDistance)
		var auxiliary := VoxelViewer.new()
		auxiliary.name = "RetainedRegion_%d_%d" % [group.x,group.y]
		auxiliary.requires_visuals = true
		auxiliary.requires_collisions = true
		_stage_secondary_viewer("retained:%d:%d" % [group.x, group.y], "retained", auxiliary,
				position, view_distance, retained_viewer_groups[group], 2, {"group": group})
		retained_activation_reason = "retained_group_queued"
		return

func retained_group_collision_coverage_pending() -> bool:
	for group_value in retained_chunk_viewers:
		if not group_value is Vector2i:
			continue
		var group: Vector2i = group_value
		var retained_viewer: VoxelViewer = retained_chunk_viewers[group]
		if not is_instance_valid(retained_viewer) or not retained_viewer.is_inside_tree():
			continue
		if retained_group_collision_receipts_pending(group):
			return true
	return false

func retained_group_collision_receipts_pending(group: Vector2i) -> bool:
	var group_chunks: Array = retained_viewer_groups.get(group, [])
	for chunk_value in group_chunks:
		if not chunk_value is Vector2i:
			continue
		var chunk_key: Vector2i = chunk_value
		if not retained_gameplay_chunks.has(chunk_key):
			continue
		var receipt: Dictionary = published_gameplay_chunks.get(chunk_key,{}) if published_gameplay_chunks.get(chunk_key,{}) is Dictionary else {}
		if not _collision_chunk_receipt_current(chunk_key,receipt):
			return true
	return false

func _retained_groups_for_secondary(player_position: Vector3) -> Array:
	var groups: Array = retained_viewer_groups.keys()
	groups.sort_custom(func(a: Vector2i, b: Vector2i):
		var ac := (Vector2(a * 2) + Vector2.ONE) * float(GAME_CHUNK_SIZE) * CELL
		var bc := (Vector2(b * 2) + Vector2.ONE) * float(GAME_CHUNK_SIZE) * CELL
		var observer := Vector2(player_position.x, player_position.z)
		var ad := ac.distance_squared_to(observer)
		var bd := bc.distance_squared_to(observer)
		return ad < bd or ad == bd and (a.x < b.x or a.x == b.x and a.y < b.y))
	# Initial loading owns an explicit readiness lifecycle and may keep its full
	# declared collision set. Once play begins, a broad retained request is
	# scheduling evidence, not authority to instantiate another native terrain
	# authority. The primary viewer provides the bounded local collision sweep;
	# retained source/chunk demand remains retryable for reversals and downstream
	# consumers without turning every 2x2 group into an overlapping 80m radius.
	if main != null and (bool(main.get("startup_loading_active")) or bool(main.get("runtime_loading_active"))):
		return groups
	return []

func _retire_nonlocal_retained_viewers(active_groups: Array) -> void:
	var allowed := {}
	for group_value in active_groups:
		if group_value is Vector2i:
			allowed[group_value] = true
	for group_value in retained_chunk_viewers.keys():
		if not (group_value is Vector2i) or allowed.has(group_value):
			continue
		var auxiliary: VoxelViewer = retained_chunk_viewers[group_value]
		if is_instance_valid(auxiliary):
			if site_gate != null:
				site_gate.remove_viewer(auxiliary)
			auxiliary.queue_free()
		retained_chunk_viewers.erase(group_value)
		retained_viewer_attached_frame.erase(group_value)
	for identity_value in secondary_viewer_admissions.keys():
		var identity := String(identity_value)
		var entry: Dictionary = secondary_viewer_admissions[identity]
		if String(entry.get("kind", "")) != "retained":
			continue
		var metadata: Dictionary = entry.get("metadata", {})
		var group_value = metadata.get("group")
		if group_value is Vector2i and allowed.has(group_value):
			continue
		var auxiliary_value = entry.get("viewer")
		if is_instance_valid(auxiliary_value):
			auxiliary_value.queue_free()
		secondary_viewer_admissions.erase(identity)

func _stage_secondary_viewer(identity: String, kind: String, auxiliary: VoxelViewer,
		position: Vector3, view_distance: int, chunks: Array, priority: int, metadata := {}) -> void:
	if secondary_viewer_admissions.has(identity):
		if is_instance_valid(auxiliary):
			auxiliary.queue_free()
		return
	secondary_viewer_admission_sequence += 1
	secondary_viewer_admissions[identity] = {
		"identity": identity, "kind": kind, "viewer": auxiliary,
		"position": position, "viewDistance": view_distance, "chunks": chunks.duplicate(),
		"priority": priority, "sequence": secondary_viewer_admission_sequence,
		"metadata": metadata.duplicate(true)
	}

func _mark_secondary_viewer_attached(auxiliary: VoxelViewer, attached_frame: int) -> bool:
	for index in range(startup_auxiliary_viewers.size()):
		var record_value = startup_auxiliary_viewers[index]
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		if not is_same(record.get("viewer"), auxiliary):
			continue
		record["attachedFrame"] = attached_frame
		startup_auxiliary_viewers[index] = record
		return true
	return false

static func secondary_viewer_handoff_mature(record: Dictionary, current_frame: int) -> bool:
	var attached_frame := int(record.get("attachedFrame", -1))
	return attached_frame >= 0 and current_frame - attached_frame >= 2

func _cancel_stale_retained_secondary_admissions(groups: Dictionary) -> void:
	for identity_value in secondary_viewer_admissions.keys():
		var identity := String(identity_value)
		var entry: Dictionary = secondary_viewer_admissions[identity]
		if String(entry.get("kind", "")) != "retained":
			continue
		var group_value = entry.get("metadata", {}).get("group") if entry.get("metadata", {}) is Dictionary else null
		if group_value is Vector2i and groups.has(group_value):
			continue
		var auxiliary = entry.get("viewer")
		if is_instance_valid(auxiliary):
			auxiliary.queue_free()
		secondary_viewer_admissions.erase(identity)

func _secondary_viewer_collision_coverage_pending() -> bool:
	for record_value in startup_auxiliary_viewers:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value
		var auxiliary: VoxelViewer = record.get("viewer")
		if not is_instance_valid(auxiliary) or not auxiliary.is_inside_tree():
			continue
		if _secondary_record_collision_receipts_pending(record):
			return true
	return retained_group_collision_coverage_pending()

func _secondary_record_collision_receipts_pending(record: Dictionary) -> bool:
	for chunk_value in record.get("chunks", []):
		if not (chunk_value is Vector2i):
			continue
		var chunk_key: Vector2i = chunk_value
		# Retired startup/handoff footprints must not block a current owner.
		if not startup_required_gameplay_chunks.has(chunk_key) \
				and not startup_auxiliary_publication_chunks.has(chunk_key) \
				and not retained_gameplay_chunks.has(chunk_key) and not desired_gameplay_chunks.has(chunk_key):
			continue
		var receipt: Dictionary = published_gameplay_chunks.get(chunk_key, {}) \
				if published_gameplay_chunks.get(chunk_key, {}) is Dictionary else {}
		if not _collision_chunk_receipt_current(chunk_key, receipt):
			return true
	return false


func release_startup_auxiliary_publication_chunks() -> void:
	var keys: Array=startup_auxiliary_publication_chunks.keys()
	startup_auxiliary_publication_chunks.clear()
	for key_value in keys:
		if not key_value is Vector2i: continue
		var key: Vector2i=key_value
		if desired_gameplay_chunks.has(key) or retained_gameplay_chunks.has(key): continue
		pending_gameplay_chunks.erase(key)
		pending_gameplay_chunk_order.erase(key)
		if published_gameplay_chunks.erase(key): notify_navigation_chunk_unloaded(key)
	# Navigation has consumed the collision-backed snapshot. Retire the temporary
	# native viewers only now; view-distance expansion itself is not proof that
	# their distant town footprints are no longer needed by startup capture.
	startup_auxiliary_cleanup_requested = true
	startup_auxiliary_cleanup_frames_remaining = 2


func abort_startup_auxiliary_publication_chunks() -> void:
	# A failed/cancelled load has no navigation consumer left. Drop temporary
	# demand and its native viewers immediately, while preserving chunks still
	# owned by ordinary player or retained-region demand.
	var keys: Array=startup_auxiliary_publication_chunks.keys()
	startup_auxiliary_publication_chunks.clear()
	for key_value in keys:
		if not key_value is Vector2i: continue
		var key: Vector2i=key_value
		if desired_gameplay_chunks.has(key) or retained_gameplay_chunks.has(key): continue
		pending_gameplay_chunks.erase(key)
		pending_gameplay_chunk_order.erase(key)
		if published_gameplay_chunks.erase(key): notify_navigation_chunk_unloaded(key)
	clear_startup_auxiliary_viewers()

func advance_secondary_viewer_admissions() -> void:
	var pending_tasks := voxel_engine_pending_task_count()
	secondary_viewer_peak_pending_tasks = maxi(secondary_viewer_peak_pending_tasks, pending_tasks)
	if main != null and not bool(main.get("startup_loading_active")) and not bool(main.get("runtime_loading_active")):
		if not secondary_viewer_runtime_measurement_started:
			secondary_viewer_runtime_measurement_started = true
			secondary_viewer_runtime_peak_pending_tasks = pending_tasks
			secondary_viewer_runtime_attach_counts = {"startup": 0, "retained": 0, "handoff": 0}
		else:
			secondary_viewer_runtime_peak_pending_tasks = maxi(secondary_viewer_runtime_peak_pending_tasks, pending_tasks)
	if not secondary_viewer_terminal_failure.is_empty():
		secondary_viewer_admission_reason = "site_admission_failed"
		return
	if secondary_viewer_admissions.is_empty():
		secondary_viewer_admission_reason = "idle"
		return
	if pending_tasks > SECONDARY_VIEWER_MAX_PENDING_NATIVE_TASKS:
		secondary_viewer_admission_reason = "native_task_backpressure"
		return
	if _secondary_viewer_collision_coverage_pending():
		secondary_viewer_admission_reason = "secondary_collision_coverage"
		return
	var pending: Array = secondary_viewer_admissions.values()
	pending.sort_custom(func(a: Dictionary, b: Dictionary):
		return int(a.get("priority", 0)) < int(b.get("priority", 0)) \
				if int(a.get("priority", 0)) != int(b.get("priority", 0)) \
				else int(a.get("sequence", 0)) < int(b.get("sequence", 0)))
	var entry: Dictionary = pending[0]
	var identity := String(entry.get("identity", ""))
	var admission: Dictionary = site_gate.request_cells(SITE_GATE_SCRIPT.footprint(
		entry.get("position", Vector3.ZERO), int(entry.get("viewDistance", STARTUP_VIEW_DISTANCE))))
	if admission.get("status") == "failed":
		_record_secondary_viewer_terminal_failure(entry,
			String(admission.get("reason", "secondary_viewer_site_admission_failed")), "cells")
		return
	if admission.get("status") != "ready":
		secondary_viewer_admission_reason = "site_admission_%s" % String(admission.get("status", "pending"))
		return
	# Demand retirement can free a staged viewer between queue selection and
	# admission. Validate the untyped reference first: assigning a freed Object
	# to a typed VoxelViewer itself emits an engine error before a guard can run.
	var auxiliary_value = entry.get("viewer")
	if not is_instance_valid(auxiliary_value):
		secondary_viewer_admissions.erase(identity)
		secondary_viewer_admission_reason = "stale_secondary_viewer_retired"
		return
	var auxiliary: VoxelViewer = auxiliary_value
	if not site_gate.request_viewer(auxiliary,
			entry.get("position", Vector3.ZERO), int(entry.get("viewDistance", STARTUP_VIEW_DISTANCE))):
		var site_failure := String(site_gate.failure_reason()) if site_gate.has_method("failure_reason") else ""
		if not site_failure.is_empty():
			_record_secondary_viewer_terminal_failure(entry, site_failure, "viewer")
			return
		secondary_viewer_admission_reason = "site_viewer_admission_pending"
		return
	_mark_secondary_viewer_attached(auxiliary, Engine.get_physics_frames())
	_record_native_viewer_request(kind_for_secondary_admission(entry),
			int(entry.get("viewDistance", STARTUP_VIEW_DISTANCE)), entry.get("position", Vector3.ZERO))
	secondary_viewer_admissions.erase(identity)
	var kind := String(entry.get("kind", ""))
	secondary_viewer_attach_counts[kind] = int(secondary_viewer_attach_counts.get(kind, 0)) + 1
	if secondary_viewer_runtime_measurement_started:
		secondary_viewer_runtime_attach_counts[kind] = int(secondary_viewer_runtime_attach_counts.get(kind, 0)) + 1
	if kind == "retained":
		var metadata: Dictionary = entry.get("metadata", {})
		var group_value = metadata.get("group")
		if group_value is Vector2i:
			retained_chunk_viewers[group_value] = auxiliary
			retained_viewer_attached_frame[group_value] = Engine.get_physics_frames()
	secondary_viewer_admission_reason = "%s_attached" % kind

func _record_secondary_viewer_terminal_failure(entry: Dictionary, reason: String, stage: String) -> void:
	var normalized_reason := reason.strip_edges()
	if normalized_reason.is_empty():
		normalized_reason = "secondary_viewer_site_admission_failed"
	if secondary_viewer_terminal_failure.is_empty():
		secondary_viewer_terminal_failure = {
			"status": "failed",
			"reason": normalized_reason,
			"stage": stage,
			"identity": String(entry.get("identity", "")),
			"kind": String(entry.get("kind", "secondary")),
			"position": entry.get("position", Vector3.ZERO),
			"viewDistance": int(entry.get("viewDistance", STARTUP_VIEW_DISTANCE)),
			"chunks": (entry.get("chunks", []) as Array).duplicate()
		}
	var identity := String(entry.get("identity", ""))
	var auxiliary = entry.get("viewer")
	if is_instance_valid(auxiliary):
		if site_gate != null and site_gate.has_method("remove_viewer"):
			site_gate.remove_viewer(auxiliary)
		auxiliary.queue_free()
	secondary_viewer_admissions.erase(identity)
	secondary_viewer_admission_reason = "site_admission_failed"

func secondary_viewer_admission_failure() -> Dictionary:
	return secondary_viewer_terminal_failure.duplicate(true)

func kind_for_secondary_admission(entry: Dictionary) -> String:
	return String(entry.get("kind", "secondary"))

func _record_native_viewer_request(kind: String, view_distance: int, position: Vector3) -> void:
	# The plugin starts its work asynchronously.  Sampling on later process
	# frames captures its true peak rather than falsely calling the zero at the
	# moment of request a budget guarantee.
	if active_native_viewer_workload_index >= 0 and active_native_viewer_workload_index < native_viewer_workloads.size():
		var previous := native_viewer_workloads[active_native_viewer_workload_index]
		if not bool(previous.get("settled", false)):
			previous["superseded"] = true
			native_viewer_workloads[active_native_viewer_workload_index] = previous
	var row := {
		"kind": kind,
		"viewDistance": view_distance,
		"requestMsec": Time.get_ticks_msec(),
		"position": position,
		"pendingTasksAtRequest": voxel_engine_pending_task_count(),
		"peakPendingTasks": 0,
		"observedWork": false,
		"settled": false,
		"settledMsec": 0,
		"superseded": false
	}
	native_viewer_workloads.append(row)
	if native_viewer_workloads.size() > 48:
		native_viewer_workloads.pop_front()
	active_native_viewer_workload_index = native_viewer_workloads.size() - 1

func observe_native_viewer_workload() -> void:
	if active_native_viewer_workload_index < 0 or active_native_viewer_workload_index >= native_viewer_workloads.size():
		return
	var row := native_viewer_workloads[active_native_viewer_workload_index]
	if bool(row.get("settled", false)):
		return
	var pending := voxel_engine_pending_task_count()
	if pending > 0:
		row["observedWork"] = true
		row["peakPendingTasks"] = maxi(int(row.get("peakPendingTasks", 0)), pending)
		native_viewer_workloads[active_native_viewer_workload_index] = row
		return
	if bool(row.get("observedWork", false)):
		row["settled"] = true
		row["settledMsec"] = Time.get_ticks_msec()
		row["drainMs"] = int(row["settledMsec"]) - int(row["requestMsec"])
		native_viewer_workloads[active_native_viewer_workload_index] = row

func _primary_handoff_pending_or_covering(held: Array) -> bool:
	for record_value in startup_auxiliary_viewers:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value
		if not bool(record.get("primaryHandoff", false)):
			continue
		var holder: VoxelViewer = record.get("viewer")
		if not is_instance_valid(holder):
			continue
		if not holder.is_inside_tree():
			return true
		if not secondary_viewer_handoff_mature(record, Engine.get_physics_frames()):
			return true
		var covers := true
		for chunk_value in held:
			if chunk_value is Vector2i and not _viewer_covers_chunk_at(holder, chunk_value, holder.global_position):
				covers = false
				break
		if covers:
			return true
	for entry_value in secondary_viewer_admissions.values():
		var entry: Dictionary = entry_value
		if String(entry.get("kind", "")) == "handoff":
			return true
	return false

func region_publication_readiness(bounds: Rect2i) -> Dictionary:
	const Regions := preload("res://scripts/world/WorldStreamingCoordinator.gd")
	var revision := "%s:%d" % [configured_seed,last_volume_revision]
	if not secondary_viewer_terminal_failure.is_empty():
		return {"status":"failed","reason":"startup_auxiliary_terrain_admission_failed",
			"missingChunks":[],"sourceRevision":revision,
			"admissionFailure":secondary_viewer_terminal_failure.duplicate(true)}
	if not authority_ready or not generation_context_current():
		return {"status":"pending","reason":"terrain_generation_pending","missingChunks":[],"sourceRevision":revision}
	var volume = volume_service()
	# Reject edits awaiting native publication only when their XZ section can
	# affect this query. A distant structure edit must not deadlock an unrelated
	# player/navigation tile merely because its native area is not loaded yet.
	# Callers that need a halo (navigation capture) pass it in their bounds.
	if volume == null or int(volume.get("revision")) != last_volume_revision \
			or pending_edit_sections_intersect_bounds(bounds):
		return {"status":"pending","reason":"terrain_edits_pending","missingChunks":[],"sourceRevision":revision}
	var keys: Array = Regions.chunks_for_bounds(bounds)
	if keys.is_empty():
		return {"status":"failed","reason":"invalid_terrain_region_bounds","missingChunks":[],"sourceRevision":revision}
	var missing: Array[Vector2i] = []
	for key: Vector2i in keys:
		if not published_gameplay_chunks.has(key) or pending_gameplay_chunks.has(key): missing.append(key)
	return {"status":"ready" if missing.is_empty() else "pending",
		"reason":"" if missing.is_empty() else "terrain_publication_pending",
		"missingChunks":missing, "sourceRevision":revision}

func pending_edit_sections_intersect_bounds(bounds: Rect2i) -> bool:
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return false
	for section_value in pending_edit_sections:
		if not section_value is Vector3i:
			# An invalid pending key has no safe locality proof.
			return true
		var section: Vector3i = section_value
		var section_bounds := Rect2i(Vector2i(section.x * SECTION_SIZE, section.z * SECTION_SIZE),
			Vector2i.ONE * SECTION_SIZE)
		if section_bounds.intersects(bounds):
			return true
	return false


func pending_edit_section_diagnostics(limit := 16) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var section_keys: Array = pending_edit_sections.keys()
	section_keys.sort_custom(func(a: Vector3i,b: Vector3i):
		return a.x < b.x if a.x != b.x else (a.z < b.z if a.z != b.z else a.y < b.y))
	for section_value in section_keys:
		if rows.size() >= maxi(0,limit): break
		if not section_value is Vector3i:
			rows.append({"section":str(section_value),"valid":false})
			continue
		var section: Vector3i = section_value
		var changes: Dictionary = pending_edit_sections.get(section,{})
		var min_cell := Vector3i(2147483647,2147483647,2147483647)
		var max_cell := Vector3i(-2147483647,-2147483647,-2147483647)
		for cell_value in changes:
			if not cell_value is Vector3i: continue
			var cell: Vector3i = cell_value
			min_cell=Vector3i(mini(min_cell.x,cell.x),mini(min_cell.y,cell.y),mini(min_cell.z,cell.z))
			max_cell=Vector3i(maxi(max_cell.x,cell.x),maxi(max_cell.y,cell.y),maxi(max_cell.z,cell.z))
		var has_cells := min_cell.x != 2147483647
		var size := max_cell-min_cell+Vector3i.ONE if has_cells else Vector3i.ZERO
		var editable := false
		if terrain != null and has_cells:
			editable=bool(terrain.get_voxel_tool().is_area_editable(AABB(Vector3(min_cell),Vector3(size))))
		rows.append({"section":section,"changeCount":changes.size(),"minCell":min_cell if has_cells else Vector3i.ZERO,
			"maxCell":max_cell if has_cells else Vector3i.ZERO,"editable":editable})
	return rows
var site_traversal_waiting := false
var site_traversal_pending_request := {}
var site_traversal_last_proof := {}
var site_traversal_last_poll_usec := 0

func setup(main_node) -> Dictionary:
	main = main_node
	collision_owner_generation += 1
	configured_seed = String(main.get("seed_text"))
	if not required_classes_available():
		return {"ok": false, "reason": "voxel_tools_runtime_classes_missing"}
	var generation_state := build_generation_state()
	if not bool(generation_state.get("ok", false)):
		return generation_state
	apply_generation_tracking(generation_state)

	terrain = VoxelTerrain.new()
	terrain.automatic_loading_enabled = false
	terrain.name = "VoxelTerrainAuthority"
	terrain.set_meta("kind", "terrain")
	terrain.set_meta("geometry_source", "voxel_sdf_authority")
	terrain.set_meta("collision_source", "VoxelMesherTransvoxel")
	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	terrain.set_format(format)
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	mesher.transitions_enabled = false
	mesher.mesh_optimization_enabled = false
	terrain.mesher = mesher
	terrain.generator = generator
	terrain.generate_collisions = true
	terrain.collision_layer = TERRAIN_COLLISION_LAYER
	terrain.collision_mask = 0
	terrain.mesh_block_size = NATIVE_MESH_BLOCK_SIZE_CELLS
	terrain.max_view_distance = 128
	apply_startup_vertical_bounds()
	terrain.scale = Vector3.ONE * CELL
	var material := ShaderMaterial.new()
	material.shader = TERRAIN_SHADER
	terrain.material_override = material
	add_child(terrain)
	terrain_section_shadow_publisher = TERRAIN_SECTION_SHADOW_PUBLISHER.new()
	var shadow_setup: Dictionary = terrain_section_shadow_publisher.setup(self)
	if shadow_setup.get("status") != "ready":
		return {"ok":false, "reason":"terrain_section_shadow_publisher_setup_failed", "detail":shadow_setup}
	site_gate = SITE_GATE_SCRIPT.new()
	site_gate.setup(self,terrain,main.structure_system.citadel_terrain_admission,main.world_generation_system)

	viewer = VoxelViewer.new()
	viewer.name = "VoxelTerrainViewer"
	viewer.view_distance = STARTUP_VIEW_DISTANCE
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	update_viewer_position()
	terrain.mesh_block_entered.connect(on_mesh_block_entered)
	terrain.mesh_block_exited.connect(on_mesh_block_exited)
	authority_ready = true
	return {"ok": true, "backend": "VoxelTerrain", "mesher": "VoxelMesherTransvoxel"}

func reset_for_current_seed_staged() -> Dictionary:
	if main == null:
		return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_reset_main_missing")
	if terrain == null or not is_instance_valid(terrain):
		return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_reset_authority_missing")
	var next_seed := String(main.get("seed_text"))
	if next_seed.strip_edges() == "":
		return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_reset_seed_missing")
	if generation_context_current() and authority_ready:
		return STARTUP_READINESS_RESULT_SCRIPT.ready({}, {
			"seed": configured_seed,
			"resetMode": "already_current",
			"terrainInstanceId": terrain.get_instance_id()
		})
	var generation_state := build_generation_state()
	if not bool(generation_state.get("ok", false)):
		return STARTUP_READINESS_RESULT_SCRIPT.failed(
			String(generation_state.get("reason", "voxel_terrain_generation_state_failed"))
		)
	var previous_seed := configured_seed
	var terrain_instance_id := terrain.get_instance_id()
	var previous_mesh_blocks := published_mesh_blocks.size()
	var previous_gameplay_chunks := published_gameplay_chunks.size()
	_retire_mesh_preparation_viewer()
	clear_retained_gameplay_chunks()
	var invalidated_chunks := invalidate_gameplay_publication()
	if site_gate != null: site_gate.stop()
	clear_startup_auxiliary_viewers()
	secondary_viewer_terminal_failure.clear()
	authority_ready = false
	set_process(false)
	set_physics_process(false)
	if viewer != null and is_instance_valid(viewer):
		viewer.requires_visuals = false
		viewer.requires_collisions = false
	terrain.automatic_loading_enabled = false
	await get_tree().physics_frame
	# Voxel generation and meshing are native asynchronous work.  Swapping the
	# script generator before that work has stopped can leave a task holding the
	# previous generator while the terrain is already configured for a new seed.
	# The Voxel Tools documentation explicitly warns that changing a script while
	# worker threads are using it is undefined behavior, so preserve the loading
	# screen and wait for a stable idle boundary before the replacement.
	var task_drain_result := await wait_for_seed_reset_task_drain()
	if not bool(task_drain_result.get("ok", false)):
		return task_drain_result
	var reset_started_usec := Time.get_ticks_usec()
	var next_generator = generation_state.get("generator")
	terrain.generator = next_generator
	var reset_map_usec := Time.get_ticks_usec() - reset_started_usec
	if terrain.generator != next_generator:
		return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_generator_replacement_failed", {}, [], {
			"previousSeed": previous_seed,
			"nextSeed": next_seed,
			"terrainInstanceId": terrain_instance_id,
			"resetMapUsec": reset_map_usec
		})
	published_mesh_blocks.clear()
	mesh_block_revisions.clear()
	mesh_publication_serial += 1
	pending_edit_sections.clear()
	gameplay_chunk_edit_revisions.clear()
	collision_owner_generation += 1
	edit_batches_applied = 0
	collision_probe_attempts = 0
	collision_probe_passes = 0
	apply_generation_tracking(generation_state)
	configured_seed = next_seed
	apply_startup_vertical_bounds()
	site_gate = SITE_GATE_SCRIPT.new()
	site_gate.setup(self,terrain,main.structure_system.citadel_terrain_admission,main.world_generation_system)
	if viewer != null and is_instance_valid(viewer):
		viewer.requires_visuals = true
		viewer.requires_collisions = true
		viewer.view_distance = STARTUP_VIEW_DISTANCE
	primary_viewer_request_cell = Vector2i(2147483000,2147483000)
	primary_viewer_request_distance = -1
	primary_unpublished_collision_request_key = ""
	view_distance_expansion_elapsed = 0.0
	view_distance_expansion_requested = false
	final_expansion_quiet_frames = 0
	update_viewer_position()
	authority_ready = true
	set_process(true)
	set_physics_process(true)
	await get_tree().process_frame
	return STARTUP_READINESS_RESULT_SCRIPT.ready({}, {
		"previousSeed": previous_seed,
		"seed": configured_seed,
		"resetMode": "in_place_generator_reload",
		"terrainInstanceId": terrain_instance_id,
		"terrainInstancePreserved": terrain.get_instance_id() == terrain_instance_id,
		"previousPublishedMeshBlocks": previous_mesh_blocks,
		"previousPublishedGameplayChunks": previous_gameplay_chunks,
		"invalidatedGameplayChunks": invalidated_chunks,
		"resetMapUsec": reset_map_usec,
		"taskDrain": task_drain_result.get("metrics", {})
	})

func wait_for_seed_reset_task_drain() -> Dictionary:
	var drain_started_usec := Time.get_ticks_usec()
	var checks := 0
	var quiet_frames := 0
	var peak_pending_tasks := 0
	var last_pending_tasks := -1
	while quiet_frames < SEED_RESET_REQUIRED_QUIET_FRAMES:
		if terrain == null or not is_instance_valid(terrain):
			return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_reset_authority_missing")
		var pending_tasks := voxel_engine_pending_task_count()
		peak_pending_tasks = maxi(peak_pending_tasks, pending_tasks)
		checks += 1
		if pending_tasks <= 0:
			quiet_frames += 1
		else:
			quiet_frames = 0
		var elapsed_seconds := float(Time.get_ticks_usec() - drain_started_usec) / 1000000.0
		if elapsed_seconds >= SEED_RESET_TASK_DRAIN_TIMEOUT_SECONDS:
			return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_seed_reset_task_drain_timeout", {}, [], {
				"pendingTasks": pending_tasks,
				"peakPendingTasks": peak_pending_tasks,
				"checks": checks,
				"elapsedMs": elapsed_seconds * 1000.0
			})
		if quiet_frames >= SEED_RESET_REQUIRED_QUIET_FRAMES:
			break
		if main != null and is_instance_valid(main) and main.has_method("startup_loading_yield") \
				and (checks == 1 or pending_tasks != last_pending_tasks or checks % 30 == 0):
			await main.call("startup_loading_yield", "Retiring previous terrain: %d tasks" % pending_tasks, "terrain_authority", "pending", {
				"pendingTasks": pending_tasks,
				"peakPendingTasks": peak_pending_tasks,
				"checks": checks
			})
		else:
			await get_tree().process_frame
		last_pending_tasks = pending_tasks
	return STARTUP_READINESS_RESULT_SCRIPT.ready({}, {
		"pendingTasks": 0,
		"peakPendingTasks": peak_pending_tasks,
		"checks": checks,
		"quietFrames": quiet_frames,
		"elapsedMs": float(Time.get_ticks_usec() - drain_started_usec) / 1000.0
	})

func build_generation_state() -> Dictionary:
	if main == null:
		return {"ok": false, "reason": "voxel_terrain_generation_main_missing"}
	var structures = main.get("structure_system")
	if structures == null:
		return {"ok":false,"reason":"terrain_structure_owner_missing"}
	var admission = structures.citadel_terrain_admission
	if admission.world_seed != String(main.seed_text) or admission.profile_store.world_seed() != String(main.seed_text):
		if terrain != null: terrain.automatic_loading_enabled = false
		return {"ok":false,"reason":"citadel_admission_seed_mismatch"}
	var inputs: Dictionary = admission.finalize_town_inputs(main.town_region_cache)
	if inputs.status != "ready":
		if terrain != null: terrain.automatic_loading_enabled = false
		return {"ok":false,"reason":inputs.reason}
	main.world_generation_system.bind_generated_site_profile_store(structures.citadel_terrain_admission.profile_store)
	var context = CONTEXT_SCRIPT.new()
	context.setup_from_main(main,inputs.towns)
	var signatures := {}
	for cell_value in context.initial_terrain_edits.keys():
		var state: Dictionary = context.initial_terrain_edits[cell_value]
		signatures[cell_value] = edit_signature(state)
	var next_generator = GENERATOR_SCRIPT.new()
	next_generator.setup(context)
	var service = volume_service()
	return {
		"ok": true,
		"generator": next_generator,
		"editSignatures": signatures,
		"volumeRevision": int(service.get("revision")) if service != null else -1
	}

func apply_generation_tracking(generation_state: Dictionary) -> void:
	generator = generation_state.get("generator")
	var signatures_value = generation_state.get("editSignatures", {})
	applied_edit_signatures = (signatures_value as Dictionary).duplicate(true) if signatures_value is Dictionary else {}
	last_volume_revision = int(generation_state.get("volumeRevision", -1))

func generation_context_current() -> bool:
	return main != null and configured_seed == String(main.seed_text) and site_gate != null and site_gate.current() \
		and main.structure_system.citadel_terrain_admission.world_seed == configured_seed

func admit_gameplay_chunk(chunk_key: Vector2i) -> Dictionary:
	if site_gate == null: return {"status":"failed","reason":"terrain_site_gate_missing"}
	return site_gate.request_cells(Rect2i(chunk_key*GAME_CHUNK_SIZE,Vector2i.ONE*GAME_CHUNK_SIZE).grow(2))

func wait_for_site_admission(chunk_keys: Array) -> Dictionary:
	# Source preparation precedes the existing chunk/collision readiness clocks.
	# Keep the real loading overlay responsive; do not widen their timeouts.
	while true:
		if not is_instance_valid(main) or main.get("shutdown_requested") == true:
			return STARTUP_READINESS_RESULT_SCRIPT.failed("startup_cancelled")
		var pending := false
		for chunk_key: Vector2i in chunk_keys:
			var result := admit_gameplay_chunk(chunk_key)
			if result.status == "failed": return STARTUP_READINESS_RESULT_SCRIPT.failed(result.reason)
			pending = pending or result.status != "ready"
		var player_value = main.get("player")
		if player_value is Node3D:
			var result: Dictionary = site_gate.request_cells(SITE_GATE_SCRIPT.footprint(player_value.global_position,STARTUP_VIEW_DISTANCE))
			if result.status == "failed": return STARTUP_READINESS_RESULT_SCRIPT.failed(result.reason)
			pending = pending or result.status != "ready"
		if not pending: return STARTUP_READINESS_RESULT_SCRIPT.ready({})
		var admission = main.structure_system.citadel_terrain_admission
		await main.startup_loading_yield("Preparing landmark foundations", "citadel_terrain", "pending",admission.stats())
	return STARTUP_READINESS_RESULT_SCRIPT.failed("site_admission_interrupted")

func invalidate_gameplay_publication() -> int:
	var invalidated := published_gameplay_chunks.size()
	for chunk_value in published_gameplay_chunks.keys():
		if chunk_value is Vector2i:
			notify_navigation_chunk_unloaded(chunk_value)
	desired_gameplay_chunks.clear()
	pending_gameplay_chunks.clear()
	pending_gameplay_chunk_order.clear()
	published_gameplay_chunks.clear()
	clear_foreground_collision_demand()
	primary_unpublished_collision_request_key = ""
	return invalidated

func full_vertical_cell_bounds() -> Vector2i:
	if main == null:
		return Vector2i(STARTUP_VERTICAL_MIN_CELL, STARTUP_VERTICAL_MAX_CELL)
	var world_generation = main.get("world_generation_system")
	if world_generation == null:
		return Vector2i(STARTUP_VERTICAL_MIN_CELL, STARTUP_VERTICAL_MAX_CELL)
	return Vector2i(
		int(world_generation.call("world_bottom_cell_y")) - COLLISION_MESH_VERTICAL_MARGIN_CELLS,
		int(world_generation.call("world_top_cell_y")) + COLLISION_MESH_VERTICAL_MARGIN_CELLS
	)

func apply_vertical_cell_bounds(min_cell: int, max_cell: int) -> void:
	if terrain == null or main == null:
		return
	var full_bounds := full_vertical_cell_bounds()
	var bottom_cell := clampi(min_cell, full_bounds.x, full_bounds.y)
	var top_cell := clampi(max_cell, bottom_cell, full_bounds.y)
	var terrain_bounds := terrain.bounds
	terrain_bounds.position.y = float(bottom_cell)
	terrain_bounds.size.y = float(top_cell - bottom_cell + 1)
	terrain.bounds = terrain_bounds

func apply_startup_vertical_bounds() -> void:
	var full_bounds := full_vertical_cell_bounds()
	apply_vertical_cell_bounds(
		maxi(full_bounds.x, STARTUP_VERTICAL_MIN_CELL),
		mini(full_bounds.y, STARTUP_VERTICAL_MAX_CELL)
	)

static func gameplay_chunk_collision_probe_positions(chunk_key: Vector2i) -> Array[Vector3]:
	var positions: Array[Vector3] = []
	var origin_x := float(chunk_key.x * GAME_CHUNK_SIZE) * CELL
	var origin_z := float(chunk_key.y * GAME_CHUNK_SIZE) * CELL
	var span := float(GAME_CHUNK_SIZE) * CELL
	for offset_value in GAMEPLAY_CHUNK_COLLISION_PROBE_OFFSETS:
		var offset: Vector2 = offset_value
		positions.append(Vector3(origin_x + span * offset.x, 0.0, origin_z + span * offset.y))
	return positions

static func startup_collision_surface_cell_bounds(chunk_keys: Array, world_generation, volume) -> Vector2i:
	var min_surface_cell := 2147483000
	var max_surface_cell := -2147483000
	var can_project := false
	if volume != null:
		can_project = volume.has_method("terrain_mesh_surface_projection_for_cell")
	var can_fallback := false
	if world_generation != null:
		can_fallback = world_generation.has_method("surface_y_at")
	for key_value in chunk_keys:
		if not (key_value is Vector2i):
			continue
		var chunk_key: Vector2i = key_value
		for position in gameplay_chunk_collision_probe_positions(chunk_key):
			var surface_y: Variant = null
			if can_project:
				var cell := Vector3i(floori(position.x / CELL), 0, floori(position.z / CELL))
				var projection: Dictionary = volume.call("terrain_mesh_surface_projection_for_cell", cell)
				if bool(projection.get("found", false)):
					surface_y = float((projection.get("position", Vector3.ZERO) as Vector3).y)
			if surface_y == null and can_fallback:
				surface_y = float(world_generation.call("surface_y_at", position))
			if surface_y == null:
				continue
			var surface_cell := floori(float(surface_y) / CELL)
			min_surface_cell = mini(min_surface_cell, surface_cell)
			max_surface_cell = maxi(max_surface_cell, surface_cell)
	return Vector2i(min_surface_cell, max_surface_cell)

func configure_startup_collision_bounds(chunk_keys: Array, auxiliary_chunk_keys: Array = []) -> void:
	clear_startup_auxiliary_viewers()
	secondary_viewer_terminal_failure.clear()
	startup_required_gameplay_chunks = chunk_keys.duplicate()
	secondary_viewer_peak_pending_tasks = voxel_engine_pending_task_count()
	secondary_viewer_attach_counts["startup"] = 0
	secondary_viewer_runtime_measurement_started = false
	secondary_viewer_runtime_peak_pending_tasks = 0
	secondary_viewer_runtime_attach_counts = {"startup": 0, "retained": 0, "handoff": 0}
	if terrain == null or main == null or chunk_keys.is_empty():
		return
	var world_generation = main.get("world_generation_system")
	if world_generation == null or not world_generation.has_method("surface_y_at"):
		return
	var coverage_chunks := {}
	for key_value in chunk_keys:
		if key_value is Vector2i: coverage_chunks[key_value]=true
	for key_value in auxiliary_chunk_keys:
		if key_value is Vector2i: coverage_chunks[key_value]=true
	var publication_chunks := startup_edit_publication_chunks(coverage_chunks.keys())
	for key_value in publication_chunks:
		if not key_value is Vector2i: continue
		startup_auxiliary_publication_chunks[key_value]=true
		if not published_gameplay_chunks.has(key_value): queue_pending_gameplay_chunk(key_value)
	# Startup bounds must cover the same authoritative positions used to prove
	# chunk collision. Sampling only a chunk centre can exclude a steep corner
	# after native work has already gone idle, leaving a permanent 24/25-ready
	# startup. The terrain-volume projection remains primary; the generation
	# facade is retained only for positions without a projected terrain surface.
	var surface_bounds := startup_collision_surface_cell_bounds(publication_chunks, world_generation, volume_service())
	if surface_bounds.x > surface_bounds.y:
		return
	apply_vertical_cell_bounds(surface_bounds.x - 16, surface_bounds.y + 16)
	configure_startup_auxiliary_viewers(publication_chunks, world_generation)


func startup_edit_publication_chunks(required_chunks: Array) -> Array:
	var selected := {}
	var halo := {}
	for key_value in required_chunks:
		if not key_value is Vector2i: continue
		var key: Vector2i = key_value
		selected[key]=true
		for dz in range(-1,2):
			for dx in range(-1,2): halo[key+Vector2i(dx,dz)]=true
	var service = volume_service()
	if service != null:
		var edits_value = service.get("edited_cells")
		if edits_value is Dictionary:
			for cell_value in (edits_value as Dictionary):
				if not cell_value is Vector3i: continue
				var state: Dictionary = edits_value[cell_value] if edits_value[cell_value] is Dictionary else {}
				if not state_affects_terrain_mesh(service,state): continue
				var edit_chunk := game_chunk_for_cell(cell_value)
				if halo.has(edit_chunk): selected[edit_chunk]=true
	var result: Array[Vector2i] = []
	for key_value in selected: result.append(key_value)
	result.sort_custom(func(a: Vector2i,b: Vector2i): return a.x < b.x if a.x != b.x else a.y < b.y)
	return result


func configure_startup_auxiliary_viewers(chunk_keys: Array, world_generation) -> void:
	if viewer == null or not is_instance_valid(viewer):
		return
	var components := connected_gameplay_chunk_components(chunk_keys)
	for component_value in components:
		var component: Array = component_value
		if primary_viewer_covers_component(component):
			continue
		for spec_value in auxiliary_viewer_specs_for_component(component, world_generation):
			var spec: Dictionary = spec_value
			var auxiliary := VoxelViewer.new()
			auxiliary.name = "StartupAuxiliaryVoxelViewer_%d" % startup_auxiliary_viewers_created
			auxiliary.view_distance = int(spec.get("viewDistance", STARTUP_VIEW_DISTANCE))
			auxiliary.requires_visuals = true
			auxiliary.requires_collisions = true
			auxiliary.set_meta("startup_auxiliary", true)
			var record := {
				"viewer": auxiliary,
				"attachedFrame": -1,
				"requiredDistance": float(spec.get("requiredDistance", auxiliary.view_distance)),
				"chunks": (spec.get("chunks", []) as Array).duplicate(),
				"secondaryKind": "startup"
			}
			startup_auxiliary_viewers.append(record)
			_stage_secondary_viewer("startup:%d" % auxiliary.get_instance_id(), "startup", auxiliary,
				spec.get("position", Vector3.ZERO), auxiliary.view_distance, record.chunks, 1)
			startup_auxiliary_viewers_created += 1


func connected_gameplay_chunk_components(chunk_keys: Array) -> Array:
	var remaining := {}
	for key_value in chunk_keys:
		if key_value is Vector2i:
			remaining[key_value] = true
	var components: Array = []
	while not remaining.is_empty():
		var ordered_keys: Array = remaining.keys()
		ordered_keys.sort_custom(func(a: Vector2i, b: Vector2i):
			return a.x < b.x if a.x != b.x else a.y < b.y
		)
		var seed: Vector2i = ordered_keys[0]
		var pending: Array[Vector2i] = [seed]
		var component: Array[Vector2i] = []
		remaining.erase(seed)
		while not pending.is_empty():
			var current: Vector2i = pending.pop_front()
			component.append(current)
			for neighbor in [
				current + Vector2i.LEFT,
				current + Vector2i.RIGHT,
				current + Vector2i.UP,
				current + Vector2i.DOWN
			]:
				if remaining.erase(neighbor):
					pending.append(neighbor)
		component.sort_custom(func(a: Vector2i, b: Vector2i):
			return a.x < b.x if a.x != b.x else a.y < b.y
		)
		components.append(component)
	return components


func primary_viewer_covers_component(component: Array) -> bool:
	if viewer == null or not is_instance_valid(viewer) or not viewer.is_inside_tree() or component.is_empty():
		return false
	var available_distance := maxf(0.0, float(viewer.view_distance) - CELL * float(COLLISION_PUBLICATION_VIEWER_MARGIN_CELLS))
	var viewer_xz := Vector2(viewer.global_position.x, viewer.global_position.z)
	var half_chunk_diagonal := float(GAME_CHUNK_SIZE) * CELL * sqrt(2.0) * 0.5
	for key_value in component:
		if not (key_value is Vector2i):
			continue
		var chunk_key: Vector2i = key_value
		var center := Vector2(
			(float(chunk_key.x * GAME_CHUNK_SIZE) + float(GAME_CHUNK_SIZE) * 0.5) * CELL,
			(float(chunk_key.y * GAME_CHUNK_SIZE) + float(GAME_CHUNK_SIZE) * 0.5) * CELL
		)
		if viewer_xz.distance_to(center) + half_chunk_diagonal > available_distance:
			return false
	return true

func _viewer_covers_chunk_at(native_viewer: VoxelViewer, chunk_key: Vector2i, position: Vector3) -> bool:
	if not is_instance_valid(native_viewer) or not native_viewer.is_inside_tree() or native_viewer.is_queued_for_deletion(): return false
	if not native_viewer.requires_collisions or not native_viewer.requires_visuals: return false
	return viewer_position_covers_gameplay_chunk(chunk_key,position,int(native_viewer.view_distance))

func _retained_viewer_covers_chunk(chunk_key: Vector2i) -> bool:
	var group := Vector2i(floori(float(chunk_key.x)/2.0),floori(float(chunk_key.y)/2.0))
	var auxiliary: VoxelViewer = retained_chunk_viewers.get(group)
	if not is_instance_valid(auxiliary): return false
	if Engine.get_physics_frames()-int(retained_viewer_attached_frame.get(group,Engine.get_physics_frames())) < 2: return false
	return _viewer_covers_chunk_at(auxiliary,chunk_key,auxiliary.global_position)

func _preserve_retained_primary_coverage(next_position: Vector3) -> bool:
	if not is_instance_valid(viewer) or not viewer.is_inside_tree(): return true
	# During ordinary play the primary viewer is the single native owner of the
	# player's local terrain. Retained demand must not clone its complete radius
	# behind every grid move; the collision proof remains fail-closed until the
	# primary's current local receipt exists. Startup/replacement loading keeps
	# its explicit handoff lifecycle below.
	if main != null and not bool(main.get("startup_loading_active")) and not bool(main.get("runtime_loading_active")):
		return true
	var old_position := viewer.global_position
	if next_position == old_position: return true
	var held: Array = []
	var needs_handoff := false
	for key: Vector2i in retained_gameplay_chunks:
		if not published_gameplay_chunks.has(key) or not _viewer_covers_chunk_at(viewer,key,old_position): continue
		held.append(key)
		if _viewer_covers_chunk_at(viewer,key,next_position) or _retained_viewer_covers_chunk(key): continue
		var covered := false
		for record: Dictionary in startup_auxiliary_viewers:
			var auxiliary: VoxelViewer = record.get("viewer")
			if not is_instance_valid(auxiliary) or not auxiliary.is_inside_tree(): continue
			if not _viewer_covers_chunk_at(auxiliary,key,auxiliary.global_position): continue
			# Keep the old primary footprint until its equivalent owner has
			# participated in two physics frames. No new terrain area is requested.
			if not secondary_viewer_handoff_mature(record, Engine.get_physics_frames()): return false
			covered = true
			break
		if not covered: needs_handoff = true
	if not needs_handoff: return true
	# The old primary stays authoritative until one bounded secondary handoff is
	# attached and has survived physics.  Do not clone a 96m viewer on every
	# rendered movement update while the first clone is still pending.
	if _primary_handoff_pending_or_covering(held):
		return false
	var bridge := VoxelViewer.new()
	bridge.name = "RetainedPrimaryHandoff"
	bridge.requires_visuals = true
	bridge.requires_collisions = true
	var record := {"viewer": bridge, "chunks": held, "attachedFrame": -1,
		"primaryHandoff": true, "secondaryKind": "handoff"}
	startup_auxiliary_viewers.append(record)
	_stage_secondary_viewer("handoff:%d" % bridge.get_instance_id(), "handoff", bridge,
		old_position, viewer.view_distance, held, 0)
	startup_auxiliary_cleanup_requested = true
	return false


func auxiliary_viewer_specs_for_component(component: Array, world_generation) -> Array[Dictionary]:
	var specs: Array[Dictionary] = []
	var groups: Dictionary = {}
	for key_value in component:
		if not key_value is Vector2i: continue
		var chunk_key: Vector2i = key_value
		var group := Vector2i(floori(float(chunk_key.x)/2.0),floori(float(chunk_key.y)/2.0))
		if not groups.has(group): groups[group] = []
		groups[group].append(chunk_key)
	var ordered_groups: Array = groups.keys()
	ordered_groups.sort_custom(func(a: Vector2i,b: Vector2i): return a.x<b.x if a.x!=b.x else a.y<b.y)
	for group: Vector2i in ordered_groups:
		var spec := auxiliary_viewer_spec_for_chunks(groups[group],world_generation)
		if not spec.is_empty(): specs.append(spec)
	return specs

static func collision_publication_view_distance_requirement(center_distance: float) -> int:
	var half_chunk_diagonal := float(GAME_CHUNK_SIZE) * CELL * sqrt(2.0) * 0.5
	return ceili(maxf(0.0, center_distance) + half_chunk_diagonal \
		+ CELL * float(COLLISION_PUBLICATION_VIEWER_MARGIN_CELLS))

func auxiliary_viewer_spec_for_chunks(chunks: Array, world_generation) -> Dictionary:
	if chunks.is_empty() or world_generation==null: return {}
	var min_chunk := Vector2i(2147483000,2147483000)
	var max_chunk := Vector2i(-2147483000,-2147483000)
	var valid_chunks: Array = []
	for key_value in chunks:
		if not key_value is Vector2i: continue
		var chunk_key: Vector2i = key_value
		valid_chunks.append(chunk_key)
		min_chunk = Vector2i(mini(min_chunk.x,chunk_key.x),mini(min_chunk.y,chunk_key.y))
		max_chunk = Vector2i(maxi(max_chunk.x,chunk_key.x),maxi(max_chunk.y,chunk_key.y))
	if valid_chunks.is_empty(): return {}
	var minimum := Vector2(float(min_chunk.x * GAME_CHUNK_SIZE) * CELL, float(min_chunk.y * GAME_CHUNK_SIZE) * CELL)
	var maximum := Vector2(float((max_chunk.x + 1) * GAME_CHUNK_SIZE) * CELL, float((max_chunk.y + 1) * GAME_CHUNK_SIZE) * CELL)
	var center_xz := (minimum + maximum) * 0.5
	var required_distance := 0.0
	for chunk_key: Vector2i in valid_chunks:
		var chunk_center := (Vector2(chunk_key)+Vector2.ONE*0.5)*float(GAME_CHUNK_SIZE)*CELL
		required_distance = maxf(required_distance,
			float(collision_publication_view_distance_requirement(center_xz.distance_to(chunk_center))))
	var maximum_view_distance := int(terrain.max_view_distance) if terrain != null else FINAL_VIEW_DISTANCE
	if required_distance>float(maximum_view_distance): return {}
	var center_position := Vector3(center_xz.x,0.0,center_xz.y)
	center_position.y = float(world_generation.call("surface_y_at",center_position))
	return {"position":center_position,"viewDistance":ceili(required_distance),"requiredDistance":required_distance,
		"collisionPublicationViewerMarginCells":COLLISION_PUBLICATION_VIEWER_MARGIN_CELLS,
		"nativeMeshBlockSizeCells":NATIVE_MESH_BLOCK_SIZE_CELLS,"chunks":valid_chunks}


func clear_startup_auxiliary_viewers() -> void:
	for identity_value in secondary_viewer_admissions.keys():
		var identity := String(identity_value)
		var entry: Dictionary = secondary_viewer_admissions[identity]
		var kind := String(entry.get("kind", ""))
		if kind != "startup" and kind != "handoff":
			continue
		var queued_auxiliary = entry.get("viewer")
		if is_instance_valid(queued_auxiliary):
			queued_auxiliary.queue_free()
		secondary_viewer_admissions.erase(identity)
	for record_value in startup_auxiliary_viewers:
		var record: Dictionary = record_value
		var auxiliary = record.get("viewer")
		if auxiliary == null or not is_instance_valid(auxiliary):
			continue
		auxiliary.requires_visuals = false
		auxiliary.requires_collisions = false
		if site_gate != null: site_gate.remove_viewer(auxiliary)
		auxiliary.queue_free()
	startup_auxiliary_viewers.clear()
	startup_auxiliary_publication_chunks.clear()
	startup_auxiliary_cleanup_requested = false
	startup_auxiliary_cleanup_frames_remaining = 0


func prune_startup_auxiliary_viewers() -> void:
	if not startup_auxiliary_cleanup_requested:
		return
	if startup_auxiliary_viewers.is_empty():
		startup_auxiliary_cleanup_requested = false
		startup_auxiliary_cleanup_frames_remaining = 0
		return
	if startup_auxiliary_cleanup_frames_remaining > 0:
		startup_auxiliary_cleanup_frames_remaining -= 1
		return
	# Retire only after an admitted, attached replacement holds every still
	# demanded chunk. A timer alone cannot transfer native loading ownership.
	for index in range(startup_auxiliary_viewers.size()-1,-1,-1):
		var record: Dictionary = startup_auxiliary_viewers[index]
		var holder: VoxelViewer = record.get("viewer")
		# A freshly cloned footprint must survive until the primary actually
		# moves; otherwise pruning would destroy the pending handoff each frame.
		if record.get("primaryHandoff",false) and not retained_gameplay_chunks.is_empty() \
				and is_instance_valid(holder) and holder.is_inside_tree() and is_instance_valid(viewer) and viewer.is_inside_tree() \
				and holder.global_position == viewer.global_position: continue
		var covered := true
		for key: Vector2i in record.get("chunks",[]):
			var chunk_bounds := Rect2i(key * GAME_CHUNK_SIZE, Vector2i.ONE * GAME_CHUNK_SIZE)
			if pending_edit_sections_intersect_bounds(chunk_bounds):
				covered = false
				break
			if startup_auxiliary_publication_chunks.has(key):
				var auxiliary_receipt: Dictionary=published_gameplay_chunks.get(key,{}) \
					if published_gameplay_chunks.get(key,{}) is Dictionary else {}
				if not _collision_chunk_receipt_current(key,auxiliary_receipt):
					covered=false
					break
			if not retained_gameplay_chunks.has(key) and not desired_gameplay_chunks.has(key): continue
			if not published_gameplay_chunks.has(key):
				covered = false
				break
			if is_instance_valid(viewer) and viewer.is_inside_tree() and _viewer_covers_chunk_at(viewer,key,viewer.global_position): continue
			if _retained_viewer_covers_chunk(key): continue
			covered = false
			break
		if not covered: continue
		var auxiliary: VoxelViewer = record.get("viewer")
		if is_instance_valid(auxiliary):
			auxiliary.requires_visuals = false
			auxiliary.requires_collisions = false
			if site_gate != null: site_gate.remove_viewer(auxiliary)
			auxiliary.queue_free()
		startup_auxiliary_viewers.remove_at(index)
	if startup_auxiliary_viewers.is_empty(): startup_auxiliary_cleanup_requested = false


func startup_auxiliary_viewer_diagnostics() -> Array:
	var diagnostics: Array = []
	for record_value in startup_auxiliary_viewers:
		var record: Dictionary = record_value
		var auxiliary = record.get("viewer")
		if auxiliary == null or not is_instance_valid(auxiliary):
			continue
		var attached: bool = auxiliary.is_inside_tree()
		var keys: Array[String] = []
		var chunks_value = record.get("chunks", [])
		if chunks_value is Array:
			for key_value in chunks_value:
				if key_value is Vector2i:
					keys.append("%d,%d" % [key_value.x, key_value.y])
		diagnostics.append({
			"name": auxiliary.name,
			"attached": attached,
			# A queued secondary viewer may remain in the bounded diagnostic
			# inventory for one frame after leaving the tree. Reading its global
			# transform emits an engine error and turns an otherwise retryable
			# startup observation into a hard failure.
			"position": auxiliary.global_position if attached else Vector3.ZERO,
			"viewDistance": int(auxiliary.view_distance),
			"requiredDistance": float(record.get("requiredDistance", auxiliary.view_distance)),
			"collisionPublicationViewerMarginCells": COLLISION_PUBLICATION_VIEWER_MARGIN_CELLS,
			"nativeMeshBlockSizeCells": NATIVE_MESH_BLOCK_SIZE_CELLS,
			"requiresVisuals": bool(auxiliary.requires_visuals),
			"requiresCollisions": bool(auxiliary.requires_collisions),
			"chunks": keys
		})
	return diagnostics

func pending_gameplay_chunk_keys() -> Array[String]:
	var keys: Array[String] = []
	for key_value in pending_gameplay_chunks:
		if key_value is Vector2i:
			var key: Vector2i = key_value
			keys.append("%d,%d" % [key.x,key.y])
	keys.sort()
	return keys

func vertical_cell_bounds() -> Vector2i:
	if terrain == null:
		return Vector2i.ZERO
	var current := terrain.bounds
	var min_cell := floori(current.position.y)
	return Vector2i(min_cell, min_cell + floori(current.size.y) - 1)

func vertical_bounds_cover_full() -> bool:
	var current := vertical_cell_bounds()
	var target := full_vertical_cell_bounds()
	return current.x <= target.x and current.y >= target.y

func expand_vertical_bounds_step() -> void:
	var current := vertical_cell_bounds()
	var target := full_vertical_cell_bounds()
	if vertical_bounds_cover_full():
		return
	apply_vertical_cell_bounds(
		maxi(target.x, current.x - VERTICAL_BOUNDS_EXPANSION_STEP_CELLS),
		mini(target.y, current.y + VERTICAL_BOUNDS_EXPANSION_STEP_CELLS)
	)

func _process(delta: float) -> void:
	# StructureSystem owns publication preparation. Always pump retirement before
	# native-generation early returns; only current player demand may dispatch.
	if main != null and main.structure_system != null:
		var can_prepare: bool = authority_ready and generation_context_current() \
			and main.player != null and main.player.is_inside_tree()
		var bounds := Rect2i()
		if can_prepare:
			var player_cell := Vector2i(floori(main.player.global_position.x/CELL),floori(main.player.global_position.z/CELL))
			bounds=Rect2i(player_cell-Vector2i(2,2),Vector2i(5,5))
		if main.has_method("advance_citadel_publication_shared"):
			main.advance_citadel_publication_shared(bounds,can_prepare)
	if authority_ready:
		if not generation_context_current():
			terrain.automatic_loading_enabled = false
			_retire_mesh_preparation_viewer()
			return
		if site_gate != null: site_gate.advance()
		if terrain_section_shadow_publisher != null:
			terrain_section_shadow_publisher.advance()
		observe_native_viewer_workload()
		update_viewer_position()
		update_viewer_distance(delta)
		advance_retained_viewers(delta)
		advance_secondary_viewer_admissions()
		advance_mesh_preparation_viewer()
		# Discover and apply durable edits while the temporary startup viewers
		# that make their native sections editable are still attached. Retirement
		# below also checks pending intersections, so an unloaded tutorial-town
		# section cannot strand navigation publication after Continue far away.
		collect_volume_edit_changes()
		process_pending_edit_sections()
		prune_startup_auxiliary_viewers()
		poll_site_traversal_readiness()

func _physics_process(_delta: float) -> void:
	if authority_ready and generation_context_current():
		process_pending_gameplay_chunk_publications()


func _exit_tree() -> void:
	if terrain_section_shadow_publisher != null:
		terrain_section_shadow_publisher.shutdown()
	clear_site_traversal_wait()
	clear_retained_gameplay_chunks()
	_retire_mesh_preparation_viewer()
	if site_gate != null: site_gate.stop()
	if viewer != null and is_instance_valid(viewer) and viewer.get_parent() != self:
		viewer.queue_free()

func begin_shutdown() -> void:
	authority_ready = false
	if terrain_section_shadow_publisher != null:
		terrain_section_shadow_publisher.shutdown()
		terrain_section_shadow_publisher = null
	clear_site_traversal_wait()
	clear_retained_gameplay_chunks()
	clear_foreground_collision_demand()
	_retire_mesh_preparation_viewer()
	if site_gate != null: site_gate.stop()
	set_process(false)
	set_physics_process(false)
	if viewer != null and is_instance_valid(viewer):
		viewer.requires_visuals = false
		viewer.requires_collisions = false
		viewer.queue_free()
		viewer = null
	clear_startup_auxiliary_viewers()
	if terrain != null and is_instance_valid(terrain):
		terrain.automatic_loading_enabled = false
	pending_gameplay_chunks.clear()
	pending_gameplay_chunk_order.clear()
	desired_gameplay_chunks.clear()
	view_distance_expansion_elapsed = 0.0
	view_distance_expansion_requested = false
	final_expansion_quiet_frames = 0


func request_final_view_distance_expansion() -> void:
	if not authority_ready:
		return
	view_distance_expansion_requested = true
	view_distance_expansion_elapsed = 0.0
	final_expansion_quiet_frames = 0

func final_view_distance_expansion_state() -> Dictionary:
	var pending_native_tasks := voxel_engine_pending_task_count()
	var current_distance := int(viewer.view_distance) if viewer != null and is_instance_valid(viewer) else 0
	var vertical_ready := vertical_bounds_cover_full()
	var retained_keys: Array = retained_gameplay_chunks.keys()
	var retained_chunks_ready := gameplay_chunks_published(retained_keys)
	var retained_viewers_ready := retained_chunk_viewers.size() >= retained_viewer_groups.size()
	var expansion_ready := authority_ready and generation_context_current() \
		and view_distance_expansion_requested and current_distance >= FINAL_VIEW_DISTANCE \
		and vertical_ready and retained_chunks_ready and retained_viewers_ready \
		and pending_native_tasks <= RETAINED_MAX_PENDING_NATIVE_TASKS
	if expansion_ready:
		final_expansion_quiet_frames += 1
	else:
		final_expansion_quiet_frames = 0
	var metrics := {
		"currentViewDistance": current_distance,
		"finalViewDistance": FINAL_VIEW_DISTANCE,
		"verticalCellBounds": vertical_cell_bounds(),
		"finalVerticalCellBounds": full_vertical_cell_bounds(),
		"retainedGameplayChunks": retained_gameplay_chunks.size(),
		"publishedRetainedGameplayChunks": published_gameplay_chunk_count(retained_keys),
		"retainedRegionViewers": retained_chunk_viewers.size(),
		"retainedViewerGroups": retained_viewer_groups.size(),
		"retainedActivationReason": retained_activation_reason,
		"pendingNativeTasks": pending_native_tasks,
		"nativeTaskLimit": RETAINED_MAX_PENDING_NATIVE_TASKS,
		"quietFrames": final_expansion_quiet_frames,
		"requiredQuietFrames": FINAL_EXPANSION_REQUIRED_QUIET_FRAMES
	}
	if not secondary_viewer_terminal_failure.is_empty():
		metrics["secondaryViewerAdmissionFailure"] = secondary_viewer_terminal_failure.duplicate(true)
		return STARTUP_READINESS_RESULT_SCRIPT.failed(
			"startup_auxiliary_terrain_admission_failed", {}, [], metrics)
	if not authority_ready or not generation_context_current():
		return STARTUP_READINESS_RESULT_SCRIPT.failed("terrain_generation_pending", {}, [], metrics)
	if final_expansion_quiet_frames >= FINAL_EXPANSION_REQUIRED_QUIET_FRAMES:
		return STARTUP_READINESS_RESULT_SCRIPT.ready({}, metrics)
	var pending_requirements: Array = []
	if current_distance < FINAL_VIEW_DISTANCE: pending_requirements.append("view_distance")
	if not vertical_ready: pending_requirements.append("vertical_bounds")
	if not retained_viewers_ready: pending_requirements.append("retained_viewers")
	if not retained_chunks_ready: pending_requirements.append("retained_collision")
	if pending_native_tasks > RETAINED_MAX_PENDING_NATIVE_TASKS: pending_requirements.append("native_tasks")
	if pending_requirements.is_empty(): pending_requirements.append("quiet_frames")
	return STARTUP_READINESS_RESULT_SCRIPT.pending("terrain_view_expansion_pending", {}, pending_requirements, metrics)

func update_viewer_distance(delta: float) -> void:
	if viewer == null or not is_instance_valid(viewer) or not viewer.is_inside_tree() or main == null:
		return
	var loading := bool(main.get("startup_loading_active")) or bool(main.get("runtime_loading_active"))
	if loading and not view_distance_expansion_requested:
		if int(viewer.view_distance) != STARTUP_VIEW_DISTANCE:
			viewer.view_distance = STARTUP_VIEW_DISTANCE
		view_distance_expansion_elapsed = 0.0
		return
	if not view_distance_expansion_requested:
		return
	var vertical_bounds_ready := vertical_bounds_cover_full()
	if int(viewer.view_distance) >= FINAL_VIEW_DISTANCE and vertical_bounds_ready:
		return
	view_distance_expansion_elapsed += maxf(0.0, delta)
	if view_distance_expansion_elapsed < VIEW_DISTANCE_EXPANSION_INTERVAL_SECONDS:
		return
	view_distance_expansion_elapsed = 0.0
	var next_distance := mini(FINAL_VIEW_DISTANCE,int(viewer.view_distance)+VIEW_DISTANCE_EXPANSION_STEP)
	if voxel_engine_pending_task_count() > RETAINED_MAX_PENDING_NATIVE_TASKS: return
	if _request_primary_viewer(viewer.global_position, next_distance, true):
		expand_vertical_bounds_step()

func voxel_engine_task_stats() -> Dictionary:
	if not Engine.has_singleton("VoxelEngine"):
		return {}
	var voxel_engine = Engine.get_singleton("VoxelEngine")
	if voxel_engine == null or not voxel_engine.has_method("get_stats"):
		return {}
	var stats_value = voxel_engine.call("get_stats")
	return (stats_value as Dictionary).duplicate(true) if stats_value is Dictionary else {}

func voxel_engine_pending_task_count() -> int:
	var engine_stats := voxel_engine_task_stats()
	var tasks_value = engine_stats.get("tasks", {})
	if not (tasks_value is Dictionary):
		return 0
	var tasks: Dictionary = tasks_value
	var total := 0
	for key in ["streaming", "meshing", "generation", "main_thread", "gpu"]:
		total += maxi(0, int(tasks.get(key, 0)))
	return total

## Accept Main's already-retained player corridor as native-view scheduling
## input. This never creates terrain demand or certifies collision: movement
## continues to require a fresh mesh receipt from this runtime.
func set_foreground_collision_demand(current_position: Vector3, predicted_position: Vector3) -> bool:
	if not current_position.is_finite() or not predicted_position.is_finite():
		return false
	var distance := int(viewer.view_distance) if is_instance_valid(viewer) else STARTUP_VIEW_DISTANCE
	var target := foreground_viewer_target(current_position,predicted_position,distance)
	foreground_collision_current = current_position
	foreground_collision_target = target
	foreground_collision_demand_revision += 1
	# WorldStreaming has already retained this forecast. Promote only its existing
	# collision-publication request so the receipt can be certified as soon as
	# native meshing completes, rather than waiting for locomotion to hit it.
	# This does not create terrain demand or weaken the fail-closed motion proof.
	if target != current_position:
		_promote_pending_gameplay_chunk_for_collision(gameplay_chunk_for_world_position(target))
	return target != current_position

func clear_foreground_collision_demand() -> void:
	foreground_collision_current = Vector3.INF
	foreground_collision_target = Vector3.INF
	foreground_collision_demand_revision = 0

static func foreground_viewer_target(current_position: Vector3, predicted_position: Vector3, view_distance: int) -> Vector3:
	if not current_position.is_finite() or not predicted_position.is_finite():
		return current_position
	var current_chunk := gameplay_chunk_for_world_position(current_position)
	var predicted_chunk := gameplay_chunk_for_world_position(predicted_position)
	if not viewer_position_covers_gameplay_chunk(current_chunk,predicted_position,view_distance) \
			or not viewer_position_covers_gameplay_chunk(predicted_chunk,predicted_position,view_distance):
		return current_position
	return predicted_position

static func gameplay_chunk_for_world_position(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x/(GAME_CHUNK_SIZE*CELL)),floori(position.z/(GAME_CHUNK_SIZE*CELL)))

static func viewer_position_covers_gameplay_chunk(chunk_key: Vector2i, position: Vector3, view_distance: int) -> bool:
	var center := (Vector2(chunk_key)+Vector2.ONE*0.5)*float(GAME_CHUNK_SIZE)*CELL
	var distance := Vector2(position.x,position.z).distance_to(center)
	return distance+float(GAME_CHUNK_SIZE)*CELL*sqrt(2.0)*0.5 \
		<= float(view_distance)-CELL*float(COLLISION_PUBLICATION_VIEWER_MARGIN_CELLS)

func update_viewer_position() -> void:
	if viewer == null or main == null:
		return
	var player_value = main.get("player")
	if player_value is Node3D and is_instance_valid(player_value):
		var player_position: Vector3 = (player_value as Node3D).global_position
		var target_position := foreground_collision_target if foreground_collision_target.is_finite() \
				and viewer_position_covers_gameplay_chunk(gameplay_chunk_for_world_position(player_position),foreground_collision_target,int(viewer.view_distance)) \
				else player_position
		var request_changed := _primary_viewer_request_changed(target_position, int(viewer.view_distance))
		var primary_covers_player := _primary_viewer_covers_player_chunk(player_position)
		var primary_covers_foreground := _primary_viewer_covers_player_chunk(target_position)
		var player_collision_published := _collision_receipt_current_for_world_position(player_position)
		var foreground_collision_published := _collision_receipt_current_for_world_position(target_position)
		var unpublished_request_key := _primary_collision_request_key(
			player_position,target_position,int(viewer.view_distance))
		if player_collision_published and foreground_collision_published:
			primary_unpublished_collision_request_key = ""
		if primary_viewer_request_is_satisfied(request_changed,primary_covers_player,
				primary_covers_foreground,player_collision_published,foreground_collision_published):
			return
		# Force the first request for an unpublished dependency even inside the
		# current quantization cell, but do not move the raw forecast every rendered
		# frame while that exact request remains in flight. SiteGate and the native
		# viewer retain it until the authoritative receipt is published.
		if primary_unpublished_request_already_inflight(request_changed,
				player_collision_published,foreground_collision_published,
				unpublished_request_key,primary_unpublished_collision_request_key):
			secondary_viewer_admission_reason = "primary_collision_publication_inflight"
			return
		# Coalesce normal player motion to native mesh-block cells.  SiteGate keeps
		# the latest admitted request; sending a new world position every process
		# turn otherwise gives the voxel engine an unbounded stream of overlapping
		# primary footprints.
		# A forecast is a priority hint, never permission to stack another broad
		# native footprint behind outstanding terrain work. Reissuing the primary
		# viewer while generation is busy creates a long-lived plugin backlog and
		# eventually delays the very collision receipt the hint is meant to help.
		if primary_viewer_request_may_defer(voxel_engine_pending_task_count(),primary_covers_player,
				primary_covers_foreground,player_collision_published,foreground_collision_published):
			secondary_viewer_admission_reason = "primary_position_backpressure"
			return
		if not _preserve_retained_primary_coverage(target_position):
			return
		# A quantized request may be unchanged while the actual viewer has fallen
		# behind the player. Coverage is the safety authority in that case, not the
		# quantization cell, so force exactly this replacement request.
		if _request_primary_viewer(target_position, int(viewer.view_distance), not request_changed):
			primary_unpublished_collision_request_key = unpublished_request_key \
				if not player_collision_published or not foreground_collision_published else ""


## A single optional native viewer prepares the next all-direction 3D shell.
## It is never a collision or visual receipt owner and never participates in
## startup readiness. Admission remains owned by the same SiteGate as primary.
func advance_mesh_preparation_viewer() -> void:
	if main == null or not authority_ready or site_gate == null or not is_instance_valid(viewer) \
			or not viewer.is_inside_tree() or int(viewer.view_distance) < FINAL_VIEW_DISTANCE \
			or bool(main.get("startup_loading_active")) or bool(main.get("runtime_loading_active")) \
			or bool(main.get("shutdown_requested")):
		_retire_mesh_preparation_viewer()
		mesh_preparation_admission_reason = "not_playable"
		return
	var player_value = main.get("player")
	if not (player_value is Node3D) or not is_instance_valid(player_value) \
			or not (player_value as Node3D).is_inside_tree():
		_retire_mesh_preparation_viewer()
		mesh_preparation_admission_reason = "player_unavailable"
		return
	if not mesh_preparation_extension_checked:
		mesh_preparation_extension_checked = true
		var candidate := VoxelViewer.new()
		for property_value in candidate.get_property_list():
			if property_value is Dictionary and String(property_value.get("name", "")) == "requires_mesh_preparation":
				mesh_preparation_extension_available = true
				break
		candidate.queue_free()
	if not mesh_preparation_extension_available or not site_gate.has_method("request_optional_viewer"):
		mesh_preparation_admission_reason = "native_mesh_preparation_unavailable"
		return
	var player_position: Vector3 = (player_value as Node3D).global_position
	var target := foreground_viewer_target(player_position,foreground_collision_target,
		int(viewer.view_distance)) if foreground_collision_target.is_finite() else player_position
	var span := CELL * float(MESH_PREPARATION_REBASE_CELLS)
	var cell := Vector3i(roundi(target.x/span),roundi(target.y/span),roundi(target.z/span))
	var position := Vector3(float(cell.x)*span,float(cell.y)*span,float(cell.z)*span)
	if is_instance_valid(mesh_preparation_viewer) and mesh_preparation_viewer.is_inside_tree() \
			and cell == mesh_preparation_request_cell:
		mesh_preparation_admission_reason = "attached"
		return
	mesh_preparation_last_pending_native_tasks = voxel_engine_pending_task_count()
	if mesh_preparation_last_pending_native_tasks > MESH_PREPARATION_MAX_PENDING_NATIVE_TASKS \
			or not secondary_viewer_admissions.is_empty() or _secondary_viewer_collision_coverage_pending():
		mesh_preparation_backpressure_deferrals += 1
		mesh_preparation_admission_reason = "native_or_collision_backpressure"
		return
	if not is_instance_valid(mesh_preparation_viewer):
		mesh_preparation_viewer = VoxelViewer.new()
		mesh_preparation_viewer.name = "OptionalMeshPreparationViewer"
		mesh_preparation_viewer.view_distance = MESH_PREPARATION_VIEW_DISTANCE
		mesh_preparation_viewer.view_distance_vertical_ratio = 1.0
		mesh_preparation_viewer.requires_visuals = false
		mesh_preparation_viewer.requires_collisions = false
		mesh_preparation_viewer.set("requires_mesh_preparation",true)
	mesh_preparation_admission_attempts += 1
	var admission: Dictionary = site_gate.request_optional_viewer(mesh_preparation_viewer,
		position,MESH_PREPARATION_VIEW_DISTANCE)
	mesh_preparation_admission_reason = String(admission.get("reason", admission.get("status", "pending")))
	if admission.get("status") == "ready":
		mesh_preparation_request_cell = cell
		mesh_preparation_admission_accepts += 1
		mesh_preparation_admission_reason = "attached"
		_record_native_viewer_request("mesh_preparation",MESH_PREPARATION_VIEW_DISTANCE,position)

func _retire_mesh_preparation_viewer() -> void:
	if is_instance_valid(mesh_preparation_viewer):
		mesh_preparation_viewer.set("requires_mesh_preparation",false)
		if site_gate != null: site_gate.remove_viewer(mesh_preparation_viewer)
		mesh_preparation_viewer.queue_free()
	mesh_preparation_viewer = null
	mesh_preparation_request_cell = Vector3i(2147483000,2147483000,2147483000)


## An unchanged quantized request is complete only when the existing primary
## viewer owns current collision receipts for both its player and forecast
## chunks. Geometric radius alone is not publication: native work can still be
## outstanding inside that footprint.
static func primary_viewer_request_is_satisfied(request_changed: bool,
		covers_player: bool, covers_foreground: bool,
		player_collision_published: bool, foreground_collision_published: bool) -> bool:
	return not request_changed and covers_player and covers_foreground \
		and player_collision_published and foreground_collision_published


static func primary_unpublished_request_already_inflight(request_changed: bool,
		player_collision_published: bool, foreground_collision_published: bool,
		request_key: String, active_request_key: String) -> bool:
	return not request_changed \
		and (not player_collision_published or not foreground_collision_published) \
		and not request_key.is_empty() and request_key == active_request_key


## Native backlog may defer an overlapping broad-footprint replacement only
## while the existing primary viewer covers both the capsule and its already-
## admitted foreground collision dependency, and both authoritative collision
## receipts are current. Deferring based on geometric coverage alone leaves an
## unpublished forecast reactive at the next gameplay-chunk seam.
static func primary_viewer_request_may_defer(pending_native_tasks: int,
		covers_player: bool, covers_foreground: bool,
		player_collision_published: bool, foreground_collision_published: bool) -> bool:
	return pending_native_tasks > SECONDARY_VIEWER_MAX_PENDING_NATIVE_TASKS \
		and covers_player and covers_foreground \
		and player_collision_published and foreground_collision_published

func _primary_viewer_request_cell_for(position: Vector3) -> Vector2i:
	var span := CELL * float(PRIMARY_VIEWER_REQUEST_CELL_SIZE)
	return Vector2i(floori(position.x / span), floori(position.z / span))

func _primary_viewer_request_changed(position: Vector3, distance: int) -> bool:
	return _primary_viewer_request_cell_for(position) != primary_viewer_request_cell \
			or distance != primary_viewer_request_distance


func _primary_collision_request_key(player_position: Vector3, target_position: Vector3,
		distance: int) -> String:
	var player_chunk := gameplay_chunk_for_world_position(player_position)
	var foreground_chunk := gameplay_chunk_for_world_position(target_position)
	var request_cell := _primary_viewer_request_cell_for(target_position)
	return "%d,%d|%d,%d|%d,%d|%d" % [
		player_chunk.x,player_chunk.y,foreground_chunk.x,foreground_chunk.y,
		request_cell.x,request_cell.y,distance]

func _primary_viewer_covers_player_chunk(position: Vector3) -> bool:
	# setup() requests the initial footprint before the viewer is attached to the
	# scene tree.  It has no meaningful world transform at that point, so treat
	# it as uncovered and let the ordinary initial request establish coverage.
	if viewer == null or not is_instance_valid(viewer) or not viewer.is_inside_tree():
		return false
	var player_chunk := gameplay_chunk_for_world_position(position)
	return _viewer_covers_chunk_at(viewer, player_chunk, viewer.global_position)


func _collision_receipt_current_for_world_position(position: Vector3) -> bool:
	var chunk_key := gameplay_chunk_for_world_position(position)
	var receipt: Dictionary = published_gameplay_chunks.get(chunk_key,{}) \
		if published_gameplay_chunks.get(chunk_key,{}) is Dictionary else {}
	return _collision_chunk_receipt_current(chunk_key,receipt)

func _request_primary_viewer(position: Vector3, distance: int, force := false) -> bool:
	if viewer == null or site_gate == null:
		return false
	if not force and not _primary_viewer_request_changed(position, distance):
		return true
	if not site_gate.request_viewer(viewer, position, distance):
		return false
	_record_native_viewer_request("primary", distance, position)
	primary_viewer_request_cell = _primary_viewer_request_cell_for(position)
	primary_viewer_request_distance = distance
	return true

func required_classes_available() -> bool:
	for class_name_value in ["VoxelTerrain", "VoxelViewer", "VoxelMesherTransvoxel", "VoxelFormat"]:
		if not ClassDB.class_exists(class_name_value):
			return false
	return true

func on_mesh_block_entered(block_position: Vector3i) -> void:
	mesh_publication_serial += 1
	mesh_block_revisions[block_position] = mesh_publication_serial
	published_mesh_blocks[block_position] = true
	visible_mesh_block_revision_changed.emit(block_position, int(mesh_block_revisions[block_position]))
	queue_loaded_block_edit_sections(block_position)

func on_mesh_block_exited(block_position: Vector3i) -> void:
	published_mesh_blocks.erase(block_position)
	mesh_publication_serial += 1
	visible_mesh_block_revision_changed.emit(block_position, mesh_publication_serial)
	mesh_block_revisions.erase(block_position)
	invalidate_gameplay_publications_for_mesh_block(block_position)


func request_terrain_section_shadow_install(block_position: Vector3i) -> Dictionary:
	if not authority_ready or terrain_section_shadow_publisher == null:
		return {"status":"failed", "reason":"terrain_section_shadow_publisher_unavailable"}
	return terrain_section_shadow_publisher.request(block_position)


func poll_terrain_section_shadow_install(ticket: int) -> Dictionary:
	if terrain_section_shadow_publisher == null:
		return {"status":"failed", "reason":"terrain_section_shadow_publisher_unavailable"}
	return terrain_section_shadow_publisher.poll(ticket)


func visible_mesh_source_identity() -> String:
	if terrain == null or not is_instance_valid(terrain): return ""
	return "voxel-terrain:%d:%d" % [get_instance_id(), terrain.get_instance_id()]


func visible_mesh_world_revision() -> String:
	return "%s:%d:%d" % [configured_seed, last_volume_revision, collision_owner_generation]


func visible_mesh_source_revision(block_position: Vector3i) -> String:
	return "%s:%d:%d,%d,%d" % [visible_mesh_world_revision(),
		int(mesh_block_revisions.get(block_position, 0)), block_position.x, block_position.y, block_position.z]


## Captures the currently resident production VoxelData for one Transvoxel
## mesh block. This is a render-source snapshot only: Voxel Tools remains the
## visible and collision authority until a complete section candidate is
## installed and acknowledged. The one-cell sample halo is included because
## the configured Transvoxel mesher needs neighboring density/material data.
func capture_resident_terrain_mesh_block(block_position: Vector3i) -> Dictionary:
	var initial := _resident_terrain_capture_state(block_position)
	if initial.get("status") != "ready":
		return initial
	var service = volume_service()
	if service == null or not service is Object:
		return {"status":"pending", "reason":"terrain_volume_authority_unavailable", "retryable":true}
	# Transvoxel advertises asymmetric one-cell minimum / two-cell maximum
	# padding. The copied inclusive range is therefore 16 + 1 + 2 = 19 cells.
	var size := NATIVE_MESH_BLOCK_SIZE_CELLS + 3
	var origin := block_position * NATIVE_MESH_BLOCK_SIZE_CELLS - Vector3i.ONE
	var capture_area := AABB(Vector3(origin), Vector3.ONE * float(size))
	var tool = terrain.get_voxel_tool()
	if not bool(tool.is_area_editable(capture_area)):
		return {"status":"pending", "reason":"terrain_capture_halo_not_resident", "retryable":true,
			"block":block_position, "origin":origin, "size":Vector3i.ONE * size}
	if not terrain.is_area_meshed(capture_area):
		return {"status":"pending", "reason":"terrain_capture_halo_not_meshed", "retryable":true,
			"block":block_position, "origin":origin, "size":Vector3i.ONE * size}
	var sections := _terrain_capture_section_revisions(service, origin, Vector3i.ONE * size)
	if sections.get("status") != "ready":
		return sections
	var buffer := VoxelBuffer.new()
	buffer.create(size, size, size)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	var channels_mask := (1 << VoxelBuffer.CHANNEL_SDF) | (1 << VoxelBuffer.CHANNEL_INDICES) | (1 << VoxelBuffer.CHANNEL_DATA5)
	tool.copy(origin, buffer, channels_mask, false)
	var sdf_bytes: PackedByteArray = buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF)
	var indices_bytes: PackedByteArray = buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_INDICES)
	var data5_bytes: PackedByteArray = buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_DATA5)
	var sample_count := size * size * size
	if sdf_bytes.size() != sample_count * 2 or indices_bytes.size() != sample_count \
			or data5_bytes.size() != sample_count:
		return {"status":"failed", "reason":"terrain_capture_channel_size_mismatch",
			"sdfBytes":sdf_bytes.size(), "indicesBytes":indices_bytes.size(), "data5Bytes":data5_bytes.size()}
	var payload_digest := _terrain_capture_payload_digest(sdf_bytes, indices_bytes, data5_bytes)
	var after := _resident_terrain_capture_state(block_position)
	if after.get("status") != "ready" or String(after.get("captureToken", "")) != String(initial.get("captureToken", "")):
		return {"status":"pending", "reason":"terrain_capture_source_changed_during_copy", "retryable":true}
	var after_sections := _terrain_capture_section_revisions(service, origin, Vector3i.ONE * size)
	if after_sections.get("status") != "ready" \
			or String(after_sections.get("revisionDigest", "")) != String(sections.get("revisionDigest", "")):
		return {"status":"pending", "reason":"terrain_capture_sections_changed_during_copy", "retryable":true}
	var result := {"status":"ready", "schema":"resident-terrain-mesh-block/v1",
		"captureToken":String(initial.captureToken), "sourceIdentity":visible_mesh_source_identity(),
		"worldRevision":visible_mesh_world_revision(), "sourceRevision":visible_mesh_source_revision(block_position),
		"terrainInstanceId":terrain.get_instance_id(), "generatorInstanceId":generator.get_instance_id() if is_instance_valid(generator) else 0,
		"seed":configured_seed, "block":block_position, "origin":origin,
		"authorityIdentity":_terrain_capture_authority_identity(),
		"size":Vector3i.ONE * size, "sectionRevisions":sections.revisions,
		"sectionRevisionDigest":String(sections.revisionDigest),
		"meshMaterialRevision":_terrain_capture_mesher_material_revision(),
		"sdf16Le":sdf_bytes, "indices8":indices_bytes, "data5_8":data5_bytes,
		"payloadDigest":payload_digest, "sampleCount":sample_count,
		"captureIsTerrainOnly":true, "collisionAuthority":"VoxelTerrainRuntime"}
	result.make_read_only()
	return result


## Call again immediately before installing a captured candidate. A snapshot
## does not pin source chunks or make later source revisions current.
func resident_terrain_capture_is_current(capture: Dictionary) -> bool:
	if not capture.is_read_only() or String(capture.get("schema", "")) != "resident-terrain-mesh-block/v1":
		return false
	var block_value: Variant = capture.get("block")
	var origin_value: Variant = capture.get("origin")
	var size_value: Variant = capture.get("size")
	if not block_value is Vector3i or not origin_value is Vector3i or not size_value is Vector3i:
		return false
	var block: Vector3i = block_value
	var sdf_value: Variant = capture.get("sdf16Le")
	var indices_value: Variant = capture.get("indices8")
	var data5_value: Variant = capture.get("data5_8")
	if not sdf_value is PackedByteArray or not indices_value is PackedByteArray \
			or not data5_value is PackedByteArray \
			or _terrain_capture_payload_digest(sdf_value, indices_value, data5_value) \
				!= String(capture.get("payloadDigest", "")):
		return false
	var state := _resident_terrain_capture_state(block)
	if state.get("status") != "ready" or String(state.get("captureToken", "")) != String(capture.get("captureToken", "")):
		return false
	if String(capture.get("sourceIdentity", "")) != visible_mesh_source_identity() \
			or String(capture.get("worldRevision", "")) != visible_mesh_world_revision() \
			or int(capture.get("terrainInstanceId", 0)) != terrain.get_instance_id() \
			or String(capture.get("meshMaterialRevision", "")) != _terrain_capture_mesher_material_revision():
		return false
	var service = volume_service()
	if service == null:
		return false
	var sections := _terrain_capture_section_revisions(service, origin_value, size_value)
	return sections.get("status") == "ready" \
		and String(sections.get("revisionDigest", "")) == String(capture.get("sectionRevisionDigest", ""))


## Validate a sealed source value after the Voxel Tools mesh block has unloaded.
## Residency proves that capture was legal; the immutable payload plus world and
## intersecting authority revisions prove that it is still current.
func terrain_capture_authority_is_current(capture: Dictionary) -> bool:
	if not capture.is_read_only() or String(capture.get("schema", "")) != "resident-terrain-mesh-block/v1" \
			or not authority_ready or terrain == null or not is_instance_valid(terrain) \
			or not terrain.is_inside_tree():
		return false
	var block_value: Variant = capture.get("block")
	var origin_value: Variant = capture.get("origin")
	var size_value: Variant = capture.get("size")
	if not block_value is Vector3i or not origin_value is Vector3i or not size_value is Vector3i:
		return false
	var sdf_value: Variant = capture.get("sdf16Le")
	var indices_value: Variant = capture.get("indices8")
	var data5_value: Variant = capture.get("data5_8")
	if not sdf_value is PackedByteArray or not indices_value is PackedByteArray \
			or not data5_value is PackedByteArray \
			or _terrain_capture_payload_digest(sdf_value, indices_value, data5_value) \
				!= String(capture.get("payloadDigest", "")):
		return false
	if String(capture.get("sourceIdentity", "")) != visible_mesh_source_identity() \
			or String(capture.get("authorityIdentity", "")) != _terrain_capture_authority_identity() \
			or String(capture.get("worldRevision", "")) != visible_mesh_world_revision() \
			or int(capture.get("terrainInstanceId", 0)) != terrain.get_instance_id() \
			or int(capture.get("generatorInstanceId", 0)) != generator.get_instance_id() \
			or String(capture.get("meshMaterialRevision", "")) != _terrain_capture_mesher_material_revision():
		return false
	var service = volume_service()
	if service == null:
		return false
	var sections := _terrain_capture_section_revisions(service, origin_value, size_value)
	return sections.get("status") == "ready" \
		and String(sections.get("revisionDigest", "")) == String(capture.get("sectionRevisionDigest", ""))


func _terrain_capture_authority_identity() -> String:
	if terrain == null or not is_instance_valid(terrain) or generator == null \
			or not is_instance_valid(generator):
		return ""
	var service = volume_service()
	if service == null or not service is Object:
		return ""
	return "%s:%d:%d:%d:%d" % [configured_seed, collision_owner_generation,
		terrain.get_instance_id(), generator.get_instance_id(), service.get_instance_id()]


func _resident_terrain_capture_state(block_position: Vector3i) -> Dictionary:
	if not authority_ready or terrain == null or not is_instance_valid(terrain) \
			or not terrain.is_inside_tree() or last_volume_revision < 0:
		return {"status":"pending", "reason":"terrain_authority_not_ready", "retryable":true}
	if not visible_mesh_block_rendered(block_position):
		return {"status":"pending", "reason":"terrain_mesh_block_not_visible", "retryable":true,
			"block":block_position}
	var area := AABB(Vector3(block_position * NATIVE_MESH_BLOCK_SIZE_CELLS - Vector3i.ONE),
		Vector3.ONE * float(NATIVE_MESH_BLOCK_SIZE_CELLS + 3))
	var tool = terrain.get_voxel_tool()
	if not bool(tool.is_area_editable(area)) or not terrain.is_area_meshed(area):
		return {"status":"pending", "reason":"terrain_mesh_block_halo_not_ready", "retryable":true,
			"block":block_position}
	if _terrain_capture_has_pending_edits(area):
		return {"status":"pending", "reason":"terrain_mesh_block_has_pending_edits", "retryable":true,
			"block":block_position}
	var service = volume_service()
	if service == null:
		return {"status":"pending", "reason":"terrain_volume_authority_unavailable", "retryable":true}
	var token := "%s:%d:%d:%d:%d:%d" % [visible_mesh_source_revision(block_position),
		terrain.get_instance_id(), generator.get_instance_id() if is_instance_valid(generator) else 0,
		area.position.x, area.position.y, int(service.get("revision"))]
	return {"status":"ready", "captureToken":token}


func _terrain_capture_payload_digest(sdf_bytes: PackedByteArray, indices_bytes: PackedByteArray,
		data5_bytes: PackedByteArray) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(sdf_bytes)
	hasher.update(indices_bytes)
	hasher.update(data5_bytes)
	return hasher.finish().hex_encode()


func _terrain_capture_has_pending_edits(area: AABB) -> bool:
	var min_cell := Vector3i(floori(area.position.x), floori(area.position.y), floori(area.position.z))
	var max_cell := min_cell + Vector3i(ceili(area.size.x), ceili(area.size.y), ceili(area.size.z)) - Vector3i.ONE
	var min_section := Vector3i(floori(float(min_cell.x) / SECTION_SIZE),
		floori(float(min_cell.y) / SECTION_SIZE), floori(float(min_cell.z) / SECTION_SIZE))
	var max_section := Vector3i(floori(float(max_cell.x) / SECTION_SIZE),
		floori(float(max_cell.y) / SECTION_SIZE), floori(float(max_cell.z) / SECTION_SIZE))
	for section_value in pending_edit_sections:
		if not section_value is Vector3i:
			return true
		var section: Vector3i = section_value
		if section.x >= min_section.x and section.x <= max_section.x \
				and section.y >= min_section.y and section.y <= max_section.y \
				and section.z >= min_section.z and section.z <= max_section.z:
			return true
	return false


func _terrain_capture_section_revisions(service, origin: Vector3i, size: Vector3i) -> Dictionary:
	if not service is Object:
		return {"status":"failed", "reason":"terrain_section_revision_authority_unavailable"}
	var section_revisions_value = service.get("section_revisions")
	if not section_revisions_value is Dictionary:
		return {"status":"failed", "reason":"terrain_section_revision_authority_invalid"}
	var end := origin + size - Vector3i.ONE
	var min_section := Vector3i(floori(float(origin.x) / SECTION_SIZE),
		floori(float(origin.y) / SECTION_SIZE), floori(float(origin.z) / SECTION_SIZE))
	var max_section := Vector3i(floori(float(end.x) / SECTION_SIZE),
		floori(float(end.y) / SECTION_SIZE), floori(float(end.z) / SECTION_SIZE))
	var keys: Array[Vector3i] = []
	var values: Array[Dictionary] = []
	for y in range(min_section.y, max_section.y + 1):
		for z in range(min_section.z, max_section.z + 1):
			for x in range(min_section.x, max_section.x + 1):
				var key := Vector3i(x, y, z)
				keys.append(key)
				values.append({"sectionKey":key, "revision":int(section_revisions_value.get(key, 0))})
	var digest_context := HashingContext.new()
	digest_context.start(HashingContext.HASH_SHA256)
	for row in values:
		digest_context.update(":".to_utf8_buffer())
		digest_context.update(str(row.sectionKey.x, ",", row.sectionKey.y, ",", row.sectionKey.z, "=", row.revision).to_utf8_buffer())
	var digest := digest_context.finish().hex_encode()
	keys.make_read_only()
	for row in values: row.make_read_only()
	values.make_read_only()
	return {"status":"ready", "revisions":values, "sectionKeys":keys, "revisionDigest":digest}


func _terrain_capture_mesher_material_revision() -> String:
	if terrain == null or not is_instance_valid(terrain):
		return ""
	var mesher = terrain.mesher
	var material := terrain.material_override
	return "%s:%s:%s:%d" % [str(mesher.get_class()) if is_instance_valid(mesher) else "missing",
		str(mesher.get_instance_id()) if is_instance_valid(mesher) else "0",
		str(material.get_instance_id()) if is_instance_valid(material) else "0",
		NATIVE_MESH_BLOCK_SIZE_CELLS]


func visible_mesh_vertical_bounds() -> Vector2i:
	return vertical_cell_bounds()


func visible_mesh_area_complete(block_position: Vector3i) -> bool:
	if not authority_ready or terrain == null or not is_instance_valid(terrain) \
			or last_volume_revision < 0:
		return false
	var area := native_mesh_block_bounds(block_position)
	var vertical := vertical_cell_bounds()
	var first_y := maxi(floori(area.position.y), vertical.x)
	var last_y := mini(floori(area.position.y + area.size.y), vertical.y + 1)
	if last_y <= first_y: return false
	area.position.y = float(first_y)
	area.size.y = float(last_y - first_y)
	var xz_bounds := Rect2i(Vector2i(block_position.x, block_position.z) * NATIVE_MESH_BLOCK_SIZE_CELLS,
		Vector2i.ONE * NATIVE_MESH_BLOCK_SIZE_CELLS)
	if pending_edit_sections_intersect_bounds(xz_bounds): return false
	return terrain.is_area_meshed(area)


func visible_mesh_area_diagnostics(block_position: Vector3i) -> Dictionary:
	var area := native_mesh_block_bounds(block_position)
	var vertical := vertical_cell_bounds()
	var first_y := maxi(floori(area.position.y), vertical.x)
	var last_y := mini(floori(area.position.y + area.size.y), vertical.y + 1)
	area.position.y = float(first_y)
	area.size = Vector3(area.size.x, float(maxi(0, last_y - first_y)), area.size.z)
	var xz_bounds := Rect2i(Vector2i(block_position.x, block_position.z) * NATIVE_MESH_BLOCK_SIZE_CELLS,
		Vector2i.ONE * NATIVE_MESH_BLOCK_SIZE_CELLS)
	var pending_sections: Array = []
	for section_value in pending_edit_sections:
		if not section_value is Vector3i:
			pending_sections.append(str(section_value))
			continue
		var section: Vector3i = section_value
		var section_bounds := Rect2i(Vector2i(section.x * SECTION_SIZE, section.z * SECTION_SIZE),
			Vector2i.ONE * SECTION_SIZE)
		if section_bounds.intersects(xz_bounds): pending_sections.append(section)
		if pending_sections.size() >= 16: break
	return {"block": block_position, "area": area, "areaMeshed": terrain.is_area_meshed(area),
		"hasGeometryReceipt": published_mesh_blocks.has(block_position),
		"nativeViewerState": native_mesh_block_viewer_state(block_position),
		"pendingEditSections": pending_sections,
		"viewerPosition": viewer.global_position if is_instance_valid(viewer) else Vector3.ZERO,
		"viewerDistance": int(viewer.view_distance) if is_instance_valid(viewer) else 0,
		"verticalBounds": vertical_cell_bounds()}


func visible_mesh_block_has_geometry(block_position: Vector3i) -> bool:
	if not published_mesh_blocks.has(block_position): return false
	if terrain == null or not terrain.has_method("get_mesh_block_viewer_state"): return true
	var state := native_mesh_block_viewer_state(block_position)
	return bool(state.get("is_loaded", false)) and bool(state.get("has_mesh", false))

func native_mesh_block_viewer_state(block_position: Vector3i) -> Dictionary:
	if terrain == null or not is_instance_valid(terrain) \
			or not terrain.has_method("get_mesh_block_viewer_state"):
		return {}
	var state_value = terrain.call("get_mesh_block_viewer_state", block_position)
	return state_value if state_value is Dictionary else {}

func visible_mesh_block_rendered(block_position: Vector3i) -> bool:
	if not published_mesh_blocks.has(block_position): return false
	if terrain == null or not terrain.has_method("get_mesh_block_viewer_state"):
		return true
	return native_mesh_viewer_state_rendered(native_mesh_block_viewer_state(block_position))

static func native_mesh_viewer_state_rendered(state: Dictionary) -> bool:
	return bool(state.get("is_loaded", false)) and bool(state.get("has_mesh", false)) \
		and int(state.get("render_viewers", 0)) > 0 \
		and bool(state.get("is_visible", false))


func visible_mesh_receipt_is_current(source_identity: String, source_revision: String,
		world_revision: String, view_revision: int, candidate_id: String,
		metadata: Dictionary, representation_id: String, tier: String) -> bool:
	if source_identity != visible_mesh_source_identity() or world_revision != visible_mesh_world_revision() \
		or not is_instance_valid(terrain) or not terrain.is_inside_tree():
		return false
	var block_value: Variant = metadata.get("nativeBlock")
	if not block_value is Vector3i: return false
	var block_position: Vector3i = block_value
	if source_revision != visible_mesh_source_revision(block_position) \
			or candidate_id != "terrain:%d,%d,%d" % [block_position.x, block_position.y, block_position.z] \
			or representation_id != candidate_id + ":native_mesh" \
			or tier not in ["near", "horizon"]:
		return false
	return visible_mesh_block_rendered(block_position) and visible_mesh_area_complete(block_position)

static func native_mesh_block_bounds(block_position: Vector3i) -> AABB:
	return AABB(Vector3(block_position * NATIVE_MESH_BLOCK_SIZE_CELLS),
		Vector3.ONE * float(NATIVE_MESH_BLOCK_SIZE_CELLS))

static func gameplay_chunks_for_native_mesh_block(block_position: Vector3i) -> Array[Vector2i]:
	var first_cell := Vector2i(block_position.x, block_position.z) * NATIVE_MESH_BLOCK_SIZE_CELLS
	var last_cell := first_cell + Vector2i.ONE * (NATIVE_MESH_BLOCK_SIZE_CELLS - 1)
	var first_chunk := Vector2i(
		floori(float(first_cell.x) / float(GAME_CHUNK_SIZE)),
		floori(float(first_cell.y) / float(GAME_CHUNK_SIZE)))
	var last_chunk := Vector2i(
		floori(float(last_cell.x) / float(GAME_CHUNK_SIZE)),
		floori(float(last_cell.y) / float(GAME_CHUNK_SIZE)))
	var result: Array[Vector2i] = []
	for z in range(first_chunk.y, last_chunk.y + 1):
		for x in range(first_chunk.x, last_chunk.x + 1):
			result.append(Vector2i(x, z))
	return result

func invalidate_gameplay_publications_for_mesh_block(block_position: Vector3i) -> Array[Vector2i]:
	var retired_bounds := native_mesh_block_bounds(block_position)
	var invalidated: Array[Vector2i] = []
	# A 16-cell native block overlaps at most four 28-cell gameplay chunks.
	# Avoid scanning every retained receipt on each streaming exit.
	for chunk_key in gameplay_chunks_for_native_mesh_block(block_position):
		if not published_gameplay_chunks.has(chunk_key):
			continue
		var receipt_value = published_gameplay_chunks.get(chunk_key, {})
		if not (receipt_value is Dictionary):
			continue
		var receipt: Dictionary = receipt_value
		var mesh_area_value = receipt.get("meshArea")
		if not (mesh_area_value is AABB) or not (mesh_area_value as AABB).intersects(retired_bounds):
			continue
		published_gameplay_chunks.erase(chunk_key)
		invalidated.append(chunk_key)
		notify_navigation_chunk_unloaded(chunk_key)
		if desired_gameplay_chunks.has(chunk_key) or retained_gameplay_chunks.has(chunk_key) \
				or startup_auxiliary_publication_chunks.has(chunk_key):
			queue_pending_gameplay_chunk(chunk_key)
	invalidated.sort_custom(func(a: Vector2i,b: Vector2i):
		return a.x < b.x if a.x != b.x else a.y < b.y)
	return invalidated

func stats() -> Dictionary:
	return {
		"retainedGameplayChunks":retained_gameplay_chunks.size(),
		"retainedRegionViewers":retained_chunk_viewers.size(),
		"retainedQueuedViewerGroups":retained_viewer_groups.size()-retained_chunk_viewers.size(),
		"retainedActivationReason":retained_activation_reason,
		"retainedLastPendingNativeTasks":retained_last_pending_tasks,
		"retainedActivationTaskLimit":RETAINED_MAX_PENDING_NATIVE_TASKS,
		"secondaryViewerPendingAdmissions":secondary_viewer_admissions.size(),
		"secondaryViewerAdmissionReason":secondary_viewer_admission_reason,
		"secondaryViewerPeakPendingNativeTasks":secondary_viewer_peak_pending_tasks,
		"secondaryViewerAttachCounts":secondary_viewer_attach_counts.duplicate(),
		"secondaryViewerRuntimeMeasurementStarted":secondary_viewer_runtime_measurement_started,
		"secondaryViewerRuntimePeakPendingNativeTasks":secondary_viewer_runtime_peak_pending_tasks,
		"secondaryViewerRuntimeAttachCounts":secondary_viewer_runtime_attach_counts.duplicate(),
		"secondaryViewerAdmissionFailure":secondary_viewer_terminal_failure.duplicate(true),
		"meshPreparationAvailable":mesh_preparation_extension_available,
		"meshPreparationAttached":is_instance_valid(mesh_preparation_viewer) and mesh_preparation_viewer.is_inside_tree(),
		"meshPreparationViewDistance":MESH_PREPARATION_VIEW_DISTANCE,
		"meshPreparationRebaseCells":MESH_PREPARATION_REBASE_CELLS,
		"meshPreparationRequestCell":mesh_preparation_request_cell,
		"meshPreparationAdmissionReason":mesh_preparation_admission_reason,
		"meshPreparationLastPendingNativeTasks":mesh_preparation_last_pending_native_tasks,
		"meshPreparationNativeTaskCap":MESH_PREPARATION_MAX_PENDING_NATIVE_TASKS,
		"meshPreparationAdmissionAttempts":mesh_preparation_admission_attempts,
		"meshPreparationAdmissionAccepts":mesh_preparation_admission_accepts,
		"meshPreparationBackpressureDeferrals":mesh_preparation_backpressure_deferrals,
		"retainedActivationIntervalSeconds":RETAINED_ACTIVATION_INTERVAL_SECONDS,
		"retainedViewDistance":RETAINED_VIEW_DISTANCE,
		"citadelAdmission":main.structure_system.citadel_terrain_admission.stats() if main != null and main.structure_system != null else {},
		"siteAdmissionFailure":site_gate.failure_reason() if site_gate != null else "",
		"ready": authority_ready,
		"publishedMeshBlocks": published_mesh_blocks.size(),
		"pendingEditSections": pending_edit_sections.size(),
		"editBatchesApplied": edit_batches_applied,
		"lastVolumeRevision": last_volume_revision,
		"appliedEditSignatures": applied_edit_signatures.size(),
		"desiredGameplayChunks": desired_gameplay_chunks.size(),
		"pendingGameplayChunks": pending_gameplay_chunks.size(),
		"pendingGameplayChunkQueue": pending_gameplay_chunk_order.size(),
		"pendingGameplayChunkKeys": pending_gameplay_chunk_keys(),
		"publishedGameplayChunks": published_gameplay_chunks.size(),
		"collisionProbeAttempts": collision_probe_attempts,
		"collisionProbePasses": collision_probe_passes,
		"collisionPriorityPromotions": collision_priority_promotions,
		"primaryViewerRequestCellSize": PRIMARY_VIEWER_REQUEST_CELL_SIZE,
		"foregroundCollisionDemandRevision": foreground_collision_demand_revision,
		"foregroundCollisionCurrent": foreground_collision_current,
		"foregroundCollisionTarget": foreground_collision_target,
		"foregroundCollisionLeadActive": foreground_collision_target.is_finite() and foreground_collision_target != foreground_collision_current,
		"nativeViewerWorkloads": native_viewer_workloads.duplicate(true),
		"startupViewDistance": STARTUP_VIEW_DISTANCE,
		"currentViewDistance": int(viewer.view_distance) if viewer != null and is_instance_valid(viewer) else 0,
		"finalViewDistance": FINAL_VIEW_DISTANCE,
		"viewDistanceExpansionRequested": view_distance_expansion_requested,
		"finalExpansionQuietFrames": final_expansion_quiet_frames,
		"startupAuxiliaryViewerCount": startup_auxiliary_viewers.size(),
		"startupAuxiliaryViewersCreated": startup_auxiliary_viewers_created,
		"startupAuxiliaryCleanupRequested": startup_auxiliary_cleanup_requested,
		"startupAuxiliaryCleanupFramesRemaining": startup_auxiliary_cleanup_frames_remaining,
		"startupAuxiliaryViewers": startup_auxiliary_viewer_diagnostics(),
		"verticalCellBounds": vertical_cell_bounds(),
		"finalVerticalCellBounds": full_vertical_cell_bounds(),
		"voxelEngine": voxel_engine_task_stats(),
		"terrain": terrain.get_statistics() if terrain != null else {},
		"configuredSeed": configured_seed
	}

func collect_volume_edit_changes() -> void:
	var service = volume_service()
	if service == null:
		return
	var revision := int(service.get("revision"))
	if revision == last_volume_revision:
		return
	last_volume_revision = revision
	var current_signatures := {}
	var edited_value = service.get("edited_cells")
	var edited_cells: Dictionary = edited_value if edited_value is Dictionary else {}
	for cell_value in edited_cells.keys():
		if not (cell_value is Vector3i):
			continue
		var cell: Vector3i = cell_value
		var state: Dictionary = edited_cells[cell] if edited_cells[cell] is Dictionary else {}
		if not state_affects_terrain_mesh(service, state):
			continue
		var signature := edit_signature(state)
		current_signatures[cell] = signature
		if String(applied_edit_signatures.get(cell, "")) != signature:
			queue_edit_change(cell, state, signature)
	for cell_value in applied_edit_signatures.keys():
		if current_signatures.has(cell_value):
			continue
		if cell_value is Vector3i:
			queue_edit_change(cell_value, {}, "")

func queue_loaded_block_edit_sections(block_position: Vector3i) -> void:
	var service = volume_service()
	if service == null:
		return
	var edited_value = service.get("edited_cells")
	if not (edited_value is Dictionary):
		return
	for cell_value in (edited_value as Dictionary).keys():
		if not (cell_value is Vector3i):
			continue
		var cell: Vector3i = cell_value
		if section_key_for_cell(cell) != block_position:
			continue
		var state: Dictionary = edited_value[cell] if edited_value[cell] is Dictionary else {}
		if state_affects_terrain_mesh(service, state):
			var signature := edit_signature(state)
			if String(applied_edit_signatures.get(cell, "")) != signature:
				queue_edit_change(cell, state, signature)

func queue_edit_change(cell: Vector3i, state: Dictionary, signature: String) -> void:
	var section_key := section_key_for_cell(cell)
	var changes: Dictionary = pending_edit_sections.get(section_key, {}) if pending_edit_sections.get(section_key, {}) is Dictionary else {}
	changes[cell] = {"state": state.duplicate(true), "signature": signature}
	pending_edit_sections[section_key] = changes
	# Invalidate only collision publications whose meshing halo can contain this
	# edit. This happens when the durable revision is observed, before the native
	# edit is pasted, so locomotion cannot reuse a stale local receipt.
	for chunk_key in gameplay_chunks_for_edit_cell(cell):
		gameplay_chunk_edit_revisions[chunk_key] = int(gameplay_chunk_edit_revisions.get(chunk_key, 0)) + 1
		if published_gameplay_chunks.erase(chunk_key):
			notify_navigation_chunk_unloaded(chunk_key)
		if gameplay_chunk_publication_owned(chunk_key):
			queue_pending_gameplay_chunk(chunk_key)

func gameplay_chunks_for_edit_cell(cell: Vector3i) -> Array[Vector2i]:
	var edit_bounds := Rect2i(Vector2i(cell.x, cell.z), Vector2i.ONE)
	var center_chunk := game_chunk_for_cell(cell)
	var result: Array[Vector2i] = []
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var chunk_key := center_chunk + Vector2i(dx, dz)
			var collision_bounds := Rect2i(
				chunk_key * GAME_CHUNK_SIZE,
				Vector2i.ONE * GAME_CHUNK_SIZE
			).grow(2)
			if collision_bounds.intersects(edit_bounds):
				result.append(chunk_key)
	result.sort_custom(func(a: Vector2i, b: Vector2i):
		return a.x < b.x if a.x != b.x else a.y < b.y)
	return result

func process_pending_edit_sections() -> void:
	if terrain == null or pending_edit_sections.is_empty():
		return
	var processed := 0
	for section_value in pending_edit_sections.keys():
		if processed >= EDIT_SECTIONS_PER_FRAME:
			break
		var section_key: Vector3i = section_value
		var changes: Dictionary = pending_edit_sections[section_key]
		if not apply_edit_batch(changes):
			continue
		pending_edit_sections.erase(section_key)
		processed += 1
		edit_batches_applied += 1

func apply_edit_batch(changes: Dictionary) -> bool:
	if changes.is_empty():
		return true
	var min_cell := Vector3i(2147483647, 2147483647, 2147483647)
	var max_cell := Vector3i(-2147483647, -2147483647, -2147483647)
	for cell_value in changes.keys():
		var cell: Vector3i = cell_value
		min_cell = Vector3i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y), mini(min_cell.z, cell.z))
		max_cell = Vector3i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y), maxi(max_cell.z, cell.z))
	var size := max_cell - min_cell + Vector3i.ONE
	var tool = terrain.get_voxel_tool()
	if not bool(tool.is_area_editable(AABB(Vector3(min_cell), Vector3(size)))):
		return false
	var buffer := VoxelBuffer.new()
	buffer.create(size.x, size.y, size.z)
	var channels_mask := (1 << VoxelBuffer.CHANNEL_SDF) | (1 << VoxelBuffer.CHANNEL_INDICES) | (1 << VoxelBuffer.CHANNEL_DATA5)
	tool.copy(min_cell, buffer, channels_mask, false)
	for cell_value in changes.keys():
		var cell: Vector3i = cell_value
		var change: Dictionary = changes[cell]
		var state: Dictionary = change.get("state", {}) if change.get("state", {}) is Dictionary else {}
		var sample := state if not state.is_empty() else generated_state_at_grid_cell(cell)
		var density := float(sample.get("density", -CELL))
		var material := String(sample.get("material", "air"))
		var material_id := int(MATERIAL_IDS.get(material, MATERIAL_IDS["stone"]))
		var local := cell - min_cell
		buffer.set_voxel_f(-density / CELL, local.x, local.y, local.z, VoxelBuffer.CHANNEL_SDF)
		buffer.set_voxel(material_id, local.x, local.y, local.z, VoxelBuffer.CHANNEL_INDICES)
		buffer.set_voxel(material_id, local.x, local.y, local.z, VoxelBuffer.CHANNEL_DATA5)
		var signature := String(change.get("signature", ""))
		if signature == "":
			applied_edit_signatures.erase(cell)
		else:
			applied_edit_signatures[cell] = signature
	tool.paste(min_cell, buffer, channels_mask)
	var affected_game_chunks := {}
	for cell_value in changes.keys():
		var cell: Vector3i = cell_value
		for chunk_key in gameplay_chunks_for_edit_cell(cell):
			affected_game_chunks[chunk_key] = true
	for chunk_value in affected_game_chunks.keys():
		request_gameplay_chunk_republication(chunk_value)
	return true

func request_gameplay_chunk_publication(chunk_key: Vector2i) -> void:
	desired_gameplay_chunks[chunk_key] = true
	if not published_gameplay_chunks.has(chunk_key):
		queue_pending_gameplay_chunk(chunk_key)

func request_gameplay_chunk_republication(chunk_key: Vector2i) -> void:
	if not gameplay_chunk_publication_owned(chunk_key):
		return
	if published_gameplay_chunks.erase(chunk_key):
		notify_navigation_chunk_unloaded(chunk_key)
	queue_pending_gameplay_chunk(chunk_key)

func release_gameplay_chunk(chunk_key: Vector2i) -> bool:
	if retained_gameplay_chunks.has(chunk_key) or startup_auxiliary_publication_chunks.has(chunk_key): return false
	desired_gameplay_chunks.erase(chunk_key)
	pending_gameplay_chunks.erase(chunk_key)
	pending_gameplay_chunk_order.erase(chunk_key)
	if published_gameplay_chunks.erase(chunk_key):
		notify_navigation_chunk_unloaded(chunk_key)
	return true

func queue_pending_gameplay_chunk(chunk_key: Vector2i) -> void:
	if pending_gameplay_chunks.has(chunk_key):
		return
	pending_gameplay_chunks[chunk_key] = true
	pending_gameplay_chunk_order.append(chunk_key)

func gameplay_chunk_publication_owned(chunk_key: Vector2i) -> bool:
	return desired_gameplay_chunks.has(chunk_key) \
		or retained_gameplay_chunks.has(chunk_key) \
		or startup_auxiliary_publication_chunks.has(chunk_key)

func _promote_pending_gameplay_chunk_for_collision(chunk_key: Vector2i) -> bool:
	if not pending_gameplay_chunks.has(chunk_key):
		return false
	var index := pending_gameplay_chunk_order.find(chunk_key)
	if index < 0:
		# Preserve retryability if a stale queue shell was repaired while the
		# pending authority remained live. This creates no new terrain demand.
		pending_gameplay_chunk_order.push_front(chunk_key)
		collision_priority_promotions += 1
		return true
	if index == 0:
		return false
	pending_gameplay_chunk_order.remove_at(index)
	pending_gameplay_chunk_order.push_front(chunk_key)
	collision_priority_promotions += 1
	return true

func gameplay_chunks_published(chunk_keys: Array) -> bool:
	for key_value in chunk_keys:
		if key_value is Vector2i and not published_gameplay_chunks.has(key_value):
			return false
	return true

func published_gameplay_chunk_count(chunk_keys: Array) -> int:
	var count := 0
	for key_value in chunk_keys:
		if key_value is Vector2i and published_gameplay_chunks.has(key_value):
			count += 1
	return count

func gameplay_publication_diagnostics(chunk_keys: Array) -> Dictionary:
	var chunk_diagnostics: Array = []
	for key_value in chunk_keys:
		if not (key_value is Vector2i):
			continue
		var chunk_key: Vector2i = key_value
		var proof: Dictionary = published_gameplay_chunks.get(chunk_key, {}) if published_gameplay_chunks.get(chunk_key, {}) is Dictionary else {}
		if proof.is_empty():
			proof = collision_proof_for_game_chunk(chunk_key)
		chunk_diagnostics.append({
			"key": "%d,%d" % [chunk_key.x, chunk_key.y],
			"desired": desired_gameplay_chunks.has(chunk_key),
			"pending": pending_gameplay_chunks.has(chunk_key),
			"published": published_gameplay_chunks.has(chunk_key),
			"proof": proof
		})
	return {
		"configuredSeed": configured_seed,
		"authorityReady": authority_ready,
		"viewerPosition": viewer.global_position if viewer != null and is_instance_valid(viewer) and viewer.is_inside_tree() else Vector3.ZERO,
		"viewerRequiresVisuals": bool(viewer.requires_visuals) if viewer != null and is_instance_valid(viewer) else false,
		"viewerRequiresCollisions": bool(viewer.requires_collisions) if viewer != null and is_instance_valid(viewer) else false,
		"startupAuxiliaryViewers": startup_auxiliary_viewer_diagnostics(),
		"publishedMeshBlockCount": published_mesh_blocks.size(),
		"desiredGameplayChunkCount": desired_gameplay_chunks.size(),
		"pendingGameplayChunkCount": pending_gameplay_chunks.size(),
		"publishedGameplayChunkCount": published_gameplay_chunks.size(),
		"terrainStatistics": terrain.get_statistics() if terrain != null else {},
		"chunks": chunk_diagnostics
	}

func process_pending_gameplay_chunk_publications() -> void:
	if pending_gameplay_chunks.is_empty() or main == null or not is_inside_tree():
		return
	if pending_gameplay_chunk_order.is_empty():
		for key_value in pending_gameplay_chunks.keys():
			if key_value is Vector2i:
				pending_gameplay_chunk_order.append(key_value)
	var probe_count := mini(PUBLICATION_PROBES_PER_PHYSICS_FRAME, pending_gameplay_chunk_order.size())
	for _index in range(probe_count):
		var chunk_key: Vector2i = pending_gameplay_chunk_order.pop_front()
		if not pending_gameplay_chunks.has(chunk_key):
			continue
		if not gameplay_chunk_publication_owned(chunk_key):
			pending_gameplay_chunks.erase(chunk_key)
			continue
		# Durable edit state invalidates the old receipt before the native voxel
		# paste is necessarily available. Do not certify collision from that
		# in-between mesh. The two-cell halo matches queue_edit_change's mesh
		# invalidation footprint, and the pending entry remains retryable.
		var chunk_collision_bounds := Rect2i(
			chunk_key * GAME_CHUNK_SIZE,
			Vector2i.ONE * GAME_CHUNK_SIZE
		).grow(2)
		if pending_edit_sections_intersect_bounds(chunk_collision_bounds):
			pending_gameplay_chunk_order.append(chunk_key)
			continue
		collision_probe_attempts += 1
		var proof := collision_proof_for_game_chunk(chunk_key)
		if not bool(proof.get("passed", false)):
			pending_gameplay_chunk_order.append(chunk_key)
			continue
		pending_gameplay_chunks.erase(chunk_key)
		published_gameplay_chunks[chunk_key] = proof
		collision_probe_passes += 1
		notify_navigation_chunk_loaded(chunk_key)

func collision_proof_for_game_chunk(chunk_key: Vector2i) -> Dictionary:
	if terrain == null or get_world_3d() == null:
		return {"passed": false, "reason": "physics_world_missing"}
	var volume = volume_service()
	if volume == null or not volume.has_method("terrain_mesh_surface_projection_for_cell"):
		return {"passed": false, "reason": "terrain_volume_projection_missing"}
	var probe_positions := gameplay_chunk_collision_probe_positions(chunk_key)
	var hits := 0
	var matched := 0
	var expected_surfaces := 0
	var samples := []
	var min_surface_cell_y := 2147483000
	var max_surface_cell_y := -2147483000
	var space := get_world_3d().direct_space_state
	for probe_position in probe_positions:
		var x := probe_position.x
		var z := probe_position.z
		var cell := Vector3i(floori(x / CELL), 0, floori(z / CELL))
		var projection: Dictionary = volume.call("terrain_mesh_surface_projection_for_cell", cell)
		if not bool(projection.get("found", false)):
			samples.append({"x": snappedf(x, 0.01), "z": snappedf(z, 0.01), "expectedTerrainSurface": false})
			continue
		expected_surfaces += 1
		var expected_y := float((projection.get("position", Vector3.ZERO) as Vector3).y)
		var expected_cell_y := floori(expected_y / CELL)
		min_surface_cell_y = mini(min_surface_cell_y, expected_cell_y)
		max_surface_cell_y = maxi(max_surface_cell_y, expected_cell_y)
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(x, expected_y + CELL * 48.0, z),
			Vector3(x, float(volume.call("world_bottom_cell_y")) * CELL - CELL * 2.0, z),
			TERRAIN_COLLISION_LAYER
		)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty() or not voxel_terrain_collider(hit.get("collider")):
			samples.append({"x": snappedf(x, 0.01), "z": snappedf(z, 0.01), "expectedY": snappedf(expected_y, 0.01), "hit": false})
			continue
		hits += 1
		var hit_y := float((hit.get("position", Vector3.ZERO) as Vector3).y)
		var delta_y := absf(hit_y - expected_y)
		if delta_y <= COLLISION_SURFACE_TOLERANCE:
			matched += 1
		samples.append({"x": snappedf(x, 0.01), "z": snappedf(z, 0.01), "expectedY": snappedf(expected_y, 0.01), "hit": true, "hitY": snappedf(hit_y, 0.01), "deltaY": snappedf(delta_y, 0.01)})
	if expected_surfaces == 0:
		var active_vertical_bounds := vertical_cell_bounds()
		min_surface_cell_y = active_vertical_bounds.x + COLLISION_MESH_VERTICAL_MARGIN_CELLS
		max_surface_cell_y = active_vertical_bounds.y - COLLISION_MESH_VERTICAL_MARGIN_CELLS
	var mesh_area := AABB(
		Vector3(
			float(chunk_key.x * GAME_CHUNK_SIZE),
			float(min_surface_cell_y - COLLISION_MESH_VERTICAL_MARGIN_CELLS),
			float(chunk_key.y * GAME_CHUNK_SIZE)
		),
		Vector3(
			float(GAME_CHUNK_SIZE),
			float(max_surface_cell_y - min_surface_cell_y + COLLISION_MESH_VERTICAL_MARGIN_CELLS * 2 + 1),
			float(GAME_CHUNK_SIZE)
		)
	)
	var area_meshed := terrain.is_area_meshed(mesh_area)
	return {
		"passed": area_meshed and hits == expected_surfaces,
		"areaMeshed": area_meshed,
		"meshArea": mesh_area,
		"hits": hits,
		"expectedTerrainSurfaces": expected_surfaces,
		"surfaceMatches": matched,
		"heightfieldComparisonPassed": matched == probe_positions.size(),
		"collisionAuthority": "VoxelTerrain",
		"configuredSeed": configured_seed,
		"collisionOwnerGeneration": collision_owner_generation,
		"terrainInstanceId": terrain.get_instance_id(),
		"chunk": chunk_key,
		"chunkEditRevision": int(gameplay_chunk_edit_revisions.get(chunk_key, 0)),
		"probeCount": probe_positions.size(),
		"samples": samples
	}


func collision_proof_for_world_position(world_position: Vector3, footprint_radius := 0.0) -> Dictionary:
	if terrain == null or get_world_3d() == null:
		return {"passed": false, "reason": "physics_world_missing"}
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null or not world_generation.has_method("surface_y_at"):
		return {"passed": false, "reason": "surface_facade_missing"}
	var radius := maxf(0.0, footprint_radius)
	var offsets: Array[Vector2] = [Vector2.ZERO]
	if radius > 0.0:
		offsets.append_array([
			Vector2(radius, 0.0),
			Vector2(-radius, 0.0),
			Vector2(0.0, radius),
			Vector2(0.0, -radius)
		])
	var samples: Array = []
	var center_matched := false
	var matched := 0
	var mesh_ready := collision_mesh_ready_for_world_position(world_position, radius)
	if not bool(mesh_ready.get("passed", false)):
		return {
			"passed": false,
			"reason": "collision_mesh_not_ready",
			"position": world_position,
			"footprintRadius": radius,
			"mesh": mesh_ready,
			"samples": []
		}
	var space := get_world_3d().direct_space_state
	for index in range(offsets.size()):
		var sample_x := world_position.x + offsets[index].x
		var sample_z := world_position.z + offsets[index].y
		var expected_y := float(world_generation.call("surface_y_at", Vector3(sample_x, 0.0, sample_z)))
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(sample_x, expected_y + CELL * 48.0, sample_z),
			Vector3(sample_x, float(world_generation.call("world_bottom_cell_y")) * CELL - CELL * 2.0, sample_z),
			TERRAIN_COLLISION_LAYER
		)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty() or not voxel_terrain_collider(hit.get("collider")):
			samples.append({"offset": offsets[index], "expectedY": snappedf(expected_y, 0.01), "hit": false})
			continue
		var hit_y := float((hit.get("position", Vector3.ZERO) as Vector3).y)
		var delta_y := absf(hit_y - expected_y)
		var surface_matched := delta_y <= COLLISION_SURFACE_TOLERANCE
		if surface_matched:
			matched += 1
			if index == 0:
				center_matched = true
		samples.append({
			"offset": offsets[index],
			"expectedY": snappedf(expected_y, 0.01),
			"hit": true,
			"hitY": snappedf(hit_y, 0.01),
			"deltaY": snappedf(delta_y, 0.01),
			"surfaceMatched": surface_matched
		})
	return {
		"passed": center_matched and matched == samples.size(),
		"reason": "collision_ready" if center_matched and matched == samples.size() else "footprint_collision_not_ready",
		"position": world_position,
		"footprintRadius": radius,
		"mesh": mesh_ready,
		"matchedSamples": matched,
		"sampleCount": samples.size(),
		"samples": samples
	}


func collision_mesh_ready_for_world_position(world_position: Vector3, footprint_radius := 0.0) -> Dictionary:
	if terrain == null:
		return {"passed": false, "reason": "terrain_missing"}
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null or not world_generation.has_method("surface_y_at"):
		return {"passed": false, "reason": "surface_facade_missing"}
	var radius_cells := maxi(1, ceili(maxf(0.0, footprint_radius) / CELL) + 1)
	var local_position := terrain.to_local(world_position)
	var expected_y := float(world_generation.call("surface_y_at", world_position))
	var local_surface_y := terrain.to_local(Vector3(world_position.x, expected_y, world_position.z)).y
	var area := AABB(
		Vector3(
			floorf(local_position.x) - float(radius_cells),
			floorf(local_surface_y) - float(COLLISION_MESH_VERTICAL_MARGIN_CELLS),
			floorf(local_position.z) - float(radius_cells)
		),
		Vector3(
			float(radius_cells * 2 + 1),
			float(COLLISION_MESH_VERTICAL_MARGIN_CELLS * 2 + 1),
			float(radius_cells * 2 + 1)
		)
	)
	return {
		"passed": terrain.is_area_meshed(area),
		"area": area,
		"expectedY": expected_y
	}


func spawn_presentation_state(world_position: Vector3) -> Dictionary:
	if not authority_ready or terrain == null or not terrain.is_visible_in_tree():
		return {"ready":false,"reason":"terrain_visual_owner_pending"}
	if viewer == null or not viewer.requires_visuals or get_viewport().get_camera_3d() == null:
		return {"ready":false,"reason":"terrain_visual_view_pending"}
	var key := Vector2i(floori(world_position.x/(GAME_CHUNK_SIZE*CELL)),floori(world_position.z/(GAME_CHUNK_SIZE*CELL)))
	# Visual readiness is a local proof for the player chunk. Keep its mesh
	# collision halo conservative, but do not turn a distant edit awaiting native
	# residency into an indefinite loading screen at the spawn point.
	var presentation_bounds := Rect2i(key * GAME_CHUNK_SIZE, Vector2i.ONE * GAME_CHUNK_SIZE).grow(1)
	if not published_gameplay_chunks.has(key) or pending_gameplay_chunks.has(key) \
			or pending_edit_sections_intersect_bounds(presentation_bounds):
		return {"ready":false,"reason":"spawn_chunk_publication_pending","chunk":key}
	var proof := collision_mesh_ready_for_body_position(world_position,0.42)
	return {"ready":bool(proof.get("passed",false)),"reason":"spawn_mesh_publication","chunk":key,
		"seed":configured_seed,"volumeRevision":last_volume_revision,"mesh":proof}

func wait_for_spawn_presentation(world_position: Vector3, timeout_seconds: float) -> Dictionary:
	# Existing startup gates already require nearby chunk meshes and physics.
	# Keep the loading UI and movement lock until a frame using those resources
	# has been drawn. Headless contracts cannot certify visual presentation.
	if DisplayServer.get_name() == "headless":
		return STARTUP_READINESS_RESULT_SCRIPT.ready({}, {"presentationVerified":false,"reason":"headless_presentation_excluded"})
	var started := Time.get_ticks_msec()
	var drawn := [false]
	var on_draw := func(): drawn[0] = true
	var armed_state := {}
	while float(Time.get_ticks_msec()-started)/1000.0 < timeout_seconds:
		if not is_instance_valid(main) or main.get("shutdown_requested") == true:
			if RenderingServer.frame_post_draw.is_connected(on_draw): RenderingServer.frame_post_draw.disconnect(on_draw)
			return STARTUP_READINESS_RESULT_SCRIPT.failed("startup_cancelled")
		var state := spawn_presentation_state(world_position)
		if state.get("ready",false):
			if drawn[0] and state == armed_state:
				var metrics := {"presentationVerified":true,"elapsedMs":Time.get_ticks_msec()-started,"terrain":state}
				await main.startup_loading_yield("Nearby terrain displayed", "terrain_presentation", "ready", metrics)
				return STARTUP_READINESS_RESULT_SCRIPT.ready({},metrics)
			if armed_state != state:
				if RenderingServer.frame_post_draw.is_connected(on_draw): RenderingServer.frame_post_draw.disconnect(on_draw)
				drawn[0] = false
				armed_state = state
				RenderingServer.frame_post_draw.connect(on_draw,CONNECT_ONE_SHOT)
		else:
			if RenderingServer.frame_post_draw.is_connected(on_draw): RenderingServer.frame_post_draw.disconnect(on_draw)
			drawn[0] = false
			armed_state = {}
		await main.startup_loading_yield("Drawing nearby terrain", "terrain_presentation", "pending",state)
	if RenderingServer.frame_post_draw.is_connected(on_draw): RenderingServer.frame_post_draw.disconnect(on_draw)
	return STARTUP_READINESS_RESULT_SCRIPT.failed("terrain_presentation_timeout",{},[],{"terrain":spawn_presentation_state(world_position)})

func collision_mesh_ready_for_body_position(world_position: Vector3, footprint_radius := 0.0) -> Dictionary:
	if terrain == null:
		return {"passed": false, "reason": "terrain_missing"}
	var radius_cells := maxi(1, ceili(maxf(0.0, footprint_radius) / CELL) + 1)
	var local_position := terrain.to_local(world_position)
	var area := AABB(
		Vector3(
			floorf(local_position.x) - float(radius_cells),
			floorf(local_position.y) - float(COLLISION_MESH_VERTICAL_MARGIN_CELLS),
			floorf(local_position.z) - float(radius_cells)
		),
		Vector3(
			float(radius_cells * 2 + 1),
			float(COLLISION_MESH_VERTICAL_MARGIN_CELLS * 2 + 3),
			float(radius_cells * 2 + 1)
		)
	)
	var passed := terrain.is_area_meshed(area)
	return {
		"passed": passed,
		"reason": "collision_mesh_ready" if passed else "collision_mesh_not_ready",
		"area": area,
		"position": world_position,
		"footprintRadius": maxf(0.0, footprint_radius),
		"collisionAuthority": "VoxelTerrain"
	}


func collision_proof_for_motion(from_position: Vector3, to_position: Vector3, footprint_radius := 0.42) -> Dictionary:
	var monitor = main.get("runtime_perf_monitor") if main != null else null
	var motion_started := Time.get_ticks_usec()
	if monitor != null:
		monitor.increment_counter("terrain_motion_proof_entries")
	var request := {"from":from_position,"to":to_position,"radius":footprint_radius}
	var now_usec := Time.get_ticks_usec()
	if site_traversal_waiting and request == site_traversal_pending_request \
			and now_usec-site_traversal_last_poll_usec<SITE_TRAVERSAL_READINESS_POLL_USEC \
			and not site_traversal_last_proof.is_empty():
		var retained := site_traversal_last_proof.duplicate(true)
		_record_motion_proof(monitor,motion_started,int(retained.get("sampleCount",0)),int(retained.get("chunkCount",0)),true)
		return retained
	site_traversal_pending_request = request
	site_traversal_last_poll_usec = now_usec
	if not _local_collision_identity_current():
		var invalid := _retain_site_traversal_wait({"passed":false,"reason":"terrain_collision_owner_stale","sampleCount":0,"chunkCount":0})
		_record_motion_proof(monitor,motion_started,0,0,false)
		return invalid
	var displacement := to_position - from_position
	var distance := displacement.length()
	var sample_spacing := maxf(CELL * MOTION_PROOF_SAMPLE_SPACING_CELLS, footprint_radius)
	var sample_segments := maxi(1,ceili(distance/sample_spacing))
	if sample_segments + 1 > MOTION_PROOF_MAX_SAMPLES:
		var split := _retain_site_traversal_wait({"passed":false,"reason":"motion_sweep_requires_progression",
			"sampleCount":0,"chunkCount":0,"requestedSamples":sample_segments+1,
			"maximumSamples":MOTION_PROOF_MAX_SAMPLES})
		_record_motion_proof(monitor,motion_started,0,0,false)
		return split
	var chunk_started := Time.get_ticks_usec()
	var required_chunks := _motion_gameplay_chunks(from_position,to_position,footprint_radius)
	if monitor != null: monitor.observe_external_duration("terrain_motion_proof_chunk_receipts",float(Time.get_ticks_usec()-chunk_started)/1000.0)
	for chunk_key: Vector2i in required_chunks:
		var receipt: Dictionary = published_gameplay_chunks.get(chunk_key,{}) if published_gameplay_chunks.get(chunk_key,{}) is Dictionary else {}
		if not _collision_chunk_receipt_current(chunk_key,receipt):
			# This is an exact authoritative movement dependency, not speculative
			# prefetch. Keep the fail-closed result, but let its already-retained
			# collision publication move ahead of unrelated background receipts.
			_promote_pending_gameplay_chunk_for_collision(chunk_key)
			var missing := _retain_site_traversal_wait({"passed":false,"reason":"collision_chunk_publication_pending",
				"missingChunk":chunk_key,"sampleCount":0,"chunkCount":required_chunks.size()})
			_record_motion_proof(monitor,motion_started,0,required_chunks.size(),false)
			return missing
	var proofs: Array = []
	for index in range(sample_segments + 1):
		var weight := float(index) / float(sample_segments)
		var sample_position := from_position.lerp(to_position, weight)
		var mesh_started := Time.get_ticks_usec()
		var mesh_proof := collision_mesh_ready_for_body_position(sample_position, footprint_radius)
		if monitor != null: monitor.observe_external_duration("terrain_motion_proof_mesh_query",float(Time.get_ticks_usec()-mesh_started)/1000.0)
		var proof := {
			"passed": bool(mesh_proof.get("passed", false)),
			"reason": String(mesh_proof.get("reason", "collision_mesh_not_ready")),
			"position": sample_position,
			"mesh": mesh_proof,
			"supportRequiredForMotion": false,
			"supportObservationReason": "not_sampled_hot_path"
		}
		proofs.append(proof)
		if not bool(proof.get("passed", false)):
			var failed := _retain_site_traversal_wait({
				"passed": false,
				"reason": String(proof.get("reason", "collision_not_ready")),
				"failedSample": index,
				"sampleCount": sample_segments + 1,
				"chunkCount": required_chunks.size(),
				"proofs": proofs
			})
			_record_motion_proof(monitor,motion_started,sample_segments+1,required_chunks.size(),false)
			return failed
	clear_site_traversal_wait()
	var result := {
		"passed": true,
		"reason": "collision_mesh_ready",
		"supportRequiredForMotion": false,
		"sampleCount": sample_segments + 1,
		"chunkCount": required_chunks.size(),
		"collisionOwnerGeneration":collision_owner_generation,
		"proofs": proofs
	}
	_record_motion_proof(monitor,motion_started,sample_segments+1,required_chunks.size(),false)
	return result

func _local_collision_identity_current() -> bool:
	if not authority_ready or terrain == null or not is_instance_valid(terrain) or main == null:
		return false
	if configured_seed != String(main.get("seed_text")):
		return false
	var volume = volume_service()
	return volume != null and int(volume.get("revision")) == last_volume_revision

func _collision_chunk_receipt_current(chunk_key: Vector2i, receipt: Dictionary) -> bool:
	return bool(receipt.get("passed",false)) and receipt.get("chunk") == chunk_key \
		and String(receipt.get("configuredSeed","")) == configured_seed \
		and int(receipt.get("collisionOwnerGeneration",-1)) == collision_owner_generation \
		and int(receipt.get("terrainInstanceId",0)) == terrain.get_instance_id() \
		and int(receipt.get("chunkEditRevision",-1)) == int(gameplay_chunk_edit_revisions.get(chunk_key,0)) \
		and not pending_gameplay_chunks.has(chunk_key)

func _motion_gameplay_chunks(from_position: Vector3, to_position: Vector3, footprint_radius: float) -> Array[Vector2i]:
	var margin_cells := ceili(maxf(0.0,footprint_radius)/CELL)+2
	var low := Vector2i(floori(minf(from_position.x,to_position.x)/CELL),floori(minf(from_position.z,to_position.z)/CELL))-Vector2i.ONE*margin_cells
	var high := Vector2i(ceili(maxf(from_position.x,to_position.x)/CELL),ceili(maxf(from_position.z,to_position.z)/CELL))+Vector2i.ONE*margin_cells
	var first := Vector2i(floori(float(low.x)/GAME_CHUNK_SIZE),floori(float(low.y)/GAME_CHUNK_SIZE))
	var last := Vector2i(floori(float(high.x)/GAME_CHUNK_SIZE),floori(float(high.y)/GAME_CHUNK_SIZE))
	var result: Array[Vector2i] = []
	for z in range(first.y,last.y+1):
		for x in range(first.x,last.x+1): result.append(Vector2i(x,z))
	return result

func _record_motion_proof(monitor, started_usec: int, samples: int, chunks: int, reused: bool) -> void:
	if monitor == null: return
	monitor.increment_counter("terrain_motion_proof_samples",samples)
	monitor.increment_counter("terrain_motion_proof_chunks",chunks)
	if reused: monitor.increment_counter("terrain_motion_proof_retained_poll_hits")
	monitor.observe_gauge("terrain_motion_proof_last_samples",float(samples))
	monitor.observe_gauge("terrain_motion_proof_last_chunks",float(chunks))
	monitor.observe_external_duration("terrain_motion_proof",float(Time.get_ticks_usec()-started_usec)/1000.0)

func _retain_site_traversal_wait(proof: Dictionary) -> Dictionary:
	site_traversal_waiting = true
	site_traversal_last_proof = proof.duplicate(true)
	return proof

func clear_site_traversal_wait() -> void:
	if site_traversal_waiting and main != null and main.has_method("hide_streaming_loading_overlay"):
		main.call("hide_streaming_loading_overlay","terrain_traversal")
	site_traversal_waiting = false
	site_traversal_pending_request.clear()
	site_traversal_last_proof.clear()
	site_traversal_last_poll_usec = 0

func poll_site_traversal_readiness() -> void:
	if not site_traversal_waiting or site_traversal_pending_request.is_empty(): return
	if Time.get_ticks_usec()-site_traversal_last_poll_usec<SITE_TRAVERSAL_READINESS_POLL_USEC: return
	collision_proof_for_motion(site_traversal_pending_request.from,site_traversal_pending_request.to,
		float(site_traversal_pending_request.radius))

func voxel_terrain_collider(value) -> bool:
	if value == null or not is_instance_valid(value):
		return false
	if value == terrain:
		return true
	return value is Node and (value as Node).name == terrain.name

func notify_navigation_chunk_loaded(chunk_key: Vector2i) -> void:
	var npc_system = main.get("npc_system") if main != null else null
	if npc_system != null and npc_system.has_method("notify_navigation_chunk_loaded"):
		for navigation_tile_key in navigation_tile_keys_for_game_chunk(chunk_key):
			npc_system.call("notify_navigation_chunk_loaded", navigation_tile_key)

func notify_navigation_chunk_unloaded(chunk_key: Vector2i) -> void:
	var npc_system = main.get("npc_system") if main != null else null
	if npc_system != null and npc_system.has_method("notify_navigation_chunk_unloaded"):
		for navigation_tile_key in navigation_tile_keys_for_game_chunk(chunk_key):
			npc_system.call("notify_navigation_chunk_unloaded", navigation_tile_key)

## Native terrain publishes 28-cell gameplay chunks, while NPC topology is
## partitioned into 16-cell navigation tiles whose terrain capture grows one
## cell beyond the core. Convert the gameplay chunk through that same capture
## halo so load/unload cannot leave an aligned neighbouring tile stale.
static func navigation_tile_keys_for_game_chunk(chunk_key: Vector2i) -> Array[Vector2i]:
	var gameplay_bounds := Rect2i(
		chunk_key * GAME_CHUNK_SIZE,
		Vector2i.ONE * GAME_CHUNK_SIZE)
	var candidate_core_cells := gameplay_bounds.grow(1)
	var first_cell := candidate_core_cells.position
	var last_cell := candidate_core_cells.end - Vector2i.ONE
	var first_tile := Vector2i(
		floori(float(first_cell.x) / float(NAVIGATION_TILE_CELL_SIZE)),
		floori(float(first_cell.y) / float(NAVIGATION_TILE_CELL_SIZE))
	)
	var last_tile := Vector2i(
		floori(float(last_cell.x) / float(NAVIGATION_TILE_CELL_SIZE)),
		floori(float(last_cell.y) / float(NAVIGATION_TILE_CELL_SIZE))
	)
	var result: Array[Vector2i] = []
	for tile_z in range(first_tile.y, last_tile.y + 1):
		for tile_x in range(first_tile.x, last_tile.x + 1):
			result.append(Vector2i(tile_x, tile_z))
	return result

func game_chunk_for_cell(cell: Vector3i) -> Vector2i:
	return Vector2i(
		floori(float(cell.x) / float(GAME_CHUNK_SIZE)),
		floori(float(cell.z) / float(GAME_CHUNK_SIZE))
	)

func generated_state_at_grid_cell(cell: Vector3i) -> Dictionary:
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null or not world_generation.has_method("generate_sample_without_volume"):
		return {"density": -CELL, "material": "air"}
	var position := Vector3(cell) * CELL
	var sample: Dictionary = world_generation.call("generate_sample_without_volume", position)
	var density := float(sample.get("density", -CELL))
	var material := String(sample.get("material", "air"))
	if density >= 0.0 and world_generation.has_method("generated_solid_material_for_cell"):
		var surface_y := float(sample.get("baseSurfaceY", sample.get("surfaceY", position.y)))
		var surface_biome := String(world_generation.call("surface_biome_for_cell3", Vector3i(cell.x, 0, cell.z)))
		var depth := maxf(0.0, surface_y - position.y)
		material = String(world_generation.call("generated_solid_material_for_cell", cell, surface_y, surface_biome, depth))
	return {"density": density, "material": material}

func section_key_for_cell(cell: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(cell.x) / float(SECTION_SIZE)),
		floori(float(cell.y) / float(SECTION_SIZE)),
		floori(float(cell.z) / float(SECTION_SIZE))
	)

func volume_service():
	var world_generation = main.get("world_generation_system") if main != null else null
	return world_generation.get("terrain_volume_service") if world_generation != null else null

func state_affects_terrain_mesh(service, state: Dictionary) -> bool:
	if service != null and service.has_method("cell_state_affects_terrain_mesh"):
		return bool(service.call("cell_state_affects_terrain_mesh", state))
	return true

func edit_signature(state: Dictionary) -> String:
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	return "%s|%s|%.6f|%s|%s" % [
		String(state.get("material", "air")),
		str(bool(state.get("solid", false))),
		float(state.get("density", -CELL)),
		String(state.get("fluid", "")),
		String(metadata.get("source", ""))
	]
