extends RefCounted
class_name CitadelPublicationService

## StructureSystem-owned preparation and scene-job lifecycle. Scene construction
## is distinct from gameplay activation: doors/access must be acknowledged by
## the ordinary owner before a constructed city can become playable.
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const SceneJob = preload("res://scripts/buildings/BuildingScenePublicationJob.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const SitePreparation = preload("res://scripts/world/CitadelSitePreparation.gd")
const DemandSet = preload("res://scripts/world/RegionDemandSet.gd")
const ViewPriority = preload("res://scripts/world/GeneratedContentViewPriority.gd")
const SectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const SectionGeometryAdapter = preload("res://scripts/world/CitadelSectionGeometryAdapter.gd")
const SectionSnapshotBuilder = preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const SectionPacketOwner = preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const SectionInstallSession = preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const OwnerCompletion = preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const OwnerSectionSlice = preload("res://scripts/world/StaticGeometryOwnerSectionSlice.gd")
const LegacyVisualIndex = preload("res://scripts/world/CitadelLegacySectionVisualIndex.gd")
const SourceRoster = preload("res://scripts/world/StaticSectionSourceRoster.gd")
const TreeVisualPolicy = preload("res://scripts/world/EcologyProducerDomain.gd")
const MAX_REGIONS := 16
const MAX_RETAINED_BOUNDS := 64
const MAX_OWNER_SECTION_SLICE_CACHE := 512
const MAX_OWNER_SECTION_SLICE_JOBS := 512
const MAX_SECTION_CONTRIBUTION_CAPTURE_JOBS := 32
const SECTION_CONTRIBUTION_CAPTURE_IDLE_FRAMES := 120
const MAX_CITADEL_CENSUS_MEMBER_AUTHORITIES_PER_ADVANCE := 8
const CITADEL_CENSUS_MEMBER_AUTHORITY_ADVANCE_BUDGET_USEC := 2000
const MAX_CITADEL_CENSUS_CAPTURE_JOBS := 64
const CITADEL_CENSUS_CAPTURE_IDLE_FRAMES := 120
const MAX_RETAINED_TRANSFORM_ARTIFACT_CAPTURES := 2048
const OWNER_SECTION_SLICE_ADVANCE_BUDGET_USEC := 250
const MAX_PENDING_SECTION_SOURCE_RETIREMENTS := 512
const MAX_SECTION_SOURCE_RETIREMENTS_PER_ADVANCE := 2
const SECTION_SOURCE_RETIREMENT_ADVANCE_BUDGET_USEC := 500
const MAX_DISCOVERY_CHUNKS := 256
const DISCOVERY_CHUNK_SIZE := 28
const PREPARATION_TIMEOUT_USEC := 60000000
const NAVIGATION_TILE_CELLS := preload("res://scripts/buildings/layout/BuildingLayoutConstants.gd").NAV_TILE_CELL_SIZE
# Admission confines source geometry to one candidate region. The producer
# adds one output-neighbour tile on each side; this bounds INVENTORY, not the
# independent limit on simultaneously retained navigation requests.
const MAX_NAVIGATION_DOMAIN_AXIS := ceili(float(Field.REGION_CELLS)/float(NAVIGATION_TILE_CELLS))+2
const MAX_NAVIGATION_DOMAIN_KEYS := MAX_NAVIGATION_DOMAIN_AXIS*MAX_NAVIGATION_DOMAIN_AXIS
const MAX_PENDING_NAVIGATION_TILES := 512
# Scheduling policy, not a measured latency target. An eligible waiter gains
# one priority class per four successful worker dispatches, never per query.
const PRIORITY_AGING_DISPATCH_TURNS := 4
# Optional view breadth is a scheduling quota. An exact player/nav safety
# closure may legitimately be wider (the gatehouse joins many collision-bearing
# parts), but remains finite and is split below by the job's measured byte,
# member, collision, registration and time budgets.
const MAX_REQUIRED_FOREGROUND_GROUPS := 1024
const MAX_INCREMENTAL_FOREGROUND_GROUPS := 256
const MAX_ACTIVE_NAVIGATION_PHYSICAL_GROUPS := 256
# Navigation can retain a much wider source closure than the facing physical
# packet. Merge at most this many supplemental groups alongside the source
# window so one tile cannot turn hundreds of tiny battlement groups into a
# single long-lived scene backlog. The combined window remains subject to the
# hard required-foreground ceiling.
const MAX_NAVIGATION_MERGED_FOREGROUND_GROUPS := 128
# Ahead-of-player presentation may warm a substantial, view-ranked working set,
# but it must settle instead of draining the entire source while the camera is
# unchanged. Exact owner and navigation closures can still exceed this count.
const MAX_RESIDENT_PRESENTATION_GROUPS := 1024
const VIEW_WINDOW_PROGRESS_TARGET_GROUPS := 64
const SCENE_UNIT_SAMPLE_CAPACITY := 4096
# Leave headroom for the scene job's final bounded atomic unit and scheduler
# jitter inside the public 4 ms gameplay-thread ceiling.
const SCENE_JOB_SLICE_USEC := 1500
const RETAINED_SOURCE_SLICE_USEC := 750
const RETAINED_SOURCE_UNIT_CAP := 96
const FIRST_USEFUL_HOME_COUNT := 2
const FIRST_USEFUL_HOME_ARCHETYPES: Array[String] = ["bed","chair","hearth","table"]
const FIRST_USEFUL_STRUCTURAL_SEMANTICS: Array[String] = [
	"castle_gatehouse_wall_stair_exit",
	"castle_gatehouse_wall_stair_landing",
	"castle_keep_stair_exit",
	"castle_keep_stair_landing",
]
# G2 measured a 57 s source p95 and representative sprint speed of 15.4 m/s.
# Add twelve seconds for a reversal plus the 180 m visible range. This is a
# scheduling envelope only; it does not retain terrain or certify a source.
const SOURCE_PREFETCH_LOOKAHEAD_METERS := 15.4 * (57.0 + 12.0) + 180.0
const SOURCE_PREFETCH_LATERAL_METERS := float(SitePreparation.MAX_INFLUENCE_RADIUS_CELLS) * SitePreparation.CELL + 180.0

var _admission
var _owner_snapshot_serial := 0
var _owner_snapshot_token := 0
var _owner_snapshot_owner: WeakRef
var _owner_snapshot_generation := -1
var _owner_snapshot_values: Dictionary = {}
var _source_capture_phase_observer := Callable()
var _source_capture_active_section := Vector3i.ZERO


func set_source_capture_phase_observer(observer: Callable) -> void:
	_source_capture_phase_observer = observer


func _emit_source_capture_phase(phase: String, details: Dictionary = {}) -> void:
	if _source_capture_phase_observer.is_valid():
		var observed := details.duplicate(false)
		observed["sectionKey"] = _source_capture_active_section
		_source_capture_phase_observer.call("citadel_census:%s" % phase, observed)

func begin_owner_expectation_snapshot(owner: Object) -> Dictionary:
	if not is_instance_valid(owner) or _owner_snapshot_token != 0:
		return {"status":"failed", "reason":"owner_expectation_snapshot_scope_busy"}
	_owner_snapshot_serial += 1
	_owner_snapshot_token = _owner_snapshot_serial
	_owner_snapshot_owner = weakref(owner)
	_owner_snapshot_generation = _generation
	_owner_snapshot_values = {}
	return {"status":"ready", "token":_owner_snapshot_token}

func end_owner_expectation_snapshot(owner: Object, token: int) -> Dictionary:
	if token != _owner_snapshot_token or token == 0 or _owner_snapshot_owner == null \
			or _owner_snapshot_owner.get_ref() != owner:
		return {"status":"failed", "reason":"owner_expectation_snapshot_scope_mismatch"}
	_owner_snapshot_token = 0
	_owner_snapshot_owner = null
	_owner_snapshot_values.clear()
	return {"status":"released"}

func _owner_snapshot_active() -> bool:
	return _owner_snapshot_token != 0 and _owner_snapshot_owner != null \
		and is_instance_valid(_owner_snapshot_owner.get_ref()) and _owner_snapshot_generation == _generation

func _owner_snapshot_bucket(kind: String) -> Dictionary:
	if not _owner_snapshot_active(): return {}
	if not _owner_snapshot_values.has(kind): _owner_snapshot_values[kind] = {}
	return _owner_snapshot_values[kind]

func _capture_owner_source_snapshot(publisher: Object, part_id: String, revision: String) -> Dictionary:
	if not _owner_snapshot_active():
		return publisher.capture_committed_static_visual_source(part_id, revision)
	var values := _owner_snapshot_bucket("sourceCapture")
	var key := var_to_str([publisher.get_instance_id(), part_id, revision])
	if values.has(key): return values[key]
	_emit_source_capture_phase("publisher_artifact_capture", {"sourcePartId":part_id})
	var result: Dictionary = publisher.capture_committed_static_visual_source(part_id, revision)
	_emit_source_capture_phase("publisher_artifact_capture_complete", {"sourcePartId":part_id,
		"status":String(result.get("status", ""))})
	if result.get("status") == "ready":
		var sealed := result.duplicate(false)
		sealed.make_read_only()
		values[key] = sealed
		return sealed
	return result

var _worker = Worker.new()
var _generation := 0
var _seed := ""
var _closing := false
var _desired: Dictionary = {}
var _retained_region_bounds: Array[Rect2i] = []
var _retained_consumers: Array[Dictionary] = []
var _retained_navigation_priorities: Dictionary = {}
var _retained_binding_priorities: Dictionary = {}
var _retained_discovery_priorities: Dictionary = {}
var _retained_source_compile_job: Dictionary = {}
var _retained_source_committed_revision := -1
var _retained_source_request_serial := -1
var _retained_source_identity := PackedByteArray()
var _retained_source_rejection: Dictionary = {}
var _retained_source_compile_metrics := {"ownerUnits":0,"admissionUnits":0,"navigationUnits":0,
	"bindingUnits":0,"groupUnits":0,"phase":"idle","restarts":0,"rejections":0}
var _observer_region_bounds := Rect2i()
var _observer_bounds_rejected := false
var _prefetch_regions: Array[Vector2i] = []
var _prefetch_rejected := false
var _prefetch_started_usec: Dictionary = {}
var _demand_started_usec: Dictionary = {}
var _demand_revision := 0
var _view_revision := 0
var _prepared: Dictionary = {}
var _navigation: Dictionary = {}
var _pending_packet_navigation: Dictionary = {}
# A retained source query starts before its description has supplied a precise
# physical closure.  Keep its immutable base outside the scene lifecycle so
# the next retained request can promote that same source revision into packet
# navigation.  This is intentionally separate from ordinary retained bounds:
# those callers retain the established whole-source preparation behavior.
var _packet_bootstrap_bases: Dictionary = {}
var _described: Dictionary = {}
var _description_serial := 0
var _retired: Dictionary = {}
var _inflight: Dictionary = {}
var _failures: Dictionary = {}
var _retirement_serial := 0
var _last_worker_status: Dictionary = {}
var _max_advance_usec := 0
var _dispatch_count := 0
var _accepted_count := 0
var _scene_parent: WeakRef
var _tree_receiver: WeakRef
var _tree_method: StringName
var _tree_retire_receiver: WeakRef
var _tree_retire_method: StringName
var _require_tree_retirement_ack := false
var _construction_guard_receiver: WeakRef
var _construction_guard_method: StringName
var _construction_guard_accepts_members := false
var _door_lifecycle_configured := false
var _door_receiver: WeakRef
var _door_method: StringName
var _door_retire_receiver: WeakRef
var _door_retire_method: StringName
var _scenes: Dictionary = {}
var _section_install_acknowledgements: Dictionary = {}
## Section installation ACKs are independent of source-wide legacy retirement.
## Keep a bounded, deduplicated retry obligation until every support receipt and
## the exact producer owner are current, then retire only the source visual.
var _pending_section_source_retirements: Dictionary = {}
var _pending_section_source_retirement_queue: Array[String] = []
var _section_source_retirement_serial: int = 0
var _section_ack_phase_diagnostics: Dictionary = {}
var _section_ack_currentness_scope: Dictionary = {}
var _geometry_completion_owner: WeakRef
var _geometry_owner_rosters: Dictionary = {}
var _geometry_owner_prior_rosters: Dictionary = {}
var _geometry_owner_section_slice_cache: Dictionary = {}
var _geometry_owner_section_slice_cache_order: Array[String] = []
var _geometry_owner_section_slice_jobs: Array[Dictionary] = []
var _geometry_owner_section_slice_job_keys: Dictionary = {}
var _geometry_owner_capture_proofs: Dictionary = {}
var _geometry_owner_removal_sections: Dictionary = {}
var _geometry_owner_removal_bounds: Dictionary = {}
## Per-section immutable producer captures retained between scheduler turns.
## Partial rows stay private here until the whole contribution is revalidated.
var _section_contribution_capture_jobs: Dictionary = {}
var _section_source_census_capture_jobs: Dictionary = {}
var _active_source_census_capture_key := ""
var _active_source_census_member_work := 0
var _active_source_census_started_usec := 0
var _retained_transform_artifact_captures: Dictionary = {}
var _legacy_visual_section_index := LegacyVisualIndex.new()


func bind_geometry_completion_owner(owner: Object) -> void:
	_geometry_completion_owner = weakref(owner)


func geometry_owner_expectation(source_id: String, part_id: String, revision: String) -> Dictionary:
	var roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
	if part_id != source_id or roster.get("sourceRevision") != revision: return {}
	return roster if _geometry_owner_roster_is_current(source_id, roster, {}).get("status") == "ready" else {}


## The full roster remains the logical producer and legacy-retirement authority.
## Residency consumers ask for the immutable slice owned by one section so a
## nearby section does not inherit every distant member of the same building.
func geometry_owner_section_expectation(source_id: String, part_id: String,
		revision: String, section_key: Vector3i) -> Dictionary:
	if _owner_snapshot_active():
		var values := _owner_snapshot_bucket("geometryOwnerSectionSlice")
		var cache_key := var_to_str([source_id, part_id, revision, section_key])
		if values.has(cache_key): return values[cache_key]
		var captured := _capture_geometry_owner_section_expectation(
			source_id, part_id, revision, section_key)
		if captured.get("status") == "ready":
			captured.make_read_only()
			values[cache_key] = captured
		return captured
	return _capture_geometry_owner_section_expectation(source_id, part_id, revision, section_key)


func _capture_geometry_owner_section_expectation(source_id: String, part_id: String,
		revision: String, section_key: Vector3i) -> Dictionary:
	var roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
	if part_id != source_id or String(roster.get("sourceRevision", "")) != revision:
		return {"status":"pending", "reason":"geometry_owner_parent_roster_unavailable",
			"retryable":true}
	var proof: Dictionary = _geometry_owner_capture_proofs.get(source_id, {})
	var current_parent: bool = _geometry_owner_section_parent_receipt_is_current(source_id, roster) \
		if Array(proof.get("presentationMembers", [])).is_empty() else \
		_geometry_owner_roster_is_current(source_id, roster, {}).get("status") == "ready"
	if not current_parent:
		return {"status":"pending", "reason":"geometry_owner_parent_roster_unavailable",
			"retryable":true}
	var current_slice_result := _owner_section_slice_for_validated_roster(source_id,
		roster, section_key)
	if current_slice_result.get("status") != "ready": return current_slice_result
	var current_slice: Dictionary = current_slice_result.get("slice", {})
	if current_slice.is_empty() or not _owner_section_slice_cache_owns(source_id, roster,
		section_key, current_slice):
		return {"status":"pending", "reason":"geometry_owner_section_slice_unavailable",
			"retryable":true}
	var prior_slices: Array[Dictionary] = []
	for prior_value: Variant in _geometry_owner_prior_rosters.get(source_id, []):
		if not prior_value is Dictionary or not _owner_roster_envelope_is_trusted(prior_value) \
				or prior_value.get("worldId") != roster.get("worldId") \
				or prior_value.get("sourceId") != source_id \
				or prior_value.get("sourcePartId") != part_id \
				or section_key not in OwnerCompletion.owner_sections(prior_value):
			continue
		var prior_slice_result := _owner_section_slice_for_validated_roster(source_id,
			prior_value, section_key)
		if prior_slice_result.get("status") != "ready":
			return {"status":"pending", "reason":"geometry_owner_prior_section_slice_unavailable",
				"retryable":true}
		var prior_slice: Dictionary = prior_slice_result.get("slice", {})
		if not _owner_section_slice_cache_owns(source_id, prior_value, section_key, prior_slice):
			return {"status":"pending", "reason":"geometry_owner_prior_section_slice_invalid",
				"retryable":true}
		prior_slices.append(prior_slice)
	prior_slices.make_read_only()
	var result := {"status":"ready", "slice":current_slice,
		"parentRoster":roster, "priorSlices":prior_slices}
	result.make_read_only()
	return result


## Section queries use the immutable receipt admitted with the full roster.
## The publisher boundary and live scene owner are still checked on every query;
## full source recapture, census and roster hashing remain at admission and at
## asynchronous acceptance/installation boundaries.
func _geometry_owner_section_parent_receipt_is_current(source_id: String,
		roster: Dictionary) -> bool:
	if not _owner_roster_envelope_is_trusted(roster) \
			or String(roster.get("sourceId", "")) != source_id:
		return false
	var proof: Dictionary = _geometry_owner_capture_proofs.get(source_id, {})
	if proof.is_empty() or proof.get("kind") == "tree" \
			or String(proof.get("sourceRevision", "")) != String(roster.get("sourceRevision", "")):
		return false
	var reference: Variant = proof.get("publisher")
	var publisher: Variant = reference.get_ref() if reference is WeakRef else null
	if not is_instance_valid(publisher) \
			or publisher.get_instance_id() != int(proof.get("publisherId", 0)):
		return false
	var identity: Dictionary = publisher.committed_static_visual_source_identity(
		String(proof.get("partId", "")))
	if identity.get("status") != "ready" or identity != proof.get("visualSourceReceipt", {}) \
			or String(identity.get("sourceRevision", "")) != String(proof.get("memberBinding", "")):
		return false
	if not publisher.has_method("static_section_transform_artifact_receipt_is_current") \
			or not publisher.static_section_transform_artifact_receipt_is_current(
			String(proof.get("partId", "")), String(proof.get("memberBinding", "")),
			proof.get("artifactGroups", [])):
		return false
	var current := _current_transform_artifact_publisher_for_member(
		String(proof.get("siteId", "")), _proof_transform_member(proof))
	return current.get("status") == "ready" and current.get("publisher") == publisher \
		and current.get("binding") == proof.get("binding") \
		and current.get("sourceToWorld") == proof.get("sourceToWorld") \
		and current.get("sceneJobInstanceId", 0) == proof.get("sceneJobInstanceId", 0)


func _owner_roster_envelope_is_trusted(roster: Dictionary) -> bool:
	return roster.is_read_only() and roster.get("schema") == OwnerCompletion.SCHEMA \
		and roster.get("members") is Array and roster.members.is_read_only() \
		and String(roster.get("digest", "")).length() == 64 \
		and not String(roster.get("worldId", "")).is_empty() \
		and not String(roster.get("sourceId", "")).is_empty() \
		and not String(roster.get("sourceRevision", "")).is_empty()


func _owner_section_slice_cache_owns(source_id: String, roster: Dictionary,
		section_key: Vector3i, slice: Dictionary) -> bool:
	var cache_key := var_to_str([source_id, roster.get("digest", ""), section_key])
	return is_same(_geometry_owner_section_slice_cache.get(cache_key), slice) \
		and slice.is_read_only() and slice.get("schema") == OwnerSectionSlice.SCHEMA \
		and slice.get("parentRosterDigest") == roster.get("digest") \
		and slice.get("worldId") == roster.get("worldId") \
		and slice.get("sourceId") == roster.get("sourceId") \
		and slice.get("sourcePartId") == roster.get("sourcePartId") \
		and slice.get("sourceRevision") == roster.get("sourceRevision") \
		and slice.get("sourceIncarnation") == roster.get("sourceIncarnation") \
		and slice.get("ownerSection") == section_key


func _owner_section_slice_for_validated_roster(source_id: String, roster: Dictionary,
		section_key: Vector3i) -> Dictionary:
	var cache_key := var_to_str([source_id, roster.get("digest", ""), section_key])
	var cached: Dictionary = _geometry_owner_section_slice_cache.get(cache_key, {})
	if not cached.is_empty() and _owner_section_slice_cache_owns(source_id, roster,
		section_key, cached):
		return {"status":"ready", "slice":cached, "cacheHit":true}
	_geometry_owner_section_slice_cache.erase(cache_key)
	if not _geometry_owner_section_slice_job_keys.has(cache_key):
		if _geometry_owner_section_slice_jobs.size() >= MAX_OWNER_SECTION_SLICE_JOBS:
			return {"status":"pending", "reason":"owner_section_slice_queue_backpressure",
				"retryable":true}
		var collected: Array[Dictionary] = []
		_geometry_owner_section_slice_jobs.append({"cacheKey":cache_key,
			"sourceId":source_id, "roster":roster, "section":section_key,
			"cursor":0, "members":collected})
		_geometry_owner_section_slice_job_keys[cache_key] = true
	return {"status":"pending", "reason":"owner_section_slice_preparation_pending",
		"retryable":true}


func _store_geometry_owner_section_slice(cache_key: String, slice: Dictionary) -> void:
	var stale_order_index := _geometry_owner_section_slice_cache_order.find(cache_key)
	while stale_order_index >= 0:
		_geometry_owner_section_slice_cache_order.remove_at(stale_order_index)
		stale_order_index = _geometry_owner_section_slice_cache_order.find(cache_key)
	while _geometry_owner_section_slice_cache_order.size() >= MAX_OWNER_SECTION_SLICE_CACHE:
		var evicted_key: String = _geometry_owner_section_slice_cache_order.pop_front()
		_geometry_owner_section_slice_cache.erase(evicted_key)
	_geometry_owner_section_slice_cache[cache_key] = slice
	_geometry_owner_section_slice_cache_order.append(cache_key)


func _owner_section_slice_roster_is_retained(source_id: String, roster: Dictionary) -> bool:
	if _geometry_owner_rosters.get(source_id, {}).get("digest") == roster.get("digest"):
		return true
	for prior_value: Variant in _geometry_owner_prior_rosters.get(source_id, []):
		if prior_value is Dictionary and prior_value.get("digest") == roster.get("digest"):
			return true
	return false


func _advance_owner_section_slice_jobs(budget_usec: int) -> void:
	if budget_usec < 1 or _geometry_owner_section_slice_jobs.is_empty():
		return
	var started := Time.get_ticks_usec()
	var examined := 0
	while not _geometry_owner_section_slice_jobs.is_empty() \
			and Time.get_ticks_usec() - started < budget_usec:
		var job: Dictionary = _geometry_owner_section_slice_jobs[0]
		var cache_key := String(job.get("cacheKey", ""))
		var source_id := String(job.get("sourceId", ""))
		var roster: Dictionary = job.get("roster", {})
		if cache_key.is_empty() or roster.is_empty() \
				or not _owner_section_slice_roster_is_retained(source_id, roster):
			_geometry_owner_section_slice_jobs.pop_front()
			_geometry_owner_section_slice_job_keys.erase(cache_key)
			continue
		var members: Array[Dictionary] = job.get("members", [])
		var cursor := int(job.get("cursor", 0))
		var roster_members: Array = roster.get("members", [])
		while cursor < roster_members.size() and Time.get_ticks_usec() - started < budget_usec:
			var value: Variant = roster_members[cursor]
			if not value is Dictionary:
				cursor = roster_members.size()
				break
			var member: Dictionary = value
			if member.get("geometryOwnerSection") == job.get("section"):
				members.append(member)
			cursor += 1
			examined += 1
		job["cursor"] = cursor
		job["members"] = members
		if cursor >= roster_members.size():
			var sealed: Dictionary = OwnerSectionSlice.seal_validated_section_members(
				roster, job.get("section"), members)
			if sealed.get("status") == "ready":
				var slice: Dictionary = sealed.get("slice", {})
				if OwnerSectionSlice.validate_cached_slice_for_parent(roster, slice):
					_store_geometry_owner_section_slice(cache_key, slice)
			_geometry_owner_section_slice_jobs.pop_front()
			_geometry_owner_section_slice_job_keys.erase(cache_key)
			continue
		# Rotate partially scanned requests so one very large roster cannot block
		# new candidates that are needed for the currently visible section set.
		_geometry_owner_section_slice_jobs.pop_front()
		_geometry_owner_section_slice_jobs.append(job)
		if examined == 0:
			break
		break


func geometry_owner_prior_expectations(source_id: String, part_id: String, revision: String) -> Array:
	if geometry_owner_expectation(source_id, part_id, revision).is_empty(): return []
	return _geometry_owner_prior_rosters.get(source_id, []).duplicate()

func presentation_owner_expectation(source_id: String, part_id: String, revision: String) -> Dictionary:
	var proof: Dictionary = _geometry_owner_capture_proofs.get(source_id, {})
	if part_id != source_id or proof.get("sourceRevision") != revision: return {}
	var reference: Variant = proof.get("publisher")
	var publisher: Variant = reference.get_ref() if reference is WeakRef else null
	if not is_instance_valid(publisher): return {}
	var current := _current_transform_artifact_publisher_for_member(String(proof.get("siteId", "")), _proof_transform_member(proof))
	if current.get("status") != "ready" or current.get("publisher") != publisher or current.get("binding") != proof.get("binding") \
			or current.get("sceneJobInstanceId", 0) != proof.get("sceneJobInstanceId", 0):
		return {}
	var geometry_roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
	if bool(geometry_roster.get("explicitRemoval", false)):
		if _geometry_owner_roster_is_current(source_id, geometry_roster, {}).get("status") != "ready": return {}
	else:
		var plan = _publication_plan_for_binding(current.binding)
		if plan == null or String(plan.output_signature) != String(proof.get("planSignature", "")): return {}
		var capture: Dictionary = _capture_owner_source_snapshot(publisher, String(proof.partId), String(proof.memberBinding))
		if capture.get("status") != "ready" or _geometry_capture_identity(capture) != proof.get("captureIdentity"): return {}
	var value := {"worldId":proof.worldId, "sourceId":source_id, "sourcePartId":part_id,
		"sourceRevision":revision, "members":proof.get("presentationMembers", []),
		"priorMembers":proof.get("priorPresentationMembers", [])}
	value.make_read_only()
	return value


func _retain_geometry_owner_roster(source_id: String, roster: Dictionary, proof: Dictionary) -> void:
	var previous: Dictionary = _geometry_owner_rosters.get(source_id, {})
	var previous_proof: Dictionary = _geometry_owner_capture_proofs.get(source_id, {})
	# Section captures can independently seal the same complete owner roster.
	# Keep the retained immutable object when the trusted seal has the same full
	# identity and digest; coordinator proof sessions intentionally bind to that
	# exact object. Changed owner/revision/member content gets a new seal and
	# invalidates the old session as before.
	if _same_geometry_owner_roster_seal(previous, roster):
		roster = previous
	var prior_presentations: Array = previous_proof.get("priorPresentationMembers", []).duplicate()
	for member: Dictionary in previous_proof.get("presentationMembers", []):
		if member not in proof.get("presentationMembers", []) and member not in prior_presentations:
			prior_presentations.append(member)
	proof["priorPresentationMembers"] = prior_presentations
	if not previous.is_empty() and previous != roster:
		var history: Array = _geometry_owner_prior_rosters.get(source_id, [])
		if previous not in history: history.append(previous)
		_geometry_owner_prior_rosters[source_id] = history
	_geometry_owner_rosters[source_id] = roster
	_geometry_owner_capture_proofs[source_id] = proof
	var artifact_capture: Dictionary = proof.get("artifactCapture", {})
	if artifact_capture.get("status") == "ready":
		var publisher_id := int(proof.get("publisherId", 0))
		var part_id := String(proof.get("partId", ""))
		var member_binding := String(proof.get("memberBinding", ""))
		if publisher_id != 0 and not part_id.is_empty() and not member_binding.is_empty():
			var cache_key := _transform_artifact_capture_cache_key(publisher_id,
				int(proof.get("sceneJobInstanceId", 0)), part_id, member_binding)
			_retained_transform_artifact_captures[cache_key] = {
				"publisher":proof.get("publisher"), "publisherId":publisher_id,
				"sceneJobInstanceId":int(proof.get("sceneJobInstanceId", 0)),
				"partId":part_id, "memberId":String(proof.get("memberId", "")),
				"binding":proof.get("binding", {}), "memberBinding":member_binding,
				"sourceToWorld":proof.get("sourceToWorld"),
				"visualSourceReceipt":proof.get("visualSourceReceipt", {}),
				"capture":artifact_capture,
				"lastUseFrame":Engine.get_process_frames()}
		while _retained_transform_artifact_captures.size() > MAX_RETAINED_TRANSFORM_ARTIFACT_CAPTURES:
			var oldest_key: Variant = null
			var oldest_frame := Engine.get_process_frames()
			for key_value: Variant in _retained_transform_artifact_captures:
				var row: Dictionary = _retained_transform_artifact_captures[key_value]
				if oldest_key == null or int(row.get("lastUseFrame", -1)) < oldest_frame:
					oldest_key = key_value
					oldest_frame = int(row.get("lastUseFrame", -1))
			if oldest_key == null: break
			_retained_transform_artifact_captures.erase(oldest_key)
	var coverage_bounds: Array = proof.get("supportBounds", []).duplicate()
	for member: Dictionary in proof.get("presentationMembers", []) + prior_presentations:
		for section: Vector3i in SectionGrid.keys_intersecting_bounds(member.sweptWorldBounds):
			if not _geometry_owner_removal_sections.has(section): _geometry_owner_removal_sections[section] = {}
			_geometry_owner_removal_sections[section][source_id] = true
			if not _geometry_owner_removal_bounds.has(source_id): _geometry_owner_removal_bounds[source_id] = {}
			if not _geometry_owner_removal_bounds[source_id].has(section): _geometry_owner_removal_bounds[source_id][section] = []
	for member: Dictionary in roster.get("members", []):
		if member.worldBounds not in coverage_bounds: coverage_bounds.append(member.worldBounds)
	for bounds: AABB in coverage_bounds:
		for section: Vector3i in SectionGrid.keys_intersecting_bounds(bounds):
			if not _geometry_owner_removal_sections.has(section): _geometry_owner_removal_sections[section] = {}
			_geometry_owner_removal_sections[section][source_id] = true
			if not _geometry_owner_removal_bounds.has(source_id): _geometry_owner_removal_bounds[source_id] = {}
			var bounds_by_section: Dictionary = _geometry_owner_removal_bounds[source_id]
			if not bounds_by_section.has(section): bounds_by_section[section] = []
			if bounds not in bounds_by_section[section]: bounds_by_section[section].append(bounds)


static func _same_geometry_owner_roster_seal(left: Dictionary, right: Dictionary) -> bool:
	if left.is_empty() or right.is_empty() or not left.is_read_only() or not right.is_read_only():
		return false
	for key: String in ["schema", "worldId", "sourceId", "sourcePartId", "sourceRevision",
			"sourceIncarnation", "explicitRemoval", "digest"]:
		if left.get(key) != right.get(key): return false
	var digest := String(left.get("digest", ""))
	return digest.length() == 64 and digest.is_valid_hex_number(false) \
		and left.get("members") is Array and right.get("members") is Array \
		and left.members.is_read_only() and right.members.is_read_only()


var _retiring_scenes: Array = []
var _pending_scene_disposals: Dictionary = {}
var _submitted_scene_disposals: Dictionary = {}
var _scene_cursor := 0
var _prefer_retirement := true
var _scene_started_count := 0
var _scene_completed_count := 0
var _scene_max_step_usec := 0
var _scene_unit_metrics: Dictionary = {}
var _advancing := false
var _configuration_serial := 0
var _world_reset_pending := false
var _world_reset_release_requested := false
var _worker_polled_configuration := -1
var _dispatch_turn := 0
var _dispatch_sequence := 0
var _preparation_schedule: Dictionary = {}
var _dispatch_metrics := {"navigationDispatches":0,"preparationDispatches":0,"agedDispatches":0,
	"maxFirstDemandUsecByPriority":[0,0,0,0,0],"maxWaitTurnsByPriority":[0,0,0,0,0],"last":{}}

## Bind only after the owner can balance its ordinary scene/tree lifecycle.
## No strong owner/callback cycles; reject capturing/bound custom callables.
## A new root cannot inherit old nodes or lose their cleanup receiver.
func configure_scene_publication(parent: Node3D, tree_publish: Callable, tree_retire: Callable, require_tree_retirement_ack := false) -> bool:
	if _closing or not SceneJob._valid_parent(parent): return false
	if not _ordinary_callback(tree_publish) or not _ordinary_callback(tree_retire): return false
	var same: bool = _scene_parent!=null and _scene_parent.get_ref()==parent \
		and _tree_receiver!=null and _tree_receiver.get_ref()==tree_publish.get_object() and _tree_method==tree_publish.get_method() \
		and _tree_retire_receiver!=null and _tree_retire_receiver.get_ref()==tree_retire.get_object() and _tree_retire_method==tree_retire.get_method()
	same = same and _require_tree_retirement_ack == require_tree_retirement_ack
	if not same and (not _scenes.is_empty() or _has_scene_retirements()): return false
	_scene_parent=weakref(parent)
	_tree_receiver=weakref(tree_publish.get_object()); _tree_method=tree_publish.get_method()
	_tree_retire_receiver=weakref(tree_retire.get_object()); _tree_retire_method=tree_retire.get_method()
	_require_tree_retirement_ack=require_tree_retirement_ack
	return true

## Optional only for existing construction diagnostics. The ordinary runtime
## owner must bind this balanced pair before enabling scene publication.
## Once opted in, receiver loss is not permission to fall back to diagnostics.
## Jobs capture their own weak pair; neither paused nor retiring owners may
## inherit a replacement, even after their root nodes have disappeared.
func configure_door_publication(register_callback: Callable, unregister_callback: Callable) -> bool:
	if _closing: return false
	if not _ordinary_callback(register_callback) or not _ordinary_callback(unregister_callback): return false
	var same: bool = _door_lifecycle_configured \
		and _door_receiver!=null and is_same(_door_receiver.get_ref(),register_callback.get_object()) and _door_method==register_callback.get_method() \
		and _door_retire_receiver!=null and is_same(_door_retire_receiver.get_ref(),unregister_callback.get_object()) and _door_retire_method==unregister_callback.get_method()
	if same: return true
	if not _scenes.is_empty() or _has_scene_retirements(): return false
	_door_receiver=weakref(register_callback.get_object()); _door_method=register_callback.get_method()
	_door_retire_receiver=weakref(unregister_callback.get_object()); _door_retire_method=unregister_callback.get_method()
	_door_lifecycle_configured=true
	return true

func _ordinary_callback(callback: Callable) -> bool:
	return callback.is_valid() and not callback.is_custom() and callback.get_object()!=self

func configure_construction_guard(callback: Callable, accepts_member_bounds := false) -> bool:
	if _closing or not _ordinary_callback(callback): return false
	var same: bool = _construction_guard_receiver != null and _construction_guard_receiver.get_ref() == callback.get_object() and _construction_guard_method == callback.get_method() and _construction_guard_accepts_members==accepts_member_bounds
	if not same and (not _scenes.is_empty() or _has_scene_retirements()): return false
	_construction_guard_receiver=weakref(callback.get_object())
	_construction_guard_method=callback.get_method()
	_construction_guard_accepts_members=accepts_member_bounds
	return true

func _construction_transaction_allowed(transaction: Dictionary) -> bool:
	if transaction.get("status")!="ready" or not transaction.get("collisionMemberBounds") is Array: return false
	if _construction_guard_receiver==null: return not _require_tree_retirement_ack
	var receiver = _construction_guard_receiver.get_ref()
	if not is_instance_valid(receiver): return false
	var callback: Callable = Callable(receiver,_construction_guard_method)
	if not callback.is_valid(): return false
	var configuration: int = _configuration_serial
	var demand: int = _demand_revision
	if _construction_guard_accepts_members:
		var allowed: Variant = callback.call(transaction.collisionMemberBounds)
		return allowed==true and configuration==_configuration_serial and demand==_demand_revision and not _closing and not _world_reset_pending
	# Existing diagnostic callbacks consume one rectangle. Production binds the
	# batched ordinary capsule owner, retaining exactly the same member envelopes.
	for value in transaction.collisionMemberBounds:
		if not value is AABB or not value.position.is_finite() or not value.end.is_finite(): return false
		var low: Vector2i = Vector2i(floori(value.position.x/1.35),floori(value.position.z/1.35))
		var high: Vector2i = Vector2i(ceili(value.end.x/1.35)+1,ceili(value.end.z/1.35)+1)
		if callback.call(Rect2i(low,high-low))!=true: return false
		if configuration!=_configuration_serial or demand!=_demand_revision or _closing or _world_reset_pending: return false
	return true

func _construction_allowed(source: Dictionary) -> bool:
	if _construction_guard_receiver == null: return not _require_tree_retirement_ack
	var receiver = _construction_guard_receiver.get_ref()
	if not is_instance_valid(receiver): return false
	var callback := Callable(receiver,_construction_guard_method)
	if not callback.is_valid(): return false
	var configuration := _configuration_serial
	var demand_revision := _demand_revision
	var allowed: Variant = callback.call(source.reservationCells)
	return allowed == true and configuration == _configuration_serial and demand_revision == _demand_revision and not _closing and not _world_reset_pending

func _door_callbacks_ready() -> bool:
	return _door_lifecycle_configured \
		and _door_receiver!=null and is_instance_valid(_door_receiver.get_ref()) and Callable(_door_receiver.get_ref(),_door_method).is_valid() \
		and _door_retire_receiver!=null and is_instance_valid(_door_retire_receiver.get_ref()) and Callable(_door_retire_receiver.get_ref(),_door_retire_method).is_valid()

func _scene_callbacks_ready() -> bool:
	var parent: Node3D=_scene_parent.get_ref() as Node3D if _scene_parent!=null else null
	return is_instance_valid(parent) and parent.is_inside_tree() and not parent.is_queued_for_deletion() \
		and _tree_receiver!=null and is_instance_valid(_tree_receiver.get_ref()) and Callable(_tree_receiver.get_ref(),_tree_method).is_valid() \
		and _tree_retire_receiver!=null and is_instance_valid(_tree_retire_receiver.get_ref()) and Callable(_tree_retire_receiver.get_ref(),_tree_retire_method).is_valid() \
		and (not _door_lifecycle_configured or _door_callbacks_ready())

func configure(admission) -> void:
	_configuration_serial+=1
	_legacy_visual_section_index.clear()
	# Configuration changes terrain identity, not permission to replace old
	# gameplay owners. Only an explicit post-registry-reset completion opens it.
	_world_reset_release_requested=false
	_worker_polled_configuration=-1
	_worker.reset()
	_retire_all_scenes()
	_retire_all()
	_desired = {}
	_retained_region_bounds = []
	_retained_consumers = []
	_retained_source_compile_job = {}
	_retained_source_committed_revision = -1
	_retained_source_request_serial = -1
	_retained_source_identity = PackedByteArray()
	_retained_source_rejection = {}
	_clear_retained_priorities()
	_observer_region_bounds = Rect2i()
	_prefetch_regions.clear()
	_prefetch_started_usec.clear()
	_demand_started_usec.clear()
	_observer_bounds_rejected = false
	_prefetch_rejected = false
	_demand_revision += 1
	_view_revision += 1
	_inflight = {}
	_failures = {}
	_scene_unit_metrics = {}
	_scene_max_step_usec = 0
	_admission = admission
	_section_install_acknowledgements.clear()
	_pending_section_source_retirements.clear()
	_pending_section_source_retirement_queue.clear()
	_geometry_owner_rosters.clear()
	_geometry_owner_prior_rosters.clear()
	_geometry_owner_section_slice_cache.clear()
	_geometry_owner_section_slice_cache_order.clear()
	_geometry_owner_section_slice_jobs.clear()
	_geometry_owner_section_slice_job_keys.clear()
	_geometry_owner_capture_proofs.clear()
	_retained_transform_artifact_captures.clear()
	_geometry_owner_removal_sections.clear()
	_geometry_owner_removal_bounds.clear()
	_section_contribution_capture_jobs.clear()
	_section_source_census_capture_jobs.clear()
	_active_source_census_capture_key = ""
	_active_source_census_member_work = 0
	var state: Dictionary = admission.stats()
	_generation = int(state.generation)
	_seed = String(state.worldSeed)

## The coordinator owns tokens, priorities and release hysteresis. Replacement
## is atomic and privately copied; this service owns only publication demand.
func set_retained_region_bounds(bounds: Array) -> bool:
	if _closing or bounds.size() > MAX_RETAINED_BOUNDS: return false
	_retained_source_compile_job = {}
	var owned: Array[Rect2i] = []
	for rectangle in bounds:
		if not rectangle is Rect2i or not _bounded_region_rectangle(rectangle): return false
		owned.append(rectangle)
	if bounds == _retained_region_bounds and _retained_consumers.is_empty(): return true
	_retained_region_bounds = owned
	_retained_consumers = []
	_retained_source_identity = PackedByteArray()
	_retained_source_committed_revision = -1
	_retained_source_rejection = {}
	_clear_retained_priorities()
	_demand_revision += 1
	return true

## One logical consumer owns its current query and trailing source pins.
## Discovery keys come only from original queries, never dependency envelopes.
func set_retained_source_requests(requests: Array) -> bool:
	_retained_source_request_serial=maxi(_retained_source_request_serial,_retained_source_committed_revision)+1
	var revision := _retained_source_request_serial
	if not request_retained_source_requests(revision,requests,true): return false
	while true:
		var state := advance_retained_source_requests(1000000,2147483647)
		if state.status=="ready": return true
		if state.status=="failed": return false
	return false

func request_retained_source_requests(source_revision: int, requests: Array,
		allow_synchronous_mutable_input := false) -> bool:
	_retained_source_request_serial=maxi(_retained_source_request_serial,source_revision)
	var active_revision:=int(_retained_source_compile_job.get("revision",-1))
	if source_revision<_retained_source_committed_revision or (active_revision>=0 and source_revision<active_revision):
		return false
	if not allow_synchronous_mutable_input and not requests.is_read_only():
		_retained_source_rejection={"status":"failed","reason":"mutable_retained_source_manifest","revision":source_revision}
		return false
	if int(_retained_source_rejection.get("revision",-1))==source_revision: return false
	if int(_retained_source_compile_job.get("revision",-1))==source_revision \
			or (_retained_source_committed_revision==source_revision and _retained_source_compile_job.is_empty()): return true
	if not _retained_source_compile_job.is_empty(): _retained_source_compile_metrics.restarts += 1
	_retained_source_rejection = {}
	var hasher:=HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	_retained_source_compile_job = {"revision":source_revision,"requests":requests,"phase":"owner","ownerIndex":0,
		"owned":[],"discovery":{},"navigationPriorities":{},"bindingPriorities":{},"discoveryPriorities":{},
		"ids":{},"current":{},"index":0,"siteIndex":0,"totalGroups":0,"failed":"","hasher":hasher,
		"requireImmutable":not allow_synchronous_mutable_input}
	return true

func cancel_retained_source_request_compile() -> void:
	_retained_source_compile_job = {}
	_retained_source_rejection = {}

func retained_source_request_compile_metrics() -> Dictionary:
	return _retained_source_compile_metrics.duplicate(true)

func retained_source_committed_revision() -> int:
	return _retained_source_committed_revision

func advance_retained_source_requests(budget_usec := RETAINED_SOURCE_SLICE_USEC,
		unit_cap := RETAINED_SOURCE_UNIT_CAP) -> Dictionary:
	if _closing: return {"status":"failed","reason":"service_closing"}
	if _retained_source_compile_job.is_empty():
		if not _retained_source_rejection.is_empty(): return _retained_source_rejection.duplicate(true)
		return {"status":"ready","revision":_retained_source_committed_revision}
	var started := Time.get_ticks_usec()
	var units := 0
	while units<maxi(1,unit_cap) and Time.get_ticks_usec()-started<maxi(1,budget_usec):
		var status := _advance_retained_source_request_unit()
		if status!="pending":
			if status=="failed":
				var reason: String = _retained_source_compile_job.get("failed","invalid_retained_source_manifest")
				var rejected_revision:=int(_retained_source_compile_job.get("revision",-1))
				_retained_source_compile_job = {}
				_retained_source_compile_metrics.rejections += 1
				_retained_source_rejection = {"status":"failed","reason":reason,"revision":rejected_revision}
				return _retained_source_rejection.duplicate(true)
			var job := _retained_source_compile_job
			var bounds: Array[Rect2i] = []
			var world_bounds := Rect2i(-1000000,-1000000,2000000,2000000)
			for rectangle: Rect2i in DemandSet.rectangles(job.discovery,DISCOVERY_CHUNK_SIZE):
				var clipped := rectangle.intersection(world_bounds)
				if not _bounded_region_rectangle(clipped):
					var rejected_revision:=int(job.revision)
					_retained_source_compile_job = {}
					_retained_source_compile_metrics.rejections += 1
					_retained_source_rejection={"status":"failed","reason":"invalid_retained_bounds","revision":rejected_revision}
					return _retained_source_rejection.duplicate(true)
				bounds.append(clipped)
			var identity: PackedByteArray=job.hasher.finish()
			if identity!=_retained_source_identity:
				var completed_consumers: Array[Dictionary] = []
				completed_consumers.assign(job.owned)
				_retained_consumers = completed_consumers
				_retained_region_bounds = bounds
				_retained_navigation_priorities = job.navigationPriorities
				_retained_binding_priorities = job.bindingPriorities
				_retained_discovery_priorities = job.discoveryPriorities
				_retained_source_identity = identity
				_demand_revision += 1
			_retained_source_committed_revision = int(job.revision)
			_retained_source_compile_job = {}
			_retained_source_compile_metrics.phase = "ready"
			return {"status":"ready","revision":_retained_source_committed_revision}
		units += 1
	return {"status":"pending","revision":int(_retained_source_compile_job.revision)}

func _retained_compile_fail(reason: String) -> String:
	_retained_source_compile_job.failed = reason
	return "failed"

static func _retained_consumer_hash(job: Dictionary, value: Variant) -> void:
	job.hasher.update(var_to_bytes(value))

func _advance_retained_source_request_unit() -> String:
	var job := _retained_source_compile_job
	_retained_source_compile_metrics.phase = job.phase
	var requests: Array = job.requests
	if job.phase=="owner":
		if requests.size()>MAX_RETAINED_BOUNDS: return _retained_compile_fail("retained_consumer_capacity")
		if int(job.ownerIndex)>=requests.size(): return "ready"
		var value = requests[job.ownerIndex]
		if not value is Dictionary or not value.get("ownerId") is int or int(value.ownerId)<=0 or job.ids.has(value.ownerId): return _retained_compile_fail("invalid_owner")
		if not value.get("bounds") is Rect2i or not DemandSet.valid_bounds(value.bounds): return _retained_compile_fail("invalid_bounds")
		if not value.get("priority") is int or int(value.priority)<0 or int(value.priority)>4: return _retained_compile_fail("invalid_priority")
		if not value.get("sites",[]) is Array or value.sites.size()>MAX_REGIONS: return _retained_compile_fail("invalid_sites")
		if not value.get("admissionKeys") is Array or value.admissionKeys.is_empty() or value.admissionKeys.size()>MAX_DISCOVERY_CHUNKS: return _retained_compile_fail("invalid_admission_keys")
		if not value.get("navigationTileKeys") is Array or value.navigationTileKeys.is_empty() or value.navigationTileKeys.size()>MAX_PENDING_NAVIGATION_TILES: return _retained_compile_fail("invalid_navigation_keys")
		if value.has("navigationTilePriorities") and not value.navigationTilePriorities is Dictionary: return _retained_compile_fail("invalid_navigation_priorities")
		if bool(job.requireImmutable) and (not value.is_read_only() or not value.admissionKeys.is_read_only()
				or not value.navigationTileKeys.is_read_only() or not value.sites.is_read_only()
				or (value.has("navigationTilePriorities") and not value.navigationTilePriorities.is_read_only())):
			return _retained_compile_fail("mutable_retained_source_manifest")
		job.ids[value.ownerId] = true
		job.current = {"value":value,"consumerKeys":{},"navigationMembers":{},"navigationKeys":[],"navigationDeclaredPriorities":{},
			"admissionKeys":[],"sites":[],"siteBindings":[],"totalGroups":0,"retainedTilePriorities":{}}
		job.index=0; job.phase="admission"; _retained_source_compile_metrics.ownerUnits += 1
		_retained_consumer_hash(job,["owner",value.ownerId,value.bounds,value.priority])
		return "pending"
	var current: Dictionary = job.current
	var value: Dictionary = current.value
	if job.phase=="admission":
		if int(job.index)<value.admissionKeys.size():
			var key = value.admissionKeys[job.index]
			if not key is Vector2i or key.x < -35715 or key.x > 35714 or key.y < -35715 or key.y > 35714: return _retained_compile_fail("invalid_admission_key")
			current.consumerKeys[key]=true; job.discovery[key]=true
			if job.discovery.size()>MAX_DISCOVERY_CHUNKS: return _retained_compile_fail("discovery_capacity")
			job.index+=1; _retained_source_compile_metrics.admissionUnits += 1
			return "pending"
		var required := DemandSet.from_regions([value.bounds],DISCOVERY_CHUNK_SIZE,MAX_DISCOVERY_CHUNKS,32)
		if required.status!="ready" or not DemandSet.contains(current.consumerKeys,required.keys): return _retained_compile_fail("incomplete_admission_keys")
		job.index=0; job.phase="navigation"; return "pending"
	if job.phase=="navigation":
		if int(job.index)<value.navigationTileKeys.size():
			var raw_key = value.navigationTileKeys[job.index]
			if not raw_key is String or raw_key.length()>23: return _retained_compile_fail("invalid_navigation_key")
			var coordinates: PackedStringArray = raw_key.split(",",true)
			if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int(): return _retained_compile_fail("invalid_navigation_key")
			var x:=int(coordinates[0]); var z:=int(coordinates[1])
			if x < -62500 or x > 62499 or z < -62500 or z > 62499 or raw_key!="%d,%d" % [x,z]: return _retained_compile_fail("invalid_navigation_key")
			var tile:=Vector2i(x,z)
			var first_tile: bool=not current.navigationMembers.has(tile)
			if first_tile: current.navigationKeys.append(raw_key)
			current.navigationMembers[tile]=true
			var declared: Dictionary=value.get("navigationTilePriorities",{})
			var priority:=int(declared.get(raw_key,value.priority))
			if priority<0 or priority>4: return _retained_compile_fail("invalid_navigation_priority")
			current.navigationDeclaredPriorities[raw_key]=priority
			job.navigationPriorities[raw_key]=mini(int(job.navigationPriorities.get(raw_key,4)),priority)
			if job.navigationPriorities.size()>MAX_PENDING_NAVIGATION_TILES: return _retained_compile_fail("navigation_capacity")
			job.index+=1; _retained_source_compile_metrics.navigationUnits += 1
			return "pending"
		var required_nav:=DemandSet.from_regions([value.bounds],NAVIGATION_TILE_CELLS,MAX_PENDING_NAVIGATION_TILES)
		if required_nav.status!="ready" or not DemandSet.contains(current.navigationMembers,required_nav.keys): return _retained_compile_fail("incomplete_navigation_keys")
		current.navigationKeys.sort()
		job.index=0; job.phase="navigation_hash"; return "pending"
	if job.phase=="navigation_hash":
		if int(job.index)<current.navigationKeys.size():
			var key: String=current.navigationKeys[job.index]
			_retained_consumer_hash(job,["navigation",key,current.navigationDeclaredPriorities[key]])
			job.index+=1; return "pending"
		job.index=0; job.phase="discovery_priority"; return "pending"
	if job.phase=="discovery_priority":
		var keys: Array=current.consumerKeys.keys()
		if int(job.index)<keys.size():
			var key: Vector2i=keys[job.index]
			current.admissionKeys.append(key)
			var chunk_bounds:=Rect2i(key*DISCOVERY_CHUNK_SIZE,Vector2i.ONE*DISCOVERY_CHUNK_SIZE)
			var low:=Field.region_for_cell(chunk_bounds.position); var high:=Field.region_for_cell(chunk_bounds.end-Vector2i.ONE)
			for z in range(low.y,high.y+1):
				for x in range(low.x,high.x+1):
					var region:=Vector2i(x,z)
					if not job.discoveryPriorities.has(region): job.discoveryPriorities[region]={}
					job.discoveryPriorities[region][key]=mini(int(job.discoveryPriorities[region].get(key,4)),int(value.priority))
			job.index+=1; _retained_source_compile_metrics.admissionUnits += 1
			return "pending"
		current.admissionKeys.sort_custom(func(a:Vector2i,b:Vector2i):return a.y<b.y if a.y!=b.y else a.x<b.x)
		job.index=0; job.phase="admission_hash"; return "pending"
	if job.phase=="admission_hash":
		if int(job.index)<current.admissionKeys.size():
			_retained_consumer_hash(job,["admission",current.admissionKeys[job.index]])
			job.index+=1; return "pending"
		job.siteIndex=0; job.phase="site"; return "pending"
	if job.phase=="site":
		if int(job.siteIndex)>=value.sites.size():
			for key: String in current.navigationKeys: current.retainedTilePriorities[key]=int(value.get("navigationTilePriorities",{}).get(key,value.priority))
			var retained := {"ownerId":value.ownerId,"bounds":value.bounds,"priority":value.priority,
				"admissionKeys":current.admissionKeys,"navigationTileKeys":current.navigationKeys,
				"navigationTilePriorities":current.retainedTilePriorities,"sites":current.sites}
			job.owned.append(retained); job.ownerIndex+=1; job.phase="owner"
			return "pending"
		var site=value.sites[job.siteIndex]
		if not site is Dictionary: return _retained_compile_fail("invalid_site")
		if bool(job.requireImmutable) and not site.is_read_only(): return _retained_compile_fail("mutable_retained_source_manifest")
		if not site.has("groupIds"): job.siteIndex+=1; return "pending"
		if not site.get("binding") is Dictionary or not site.groupIds is Array or site.groupIds.size()>30000: return _retained_compile_fail("invalid_binding")
		if bool(job.requireImmutable) and (not site.binding.is_read_only() or not site.groupIds.is_read_only()
				or (site.has("foregroundGroupIds") and not site.foregroundGroupIds.is_read_only())
				or (site.has("foregroundNavigationTileKeys") and not site.foregroundNavigationTileKeys.is_read_only())):
			return _retained_compile_fail("mutable_retained_source_manifest")
		var binding:Dictionary=site.binding
		if binding.size()!=3 or not binding.get("siteId") is String or binding.siteId.is_empty() or not binding.get("sourceKey") is String or binding.sourceKey.is_empty() or not binding.get("generation") is int or int(binding.generation)<=0: return _retained_compile_fail("invalid_binding")
		if current.siteBindings.has(binding): return _retained_compile_fail("duplicate_binding")
		current.siteBindings.append(binding.duplicate())
		_retained_consumer_hash(job,["binding",binding])
		# Presence is semantic: an explicitly empty foreground group closure says
		# dependency discovery completed with no urgent groups, while omission says
		# the source is still on the legacy/tile-derived path.
		_retained_consumer_hash(job,["sitePresence",site.has("foregroundGroupIds")])
		job.currentSite={"raw":site,"binding":binding.duplicate(),"groupIds":[],"seen":{},"foregroundNavigationTileKeys":[],"foregroundSeen":{},"foregroundGroupIds":[],"foregroundGroupSeen":{}}
		job.index=0; job.phase="groups"; _retained_source_compile_metrics.bindingUnits += 1
		return "pending"
	var current_site:Dictionary=job.currentSite
	var raw_site:Dictionary=current_site.raw
	if job.phase=="groups":
		if int(job.index)<raw_site.groupIds.size():
			var id=raw_site.groupIds[job.index]
			if not id is String or id.is_empty(): return _retained_compile_fail("invalid_group")
			if not current_site.seen.has(id):
				current_site.seen[id]=true; current_site.groupIds.append(id); current.totalGroups+=1
				_retained_consumer_hash(job,["group",id])
			if int(current.totalGroups)>30000: return _retained_compile_fail("group_capacity")
			job.index+=1; _retained_source_compile_metrics.groupUnits += 1
			return "pending"
		job.index=0; job.phase="foreground_navigation"; return "pending"
	if job.phase=="foreground_navigation":
		if raw_site.has("foregroundNavigationTileKeys"):
			if not raw_site.foregroundNavigationTileKeys is Array or raw_site.foregroundNavigationTileKeys.size()>MAX_PENDING_NAVIGATION_TILES: return _retained_compile_fail("invalid_foreground_navigation")
			if int(job.index)<raw_site.foregroundNavigationTileKeys.size():
				var raw_key=raw_site.foregroundNavigationTileKeys[job.index]
				if not raw_key is String or not value.navigationTileKeys.has(raw_key): return _retained_compile_fail("invalid_foreground_navigation")
				if not current_site.foregroundSeen.has(raw_key):
					current_site.foregroundSeen[raw_key]=true; current_site.foregroundNavigationTileKeys.append(raw_key)
				job.index+=1; _retained_source_compile_metrics.navigationUnits += 1; return "pending"
		current_site.foregroundNavigationTileKeys.sort(); job.index=0; job.phase="foreground_navigation_hash"; return "pending"
	if job.phase=="foreground_navigation_hash":
		if int(job.index)<current_site.foregroundNavigationTileKeys.size():
			_retained_consumer_hash(job,["foregroundNavigation",current_site.foregroundNavigationTileKeys[job.index]])
			job.index+=1; return "pending"
		job.index=0; job.phase="foreground_groups"; return "pending"
	if job.phase=="foreground_groups":
		if raw_site.has("foregroundGroupIds"):
			if not raw_site.foregroundGroupIds is Array or raw_site.foregroundGroupIds.size()>30000: return _retained_compile_fail("invalid_foreground_groups")
			if int(job.index)<raw_site.foregroundGroupIds.size():
				var id=raw_site.foregroundGroupIds[job.index]
				if not id is String or id.is_empty() or not current_site.seen.has(id): return _retained_compile_fail("invalid_foreground_group")
				if not current_site.foregroundGroupSeen.has(id):
					current_site.foregroundGroupSeen[id]=true; current_site.foregroundGroupIds.append(id)
				job.index+=1; _retained_source_compile_metrics.groupUnits += 1; return "pending"
		job.foregroundHeap=current_site.foregroundGroupIds
		current_site.foregroundGroupIds=[]
		job.heapIndex=floori(float(job.foregroundHeap.size())/2.0)-1
		job.phase="foreground_group_heap"
		return "pending"
	if job.phase=="foreground_group_heap":
		if int(job.heapIndex)>=0:
			_retained_string_heap_sift_down(job.foregroundHeap,int(job.heapIndex),job.foregroundHeap.size())
			job.heapIndex-=1
			return "pending"
		job.phase="foreground_group_order"; return "pending"
	if job.phase=="foreground_group_order":
		if not job.foregroundHeap.is_empty():
			var id:=_retained_string_heap_pop(job.foregroundHeap)
			current_site.foregroundGroupIds.append(id)
			_retained_consumer_hash(job,["foregroundGroup",id])
			_retained_source_compile_metrics.groupUnits += 1
			return "pending"
		job.sourcePlan=_publication_plan_for_binding(current_site.binding) if raw_site.has("foregroundGroupIds") else null
		job.planEligible=job.sourcePlan!=null
		job.eligibilityIndex=0
		job.phase="foreground_eligibility"
		return "pending"
	if job.phase=="foreground_eligibility":
		if bool(job.planEligible) and int(job.eligibilityIndex)<current_site.foregroundGroupIds.size():
			if not job.sourcePlan.eligible_group_ids.has(current_site.foregroundGroupIds[job.eligibilityIndex]): job.planEligible=false
			job.eligibilityIndex+=1
			_retained_source_compile_metrics.groupUnits += 1
			return "pending"
		var retained_site:={"binding":current_site.binding,"groupIds":current_site.groupIds,
			"foregroundNavigationTileKeys":current_site.foregroundNavigationTileKeys}
		if raw_site.has("foregroundGroupIds"):
			retained_site["foregroundGroupIds"]=current_site.foregroundGroupIds
			if bool(job.planEligible): retained_site["foregroundPlanSignature"]=job.sourcePlan.output_signature
		_retained_consumer_hash(job,["siteEnd",retained_site.get("foregroundPlanSignature","")])
		current.sites.append(retained_site)
		var binding_key:=_priority_binding_key(current_site.binding)
		job.bindingPriorities[binding_key]=mini(int(job.bindingPriorities.get(binding_key,4)),int(value.priority))
		job.siteIndex+=1; job.phase="site"; return "pending"
	return _retained_compile_fail("invalid_compile_phase")

static func _retained_string_heap_sift_down(values: Array, start: int, end: int) -> void:
	var root:=start
	while root*2+1<end:
		var child:=root*2+1
		if child+1<end and String(values[child+1])<String(values[child]): child+=1
		if String(values[root])<=String(values[child]): return
		var swap_value=values[root]; values[root]=values[child]; values[child]=swap_value
		root=child

static func _retained_string_heap_pop(values: Array) -> String:
	var result:=String(values[0])
	var tail=values.pop_back()
	if not values.is_empty():
		values[0]=tail
		_retained_string_heap_sift_down(values,0,values.size())
	return result

func _publication_plan_for_binding(binding: Dictionary):
	for region: Vector2i in _scenes:
		var entry: Dictionary = _scenes[region]
		if entry.get("binding",{})!=binding: continue
		var job = entry.get("job",null)
		var base = job._cpu.get("publicationBase",null) if job!=null else null
		if base!=null and base.publication_plan!=null and base.publication_plan.matches(binding,base.description.publication_groups.groups):
			return base.publication_plan
	for region: Vector2i in _packet_bootstrap_bases:
		var bootstrap: Dictionary = _packet_bootstrap_bases[region]
		var base = bootstrap.get("base",null)
		if bootstrap.get("binding",{}) == binding and base != null \
				and base.publication_plan != null and base.publication_plan.matches(binding,base.description.publication_groups.groups):
			return base.publication_plan
	for region: Vector2i in _prepared:
		var prepared: Dictionary = _prepared[region]
		var base = prepared.get("base",null)
		if prepared.get("binding",{}) == binding and base != null \
				and base.publication_plan != null and base.publication_plan.matches(binding,base.description.publication_groups.groups):
			return base.publication_plan
	return null


## Blueprint buildings are one provider in the section census, not proof that
## the other static domains are empty. This query uses the immutable plan and
## admission decisions only; scene Nodes and publication readiness are excluded.
func capture_static_section_sources(world_id: String, section_keys: Array) -> Dictionary:
	var snapshot_active := _owner_snapshot_active()
	var values := _owner_snapshot_bucket("census") if snapshot_active else {}
	var key := var_to_str([world_id, section_keys])
	if snapshot_active and values.has(key): return values[key]
	var result := _capture_resumable_static_section_sources(world_id, section_keys)
	if snapshot_active and result.get("status") == "complete":
		var sealed := result.duplicate(false)
		sealed.make_read_only()
		values[key] = sealed
		return sealed
	return result


func _capture_resumable_static_section_sources(world_id: String,
		section_keys: Array) -> Dictionary:
	var canonical_sections: Array[Vector3i] = []
	for section_value: Variant in section_keys:
		if not section_value is Vector3i or section_value in canonical_sections:
			return _capture_static_section_sources_uncached(world_id, section_keys)
		canonical_sections.append(section_value)
	canonical_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var capture_key := var_to_str([world_id, canonical_sections,
		_owner_snapshot_token if _owner_snapshot_active() else 0])
	var input_identity := _static_section_source_capture_identity(world_id, canonical_sections)
	if input_identity.is_empty():
		return {"status":"pending", "reason":"citadel_source_capture_identity_unavailable",
			"retryable":true}
	var job: Dictionary = _section_source_census_capture_jobs.get(capture_key, {})
	if not job.is_empty() and String(job.get("inputIdentity", "")) != input_identity:
		_section_source_census_capture_jobs.erase(capture_key)
		job = {}
	if job.is_empty():
		_prune_static_section_source_capture_jobs(capture_key)
		job = {"inputIdentity":input_identity, "worldId":world_id,
			"sections":canonical_sections.duplicate(), "memberAuthorities":{},
			"createdFrame":Engine.get_process_frames(),
			"lastAdvanceFrame":Engine.get_process_frames(), "memberAuthorityCount":0}
		_section_source_census_capture_jobs[capture_key] = job
	if job.has("completedResult"):
		var current_epoch_proof := _completed_census_member_epoch_proof(job)
		if current_epoch_proof.get("status") == "ready" \
				and String(current_epoch_proof.get("digest", "")) \
				== String(job.get("completedAuthorityEpochDigest", "")):
			job["validatedFrame"] = Engine.get_process_frames()
			job["lastAdvanceFrame"] = Engine.get_process_frames()
			_section_source_census_capture_jobs[capture_key] = job
			return job.get("completedResult", {})
		if current_epoch_proof.get("status") == "changed":
			_section_source_census_capture_jobs.erase(capture_key)
			return {"status":"pending", "reason":"citadel_section_source_census_member_changed",
				"retryable":true, "captureProgress":{"phase":"member_authority_epoch_fence",
					"completedMemberAuthorityCount":int(job.get("memberAuthorityCount", 0)),
					"requiredMemberAuthorityCount":job.get("validationMembers", []).size(),
					"currentMemberId":String(current_epoch_proof.get("memberId", ""))}}
		_active_source_census_member_work = 0
		_active_source_census_started_usec = Time.get_ticks_usec()
		var validation := _advance_completed_section_source_census_validation(
			capture_key, job)
		_active_source_census_member_work = 0
		_active_source_census_started_usec = 0
		if validation.get("status") == "ready":
			return validation.get("result", {})
		job["lastAdvanceFrame"] = Engine.get_process_frames()
		_section_source_census_capture_jobs[capture_key] = job
		return validation
	_active_source_census_capture_key = capture_key
	_active_source_census_member_work = 0
	_active_source_census_started_usec = Time.get_ticks_usec()
	var result := _capture_static_section_sources_uncached(world_id, canonical_sections)
	_active_source_census_capture_key = ""
	_active_source_census_member_work = 0
	_active_source_census_started_usec = 0
	var retain_completed_census: bool = result.get("status") == "complete" \
		and String(result.get("worldId", "")) == world_id \
		and result.get("sections", {}) is Dictionary \
		and result.get("sourceRevisions", {}) is Dictionary
	if retain_completed_census:
		var sealed_result := result.duplicate(false)
		sealed_result.make_read_only()
		var validation_members: Array = job.get("memberAuthorities", {}).keys()
		validation_members.sort()
		job["completedResult"] = sealed_result
		job["validationMembers"] = validation_members
		job["validationCursor"] = 0
		job["validatedAuthorities"] = {}
		job["completedAuthorityEpochDigest"] = ""
		job["validatedFrame"] = -1
		job["lastAdvanceFrame"] = Engine.get_process_frames()
		_section_source_census_capture_jobs[capture_key] = job
		if validation_members.is_empty():
			job["validatedFrame"] = Engine.get_process_frames()
			_section_source_census_capture_jobs[capture_key] = job
			return sealed_result
		return {"status":"pending", "reason":"citadel_section_source_census_validation_slice_pending",
			"retryable":true, "captureProgress":{"phase":"member_authority_validation",
				"completedMemberAuthorityCount":int(job.get("memberAuthorityCount", 0)),
				"requiredMemberAuthorityCount":validation_members.size(),
				"validatedMemberAuthorityCount":0}}
	elif result.get("status") == "complete" or result.get("status") == "failed":
		_section_source_census_capture_jobs.erase(capture_key)
	else:
		job["lastAdvanceFrame"] = Engine.get_process_frames()
		_section_source_census_capture_jobs[capture_key] = job
	return result


func _advance_completed_section_source_census_validation(capture_key: String,
		job: Dictionary) -> Dictionary:
	var frame := Engine.get_process_frames()
	var members: Array = job.get("validationMembers", [])
	var cursor := int(job.get("validationCursor", 0))
	var validated_authorities: Dictionary = job.get("validatedAuthorities", {})
	var validation_started := Time.get_ticks_usec()
	var validation_work := 0
	while cursor < members.size():
		if validation_work >= MAX_CITADEL_CENSUS_MEMBER_AUTHORITIES_PER_ADVANCE \
				or validation_work > 0 and Time.get_ticks_usec() - validation_started \
					>= CITADEL_CENSUS_MEMBER_AUTHORITY_ADVANCE_BUDGET_USEC:
			job["validationCursor"] = cursor
			job["lastAdvanceFrame"] = frame
			_section_source_census_capture_jobs[capture_key] = job
			return {"status":"pending", "reason":"citadel_section_source_census_validation_slice_pending",
				"retryable":true, "captureProgress":{"phase":"member_authority_validation",
					"completedMemberAuthorityCount":int(job.get("memberAuthorityCount", 0)),
					"requiredMemberAuthorityCount":members.size(),
					"validatedMemberAuthorityCount":cursor}}
		var encoded_key := String(members[cursor])
		var authority_key: Variant = str_to_var(encoded_key)
		if not authority_key is Array or authority_key.size() != 2:
			return {"status":"failed", "reason":"citadel_census_member_validation_key_invalid"}
		var site_id := String(authority_key[0])
		var member_id := String(authority_key[1])
		var cached: Dictionary = job.get("memberAuthorities", {}).get(encoded_key, {})
		var current := _current_census_member_authority_proof(site_id, member_id,
			cached)
		if current.get("status") == "unsupported":
			# A provider category without a cheap authoritative epoch proof keeps
			# the original incremental full-authority comparison. Its cursor still
			# survives calls; it is never silently treated as current.
			current = _current_tree_member_artifact_authority(site_id, member_id) \
				if member_id.begins_with("tree:") else \
				_capture_member_transform_artifact_authority(site_id, member_id)
		if current.get("status") == "pending":
			return {"status":"pending", "reason":String(current.get("reason",
				"citadel_census_member_validation_pending")), "retryable":true,
				"captureProgress":{"phase":"member_authority_validation",
					"completedMemberAuthorityCount":int(job.get("memberAuthorityCount", 0)),
					"requiredMemberAuthorityCount":members.size(),
					"validatedMemberAuthorityCount":cursor,
					"currentMemberId":member_id}}
		var same_ready_authority: bool = current.get("status") == "ready" \
			and cached.get("status") == "ready" \
			and String(current.get("artifactAuthorityRevision", "")) \
				== String(cached.get("artifactAuthorityRevision", ""))
		var same_removed_authority: bool = current.get("status") == "absent" \
			and current.get("reason") == "removed_prop" \
			and cached.get("status") == "absent" \
			and cached.get("reason") == "removed_prop" \
			and String(current.get("propId", "")) == String(cached.get("propId", ""))
		if not same_ready_authority and not same_removed_authority:
			_section_source_census_capture_jobs.erase(capture_key)
			return {"status":"pending", "reason":"citadel_section_source_census_member_changed",
				"retryable":true, "captureProgress":{"phase":"member_authority_validation",
					"completedMemberAuthorityCount":int(job.get("memberAuthorityCount", 0)),
					"requiredMemberAuthorityCount":members.size(),
					"validatedMemberAuthorityCount":cursor,
					"currentMemberId":member_id}}
		validated_authorities[encoded_key] = current.get("epochProof",
			String(current.get("artifactAuthorityRevision", "")))
		job["validatedAuthorities"] = validated_authorities
		cursor += 1
		validation_work += 1
	job["validationCursor"] = cursor
	job["lastAdvanceFrame"] = frame
	if cursor >= members.size():
		# The provider identity is a final revision fence for admission, region
		# reservations, plans, and scene-job ownership. It may change while the
		# member authorities are being validated across frames.
		var current_identity := _static_section_source_capture_identity(
			String(job.get("worldId", "")), job.get("sections", []))
		if current_identity.is_empty() \
				or current_identity != String(job.get("inputIdentity", "")):
			_section_source_census_capture_jobs.erase(capture_key)
			return {"status":"pending", "reason":"citadel_section_source_census_identity_changed",
				"retryable":true, "captureProgress":{"phase":"member_authority_validation",
					"completedMemberAuthorityCount":int(job.get("memberAuthorityCount", 0)),
					"requiredMemberAuthorityCount":members.size(),
					"validatedMemberAuthorityCount":cursor}}
		# Keep the successful authority fence. Calls on later frames compare the
		# source's current revision/epoch against this completed proof; they do
		# not repeat the full artifact capture/digest pass when that proof is live.
		job["validatedFrame"] = frame
		job["validationCursor"] = 0
		job["validatedAuthorities"] = validated_authorities
		job["completedAuthorityEpochDigest"] = _digest_census_authority_epoch_proofs(
			validated_authorities)
		_section_source_census_capture_jobs[capture_key] = job
		return {"status":"ready", "result":job.get("completedResult", {})}
	_section_source_census_capture_jobs[capture_key] = job
	return {"status":"pending", "reason":"citadel_section_source_census_validation_slice_pending",
		"retryable":true, "captureProgress":{"phase":"member_authority_validation",
			"completedMemberAuthorityCount":int(job.get("memberAuthorityCount", 0)),
		"requiredMemberAuthorityCount":members.size(),
		"validatedMemberAuthorityCount":cursor}}


func _completed_census_member_epoch_proof(job: Dictionary) -> Dictionary:
	var members: Array = job.get("validationMembers", [])
	var authorities: Dictionary = job.get("memberAuthorities", {})
	var proofs: Dictionary = {}
	for encoded_value: Variant in members:
		var encoded_key := String(encoded_value)
		var authority_key: Variant = str_to_var(encoded_key)
		if not authority_key is Array or authority_key.size() != 2:
			return {"status":"changed", "memberId":encoded_key}
		var cached: Dictionary = authorities.get(encoded_key, {})
		var current := _current_census_member_authority_proof(
			String(authority_key[0]), String(authority_key[1]), cached)
		if current.get("status") == "unsupported":
			return {"status":"unsupported", "memberId":String(authority_key[1])}
		if current.get("status") == "pending":
			return {"status":"pending", "reason":String(current.get("reason",
				"citadel_census_member_epoch_pending")),
			"memberId":String(authority_key[1]), "retryable":true}
		var current_revision := String(current.get("artifactAuthorityRevision", ""))
		var cached_revision := String(cached.get("artifactAuthorityRevision", ""))
		var same_ready: bool = current.get("status") == "ready" \
			and cached.get("status") == "ready" \
			and current_revision == cached_revision
		var same_removed: bool = current.get("status") == "absent" \
			and current.get("reason") == "removed_prop" \
			and cached.get("status") == "absent" \
			and cached.get("reason") == "removed_prop" \
			and current.get("propId") == cached.get("propId")
		if not same_ready and not same_removed:
			return {"status":"changed", "memberId":String(authority_key[1])}
		proofs[encoded_key] = current.get("epochProof", current_revision)
	return {"status":"ready", "digest":_digest_census_authority_epoch_proofs(proofs)}


func _digest_census_authority_epoch_proofs(proofs: Dictionary) -> String:
	var keys: Array = proofs.keys()
	keys.sort()
	var rows: Array = []
	for key_value: Variant in keys:
		var key := String(key_value)
		rows.append([key, proofs[key]])
	var digest := HashingContext.new()
	if digest.start(HashingContext.HASH_SHA256) != OK \
			or digest.update(var_to_bytes(["citadel-census-authority-epoch-proof/v1", rows])) != OK:
		return ""
	return digest.finish().hex_encode()


func _current_census_member_authority_proof(site_id: String, member_id: String,
		cached: Dictionary) -> Dictionary:
	if member_id.begins_with("tree:"):
		# Tree source authority already exposes a compact deterministic revision
		# over its live producer/compiled-source identity and body transform.
		return _current_tree_member_artifact_authority(site_id, member_id)
	if not _is_transform_member(member_id):
		return {"status":"unsupported"}
	var owner := _current_transform_artifact_publisher_for_member(site_id, member_id)
	if owner.get("status") != "ready":
		return owner
	var publisher: Variant = owner.get("publisher")
	var part_id := _transform_part_id(member_id)
	if not is_instance_valid(publisher) \
			or not publisher.has_method("committed_static_visual_source_identity"):
		return {"status":"unsupported"}
	var expected_revision := _expected_visual_source_revision(owner, part_id)
	if expected_revision.is_empty():
		return {"status":"pending", "reason":"citadel_transform_member_binding_unavailable",
			"sourcePartId":part_id, "retryable":true}
	var current_identity: Dictionary = publisher.call(
		"committed_static_visual_source_identity", part_id)
	if current_identity.get("status") != "ready":
		return {"status":"pending", "reason":String(current_identity.get("reason",
			"citadel_transform_member_identity_unavailable")), "retryable":true,
			"sourcePartId":part_id}
	var captured_identity: Variant = cached.get("visualSourceReceipt", {})
	var same_identity: bool = captured_identity is Dictionary \
		and current_identity == captured_identity \
		and String(current_identity.get("sourceRevision", "")) == expected_revision \
		and current_identity.get("sourceToWorld") == owner.get("sourceToWorld") \
		and int(cached.get("publisherInstanceId", -1)) == publisher.get_instance_id() \
		and cached.get("sourceToWorld") == owner.get("sourceToWorld")
	if not same_identity:
		return {"status":"ready", "artifactAuthorityRevision":"__stale__"}
	return {"status":"ready",
		"artifactAuthorityRevision":String(cached.get("artifactAuthorityRevision", "")),
		"epochProof":current_identity}


func _static_section_source_capture_identity(world_id: String,
		section_keys: Array[Vector3i]) -> String:
	if _admission == null:
		return ""
	var identity_rows: Array = [["citadel-section-source-capture/v2", world_id,
		_generation, int(_admission.stats().get("generation", -1)),
		_owner_snapshot_token if _owner_snapshot_active() else 0]]
	for section_key: Vector3i in section_keys:
		var admission_bounds := _citadel_section_admission_bounds(section_key)
		var low_region := Field.region_for_cell(admission_bounds.position)
		var high_region := Field.region_for_cell(admission_bounds.end - Vector2i.ONE)
		for rz in range(low_region.y, high_region.y + 1):
			for rx in range(low_region.x, high_region.x + 1):
				var region := Vector2i(rx, rz)
				var source: Dictionary = _admission.source_state(region)
				var binding: Dictionary = source.get("binding", {})
				var plan = _publication_plan_for_binding(binding) if not binding.is_empty() else null
				var scene_entry: Dictionary = _scenes.get(region, {})
				var scene_job: Variant = scene_entry.get("job")
				var publisher: Variant = scene_job.get("_building") \
					if is_instance_valid(scene_job) else null
				var publisher_id := int(publisher.get_instance_id()) \
					if is_instance_valid(publisher) else 0
				var parent: Variant = publisher.get("_scene_parent").get_ref() \
					if is_instance_valid(publisher) and publisher.get("_scene_parent") is WeakRef else null
				var source_transform: Transform3D = parent.global_transform \
					if is_instance_valid(parent) and parent is Node3D else Transform3D.IDENTITY
				identity_rows.append([section_key, region, String(source.get("status", "")),
					source.get("reservationCells"), binding,
					String(plan.output_signature) if plan != null else "",
					int(scene_job.get_instance_id()) if is_instance_valid(scene_job) else 0,
					publisher_id, source_transform])
		var removals: Dictionary = _geometry_owner_removal_sections.get(section_key, {})
		var removal_ids: Array = removals.keys()
		removal_ids.sort()
		identity_rows.append(["removals", section_key, removal_ids])
	var digest := HashingContext.new()
	if digest.start(HashingContext.HASH_SHA256) != OK \
			or digest.update(var_to_bytes(identity_rows)) != OK:
		return ""
	return digest.finish().hex_encode()


func _capture_citadel_member_authority_for_census(site_id: String,
		member_id: String) -> Dictionary:
	var job: Dictionary = _section_source_census_capture_jobs.get(
		_active_source_census_capture_key, {})
	if job.is_empty():
		return _current_tree_member_artifact_authority(site_id, member_id) \
			if member_id.begins_with("tree:") else \
			_capture_member_transform_artifact_authority(site_id, member_id)
	var cache: Dictionary = job.get("memberAuthorities", {})
	var authority_key := var_to_str([site_id, member_id])
	if cache.has(authority_key):
		return cache[authority_key]
	var advance_elapsed_usec := Time.get_ticks_usec() - _active_source_census_started_usec \
		if _active_source_census_started_usec > 0 else 0
	if _active_source_census_member_work >= MAX_CITADEL_CENSUS_MEMBER_AUTHORITIES_PER_ADVANCE \
			or _active_source_census_member_work > 0 \
			and advance_elapsed_usec >= CITADEL_CENSUS_MEMBER_AUTHORITY_ADVANCE_BUDGET_USEC:
		var continuation := {"schema":"static-section-provider-continuation/v1",
			"stage":"member_authority",
			"cursor":int(job.get("memberAuthorityCount", 0))}
		continuation.make_read_only()
		return {"status":"pending", "reason":"citadel_section_source_census_slice_pending",
			"retryable":true, "continuationHint":continuation,
			"captureProgress":{"phase":"member_authority",
				"completedMemberAuthorityCount":int(job.get("memberAuthorityCount", 0)),
				"lastAttemptedMemberId":String(job.get("lastAttemptedMemberId", "")),
				"lastAuthorityStatus":String(job.get("lastAuthorityStatus", "")),
				"lastAuthorityReason":String(job.get("lastAuthorityReason", "")),
				"budgetDeferredMemberId":member_id}}
	_active_source_census_member_work += 1
	var authority: Dictionary = _current_tree_member_artifact_authority(site_id, member_id) \
		if member_id.begins_with("tree:") else \
		_capture_member_transform_artifact_authority(site_id, member_id)
	if authority.get("status") == "ready" \
		or authority.get("status") == "absent" and authority.get("reason") == "removed_prop":
		cache[authority_key] = authority
		job["memberAuthorityCount"] = int(job.get("memberAuthorityCount", 0)) + 1
	job["memberAuthorities"] = cache
	job["lastAdvanceFrame"] = Engine.get_process_frames()
	job["lastAttemptedMemberId"] = member_id
	job["lastAuthorityStatus"] = String(authority.get("status", ""))
	job["lastAuthorityReason"] = String(authority.get("reason", ""))
	_section_source_census_capture_jobs[_active_source_census_capture_key] = job
	return authority


func _prune_static_section_source_capture_jobs(except_key: String) -> void:
	var current_frame := Engine.get_process_frames()
	for key_value: Variant in _section_source_census_capture_jobs.keys():
		var key := String(key_value)
		if key == except_key:
			continue
		var job: Dictionary = _section_source_census_capture_jobs.get(key, {})
		if current_frame - int(job.get("lastAdvanceFrame", current_frame)) \
				> CITADEL_CENSUS_CAPTURE_IDLE_FRAMES:
			_section_source_census_capture_jobs.erase(key)
	while _section_source_census_capture_jobs.size() >= MAX_CITADEL_CENSUS_CAPTURE_JOBS:
		var oldest_key := ""
		var oldest_frame := current_frame
		for key_value: Variant in _section_source_census_capture_jobs:
			var key := String(key_value)
			if key == except_key:
				continue
			var job: Dictionary = _section_source_census_capture_jobs[key]
			var last_frame := int(job.get("lastAdvanceFrame", current_frame))
			if oldest_key.is_empty() or last_frame < oldest_frame:
				oldest_key = key
				oldest_frame = last_frame
		if oldest_key.is_empty():
			break
		_section_source_census_capture_jobs.erase(oldest_key)

func _capture_static_section_sources_uncached(world_id: String, section_keys: Array) -> Dictionary:
	if _admission == null or _closing or _world_reset_pending \
			or world_id != "seed:%s:%d" % [_seed,_seed_hash(_seed)] or section_keys.is_empty():
		return {"status":"pending","reason":"citadel_section_source_authority_unavailable","retryable":true}
	var unique_sections: Dictionary = {}
	var sections: Array[Vector3i] = []
	for value in section_keys:
		if not value is Vector3i or unique_sections.has(value):
			return {"status":"failed","reason":"invalid_citadel_section_source_query"}
		unique_sections[value] = true
		sections.append(value)
	sections.sort_custom(func(a: Vector3i,b: Vector3i) -> bool:
			if a.x != b.x: return a.x < b.x
			if a.y != b.y: return a.y < b.y
			return a.z < b.z)
	var section_rows: Dictionary = {}
	var source_revisions: Dictionary = {}
	var removals_by_section: Dictionary = {}
	var authority_rows: Array = []
	for section_key: Vector3i in sections:
		_source_capture_active_section = section_key
		_emit_source_capture_phase("section_admission", {"sectionKey":section_key})
		var origin := SectionGrid.origin_for_key(section_key)
		var section_bounds := AABB(origin,Vector3.ONE*SectionGrid.SECTION_SIZE_METERS)
		# request_bounds operates on terrain cells and is deliberately conservative
		# at the section edge; exact provider membership is filtered in 3D below.
		var admission_bounds := _citadel_section_admission_bounds(section_key)
		var admitted: Dictionary = _admission.request_bounds(admission_bounds)
		if admitted.get("status") == "pending":
			return {"status":"pending","reason":"citadel_section_admission_pending",
				"section":section_key,"retryable":true}
		if admitted.get("status") != "ready":
			return {"status":"failed","reason":String(admitted.get("reason","citadel_section_admission_failed")),
				"section":section_key}
		var low_region := Field.region_for_cell(admission_bounds.position)
		var high_region := Field.region_for_cell(admission_bounds.end-Vector2i.ONE)
		var ids: Array[String] = []
		var rows: Array = []
		var region_decisions: Array = []
		for rz in range(low_region.y,high_region.y+1):
			for rx in range(low_region.x,high_region.x+1):
				var region := Vector2i(rx,rz)
				_emit_source_capture_phase("region_source_state", {
					"sectionKey":section_key, "region":region})
				var source: Dictionary = _admission.source_state(region)
				if source.get("status") == "absent":
					# request_bounds proved any unprepared region does not intersect
					# the admitted query, so source_not_requested is also safe here.
					var absent_decision := [[region.x, region.y], "absent",
						int(_admission.stats().get("generation", -1))]
					absent_decision[0].make_read_only()
					absent_decision.make_read_only()
					region_decisions.append(absent_decision)
					var absent_authority_row := [section_key, absent_decision]
					absent_authority_row.make_read_only()
					authority_rows.append(absent_authority_row)
					continue
				if source.get("status") == "failed":
					return {"status":"failed","reason":String(source.get("reason","citadel_section_source_failed")),
						"section":section_key,"region":region}
				if source.get("status") not in ["ready","prepared"]:
					return {"status":"pending","reason":"citadel_section_source_decision_pending",
						"section":section_key,"region":region,"retryable":true}
				if not source.get("reservationCells") is Rect2i:
					return {"status":"failed","reason":"citadel_section_reservation_missing","region":region}
				if not source.reservationCells.intersects(admission_bounds):
					var outside_decision := [[region.x, region.y], "ready_outside_bounds",
						source.reservationCells, String(source.get("binding", {}).get("siteId", "")),
						String(source.get("binding", {}).get("sourceKey", "")),
						int(source.get("binding", {}).get("generation", -1))]
					outside_decision[0].make_read_only()
					outside_decision.make_read_only()
					region_decisions.append(outside_decision)
					var outside_authority_row := [section_key, outside_decision]
					outside_authority_row.make_read_only()
					authority_rows.append(outside_authority_row)
					continue
				if _failures.has(region):
					return {"status":"failed","reason":String(_failures[region].reason),"region":region}
				var binding: Dictionary = source.get("binding",{})
				var plan = _publication_plan_for_binding(binding)
				if plan == null or not plan.matches(binding,plan.groups):
					return {"status":"pending","reason":"citadel_section_plan_pending",
						"section":section_key,"region":region,"retryable":true}
				var description: Dictionary = plan.visual_members_intersecting_bounds(section_bounds)
				if description.get("status") != "described":
					return {"status":"failed","reason":String(description.get("reason","citadel_section_membership_failed")),
						"region":region}
				var region_decision := [[region.x, region.y], String(source.get("status", "")),
					source.reservationCells, String(binding.get("siteId", "")),
					String(binding.get("sourceKey", "")), int(binding.get("generation", -1)),
					plan.output_signature]
				region_decision[0].make_read_only()
				region_decision.make_read_only()
				region_decisions.append(region_decision)
				var plan_authority_row := [section_key, region_decision]
				plan_authority_row.make_read_only()
				authority_rows.append(plan_authority_row)
				var described_members: Array = description.members.duplicate()
				_emit_source_capture_phase("region_plan_members", {
					"sectionKey":section_key, "region":region,
					"memberCount":described_members.size(),
					"plannedMemberCount":plan.member_records.size()})
				# Declared tree bounds are a conservative broad phase, expanded by the
				# active shader wind envelope. Only trees that can reach this section
				# need a live admitted source authority; the selected tree's complete
				# compiled support manifest remains the final membership proof below.
				var selected_tree_ids: Dictionary = {}
				for selected: Dictionary in described_members: selected_tree_ids[String(selected.memberId)] = true
				var wind_envelope: Dictionary = TreeVisualPolicy.active_tree_visual_wind_envelope()
				if wind_envelope.get("status") != "ready":
					return {"status":"pending", "reason":String(wind_envelope.get("reason",
						"citadel_tree_support_policy_pending")), "retryable":true,
						"section":section_key, "region":region}
				var horizontal_wind_margin := maxf(
					float(wind_envelope.get("branchComponentDisplacementMaxMeters", 0.0)),
					float(wind_envelope.get("foliageComponentDisplacementMaxMeters", 0.0)))
				var vertical_wind_margin := float(wind_envelope.get(
					"foliageVerticalDisplacementMaxMeters", 0.0))
				for planned: Dictionary in plan.member_records:
					var tree_member_id := String(planned.get("memberId", ""))
					if not tree_member_id.begins_with("tree:") or selected_tree_ids.has(tree_member_id): continue
					var declared_tree_bounds: Variant = planned.get("visualSupportBounds",
						planned.get("bounds", null))
					if not declared_tree_bounds is AABB:
						return {"status":"failed", "reason":"citadel_tree_declared_bounds_missing",
							"section":section_key, "region":region, "memberId":tree_member_id}
					var conservative_tree_bounds := AABB(
						declared_tree_bounds.position - Vector3(horizontal_wind_margin,
							vertical_wind_margin, horizontal_wind_margin),
						declared_tree_bounds.size + Vector3(horizontal_wind_margin * 2.0,
							vertical_wind_margin * 2.0, horizontal_wind_margin * 2.0))
					if not conservative_tree_bounds.intersects(section_bounds): continue
					_emit_source_capture_phase("tree_artifact_authority", {
						"sectionKey":section_key, "region":region,
						"memberId":tree_member_id})
					var tree_id := _citadel_census_source_id(String(binding.siteId), tree_member_id)
					var previous_support: bool = _geometry_owner_removal_sections.get(section_key, {}).has(tree_id)
					var tree_authority := _capture_citadel_member_authority_for_census(
						String(binding.siteId), tree_member_id)
					if tree_authority.get("status") == "ready":
						var manifest: Dictionary = tree_authority.capture.producer.sourceManifest
						if previous_support or section_key in manifest.get("sectionKeys", []):
							described_members.append(planned)
					elif previous_support:
						# An old source must yield an explicit removal or replacement.
						described_members.append(planned)
				described_members.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
					return String(a.get("memberId", "")) < String(b.get("memberId", "")))
				for member_value: Variant in described_members:
					if not member_value is Dictionary:
						return {"status":"failed","reason":"citadel_section_member_invalid"}
					var member: Dictionary = member_value
					var member_id := String(member.memberId)
					var source_id := _citadel_census_source_id(String(binding.siteId), member_id)
					_emit_source_capture_phase("member_transform_artifact_authority", {
						"sectionKey":section_key, "region":region,
						"memberId":member_id})
					var artifact_authority := _capture_citadel_member_authority_for_census(
						String(binding.siteId), member_id)
					if member_id.begins_with("tree:") and artifact_authority.get("status") == "absent" \
							and artifact_authority.get("reason") == "removed_prop":
						authority_rows.append([section_key, source_id, "durably_removed",
							artifact_authority.get("propId"), binding])
						continue
					if artifact_authority.get("status") != "ready":
						artifact_authority["sectionKey"] = section_key
						var capture_progress: Dictionary = artifact_authority.get("captureProgress", {})
						capture_progress["budgetDeferredMemberId"] = member_id
						artifact_authority["captureProgress"] = capture_progress
						return artifact_authority
					var revision := _citadel_member_source_revision(world_id, binding, plan,
						member, String(artifact_authority.get("artifactAuthorityRevision", "")))
					if revision.is_empty():
						return {"status":"failed","reason":"citadel_section_revision_hash_failed"}
					if source_revisions.has(source_id) and source_revisions[source_id] != revision:
						return {"status":"failed","reason":"citadel_section_source_revision_conflict"}
					source_revisions[source_id] = revision
					ids.append(source_id)
					rows.append([source_id,revision])
					var artifact_authority_row := [section_key, source_id,
						String(artifact_authority.get("artifactAuthorityRevision", ""))]
					artifact_authority_row.make_read_only()
					authority_rows.append(artifact_authority_row)
		ids.sort()
		rows.sort_custom(func(a: Array,b: Array) -> bool: return String(a[0]) < String(b[0]))
		for row_value: Variant in rows:
			if row_value is Array:
				row_value.make_read_only()
		ids.make_read_only()
		rows.make_read_only()
		region_decisions.make_read_only()
		_emit_source_capture_phase("removal_census", {"sectionKey":section_key,
			"sourceCount":ids.size()})
		var removal_result: Dictionary = _collect_current_citadel_removals(
			world_id, section_key, section_bounds, ids, rows, region_decisions)
		if removal_result.get("status") != "ready":
			return removal_result
		var removals: Array[Dictionary] = removal_result.get("removals", [])
		removals.make_read_only()
		removals_by_section[section_key] = removals
		var canonical_removals: Array = []
		for removal: Dictionary in removals:
			canonical_removals.append([String(removal.sourcePartId),
				String(removal.sourceId), String(removal.sourceRevision),
				String(removal.get("ownerBindingDigest", "")),
				String(removal.get("memberBinding", "")), removal.get("bounds", AABB())])
		var coverage_hash := HashingContext.new()
		coverage_hash.start(HashingContext.HASH_SHA256)
		coverage_hash.update(var_to_bytes([world_id,section_key,rows,
			region_decisions,canonical_removals]))
		var section_row := {"status":"complete" if not ids.is_empty() else "empty",
			"coverageRevision":coverage_hash.finish().hex_encode(),"sourcePartIds":ids,
			"regionDecisions":region_decisions}
		section_row.make_read_only()
		section_rows[section_key] = section_row
		_emit_source_capture_phase("section_revision_sealed", {"sectionKey":section_key,
			"sourceCount":ids.size(), "removalCount":removals.size()})
	section_rows.make_read_only()
	source_revisions.make_read_only()
	removals_by_section.make_read_only()
	for authority_row_value: Variant in authority_rows:
		if authority_row_value is Array:
			authority_row_value.make_read_only()
	authority_rows.make_read_only()
	var admission_state: Dictionary = _admission.stats()
	var authority_hash := HashingContext.new()
	authority_hash.start(HashingContext.HASH_SHA256)
	authority_hash.update(var_to_bytes(["citadel-section-authority/v1",world_id,_generation,
		int(admission_state.get("generation",-1)),authority_rows]))
	return {"status":"complete","worldId":world_id,
		"authorityRevision":authority_hash.finish().hex_encode(),
		"sourceRevisions":source_revisions,"sections":section_rows,
		"removalsBySection":removals_by_section}


## Bind the provider census to the live publisher incarnation, exact member
## binding, parent transform, and committed transform-artifact content. This
## keeps the generic coordinator census current across asynchronous compile and
## install without retaining a mutable side-channel acceptance proof.
static func _citadel_member_source_revision(world_id: String, binding: Dictionary,
		plan, member: Dictionary, artifact_revision: String) -> String:
	var digest := HashingContext.new()
	if artifact_revision.is_empty() or digest.start(HashingContext.HASH_SHA256) != OK:
		return ""
	digest.update(var_to_bytes(["citadel-member-source/v3", world_id, binding.siteId,
		binding.sourceKey, int(binding.get("generation", -1)), plan.output_signature,
		member.memberId, member.groupId, member.bounds, artifact_revision]))
	return digest.finish().hex_encode()


func _captured_presentation_identity(capture: Dictionary) -> Dictionary:
	if not capture.has("presentationMounts") and not capture.has("presentationBindings") and not capture.has("presentationDigest"):
		return {"status":"ready", "members":[], "digest":"", "bindingWitnesses":[]}
	var members: Variant = capture.get("presentationMounts")
	var bindings: Variant = capture.get("presentationBindings")
	if not members is Array or not members.is_read_only() or not bindings is Dictionary or not bindings.is_read_only() \
			or members.size() != bindings.size(): return {"status":"pending", "reason":"citadel_presentation_capture_unsealed"}
	var digest := HashingContext.new()
	if digest.start(HashingContext.HASH_SHA256) != OK or digest.update(var_to_bytes([
			"building-practical-light-presentation/v1", members])) != OK:
		return {"status":"failed", "reason":"citadel_presentation_capture_hash_failed"}
	var content_digest := digest.finish().hex_encode()
	if content_digest != capture.get("presentationDigest"):
		return {"status":"pending", "reason":"citadel_presentation_capture_digest_stale"}
	var seen: Dictionary = {}
	var witnesses: Array = []
	for member: Variant in members:
		if not member is Dictionary or not member.is_read_only() \
				or member.get("sourcePartId") != capture.get("sourcePartId") \
				or member.get("sourceRevision") != capture.get("sourceRevision") \
				or member.get("producerSourceRevision") != capture.get("sourceRevision"):
			return {"status":"pending", "reason":"citadel_presentation_capture_source_stale"}
		var key := String(member.get("attachmentKey", ""))
		var binding: Variant = bindings.get(key)
		if key.is_empty() or seen.has(key) or not binding is Dictionary or not binding.is_read_only():
			return {"status":"pending", "reason":"citadel_presentation_capture_binding_missing"}
		seen[key] = true
		var witness: Array = []
		for field: String in ["publisherInstanceId", "publicationEpoch", "sourcePartId", "sourceRevision",
				"parentInstanceId", "bodyInstanceId", "mountInstanceId", "lightInstanceId", "attachmentKey", "presentationMemberId"]:
			if not binding.has(field): return {"status":"pending", "reason":"citadel_presentation_binding_witness_missing:" + field}
			witness.append(binding[field])
		witnesses.append(witness)
	return {"status":"ready", "members":members, "digest":content_digest, "bindingWitnesses":witnesses}

func _current_member_transform_artifact_authority(site_id: String,
		member_id: String) -> Dictionary:
	if not _owner_snapshot_active(): return _capture_member_transform_artifact_authority(site_id, member_id)
	var values := _owner_snapshot_bucket("memberAuthority")
	var key := var_to_str([site_id, member_id])
	if values.has(key): return values[key]
	var result := _capture_member_transform_artifact_authority(site_id, member_id)
	if result.get("status") == "ready":
		var sealed := result.duplicate(false)
		sealed.make_read_only()
		values[key] = sealed
		return sealed
	return result

func _capture_member_transform_artifact_authority(site_id: String, member_id: String) -> Dictionary:
	if member_id.begins_with("tree:"):
		return _current_tree_member_artifact_authority(site_id, member_id)
	if not _is_transform_member(member_id):
		return {"status":"failed", "reason":"citadel_transform_member_kind_invalid",
			"siteId":site_id, "memberId":member_id}
	var part_id := _transform_part_id(member_id)
	_emit_source_capture_phase("member_publisher_lookup", {"memberId":member_id})
	var owner := _current_transform_artifact_publisher_for_member(site_id, member_id)
	_emit_source_capture_phase("member_publisher_lookup_complete", {"memberId":member_id,
		"status":String(owner.get("status", ""))})
	if owner.get("status") != "ready":
		return owner
	var publisher = owner.get("publisher")
	_emit_source_capture_phase("member_revision_lookup", {"memberId":member_id,
		"sourcePartId":part_id})
	var member_binding := _expected_visual_source_revision(owner, part_id)
	_emit_source_capture_phase("member_revision_lookup_complete", {"memberId":member_id,
		"sourcePartId":part_id})
	if member_binding.is_empty():
		return {"status":"pending", "reason":"citadel_transform_member_binding_unavailable",
			"sourcePartId":part_id, "retryable":true}
	var capture: Dictionary = _capture_owner_source_snapshot(publisher,
		part_id, member_binding)
	_emit_source_capture_phase("member_source_capture_complete", {"memberId":member_id,
		"sourcePartId":part_id, "status":String(capture.get("status", ""))})
	if capture.get("status") != "ready" or String(capture.get("sourceRevision", "")) != member_binding:
		return {"status":"pending", "reason":String(capture.get("reason",
			"citadel_transform_member_artifact_unavailable")),
			"sourcePartId":part_id, "retryable":true}
	var groups_value: Variant = capture.get("groups", null)
	_emit_source_capture_phase("member_presentation_identity", {"memberId":member_id,
		"sourcePartId":part_id, "groupCount":groups_value.size() if groups_value is Array else -1})
	var presentation_identity := _captured_presentation_identity(capture)
	_emit_source_capture_phase("member_presentation_identity_complete", {"memberId":member_id,
		"sourcePartId":part_id, "status":String(presentation_identity.get("status", ""))})
	if presentation_identity.get("status") != "ready": return presentation_identity
	if not groups_value is Array or not groups_value.is_read_only() \
			or (groups_value.is_empty() and presentation_identity.members.is_empty()):
		return {"status":"pending", "reason":"citadel_transform_member_artifact_manifest_unavailable",
			"sourcePartId":part_id, "retryable":true}
	var group_rows: Array = []
	var seen_group_ids: Dictionary = {}
	for group_value: Variant in groups_value:
		if not group_value is Dictionary or not group_value.is_read_only():
			return {"status":"pending", "reason":"citadel_transform_member_artifact_group_unsealed",
				"sourcePartId":part_id, "retryable":true}
		var group: Dictionary = group_value
		var group_id := String(group.get("sourceId", ""))
		_emit_source_capture_phase("member_group_identity", {"memberId":member_id,
			"sourcePartId":part_id, "groupId":group_id})
		var content_digest := String(group.get("contentDigest", ""))
		if group_id.is_empty() or seen_group_ids.has(group_id) \
				or content_digest.length() != 64 \
				or String(group.get("sourcePartId", "")) != part_id \
				or group.get("sourceToWorld") != owner.get("sourceToWorld"):
			return {"status":"pending", "reason":"citadel_transform_member_artifact_identity_stale",
				"sourcePartId":part_id, "retryable":true}
		seen_group_ids[group_id] = true
		var segment_rows: Array = []
		var segments_value: Variant = group.get("segments", null)
		if not segments_value is Array or not segments_value.is_read_only() or segments_value.is_empty():
			return {"status":"pending", "reason":"citadel_transform_member_artifact_segments_unavailable",
				"sourcePartId":part_id, "retryable":true}
		for segment_value: Variant in segments_value:
			if not segment_value is Dictionary or not segment_value.is_read_only():
				return {"status":"pending", "reason":"citadel_transform_member_artifact_segment_unsealed",
					"sourcePartId":part_id, "retryable":true}
			var segment: Dictionary = segment_value
			var segment_id := String(segment.get("segmentId", ""))
			var segment_digest := String(segment.get("contentDigest", ""))
			if segment_id.is_empty() or segment_digest.length() != 64:
				return {"status":"pending", "reason":"citadel_transform_member_artifact_segment_identity_invalid",
					"sourcePartId":part_id, "retryable":true}
			segment_rows.append([segment_id, segment_digest,
				segment.get("bounds"), int(segment.get("instanceCount", 0))])
		segment_rows.sort_custom(func(a: Array, b: Array) -> bool:
			return String(a[0]) < String(b[0]))
		group_rows.append([group_id, content_digest,
			String(group.get("meshContentDigest", "")),
			String(group.get("materialContentDigest", "")),
			group.get("sourceToWorld"), group.get("localBounds"),
			group.get("worldBounds"), group.get("ownerCell"),
			group.get("renderChunkKey"), String(group.get("renderLayer", "")),
			String(group.get("transparencySortPolicy", "")),
			int(group.get("instanceCount", 0)), segment_rows])
	group_rows.sort_custom(func(a: Array, b: Array) -> bool:
		return String(a[0]) < String(b[0]))
	var payload := ["citadel-live-transform-artifact-authority/v1",
		String(_admission.stats().get("worldSeed", "")), site_id,
		owner.get("binding", {}), int(publisher.get_instance_id()), part_id,
		member_binding, capture.get("visualSourceReceipt", {}), owner.get("sourceToWorld"), group_rows,
		presentation_identity.digest, presentation_identity.bindingWitnesses]
	if owner.has("sceneJobInstanceId"): payload.append(owner.sceneJobInstanceId)
	_emit_source_capture_phase("member_authority_hash", {"memberId":member_id,
		"sourcePartId":part_id, "groupCount":group_rows.size()})
	var digest := HashingContext.new()
	if digest.start(HashingContext.HASH_SHA256) != OK \
			or digest.update(var_to_bytes(payload)) != OK:
		return {"status":"failed", "reason":"citadel_transform_member_authority_hash_failed"}
	var authority_revision := digest.finish().hex_encode()
	_emit_source_capture_phase("member_authority_hash_complete", {"memberId":member_id,
		"sourcePartId":part_id, "groupCount":group_rows.size()})
	return {"status":"ready", "artifactAuthorityRevision":authority_revision,
		"publisherInstanceId":int(publisher.get_instance_id()),
		"memberBinding":member_binding, "visualSourceReceipt":capture.get("visualSourceReceipt", {}), "sourceToWorld":owner.get("sourceToWorld")}


## Reuse the same admitted scene job and live source-owner boundary as static
## building parts. The alias is provider membership, never a rewritten tree ID.
func _current_tree_member_artifact_authority(site_id: String, member_id: String) -> Dictionary:
	var owner := _current_transform_artifact_publisher_for_site(site_id)
	if owner.get("status") != "ready": return owner
	var entry: Dictionary = _scenes.get(owner.region, {})
	var job: Variant = entry.get("job")
	if not is_instance_valid(job) or not job.has_method("capture_tree_section_source"):
		return {"status":"pending", "reason":"citadel_tree_scene_source_unavailable", "retryable":true}
	var capture: Dictionary = job.call("capture_tree_section_source", member_id, owner.binding)
	if capture.get("status") == "absent" and capture.get("reason") == "removed_prop":
		var absent := capture.duplicate()
		absent["jobInstanceId"] = job.get_instance_id()
		return absent
	if capture.get("status") != "ready": return capture.duplicate()
	var producer: Dictionary = capture.get("producer", {})
	var manifest: Dictionary = producer.get("sourceManifest", {})
	var expected_alias := _citadel_census_source_id(site_id, member_id)
	if not capture.is_read_only() or capture.get("sourceId") != expected_alias \
			or capture.get("binding") != owner.binding \
			or int(capture.get("jobInstanceId", 0)) != job.get_instance_id():
		return {"status":"pending", "reason":"citadel_tree_admitted_source_stale", "retryable":true}
	var digest := HashingContext.new()
	if digest.start(HashingContext.HASH_SHA256) != OK \
			or digest.update(var_to_bytes(["citadel-admitted-tree-authority/v1", expected_alias,
			owner.binding, job.get_instance_id(), capture.get("admittedTreeRecord"),
			producer.get("queueInstanceId"), producer.get("bodyInstanceId"),
			producer.get("bodyGlobalTransform"), producer.get("propId"),
			producer.get("producerSourceId"), producer.get("producerRevision"),
			producer.get("compiledSourceRevision"), manifest.get("compiledAttributeDigest"),
			manifest.get("ownedSectionKeys"), manifest.get("sectionKeys")])) != OK:
		return {"status":"failed", "reason":"citadel_tree_authority_hash_failed"}
	var revision := digest.finish().hex_encode()
	return {"status":"ready", "artifactAuthorityRevision":revision,
		"memberBinding":revision, "capture":capture, "job":job,
		"publisherInstanceId":job.get_instance_id(), "binding":owner.binding,
		"sourceToWorld":owner.sourceToWorld}

func _expected_visual_source_revision(owner: Dictionary, part_id: String) -> String:
	var binding: Dictionary = owner.get("binding", {})
	var plan = _publication_plan_for_binding(binding)
	if plan == null or not plan.matches(binding, plan.groups): return ""
	var revisions: Variant = plan.get("visual_source_revisions")
	if not revisions is Dictionary or not revisions.is_read_only(): return ""
	return String(revisions.get("furnishing:" + part_id if owner.get("memberKind") == "furnishing" else part_id, ""))


func _collect_current_citadel_removals(world_id: String,
		section_key: Vector3i, section_bounds: AABB, current_source_ids: Array[String],
		member_rows: Array, region_decisions: Array) -> Dictionary:
	var current_ids: Dictionary = {}
	for source_id: String in current_source_ids:
		current_ids[source_id] = true
	var removed_members: Dictionary = {}
	var seen_sites: Dictionary = {}
	for region_value: Variant in _scenes:
		if not region_value is Vector2i or not _scenes[region_value] is Dictionary:
			return {"status":"pending", "reason":"citadel_removal_scene_owner_unavailable",
				"retryable":true}
		var region: Vector2i = region_value
		var entry: Dictionary = _scenes[region]
		var binding: Dictionary = entry.get("binding", {})
		if String(entry.get("phase", "")) != "scene_ready":
			continue
		var site_id := String(binding.get("siteId", ""))
		if site_id.is_empty():
			return {"status":"pending", "reason":"citadel_removal_scene_binding_unavailable",
				"region":region, "retryable":true}
		var current: Dictionary = _admission.source_state(region)
		if current.get("status") not in ["ready", "prepared"] \
				or current.get("binding", {}) != binding:
			continue
		var reservation_value: Variant = current.get("reservationCells", null)
		if not reservation_value is Rect2i:
			return {"status":"pending", "reason":"citadel_removal_reservation_unavailable",
				"region":region, "retryable":true}
		var reservation: Rect2i = reservation_value
		if not reservation.intersects(_citadel_section_admission_bounds(section_key)):
			continue
		if seen_sites.has(site_id):
			return {"status":"pending", "reason":"citadel_removal_site_owner_ambiguous",
				"siteId":site_id, "retryable":true}
		seen_sites[site_id] = true
		var plan = _publication_plan_for_binding(binding)
		if plan == null or not plan.matches(binding, plan.groups):
			return {"status":"pending", "reason":"citadel_removal_current_plan_unavailable",
				"siteId":site_id, "retryable":true}
		var current_description: Dictionary = plan.visual_members_intersecting_bounds(section_bounds)
		if current_description.get("status") != "described":
			return {"status":"pending", "reason":"citadel_removal_current_membership_unavailable",
				"siteId":site_id, "retryable":true}
		var current_member_ids: Dictionary = {}
		var all_current_members: Dictionary = {}
		var plan_records: Variant = plan.get("member_records")
		if not plan_records is Array:
			return {"status":"pending", "reason":"citadel_removal_complete_plan_inventory_unavailable", "retryable":true}
		if plan_records is Array:
			for member_value: Variant in plan_records:
				if not member_value is Dictionary or String(member_value.get("memberId", "")).is_empty() \
						or all_current_members.has(String(member_value.get("memberId", ""))):
					return {"status":"pending", "reason":"citadel_removal_complete_plan_inventory_invalid", "retryable":true}
				all_current_members[String(member_value.memberId)] = member_value
		for member_value: Variant in current_description.get("members", []):
			if member_value is Dictionary:
				current_member_ids[String(member_value.get("memberId", ""))] = true
		var job = entry.get("job")
		for publisher: Variant in _scene_visual_publishers(job):
			if publisher == null or not is_instance_valid(publisher) \
				or not _publisher_node_roster_available(publisher) \
					or String(publisher.get("publication_site_id")) != site_id:
				return {"status":"pending", "reason":"citadel_removal_publisher_unavailable",
					"siteId":site_id, "retryable":true}
			var binding_identity := [site_id, String(binding.get("sourceKey", "")),
				int(binding.get("generation", -1))]
			for visual_value: Variant in _published_legacy_geometry(publisher):
				var visual := visual_value as GeometryInstance3D
				if not is_instance_valid(visual) or not visual.is_inside_tree() \
						or visual.is_queued_for_deletion() \
						or (not visual.visible and not _legacy_has_section_ownership(visual)):
					continue
				var part_id := String(visual.get_meta("building_source_part_id", ""))
				if part_id.is_empty() or current_member_ids.has(_visual_member_id(visual)):
					continue
				var bounds := visual.global_transform * visual.get_aabb()
				if not bounds.position.is_finite() or not bounds.size.is_finite() \
						or bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
					return {"status":"pending", "reason":"citadel_removal_visual_bounds_unavailable",
						"siteId":site_id, "sourcePartId":part_id, "memberId":_visual_member_id(visual), "retryable":true}
				if section_key not in SectionGrid.keys_intersecting_bounds(bounds):
					continue
				var old_visual_identity: Dictionary = publisher.committed_static_visual_source_identity(part_id)
				var old_member_binding := String(old_visual_identity.get("sourceRevision", "")) if old_visual_identity.get("status") == "ready" else ""
				if old_member_binding.is_empty():
					return {"status":"pending", "reason":"citadel_removal_old_member_binding_unavailable",
						"siteId":site_id, "sourcePartId":part_id, "memberId":_visual_member_id(visual), "retryable":true}
				var source_id := _citadel_census_source_id(site_id,
					_visual_member_id(visual), section_key)
				var member_authority_revision := ""
				var current_member: Dictionary = all_current_members.get(_visual_member_id(visual), {})
				if not current_member.is_empty():
					var authority := _current_member_transform_artifact_authority(site_id, _visual_member_id(visual))
					if authority.get("status") != "ready":
						return authority
					var current_capture: Dictionary = publisher.capture_committed_static_visual_source(
						part_id, String(authority.get("memberBinding", "")))
					for group: Dictionary in current_capture.get("groups", []):
						var mesh: Mesh = group.get("resourceBindings", {}).get("mesh")
						if mesh == null:
							return {"status":"pending", "reason":"citadel_removal_current_mesh_unavailable", "retryable":true}
						for segment: Dictionary in group.get("segments", []):
							for instance_index in int(segment.get("instanceCount", 0)):
								var transform := SectionGeometryAdapter.Attributes.decode_transform(segment.buffer,
									instance_index * SectionGeometryAdapter.Attributes.FLOATS_PER_INSTANCE)
								var instance_bounds: AABB = (group.sourceToWorld as Transform3D) * transform * mesh.get_aabb()
								if SectionGrid.keys_intersecting_bounds(instance_bounds).has(section_key):
									return {"status":"pending", "reason":"citadel_member_index_does_not_cover_compiled_geometry",
										"retryable":true, "sourceId":source_id, "sectionKey":section_key}
					member_authority_revision = _citadel_member_source_revision(world_id, binding, plan,
						current_member, String(authority.get("artifactAuthorityRevision", "")))
				if current_ids.has(source_id):
					continue
				var removal_row: Dictionary = removed_members.get(source_id, {
					"siteId":site_id, "sourcePartId":part_id, "memberId":_visual_member_id(visual),
					"sourceId":source_id, "ownerBinding":binding_identity,
					"memberBinding":old_member_binding, "bounds":[],
					"memberAuthorityRevision":member_authority_revision,
					"planSignature":plan.output_signature})
				if removal_row.get("ownerBinding", []) != binding_identity \
						or String(removal_row.get("memberBinding", "")) != old_member_binding:
					return {"status":"pending", "reason":"citadel_removal_identity_conflict",
						"sourceId":source_id, "retryable":true}
				var bounds_rows: Array = removal_row.get("bounds", [])
				bounds_rows.append(bounds)
				removal_row["bounds"] = bounds_rows
				removed_members[source_id] = removal_row
	var removal_ids: Array[String] = []
	for source_id_value: Variant in removed_members:
		removal_ids.append(String(source_id_value))
	removal_ids.sort()
	var result_rows: Array[Dictionary] = []
	for source_id: String in removal_ids:
		var old_row: Dictionary = removed_members[source_id]
		var bounds_values: Array = old_row.get("bounds", [])
		bounds_values.sort_custom(func(a: AABB, b: AABB) -> bool:
			if a.position.x != b.position.x: return a.position.x < b.position.x
			if a.position.y != b.position.y: return a.position.y < b.position.y
			if a.position.z != b.position.z: return a.position.z < b.position.z
			if a.size.x != b.size.x: return a.size.x < b.size.x
			if a.size.y != b.size.y: return a.size.y < b.size.y
			return a.size.z < b.size.z)
		var owner_binding: Array = old_row.get("ownerBinding", [])
		var member_binding := String(old_row.get("memberBinding", ""))
		var revision_payload := ["citadel-member-tombstone/v2", world_id,
			owner_binding, source_id, member_binding, old_row.get("planSignature", "")]
		var revision := String(old_row.get("memberAuthorityRevision", ""))
		if revision.is_empty():
			revision = Marshalls.raw_to_base64(var_to_bytes(revision_payload)).sha256_text()
		var owner_digest := Marshalls.raw_to_base64(var_to_bytes(owner_binding)).sha256_text()
		var removal := {"sourceId":source_id, "sourcePartId":source_id,
			"sourceRevision":revision, "sectionKey":section_key,
			"siteId":String(old_row.get("siteId", "")),
			"memberId":String(old_row.get("memberId", "")),
			"ownerBindingDigest":owner_digest, "memberBinding":member_binding,
			"bounds":bounds_values.duplicate()}
		removal.bounds.make_read_only()
		removal.make_read_only()
		result_rows.append(removal)
	# Admitted previous owner coverage survives retirement of legacy nodes.
	for source_id: String in _geometry_owner_removal_sections.get(section_key, {}):
		if current_ids.has(source_id): continue
		var retained := _current_roster_removal(world_id, source_id, section_key)
		if retained.get("status") != "ready": return retained
		for index in range(result_rows.size() - 1, -1, -1):
			if result_rows[index].get("sourceId") == source_id: result_rows.remove_at(index)
		result_rows.append(retained.removal)
	result_rows.make_read_only()
	return {"status":"ready", "removals":result_rows}


func _current_roster_removal(world_id: String, source_id: String, section: Vector3i) -> Dictionary:
	var proof: Dictionary = _geometry_owner_capture_proofs.get(source_id, {})
	if proof.get("kind") == "tree":
		return _current_tree_roster_removal(world_id, source_id, section, proof)
	var current := _current_transform_artifact_publisher_for_member(String(proof.get("siteId", "")), _proof_transform_member(proof))
	var reference: WeakRef = proof.get("publisher")
	var publisher: Object = reference.get_ref() if reference != null else null
	if current.get("status") != "ready" or not is_instance_valid(publisher) \
			or current.get("publisher") != publisher or publisher.get_instance_id() != int(proof.get("publisherId", 0)) \
			or current.get("binding") != proof.get("binding") \
			or current.get("sceneJobInstanceId", 0) != proof.get("sceneJobInstanceId", 0):
		return {"status":"pending", "reason":"citadel_removal_retained_owner_changed", "retryable":true}
	var binding: Dictionary = current.binding
	var plan = _publication_plan_for_binding(binding)
	if plan == null or not plan.matches(binding, plan.groups) or not plan.get("member_records") is Array:
		return {"status":"pending", "reason":"citadel_removal_complete_plan_inventory_unavailable", "retryable":true}
	var member_id := _proof_transform_member(proof)
	var member: Dictionary = {}
	for value: Variant in plan.get("member_records"):
		if not value is Dictionary or String(value.get("memberId", "")).is_empty():
			return {"status":"pending", "reason":"citadel_removal_complete_plan_inventory_invalid", "retryable":true}
		if value.get("memberId") == member_id:
			if not member.is_empty(): return {"status":"pending", "reason":"citadel_removal_member_ambiguous", "retryable":true}
			member = value
	var roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
	var presentation_only: bool = roster.is_empty() and not proof.get("presentationMembers", []).is_empty() \
		and proof.get("worldId") == world_id
	if not presentation_only and (not OwnerCompletion.validate(roster) or roster.get("worldId") != world_id):
		return {"status":"pending", "reason":"citadel_removal_prior_roster_missing", "retryable":true}
	var revision := ""
	if not member.is_empty():
		var authority := _current_member_transform_artifact_authority(String(proof.siteId), member_id)
		if authority.get("status") != "ready": return authority
		var capture: Dictionary = publisher.capture_committed_static_visual_source(String(proof.partId), String(authority.memberBinding))
		if capture.get("status") != "ready": return capture
		for presentation: Dictionary in capture.get("presentationMounts", []):
			if SectionGrid.key_for_world_position(presentation.neutralParentToWorld.origin) == section:
				return {"status":"pending", "reason":"citadel_member_index_does_not_cover_presentation", "retryable":true}
		for group: Dictionary in capture.get("groups", []):
			var mesh: Mesh = group.get("resourceBindings", {}).get("mesh")
			if mesh == null: return {"status":"pending", "reason":"citadel_removal_current_mesh_unavailable", "retryable":true}
			for segment: Dictionary in group.get("segments", []):
				for index in int(segment.get("instanceCount", 0)):
					var transform := SectionGeometryAdapter.Attributes.decode_transform(segment.buffer, index * SectionGeometryAdapter.Attributes.FLOATS_PER_INSTANCE)
					var instance_bounds: AABB = (group.sourceToWorld as Transform3D) * transform * mesh.get_aabb()
					if section in SectionGrid.keys_intersecting_bounds(instance_bounds):
						return {"status":"pending", "reason":"citadel_member_index_does_not_cover_compiled_geometry", "retryable":true}
		revision = _citadel_member_source_revision(world_id, binding, plan, member, String(authority.artifactAuthorityRevision))
	else:
		var retained_identity: Dictionary = publisher.committed_static_visual_source_identity(String(proof.partId))
		if retained_identity.get("status") != "ready" or retained_identity != proof.get("visualSourceReceipt", {}):
			return {"status":"pending", "reason":"citadel_removal_prior_visual_receipt_changed", "retryable":true}
		if bool(roster.get("explicitRemoval", false)):
			revision = String(roster.sourceRevision)
		else:
			revision = Marshalls.raw_to_base64(var_to_bytes(["citadel-member-removal/v1", world_id,
				source_id, roster.get("sourceRevision", proof.get("sourceRevision", "")),
				_citadel_owner_binding_digest(binding), proof.get("memberBinding")])).sha256_text()
			var sealed := OwnerCompletion.seal(world_id, source_id, source_id, revision,
				String(roster.get("sourceIncarnation", proof.get("sourceIncarnation", ""))), [], true)
			if sealed.get("status") != "ready": return sealed
			proof = proof.duplicate(false)
			proof["sourceRevision"] = revision
			proof["presentationMembers"] = []
			_retain_geometry_owner_roster(source_id, sealed.roster, proof)
	var bounds: Array = _geometry_owner_removal_bounds.get(source_id, {}).get(section, []).duplicate()
	bounds.make_read_only()
	var removal := {"sourceId":source_id, "sourcePartId":source_id, "sourceRevision":revision,
		"sectionKey":section, "siteId":String(proof.siteId), "memberId":member_id,
		"ownerBindingDigest":_citadel_owner_binding_digest(binding), "memberBinding":String(proof.memberBinding),
		"bounds":bounds}
	removal.make_read_only()
	return {"status":"ready", "removal":removal}


## Bridges the current immutable Citadel source census and the actual retained
## prepared packet groups into the shared section partition/snapshot contract.
## This captures value geometry only: it does not publish, retire, or hide the
## current BuildingPartPublisher visuals, collision, doors, or navigation.
func capture_static_section_geometry_candidate(world_id: String, section_key: Vector3i,
		candidate_generation: int) -> Dictionary:
	if candidate_generation <= 0:
		return {"status":"failed", "reason":"invalid_citadel_candidate_generation"}
	var census: Dictionary = capture_static_section_sources(world_id, [section_key])
	if census.get("status") != "complete":
		return census
	var census_sections: Dictionary = census.get("sections", {})
	var census_row: Dictionary = census_sections.get(section_key, {})
	if census_row.is_empty():
		return {"status":"pending", "reason":"citadel_geometry_census_section_missing",
			"retryable":true}
	var packet_groups: Array[Dictionary] = []
	var member_bindings: Dictionary = {}
	var provider_receipts: Array[Dictionary] = []
	if census_row.get("status") == "complete":
		var source_ids: Array = census_row.get("sourcePartIds", [])
		for source_id_value: Variant in source_ids:
			var source_id := String(source_id_value)
			var site_id := SectionGeometryAdapter._site_id_from_census_source(source_id)
			var member_id := SectionGeometryAdapter._member_id_from_census_source(source_id)
			if site_id.is_empty() or not member_id.begins_with("building:"):
				return {"status":"pending", "reason":"citadel_member_kind_has_no_prepared_static_packet",
					"sourceId":source_id, "memberId":member_id, "retryable":true}
			var part_id := _transform_part_id(member_id)
			var owner_result := _current_packet_publisher_for_site(site_id)
			if owner_result.get("status") != "ready":
				owner_result["sourceId"] = source_id
				return owner_result
			var publisher = owner_result.publisher
			_restore_stale_citadel_visuals(publisher, site_id, member_id)
			var member_bindings_by_part: Dictionary = publisher.get("_physical_packet_bindings_by_part_id")
			var member_binding := String(member_bindings_by_part.get(part_id, ""))
			if member_binding.is_empty():
				return {"status":"pending", "reason":"citadel_packet_member_binding_unavailable",
					"sourceId":source_id, "sourcePartId":part_id, "retryable":true}
			var source_revision := String(census.get("sourceRevisions", {}).get(source_id, ""))
			if source_revision.is_empty():
				return {"status":"pending", "reason":"citadel_census_member_revision_unavailable",
					"sourceId":source_id, "retryable":true}
			var expected_by_source: Dictionary = publisher.get("_chunk_static_packet_expected").get(part_id, {})
			var pending_expected_by_source: Dictionary = publisher.get("_chunk_static_packet_pending_expected").get(part_id, {})
			if not pending_expected_by_source.is_empty():
				return {"status":"pending", "reason":"citadel_packet_group_receipts_pending",
					"sourceId":source_id, "pendingPacketSourceIds":pending_expected_by_source.keys(),
					"retryable":true}
			if expected_by_source.is_empty():
				return {"status":"pending", "reason":"citadel_packet_group_roster_unavailable",
					"sourceId":source_id, "sourcePartId":part_id, "retryable":true}
			var recipes: Dictionary = publisher.get("_chunk_static_packet_recipes")
			for packet_source_value: Variant in expected_by_source.keys():
				var packet_source_id := String(packet_source_value)
				var expected: Dictionary = expected_by_source[packet_source_value]
				var recipe_value: Variant = recipes.get(packet_source_id)
				if not recipe_value is Dictionary or not recipe_value.is_read_only():
					return {"status":"pending", "reason":"citadel_prepared_packet_group_missing",
						"sourceId":source_id, "packetSourceId":packet_source_id, "retryable":true}
				var recipe: Dictionary = recipe_value
				if String(recipe.get("sourcePartId", "")) != part_id \
						or String(recipe.get("sourceRevision", "")) != member_binding \
						or String(expected.get("sourceRevision", "")) != member_binding \
						or not publisher.chunk_static_packet_receipt_live(part_id, packet_source_id):
					return {"status":"pending", "reason":"citadel_packet_group_revision_or_receipt_stale",
						"sourceId":source_id, "packetSourceId":packet_source_id, "retryable":true}
				var packet_generation: Variant = expected.get("generation")
				var packet_digest := String(expected.get("packetDigest", ""))
				var expected_owner_cell: Variant = expected.get("ownerCell")
				if not packet_generation is int or int(packet_generation) <= 0 \
						or packet_digest.length() != 64 \
						or expected_owner_cell != recipe.get("ownerCell"):
					return {"status":"pending", "reason":"citadel_packet_receipt_identity_incomplete",
						"sourceId":source_id, "packetSourceId":packet_source_id, "retryable":true}
				var packet_group: Dictionary = recipe.duplicate(false)
				packet_group["siteId"] = site_id
				packet_group["packetSourceId"] = packet_source_id
				packet_group["packetGeneration"] = int(packet_generation)
				packet_group["packetDigest"] = packet_digest
				packet_group["packetOwnerCell"] = expected_owner_cell
				packet_group["sourceToWorld"] = owner_result.sourceToWorld
				packet_group.make_read_only()
				packet_groups.append(packet_group)
			member_bindings[source_id] = member_binding
			var packet_source_ids: Array[String] = []
			for packet_source_value: Variant in expected_by_source.keys():
				packet_source_ids.append(String(packet_source_value))
			packet_source_ids.sort()
			packet_source_ids.make_read_only()
			var packet_receipts: Array[Dictionary] = []
			for packet_source_value: Variant in packet_source_ids:
				var packet_source_id := String(packet_source_value)
				var expected: Dictionary = expected_by_source.get(packet_source_id, {})
				var packet_receipt := {"packetSourceId":packet_source_id,
					"generation":int(expected.get("generation", 0)),
					"packetDigest":String(expected.get("packetDigest", "")),
					"ownerCell":expected.get("ownerCell")}
				packet_receipt.make_read_only()
				packet_receipts.append(packet_receipt)
			packet_receipts.make_read_only()
			var provider_receipt := {"siteId":site_id, "sourcePartId":part_id,
				"censusRevision":source_revision, "memberBinding":member_binding,
				"packetSourceIds":packet_source_ids, "packetReceipts":packet_receipts}
			provider_receipt.make_read_only()
			provider_receipts.append(provider_receipt)
	member_bindings.make_read_only()
	provider_receipts.make_read_only()
	var default_mesh: Mesh = null
	if not packet_groups.is_empty():
		default_mesh = packet_groups[0].get("mesh") as Mesh
	var candidate: Dictionary = SectionGeometryAdapter.capture_section(census,
		section_key, candidate_generation, packet_groups, member_bindings,
		Transform3D.IDENTITY, default_mesh)
	if candidate.get("status") != "ready":
		return candidate
	var impacted_sections: Array[Vector3i] = [section_key]
	impacted_sections.make_read_only()
	var snapshot_result: Dictionary = SectionSnapshotBuilder.build_replacements(
		candidate.get("partition", {}), candidate.get("compatibilityByKey", {}),
		impacted_sections, candidate_generation, world_id)
	if snapshot_result.get("status") != "ready":
		return {"status":"failed", "reason":"citadel_section_snapshot_build_failed",
			"detail":snapshot_result}
	var current_census: Dictionary = capture_static_section_sources(world_id, [section_key])
	if current_census.get("status") != "complete" \
			or current_census.get("authorityRevision") != census.get("authorityRevision") \
			or current_census.get("sourceRevisions") != census.get("sourceRevisions") \
			or current_census.get("sections", {}).get(section_key, {}) != census_row:
		return {"status":"pending", "reason":"citadel_section_candidate_stale_after_capture",
			"retryable":true}
	var sealed_member_ids: Array[String] = []
	for source_id_value: Variant in census_row.get("sourcePartIds", []):
		sealed_member_ids.append(String(source_id_value))
	sealed_member_ids.sort()
	sealed_member_ids.make_read_only()
	var sealed_section := {"status":String(census_row.get("status", "")),
		"coverageRevision":String(census_row.get("coverageRevision", "")),
		"sourcePartIds":sealed_member_ids}
	sealed_section.make_read_only()
	var sealed_sections := {section_key:sealed_section}
	sealed_sections.make_read_only()
	var sealed_source_revisions: Dictionary = census.get("sourceRevisions", {}).duplicate()
	sealed_source_revisions.make_read_only()
	var sealed_census := {"status":"complete", "worldId":world_id,
		"authorityRevision":String(census.get("authorityRevision", "")),
		"sourceRevisions":sealed_source_revisions, "sections":sealed_sections}
	sealed_census.make_read_only()
	var result := {"status":"ready", "schema":"citadel-section-geometry-candidate/v1",
		"worldId":world_id, "sectionKey":section_key,
		"candidateGeneration":candidate_generation,
		"authorityRevision":census.get("authorityRevision", ""),
		"coverageRevision":census_row.get("coverageRevision", ""),
		"sourceCensus":sealed_census, "memberBindings":member_bindings,
		"providerPacketReceipts":provider_receipts,
		"packetGroupCount":packet_groups.size(),
		"inputs":candidate.get("inputs", []),
		"partition":candidate.get("partition", {}),
		"compatibilityByKey":candidate.get("compatibilityByKey", {}),
		"resourceBindings":candidate.get("resourceBindings", {}),
		"members":candidate.get("members", []),
		"replacements":snapshot_result.get("replacements", []),
		"legacyVisualPolicy":"retain_until_shared_coordinator_native_receipt_acknowledged",
		"evidenceScope":"prepared Citadel packet groups transformed into shared section snapshots; no native install or gameplay retirement acknowledgement"}
	result.make_read_only()
	return result


## Adapts sealed BuildingPartPublisher transform artifacts to the common
## provider contribution boundary. This path does not require legacy packet
## expectations or receipts; geometry stays staged until the whole-section
## native receipt is acknowledged by acknowledge_section_install.
func capture_static_section_contribution(census: Dictionary,
		section_key: Vector3i, candidate_generation := 1) -> Dictionary:
	if census.get("status") != "complete" or String(census.get("worldId", "")).is_empty():
		return {"status":"pending", "reason":"citadel_contribution_census_unavailable",
			"retryable":true}
	var census_digest := String(census.get("censusDigest", ""))
	var capture_job: Dictionary = _section_contribution_capture_jobs.get(section_key, {})
	var transaction_matches := not capture_job.is_empty() \
		and int(capture_job.get("serviceGeneration", -1)) == _generation \
		and int(capture_job.get("candidateGeneration", -1)) == candidate_generation \
		and String(capture_job.get("worldId", "")) == String(census.get("worldId", "")) \
		and not census_digest.is_empty() \
		and String(capture_job.get("censusDigest", "")) == census_digest
	var current_before: Dictionary
	if transaction_matches:
		# The exact admitted census and its provider revision vector are pinned to
		# this contribution transaction. Captures remain staged; the complete live
		# provider/member fence below runs before any contribution is returned.
		current_before = {"status":"ready",
			"sourceIds":capture_job.get("sourceIds", []),
			"sourceRevisions":capture_job.get("sourceRevisions", {}),
			"authorityRevision":capture_job.get("authorityRevision", ""),
			"coverageRevision":capture_job.get("coverageRevision", "")}
	else:
		current_before = _current_transform_artifact_census(census, section_key)
		if current_before.get("status") != "ready":
			return current_before
	var expected_source_ids: Array[String] = current_before.get("sourceIds", [])
	if census_digest.is_empty():
		# The production roster supplies a sealed digest. Focused service fixtures
		# may supply a narrower immutable census, so bind their continuation to the
		# exact section, revision maps, and source closure instead of refusing it.
		census_digest = Marshalls.raw_to_base64(var_to_bytes([
			String(census.get("worldId", "")), section_key,
			String(current_before.get("authorityRevision", "")),
			String(current_before.get("coverageRevision", "")), expected_source_ids,
			census.get("sourceRevisions", {})])).sha256_text()
	if not capture_job.is_empty():
		var same_inputs: bool = int(capture_job.get("serviceGeneration", -1)) == _generation \
			and int(capture_job.get("candidateGeneration", -1)) == candidate_generation \
			and String(capture_job.get("worldId", "")) == String(census.get("worldId", "")) \
			and capture_job.get("sourceIds", []) == expected_source_ids \
			and capture_job.get("sourceRevisions", {}) == current_before.get("sourceRevisions", {}) \
			and String(capture_job.get("authorityRevision", "")) \
				== String(current_before.get("authorityRevision", "")) \
			and String(capture_job.get("coverageRevision", "")) \
				== String(current_before.get("coverageRevision", ""))
		if not same_inputs:
			_section_contribution_capture_jobs.erase(section_key)
			return {"status":"pending", "reason":"citadel_contribution_capture_inputs_stale",
				"retryable":true, "sectionKey":section_key}
		# Other required providers may advance while this source cursor is pending.
		# Their new census is used for final assembly; the retained Citadel values
		# remain reusable only while this exact Citadel source closure stays current.
		capture_job["censusDigest"] = census_digest
	else:
		_prune_section_contribution_capture_jobs(section_key)
		capture_job = {"serviceGeneration":_generation,
			"candidateGeneration":candidate_generation,
			"worldId":String(census.get("worldId", "")),
			"sectionKey":section_key, "censusDigest":census_digest,
			"authorityRevision":String(current_before.get("authorityRevision", "")),
			"coverageRevision":String(current_before.get("coverageRevision", "")),
			"sourceIds":expected_source_ids.duplicate(),
			"sourceRevisions":current_before.get("sourceRevisions", {}),
			"nextSourceIndex":0, "capturesBySource":{},
			"memberBindings":{}, "ownerProofs":{},
			"sourceArtifactCacheHitCount":0, "sourceLookupUsec":0,
			"coldCaptureUsec":0, "maxSourceCaptureUsec":0,
			"adapterUsec":0, "finalValidationUsec":0}
		_section_contribution_capture_jobs[section_key] = capture_job
	capture_job["lastAdvanceFrame"] = Engine.get_process_frames()
	_section_contribution_capture_jobs[section_key] = capture_job
	var captures_by_source: Dictionary = capture_job.get("capturesBySource", {})
	var member_bindings: Dictionary = capture_job.get("memberBindings", {})
	var owner_proofs: Dictionary = capture_job.get("ownerProofs", {})
	var next_source_index := int(capture_job.get("nextSourceIndex", 0))
	for source_index in range(next_source_index, expected_source_ids.size()):
		var source_id := expected_source_ids[source_index]
		var site_id := SectionGeometryAdapter._site_id_from_census_source(source_id)
		var member_id := SectionGeometryAdapter._member_id_from_census_source(source_id)
		if not site_id.is_empty() and member_id.begins_with("tree:"):
			var tree_authority := _current_tree_member_artifact_authority(site_id, member_id)
			if tree_authority.get("status") != "ready": return tree_authority
			captures_by_source[source_id] = tree_authority.capture
			member_bindings[source_id] = tree_authority.memberBinding
			owner_proofs[source_id] = {"kind":"tree", "siteId":site_id,
				"memberId":member_id, "authorityRevision":tree_authority.artifactAuthorityRevision,
				"job":weakref(tree_authority.job), "jobInstanceId":tree_authority.job.get_instance_id(),
				"binding":tree_authority.binding}
			capture_job["nextSourceIndex"] = source_index + 1
			capture_job["capturesBySource"] = captures_by_source
			capture_job["memberBindings"] = member_bindings
			capture_job["ownerProofs"] = owner_proofs
			_section_contribution_capture_jobs[section_key] = capture_job
			break
		if site_id.is_empty() or not _is_transform_member(member_id):
			return {"status":"pending", "reason":"citadel_transform_artifact_member_kind_unsupported",
				"sourceId":source_id, "memberId":member_id, "retryable":true}
		var part_id := _transform_part_id(member_id)
		var owner_result := _current_transform_artifact_publisher_for_member(site_id, member_id)
		if owner_result.get("status") != "ready":
			owner_result["sourceId"] = source_id
			return owner_result
		var publisher = owner_result.publisher
		_restore_stale_citadel_visuals(publisher, site_id, member_id)
		var member_binding := _expected_visual_source_revision(owner_result, part_id)
		if member_binding.is_empty():
			return {"status":"pending", "reason":"citadel_transform_artifact_member_binding_unavailable",
				"sourceId":source_id, "sourcePartId":part_id, "retryable":true}
		var source_capture_started := Time.get_ticks_usec()
		var capture: Dictionary = _cached_transform_artifact_capture(
			source_id, member_id, part_id, member_binding, owner_result)
		capture_job["sourceLookupUsec"] = int(capture_job.get("sourceLookupUsec", 0)) \
			+ Time.get_ticks_usec() - source_capture_started
		if capture.is_empty():
			var cold_capture_started := Time.get_ticks_usec()
			capture = publisher.capture_committed_static_visual_source(
				part_id, member_binding)
			capture_job["coldCaptureUsec"] = int(capture_job.get("coldCaptureUsec", 0)) \
				+ Time.get_ticks_usec() - cold_capture_started
		else:
			capture_job["sourceArtifactCacheHitCount"] = int(
				capture_job.get("sourceArtifactCacheHitCount", 0)) + 1
		if capture.get("status") != "ready":
			capture["sourceId"] = source_id
			return capture
		for group_value: Variant in capture.get("groups", []):
			if not group_value is Dictionary \
					or group_value.get("sourceToWorld") != owner_result.sourceToWorld:
				return {"status":"pending", "reason":"citadel_transform_artifact_owner_transform_moved",
					"sourceId":source_id, "retryable":true}
		captures_by_source[source_id] = capture
		capture_job["maxSourceCaptureUsec"] = maxi(
			int(capture_job.get("maxSourceCaptureUsec", 0)),
			Time.get_ticks_usec() - source_capture_started)
		member_bindings[source_id] = member_binding
		owner_proofs[source_id] = {"siteId":site_id, "partId":part_id, "memberId":member_id,
			"publisher":publisher, "binding":owner_result.binding,
			"sceneJobInstanceId":owner_result.get("sceneJobInstanceId", 0),
			"memberBinding":member_binding, "sourceToWorld":owner_result.sourceToWorld}
		capture_job["nextSourceIndex"] = source_index + 1
		capture_job["capturesBySource"] = captures_by_source
		capture_job["memberBindings"] = member_bindings
		capture_job["ownerProofs"] = owner_proofs
		_section_contribution_capture_jobs[section_key] = capture_job
		break
	if int(capture_job.get("nextSourceIndex", 0)) < expected_source_ids.size():
		var continuation := {"schema":"static-section-provider-continuation/v1",
			"providerId":"blueprint_buildings", "sectionKey":section_key,
			"censusDigest":census_digest,
			"candidateGeneration":candidate_generation,
			"sourceCursor":int(capture_job.get("nextSourceIndex", 0))}
		continuation.make_read_only()
		return {"status":"pending", "reason":"citadel_section_contribution_slice_pending",
			"retryable":true, "continuationHint":continuation,
			"sectionKey":section_key,
			"completedSourceCount":int(capture_job.get("nextSourceIndex", 0)),
			"requiredSourceCount":expected_source_ids.size(),
			"sourceArtifactCacheHitCount":int(capture_job.get("sourceArtifactCacheHitCount", 0)),
			"sourceLookupUsec":int(capture_job.get("sourceLookupUsec", 0)),
			"coldCaptureUsec":int(capture_job.get("coldCaptureUsec", 0)),
			"maxSourceCaptureUsec":int(capture_job.get("maxSourceCaptureUsec", 0))}

	var needs_translucent_pov := false
	for source_capture: Dictionary in captures_by_source.values():
		for group: Dictionary in source_capture.get("groups", []):
			if group.get("renderLayer") == "translucent": needs_translucent_pov = true
	var pov_snapshot: Dictionary = {}
	var pov_owner: Variant = _geometry_completion_owner.get_ref() if _geometry_completion_owner != null else null
	if needs_translucent_pov:
		if not is_instance_valid(pov_owner) or not pov_owner.has_method("current_translucent_pov_snapshot"):
			return {"status":"pending", "reason":"citadel_translucent_pov_owner_unavailable", "retryable":true}
		pov_snapshot = pov_owner.call("current_translucent_pov_snapshot", section_key)
		if pov_snapshot.get("status") != "ready": return pov_snapshot
	var adapter_started := Time.get_ticks_usec()
	var adapter_result: Dictionary = SectionGeometryAdapter.capture_transform_artifact_contribution(
		census, section_key, candidate_generation, captures_by_source, member_bindings, pov_snapshot)
	capture_job["adapterUsec"] = Time.get_ticks_usec() - adapter_started
	if adapter_result.get("status") != "ready":
		return adapter_result
	if needs_translucent_pov:
		var current_pov: Dictionary = pov_owner.call("current_translucent_pov_snapshot", section_key)
		if current_pov.get("status") != "ready" or current_pov.get("revision") != pov_snapshot.get("revision"):
			return {"status":"pending", "reason":"citadel_translucent_pov_changed_during_capture", "retryable":true}
	var validation_started := Time.get_ticks_usec()
	var current_after := _current_transform_artifact_census(census, section_key)
	if current_after.get("status") != "ready":
		return current_after
	if current_after.get("sourceIds", []) != current_before.get("sourceIds", []) \
			or String(current_after.get("authorityRevision", "")) \
			!= String(current_before.get("authorityRevision", "")) \
			or String(current_after.get("coverageRevision", "")) \
			!= String(current_before.get("coverageRevision", "")) \
			or current_after.get("sourceRevisions", {}) \
			!= current_before.get("sourceRevisions", {}):
		return {"status":"pending", "reason":"citadel_transform_artifact_census_changed_during_capture",
			"retryable":true}
	for source_id: String in expected_source_ids:
		var proof: Dictionary = owner_proofs.get(source_id, {})
		if proof.get("kind") == "tree":
			var tree_after := _current_tree_member_artifact_authority(String(proof.siteId), String(proof.memberId))
			if tree_after.get("status") != "ready": return tree_after
			if tree_after.artifactAuthorityRevision != proof.authorityRevision \
					or tree_after.job.get_instance_id() != proof.jobInstanceId \
					or tree_after.binding != proof.binding:
				return {"status":"pending", "reason":"citadel_tree_source_changed_during_capture", "retryable":true}
			var complete_members: Array = adapter_result.get("geometryOwnerMembersBySource", {}).get(source_id, [])
			var revision := String(complete_members[0].get("sourceRevision", "")) if not complete_members.is_empty() else ""
			var incarnation := str(proof.jobInstanceId) + ":" + _citadel_owner_binding_digest(proof.binding) \
				+ ":" + str(tree_after.capture.producer.bodyInstanceId)
			var sealed := OwnerCompletion.seal(String(census.worldId), source_id, source_id,
				revision, incarnation, complete_members)
			if sealed.get("status") != "ready": return sealed
			var support_bounds: Array[AABB] = []
			for member: Dictionary in tree_after.capture.producer.sourceManifest.get("geometryOwnership", []):
				var bounds: Variant = member.get("conservativeWorldBounds")
				if not bounds is AABB or not bounds.position.is_finite() or not bounds.size.is_finite():
					return {"status":"failed", "reason":"citadel_tree_support_bounds_invalid"}
				if bounds not in support_bounds: support_bounds.append(bounds)
			proof["supportBounds"] = support_bounds
			_retain_geometry_owner_roster(source_id, sealed.roster, proof)
			continue
		var owner_after := _current_transform_artifact_publisher_for_member(
			String(proof.get("siteId", "")), _proof_transform_member(proof))
		if owner_after.get("status") != "ready" \
				or owner_after.get("publisher") != proof.get("publisher") \
				or owner_after.get("sceneJobInstanceId", 0) != proof.get("sceneJobInstanceId", 0) \
				or owner_after.get("binding", {}) != proof.get("binding", {}) \
				or owner_after.get("sourceToWorld") != proof.get("sourceToWorld"):
			return {"status":"pending", "reason":"citadel_transform_artifact_owner_changed_during_capture",
				"sourceId":source_id, "retryable":true}
		var publisher = owner_after.publisher
		if _expected_visual_source_revision(owner_after, String(proof.partId)) != String(proof.memberBinding):
			return {"status":"pending", "reason":"citadel_transform_artifact_member_binding_changed",
				"sourceId":source_id, "retryable":true}
		# capture_committed_static_visual_source already brackets its immutable
		# geometry snapshot with exact publication-boundary identities. Rebuilding
		# the full mesh/segment snapshot here duplicated the most expensive work for
		# every source in the section. Recheck the cheap boundary token instead;
		# candidate installation and provider acknowledgement revalidate revisions
		# after this worker input has been admitted.
		var capture: Dictionary = captures_by_source.get(source_id, {})
		var captured_identity: Dictionary = capture.get("visualSourceReceipt", {})
		if not publisher.has_method("committed_static_visual_source_identity"):
			return {"status":"pending", "reason":"citadel_transform_artifact_identity_api_unavailable",
				"sourceId":source_id, "retryable":true}
		var identity_after: Dictionary = publisher.call(
			"committed_static_visual_source_identity", String(proof.partId))
		if identity_after.get("status") != "ready":
			identity_after["sourceId"] = source_id
			return identity_after
		if captured_identity.is_empty() or identity_after != captured_identity:
			return {"status":"pending", "reason":"citadel_transform_artifact_content_changed_during_capture",
				"sourceId":source_id, "retryable":true}
		var complete_members: Array = adapter_result.get("geometryOwnerMembersBySource", {}).get(source_id, [])
		var presentation_members: Array = adapter_result.get("presentationOwnerMembersBySource", {}).get(source_id, [])
		var revision := String(complete_members[0].get("sourceRevision", "")) if not complete_members.is_empty() \
			else String(presentation_members[0].get("sourceRevision", "")) if not presentation_members.is_empty() else ""
		var incarnation := str(publisher.get_instance_id()) + ":" + _citadel_owner_binding_digest(proof.binding)
		if int(proof.get("sceneJobInstanceId", 0)) != 0: incarnation += ":job:" + str(proof.sceneJobInstanceId)
		var sealed := {"status":"ready", "roster":{}}
		if not complete_members.is_empty():
			sealed = OwnerCompletion.seal(String(census.worldId), source_id, source_id, revision, incarnation, complete_members)
			if sealed.get("status") != "ready": return sealed
		elif presentation_members.is_empty():
			return {"status":"pending", "reason":"citadel_complete_source_roster_unavailable"}
		var current_plan = _publication_plan_for_binding(proof.binding)
		if current_plan == null: return {"status":"pending", "reason":"citadel_presentation_plan_unavailable"}
		var retained_proof := {"publisher":weakref(publisher), "publisherId":publisher.get_instance_id(),
			"sceneJobInstanceId":proof.get("sceneJobInstanceId", 0),
			"siteId":proof.siteId, "partId":proof.partId, "memberId":_proof_transform_member(proof), "binding":proof.binding,
			"memberBinding":proof.memberBinding, "sourceToWorld":proof.sourceToWorld,
		"visualSourceReceipt":captured_identity,
		"artifactCapture":capture,
		"artifactGroups":capture.get("groups", []),
		"captureIdentity":_geometry_capture_identity(capture),
			"worldId":String(census.worldId), "sourceRevision":revision, "sourceIncarnation":incarnation,
			"presentationMembers":presentation_members, "planSignature":String(current_plan.output_signature)}
		_retain_geometry_owner_roster(source_id, sealed.roster, retained_proof)
	capture_job["finalValidationUsec"] = Time.get_ticks_usec() - validation_started
	_section_contribution_capture_jobs.erase(section_key)
	var completed_result := adapter_result.duplicate(false)
	completed_result["sourceArtifactCacheHitCount"] = int(
		capture_job.get("sourceArtifactCacheHitCount", 0))
	completed_result["sourceLookupUsec"] = int(capture_job.get("sourceLookupUsec", 0))
	completed_result["coldCaptureUsec"] = int(capture_job.get("coldCaptureUsec", 0))
	completed_result["maxSourceCaptureUsec"] = int(capture_job.get("maxSourceCaptureUsec", 0))
	completed_result["adapterUsec"] = int(capture_job.get("adapterUsec", 0))
	completed_result["finalValidationUsec"] = int(capture_job.get("finalValidationUsec", 0))
	completed_result.make_read_only()
	return completed_result


## Reuse the producer's immutable transform-artifact roster across sections
## only while the exact publisher, source boundary, mesh receipt and material
## fingerprints remain current. Presentation mounts retain their existing
## full capture path because their freshness contract is separate.
func _cached_transform_artifact_capture(source_id: String, member_id: String,
		part_id: String, member_binding: String, owner_result: Dictionary) -> Dictionary:
	var publisher: Variant = owner_result.get("publisher")
	if not is_instance_valid(publisher): return {}
	var publisher_id: int = publisher.get_instance_id()
	var scene_job_instance_id := int(owner_result.get("sceneJobInstanceId", 0))
	var cache_key := _transform_artifact_capture_cache_key(publisher_id,
		scene_job_instance_id, part_id, member_binding)
	var cached: Dictionary = _retained_transform_artifact_captures.get(cache_key, {})
	var reference: Variant = cached.get("publisher", null)
	var cached_publisher: Variant = reference.get_ref() if reference is WeakRef else null
	if not is_instance_valid(cached_publisher) or cached_publisher != publisher \
			or cached_publisher.get_instance_id() != int(cached.get("publisherId", 0)) \
			or cached.get("memberId", "") != member_id \
			or cached.get("binding", {}) != owner_result.get("binding", {}) \
			or int(cached.get("sceneJobInstanceId", 0)) != scene_job_instance_id \
			or cached.get("memberBinding", "") != member_binding \
			or cached.get("sourceToWorld") != owner_result.get("sourceToWorld"):
		return {}
	var capture: Dictionary = cached.get("capture", {})
	var groups: Variant = capture.get("groups", null)
	if capture.get("status") != "ready" or not groups is Array \
			or not capture.get("presentationMounts", []).is_empty() \
			or not capture.get("presentationBindings", {}).is_empty():
		return {}
	if not cached_publisher.has_method("committed_static_visual_source_identity") \
			or not cached_publisher.has_method("static_section_transform_artifact_receipt_is_current"):
		return {}
	var current_identity: Dictionary = cached_publisher.call(
		"committed_static_visual_source_identity", part_id)
	if current_identity.get("status") != "ready" \
			or current_identity != cached.get("visualSourceReceipt", {}) \
			or current_identity != capture.get("visualSourceReceipt", {}) \
			or current_identity.get("sourceRevision", "") != member_binding \
			or current_identity.get("sourceToWorld") != owner_result.get("sourceToWorld"):
		return {}
	if not bool(cached_publisher.call(
			"static_section_transform_artifact_receipt_is_current",
			part_id, member_binding, groups)):
		return {}
	cached["lastUseFrame"] = Engine.get_process_frames()
	_retained_transform_artifact_captures[cache_key] = cached
	return capture


static func _transform_artifact_capture_cache_key(publisher_id: int,
		scene_job_instance_id: int, part_id: String, member_binding: String) -> String:
	return var_to_str([publisher_id, scene_job_instance_id, part_id, member_binding])


## Partial source captures are private producer inputs. Expire abandoned work and
## bound retained mesh/material aliases when the camera has moved on.
func _prune_section_contribution_capture_jobs(except_section: Vector3i) -> void:
	var current_frame := Engine.get_process_frames()
	for section_value: Variant in _section_contribution_capture_jobs.keys():
		if not section_value is Vector3i or section_value == except_section:
			continue
		var job: Dictionary = _section_contribution_capture_jobs.get(section_value, {})
		if current_frame - int(job.get("lastAdvanceFrame", current_frame)) \
				> SECTION_CONTRIBUTION_CAPTURE_IDLE_FRAMES:
			_section_contribution_capture_jobs.erase(section_value)
	while _section_contribution_capture_jobs.size() >= MAX_SECTION_CONTRIBUTION_CAPTURE_JOBS:
		var oldest_section: Variant = null
		var oldest_frame := current_frame
		for section_value: Variant in _section_contribution_capture_jobs:
			if section_value == except_section:
				continue
			var job: Dictionary = _section_contribution_capture_jobs[section_value]
			var touched := int(job.get("lastAdvanceFrame", -1))
			if oldest_section == null or touched < oldest_frame:
				oldest_section = section_value
				oldest_frame = touched
		if oldest_section == null:
			break
		_section_contribution_capture_jobs.erase(oldest_section)


func _current_transform_artifact_census(census: Dictionary,
		section_key: Vector3i) -> Dictionary:
	var world_id := String(census.get("worldId", ""))
	var source_ids: Array[String] = []
	var shared_revisions_by_source_id: Dictionary = {}
	var expected_by_section: Variant = census.get("expectedContributorsBySection", null)
	var source_provider_ids: Variant = census.get("sourceProviderIds", null)
	var source_revisions_value: Variant = census.get("sourceRevisions", null)
	var source_identities_value: Variant = census.get("sourceIdentities", null)
	var provider_snapshot_revisions: Variant = census.get("providerSnapshotRevisions", null)
	var provider_coverage_revisions: Variant = census.get("providerCoverageRevisions", null)
	var expected_value: Variant = expected_by_section.get(section_key, null) \
		if expected_by_section is Dictionary else null
	if world_id.is_empty() or not expected_value is Array \
			or not source_provider_ids is Dictionary \
			or not source_revisions_value is Dictionary \
			or not source_identities_value is Dictionary \
			or not provider_snapshot_revisions is Dictionary \
			or not provider_coverage_revisions is Dictionary:
		return {"status":"pending", "reason":"citadel_transform_artifact_roster_unavailable",
			"retryable":true}
	if not census.is_read_only() or not expected_by_section.is_read_only() \
			or not expected_value.is_read_only() or not source_provider_ids.is_read_only() \
			or not source_revisions_value.is_read_only() \
			or not source_identities_value.is_read_only() \
			or not provider_snapshot_revisions.is_read_only() \
			or not provider_coverage_revisions.is_read_only():
		return {"status":"pending", "reason":"citadel_transform_artifact_roster_unsealed",
			"retryable":true}
	for source_value: Variant in expected_value:
		if not source_value is String:
			return {"status":"failed", "reason":"citadel_transform_artifact_source_id_invalid"}
		var identity_key := String(source_value)
		var identity_value: Variant = source_identities_value.get(identity_key, null)
		if not identity_value is Dictionary or not identity_value.is_read_only():
			return {"status":"pending", "reason":"citadel_transform_artifact_identity_missing",
				"retryable":true}
		var source_id := String(identity_value.get("sourceId", ""))
		var source_part_id := String(identity_value.get("sourcePartId", ""))
		if source_id.is_empty() or source_part_id.is_empty() \
				or _static_source_identity_key(source_id, source_part_id) != identity_key:
			return {"status":"pending", "reason":"citadel_transform_artifact_identity_mismatch",
				"retryable":true}
		if String(source_provider_ids.get(identity_key, "")) == "blueprint_buildings":
			if shared_revisions_by_source_id.has(source_id):
				return {"status":"pending",
					"reason":"citadel_transform_artifact_source_identity_ambiguous",
					"retryable":true}
			source_ids.append(source_id)
			shared_revisions_by_source_id[source_id] = String(
				source_revisions_value.get(identity_key, ""))
	source_ids.sort()
	var current := capture_static_section_sources(world_id, [section_key])
	if current.get("status") != "complete":
		return current
	var shared_provider_revision := String(provider_snapshot_revisions.get(
		"blueprint_buildings", ""))
	if shared_provider_revision.is_empty() \
			or shared_provider_revision != String(current.get("authorityRevision", "")):
		return {"status":"pending", "reason":"citadel_transform_artifact_provider_revision_stale",
			"retryable":true}
	var current_row: Dictionary = current.get("sections", {}).get(section_key, {})
	if current_row.is_empty():
		return {"status":"pending", "reason":"citadel_transform_artifact_current_section_missing",
			"retryable":true}
	var current_source_ids: Array[String] = []
	for source_value: Variant in current_row.get("sourcePartIds", []):
		current_source_ids.append(String(source_value))
	current_source_ids.sort()
	if current_source_ids != source_ids:
		return {"status":"pending", "reason":"citadel_transform_artifact_source_roster_stale",
			"expectedSourceIds":source_ids, "currentSourceIds":current_source_ids,
			"retryable":true}
	var shared_coverage_map: Variant = provider_coverage_revisions.get(
		"blueprint_buildings", {})
	if not shared_coverage_map is Dictionary or not shared_coverage_map.is_read_only():
		return {"status":"pending", "reason":"citadel_transform_artifact_coverage_unsealed",
			"retryable":true}
	var shared_coverage := String(shared_coverage_map.get(section_key, "")) \
		if shared_coverage_map is Dictionary else ""
	if shared_coverage.is_empty() \
			or shared_coverage != String(current_row.get("coverageRevision", "")):
		return {"status":"pending", "reason":"citadel_transform_artifact_coverage_stale",
			"retryable":true}
	var current_revisions: Dictionary = current.get("sourceRevisions", {})
	for source_id: String in source_ids:
		var revision := String(shared_revisions_by_source_id.get(source_id, ""))
		if revision.is_empty() or revision != String(current_revisions.get(source_id, "")):
			return {"status":"pending", "reason":"citadel_transform_artifact_source_revision_stale",
				"sourceId":source_id, "retryable":true}
	return {"status":"ready", "sourceIds":source_ids,
		"authorityRevision":String(current.get("authorityRevision", "")),
		"coverageRevision":String(current_row.get("coverageRevision", "")),
		"sourceRevisions":shared_revisions_by_source_id}


static func _static_source_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


static func _is_transform_member(member_id: String) -> bool:
	return member_id.begins_with("building:") or member_id.begins_with("furnishing:")


static func _transform_part_id(member_id: String) -> String:
	return member_id.trim_prefix("furnishing:") if member_id.begins_with("furnishing:") else member_id.trim_prefix("building:")


static func _proof_transform_member(proof: Dictionary) -> String:
	return String(proof.get("memberId", "building:" + String(proof.get("partId", ""))))


static func _visual_member_id(visual: GeometryInstance3D) -> String:
	return String(visual.get_meta("section_source_member_id", "building:" + String(visual.get_meta("building_source_part_id", ""))))


func _current_transform_artifact_publisher_for_member(site_id: String, member_id: String) -> Dictionary:
	var owner := _current_transform_artifact_publisher_for_site(site_id)
	if owner.get("status") != "ready" or not member_id.begins_with("furnishing:"): return owner
	var job: Variant = _scenes.get(owner.region, {}).get("job")
	if not is_instance_valid(job) or not job.has_method("furnishing_section_publisher"):
		return {"status":"pending", "reason":"citadel_furnishing_scene_owner_unavailable", "retryable":true}
	var result: Dictionary = job.furnishing_section_publisher(member_id, owner.binding)
	if result.get("status") != "ready": return result
	job.bind_furnishing_section_owner(self)
	result.publisher.bind_section_lifetime_owner(self)
	var value := owner.duplicate(false)
	value["publisher"] = result.publisher
	value["memberKind"] = "furnishing"
	value["sceneJobInstanceId"] = result.jobInstanceId
	return value


func furnishing_publisher_has_retained_sources(publisher_instance_id: int) -> bool:
	for proof: Dictionary in _geometry_owner_capture_proofs.values():
		if int(proof.get("publisherId", 0)) == publisher_instance_id:
			return true
	return false


func furnishing_section_visual_installed(site_id: String, member_id: String, body: Node3D) -> bool:
	if not is_instance_valid(body) or not member_id.begins_with("furnishing:"): return false
	var source_id := _citadel_census_source_id(site_id, member_id)
	var proof: Dictionary = _geometry_owner_capture_proofs.get(source_id, {})
	var roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
	if proof.is_empty() or roster.is_empty(): return false
	var owner := _current_transform_artifact_publisher_for_member(site_id, member_id)
	if owner.get("status") != "ready" \
			or not _publisher_node_roster_snapshot(owner.publisher).has(body): return false
	if _geometry_owner_roster_is_current(source_id, roster, {}).get("status") != "ready": return false
	var coordinator: Variant = _geometry_completion_owner.get_ref() if _geometry_completion_owner != null else null
	if not is_instance_valid(coordinator): return false
	# This legacy bool query is not called by a production publisher today. Keep
	# its full live-source currentness guard until that caller has a resumable
	# owner-currentness token; advancing only native receipts here could bless a
	# stale producer transform between calls.
	var completion: Dictionary = coordinator.call("validate_geometry_owner_completion",
		roster, _geometry_owner_prior_rosters.get(source_id, []))
	return completion.get("status") == "ready" and _validate_citadel_presentation_completion(source_id).get("status") == "ready"


func _current_transform_artifact_publisher_for_site(site_id: String) -> Dictionary:
	if site_id.is_empty() or _closing or _world_reset_pending or _admission == null:
		return {"status":"pending", "reason":"citadel_transform_artifact_owner_unavailable",
			"siteId":site_id, "retryable":true}
	var match_region := Vector2i.ZERO
	var match_entry: Dictionary = {}
	for region: Vector2i in _scenes:
		var entry: Dictionary = _scenes[region]
		if String(entry.get("binding", {}).get("siteId", "")) != site_id:
			continue
		if not match_entry.is_empty():
			return {"status":"pending", "reason":"citadel_site_has_multiple_scene_owners",
				"siteId":site_id, "retryable":true}
		match_region = region
		match_entry = entry
	if match_entry.is_empty():
		return {"status":"pending", "reason":"citadel_transform_artifact_scene_owner_unavailable",
			"siteId":site_id, "retryable":true}
	if match_entry.get("phase") != "scene_ready":
		return {"status":"pending", "reason":"citadel_transform_artifact_scene_not_ready",
			"siteId":site_id, "phase":match_entry.get("phase"), "retryable":true}
	var current: Dictionary = _admission.source_state(match_region)
	if current.get("status") not in ["ready", "prepared"] \
			or current.get("binding", {}) != match_entry.get("binding", {}):
		return {"status":"pending", "reason":"citadel_transform_artifact_scene_binding_stale",
			"siteId":site_id, "retryable":true}
	var job = match_entry.get("job")
	var publisher = job.get("_building") if job != null else null
	if publisher == null or not is_instance_valid(publisher) \
			or String(publisher.get("publication_site_id")) != site_id:
		return {"status":"pending", "reason":"citadel_transform_artifact_publisher_unavailable",
			"siteId":site_id, "retryable":true}
	if publisher.has_pending_static_flush():
		return {"status":"pending", "reason":"citadel_transform_artifact_flush_pending",
			"siteId":site_id, "retryable":true}
	var profile = match_entry.get("profile")
	if profile == null or not profile.get("origin") is Vector3 \
			or not profile.origin.is_finite():
		return {"status":"pending", "reason":"citadel_transform_artifact_root_transform_unavailable",
			"siteId":site_id, "retryable":true}
	var source_parent_ref: Variant = publisher.get("_scene_parent")
	if not source_parent_ref is WeakRef:
		return {"status":"pending", "reason":"citadel_transform_artifact_source_parent_unavailable",
			"siteId":site_id, "retryable":true}
	var source_parent := source_parent_ref.get_ref() as Node3D
	if not is_instance_valid(source_parent) or not source_parent.is_inside_tree() \
			or source_parent.is_queued_for_deletion():
		return {"status":"pending", "reason":"citadel_transform_artifact_source_parent_stale",
			"siteId":site_id, "retryable":true}
	var source_to_world := source_parent.global_transform
	if not source_to_world.origin.is_finite() \
			or not source_to_world.basis.x.is_finite() \
			or not source_to_world.basis.y.is_finite() \
			or not source_to_world.basis.z.is_finite():
		return {"status":"pending", "reason":"citadel_transform_artifact_source_transform_invalid",
			"siteId":site_id, "retryable":true}
	return {"status":"ready", "publisher":publisher, "region":match_region,
		"binding":match_entry.binding,
		"sourceToWorld":source_to_world}


## Called by the world coordinator only after a whole-section native receipt is
## live. A source visual may span more than one render section, so retain it
## until every intersected section has a current receipt for this same member
## revision. Gameplay collision, doors, furnishings, and navigation stay owned
## by the building publisher.
func acknowledge_section_install(section_key: Vector3i,
		coverage_revision: String, receipt: Dictionary = {}) -> Dictionary:
	if _admission == null or _closing or _world_reset_pending \
			or coverage_revision.strip_edges().is_empty():
		return {"status":"pending", "reason":"citadel_section_acknowledgement_unavailable",
			"retryable":true}
	var current: Dictionary = capture_static_section_sources(
		String(receipt.get("worldId", "")), [section_key])
	return acknowledge_section_install_with_census(section_key,
		coverage_revision, receipt, current)


## Retry path receives the coordinator's already recaptured current census. The
## coordinator compares its digest with the candidate before dispatching ACK,
## so repeating the same expensive Citadel census here adds no freshness proof.
func acknowledge_section_install_with_census(section_key: Vector3i,
		coverage_revision: String, receipt: Dictionary,
		current: Dictionary) -> Dictionary:
	if _admission == null or _closing or _world_reset_pending \
			or coverage_revision.strip_edges().is_empty():
		return {"status":"pending", "reason":"citadel_section_acknowledgement_unavailable",
			"retryable":true}
	_section_ack_phase_diagnostics = {"phaseUsec":{}, "counts":{}}
	var previous_currentness_scope := _section_ack_currentness_scope
	_section_ack_currentness_scope = {"current":current,
		"sectionKey":section_key, "generation":_generation}
	var result := _acknowledge_section_install_from_census_impl(section_key,
		coverage_revision, receipt, current)
	if result.is_read_only(): result = result.duplicate(false)
	result["ackDiagnostics"] = _section_ack_phase_diagnostics.duplicate(true)
	_section_ack_phase_diagnostics = {}
	_section_ack_currentness_scope = previous_currentness_scope
	return result


func _record_section_ack_phase(name: String, started_usec: int,
		count_name := "", count := 0) -> void:
	if _section_ack_phase_diagnostics.is_empty(): return
	var phases: Dictionary = _section_ack_phase_diagnostics.get("phaseUsec", {})
	phases[name] = int(phases.get(name, 0)) + Time.get_ticks_usec() - started_usec
	_section_ack_phase_diagnostics["phaseUsec"] = phases
	if not count_name.is_empty():
		var counts: Dictionary = _section_ack_phase_diagnostics.get("counts", {})
		counts[count_name] = int(counts.get(count_name, 0)) + count
		_section_ack_phase_diagnostics["counts"] = counts


func _count_section_ack_work(name: String, count := 1) -> void:
	if _section_ack_phase_diagnostics.is_empty(): return
	var counts: Dictionary = _section_ack_phase_diagnostics.get("counts", {})
	counts[name] = int(counts.get(name, 0)) + count
	_section_ack_phase_diagnostics["counts"] = counts


func _acknowledge_section_install_from_census_impl(section_key: Vector3i,
		coverage_revision: String, receipt: Dictionary,
		current: Dictionary) -> Dictionary:
	if current.get("status") != "complete":
		return {"status":"pending", "reason":String(current.get("reason",
			"citadel_section_acknowledgement_census_pending")), "retryable":true}
	var world_id := String(current.get("worldId", ""))
	var row: Dictionary = current.get("sections", {}).get(section_key, {})
	if world_id.is_empty() or row.is_empty() \
			or String(row.get("coverageRevision", "")) != coverage_revision:
		return {"status":"pending", "reason":"citadel_section_acknowledgement_coverage_stale",
			"retryable":true, "sectionKey":section_key}
	var source_revisions: Dictionary = {}
	var current_source_revisions: Dictionary = current.get("sourceRevisions", {})
	for source_id_value: Variant in row.get("sourcePartIds", []):
		var source_id := String(source_id_value)
		var revision := String(current_source_revisions.get(source_id, ""))
		if source_id.is_empty() or revision.is_empty():
			return {"status":"pending", "reason":"citadel_section_acknowledgement_source_revision_missing",
				"retryable":true, "sourceId":source_id}
		source_revisions[source_id] = revision
	var removal_records_by_id: Dictionary = {}
	var removal_revisions: Dictionary = {}
	var raw_removals: Variant = current.get("removalsBySection", {}).get(section_key, [])
	if not raw_removals is Array:
		return {"status":"pending", "reason":"citadel_section_removal_inventory_unavailable",
			"retryable":true, "sectionKey":section_key}
	for removal_value: Variant in raw_removals:
		if not removal_value is Dictionary:
			return {"status":"pending", "reason":"citadel_section_removal_record_invalid",
				"retryable":true, "sectionKey":section_key}
		var removal: Dictionary = removal_value
		var removed_source_id := String(removal.get("sourceId", ""))
		var removed_part_id := String(removal.get("sourcePartId", ""))
		var removed_revision := String(removal.get("sourceRevision", ""))
		if removed_source_id.is_empty() or removed_part_id != removed_source_id \
				or removed_revision.length() != 64 or removal.get("sectionKey") != section_key \
				or source_revisions.has(removed_source_id) \
				or removal_records_by_id.has(removed_source_id):
			return {"status":"pending", "reason":"citadel_section_removal_record_invalid",
				"retryable":true, "sectionKey":section_key,
				"sourceId":removed_source_id}
		removal_records_by_id[removed_source_id] = removal
		removal_revisions[removed_source_id] = removed_revision
	removal_revisions.make_read_only()
	if not _valid_citadel_section_receipt(world_id, section_key,
			String(current.get("authorityRevision", "")), coverage_revision, receipt):
		return {"status":"pending", "reason":"citadel_section_acknowledgement_receipt_stale",
			"retryable":true, "sectionKey":section_key}
	source_revisions.make_read_only()
	var visual_results: Array[Dictionary] = []
	var publisher_by_source: Dictionary = {}
	var publisher_sources: Dictionary = {}
	var visuals_by_publisher: Dictionary = {}
	var section_source_ids: Dictionary = {}
	for section_source_value: Variant in row.get("sourcePartIds", []):
		section_source_ids[String(section_source_value)] = true
	for source_id_value: Variant in row.get("sourcePartIds", []):
		var source_id := String(source_id_value)
		var site_id := SectionGeometryAdapter._site_id_from_census_source(source_id)
		var member_id := SectionGeometryAdapter._member_id_from_census_source(source_id)
		if site_id.is_empty() or not _is_transform_member(member_id):
			continue
		var owner_lookup_started := Time.get_ticks_usec()
		var publisher_result: Dictionary = _current_transform_artifact_publisher_for_member(site_id, member_id) if member_id.begins_with("furnishing:") else _current_packet_publisher_for_site(site_id)
		_record_section_ack_phase("ownerPublisherLookup", owner_lookup_started,
			"ownerPublisherLookupCount", 1)
		if publisher_result.get("status") != "ready":
			return {"status":"pending", "reason":String(publisher_result.get("reason",
				"citadel_visual_owner_unavailable")), "retryable":true,
				"sectionKey":section_key, "sourceId":source_id}
		var publisher = publisher_result.get("publisher")
		if publisher == null or not is_instance_valid(publisher) \
				or not _publisher_node_roster_available(publisher):
			return {"status":"pending", "reason":"citadel_visual_inventory_unavailable",
				"retryable":true, "sectionKey":section_key, "sourceId":source_id}
		publisher_by_source[source_id] = publisher
		var publisher_instance_id: int = publisher.get_instance_id()
		if not publisher_sources.has(publisher_instance_id):
			publisher_sources[publisher_instance_id] = {"publisher":publisher,
				"siteId":site_id, "partIds":{}}
		var publisher_source: Dictionary = publisher_sources[publisher_instance_id]
		publisher_source.partIds[_transform_part_id(member_id)] = true
		publisher_sources[publisher_instance_id] = publisher_source
	for publisher_source_value: Variant in publisher_sources.values():
		var publisher_source: Dictionary = publisher_source_value
		var publisher: Object = publisher_source.publisher
		var source_part_ids: Array[String] = []
		for part_value: Variant in publisher_source.partIds:
			source_part_ids.append(String(part_value))
		for removal_value: Variant in removal_records_by_id.values():
			if removal_value is Dictionary \
					and String(removal_value.get("siteId", "")) == String(publisher_source.siteId):
				var removed_member := SectionGeometryAdapter._member_id_from_census_source(
					String(removal_value.get("sourceId", "")))
				if removed_member.begins_with("building:"):
					source_part_ids.append(_transform_part_id(removed_member))
		var legacy_index_started := Time.get_ticks_usec()
		var indexed_visuals: Dictionary = _legacy_visual_section_index.request_section_sources(
			publisher, section_key, source_part_ids)
		_record_section_ack_phase("legacySectionIndex", legacy_index_started,
			"legacySectionIndexQueries", 1)
		if indexed_visuals.get("status") != "ready":
			return {"status":"pending", "reason":String(indexed_visuals.get("reason",
				"citadel_visual_inventory_index_pending")), "retryable":true,
				"sectionKey":section_key,
				"indexedNodeCount":int(indexed_visuals.get("indexedNodeCount", 0)),
				"pendingNodeCount":int(indexed_visuals.get("pendingNodeCount", 0))}
		var publisher_inventory_started := Time.get_ticks_usec()
		var inventory: Dictionary = _validate_visible_citadel_section_visual_inventory(
			publisher, String(publisher_source.siteId), section_key, section_source_ids,
			removal_revisions, indexed_visuals.get("visuals", []), true)
		_record_section_ack_phase("publisherVisualInventory", publisher_inventory_started,
			"publisherVisualInventoryQueries", 1)
		if inventory.get("status") != "ready":
			for inventory_result_value: Variant in inventory.get("visualResults", []):
				if inventory_result_value is Dictionary:
					visual_results.append(inventory_result_value)
			return {"status":"pending", "reason":"citadel_visual_inventory_unresolved",
				"retryable":true, "sectionKey":section_key,
				"waitingVisualCount":int(inventory.get("waitingVisualCount", 1)),
				"visualResults":visual_results}
		visuals_by_publisher[publisher.get_instance_id()] = indexed_visuals.get("visuals", [])
	var retained_inventory_started := Time.get_ticks_usec()
	var scene_inventory: Dictionary = _validate_visible_citadel_scene_visual_inventory(
		section_key, section_source_ids, removal_revisions, removal_records_by_id)
	_record_section_ack_phase("retainedSceneInventory", retained_inventory_started,
		"retainedSceneInventoryQueries", 1)
	if scene_inventory.get("status") != "ready":
		return {"status":"pending", "reason":"citadel_scene_visual_inventory_unresolved",
			"retryable":true, "sectionKey":section_key,
			"waitingVisualCount":int(scene_inventory.get("waitingVisualCount", 1)),
			"visualResults":scene_inventory.get("visualResults", [])}
	var receipt_proof := {"receipt":receipt,
		"worldId":world_id,
		"authorityRevision":String(current.get("authorityRevision", "")),
		"coverageRevision":coverage_revision,
		"sourceRevisions":source_revisions,
		"removalRevisions":removal_revisions}
	receipt_proof.make_read_only()
	_section_install_acknowledgements[section_key] = receipt_proof
	var retired_count := 0
	var waiting_count := 0
	var receipt_scope_owner: Object = _geometry_completion_owner.get_ref() \
		if _geometry_completion_owner != null else null
	var receipt_scope_token := 0
	if is_instance_valid(receipt_scope_owner) \
			and receipt_scope_owner.has_method("begin_geometry_owner_receipt_validation_scope"):
		var receipt_scope: Dictionary = receipt_scope_owner.call(
			"begin_geometry_owner_receipt_validation_scope", self)
		if receipt_scope.get("status") == "ready":
			receipt_scope_token = int(receipt_scope.get("token", 0))
	for source_id_value: Variant in row.get("sourcePartIds", []):
		var source_id := String(source_id_value)
		var site_id := SectionGeometryAdapter._site_id_from_census_source(source_id)
		var member_id := SectionGeometryAdapter._member_id_from_census_source(source_id)
		if not site_id.is_empty() and member_id.begins_with("tree:"):
			# Tree authority acknowledgement aggregates every section owned by the
			# tree. Keep that full-source check on the retirement retry path so this
			# section's installed receipt can be acknowledged independently.
			var queued_tree_retirement := _queue_section_source_retirement(
				"tree", source_id, site_id, member_id)
			visual_results.append(queued_tree_retirement)
			if queued_tree_retirement.get("status") != "queued":
				waiting_count += 1
			continue
		if site_id.is_empty() or not _is_transform_member(member_id):
			continue
		var publisher = publisher_by_source.get(source_id)
		if publisher == null or not is_instance_valid(publisher):
			waiting_count += 1
			continue
		var part_id := _transform_part_id(member_id)
		var presentation_started := Time.get_ticks_usec()
		var presentation_completion := _validate_citadel_presentation_completion(source_id)
		_record_section_ack_phase("presentationCompletion", presentation_started,
			"presentationCompletionQueries", 1)
		if presentation_completion.get("status") != "ready":
			visual_results.append(presentation_completion)
			var queued_presentation_retirement := _queue_section_source_retirement(
				"transform", source_id, site_id, member_id, {}, publisher)
			if queued_presentation_retirement.get("status") != "queued":
				waiting_count += 1
			continue
		if _geometry_owner_rosters.get(source_id, {}).is_empty() \
				and _geometry_owner_capture_proofs.has(source_id):
			_geometry_owner_capture_proofs[source_id]["priorPresentationMembers"] = []
		var source_visuals: Array[GeometryInstance3D] = []
		for visual_value: Variant in visuals_by_publisher.get(publisher.get_instance_id(), []):
			var visual := visual_value as GeometryInstance3D
			if not is_instance_valid(visual) or not visual.is_inside_tree() \
					or visual.is_queued_for_deletion() \
					or (not visual.visible and not _legacy_has_section_ownership(visual)) \
					or String(visual.get_meta("building_source_part_id", "")) != part_id:
				continue
			source_visuals.append(visual)
		var retirement_started := Time.get_ticks_usec()
		var retirement := _retire_citadel_visuals_if_section_coverage_is_live(
			source_visuals, site_id, member_id, {}, presentation_completion)
		_record_section_ack_phase("geometryVisualRetirement", retirement_started,
			"geometryVisualRetirementQueries", 1)
		if retirement.get("status") == "retired":
			retired_count += int(retirement.get("retiredVisualCount", 0))
			_clear_section_source_retirement(source_id)
		elif retirement.get("status") == "pending":
			visual_results.append({"sourceId":source_id, "status":"pending",
				"reason":String(retirement.get("reason", "citadel_visual_retirement_pending")),
				"sectionKey":section_key, "details":retirement})
			var queued_transform_retirement := _queue_section_source_retirement(
				"transform", source_id, site_id, member_id, {}, publisher)
			if queued_transform_retirement.get("status") != "queued":
				waiting_count += 1
	for source_id_value: Variant in removal_records_by_id:
		var source_id := String(source_id_value)
		var removal: Dictionary = removal_records_by_id[source_id]
		var expected_roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
		var completion_owner: Object = _geometry_completion_owner.get_ref() if _geometry_completion_owner != null else null
		if not is_instance_valid(completion_owner) \
				or _geometry_owner_roster_is_current(source_id, expected_roster, removal).get("status") != "ready":
			waiting_count += 1
			continue
		var removal_completion := _request_citadel_geometry_owner_completion(
			completion_owner, expected_roster,
			_geometry_owner_prior_rosters.get(source_id, []))
		if removal_completion.get("status") != "ready":
			visual_results.append({"sourceId":source_id, "status":"pending",
				"reason":"citadel_removal_owner_receipts_pending", "completion":removal_completion})
			var queued_removal_retirement := _queue_section_source_retirement(
				"removal", source_id, String(removal.get("siteId", "")),
				String(removal.get("memberId", "")), removal)
			if queued_removal_retirement.get("status") != "queued":
				waiting_count += 1
			continue
		var presentation_removal := _validate_citadel_presentation_completion(source_id, String(removal.sourceRevision))
		if presentation_removal.get("status") != "ready":
			visual_results.append(presentation_removal)
			var queued_presentation_removal := _queue_section_source_retirement(
				"removal", source_id, String(removal.get("siteId", "")),
				String(removal.get("memberId", "")), removal)
			if queued_presentation_removal.get("status") != "queued":
				waiting_count += 1
			continue
		var removed_visuals: Dictionary = _current_citadel_removal_visuals(removal)
		if removed_visuals.get("status") != "ready":
			var queued_removed_visuals := _queue_section_source_retirement(
				"removal", source_id, String(removal.get("siteId", "")),
				String(removal.get("memberId", "")), removal)
			if queued_removed_visuals.get("status") != "queued":
				waiting_count += int(removed_visuals.get("waitingVisualCount", 1))
			continue
		for visual_value: Variant in removed_visuals.get("visuals", []):
			var visual := visual_value as GeometryInstance3D
			var site_id := String(removal.get("siteId", ""))
			var member_id := String(removal.get("memberId", ""))
			var retirement := _retire_citadel_visual_if_section_coverage_is_live(
				visual, site_id, member_id, removal)
			var visual_result := {"sourceId":source_id,
				"status":String(retirement.get("status", "pending")),
				"reason":String(retirement.get("reason", "")),
				"sectionKey":retirement.get("sectionKey", section_key)}
			visual_result.make_read_only()
			visual_results.append(visual_result)
			if retirement.get("status") == "retired":
				retired_count += 1
				_clear_section_source_retirement(source_id)
			elif retirement.get("status") == "pending":
				var queued_visual_retirement := _queue_section_source_retirement(
					"removal", source_id, site_id, member_id, removal)
				if queued_visual_retirement.get("status") != "queued":
					waiting_count += 1
	var receipt_scope_result: Dictionary = {"status":"unavailable"}
	if receipt_scope_token > 0:
		receipt_scope_result = receipt_scope_owner.call(
			"end_geometry_owner_receipt_validation_scope", self, receipt_scope_token)
	var has_pending_visuals: bool = waiting_count > 0
	var pending_reason := "citadel_visual_retirement_pending" if has_pending_visuals else ""
	return {"status":"pending" if has_pending_visuals else "acknowledged",
		"retryable":has_pending_visuals,
		"reason":pending_reason,
		"sectionKey":section_key,
		"coverageRevision":coverage_revision, "retiredVisualCount":retired_count,
		"waitingVisualCount":waiting_count, "visualResults":visual_results,
		"receiptValidationScope":receipt_scope_result}


func _queue_section_source_retirement(kind: String, source_id: String,
		site_id: String, member_id: String, removal: Dictionary = {},
		visual_owner: Object = null) -> Dictionary:
	if kind not in ["transform", "tree", "removal"] or source_id.is_empty():
		return {"status":"pending", "reason":"invalid_section_source_retirement_identity"}
	var roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
	if roster.is_empty() or String(roster.get("sourceRevision", "")).is_empty() \
			or String(roster.get("sourceIncarnation", "")).is_empty() \
			or String(roster.get("digest", "")).length() != 64:
		return {"status":"pending", "reason":"section_source_retirement_roster_unavailable"}
	if _pending_section_source_retirements.has(source_id):
		var existing: Dictionary = _pending_section_source_retirements[source_id]
		if String(existing.get("sourceRevision", "")) == String(roster.sourceRevision) \
				and String(existing.get("sourceIncarnation", "")) == String(roster.sourceIncarnation) \
				and String(existing.get("rosterDigest", "")) == String(roster.digest) \
				and String(existing.get("kind", "")) == kind:
			return {"status":"queued", "deduplicated":true}
	elif _pending_section_source_retirements.size() >= MAX_PENDING_SECTION_SOURCE_RETIREMENTS:
		return {"status":"pending", "reason":"section_source_retirement_queue_full",
			"retryable":true}
	var obligation := {"kind":kind, "sourceId":source_id, "siteId":site_id,
		"memberId":member_id, "worldId":String(roster.get("worldId", "")),
		"sourceRevision":String(roster.sourceRevision),
		"sourceIncarnation":String(roster.sourceIncarnation),
		"rosterDigest":String(roster.digest), "removal":removal,
		"obligationId":_next_section_source_retirement_id(),
		"ownerInstanceId":visual_owner.get_instance_id() \
			if is_instance_valid(visual_owner) else 0,
		"attempts":0, "lastReason":""}
	obligation.make_read_only()
	_pending_section_source_retirements[source_id] = obligation
	if not _pending_section_source_retirement_queue.has(source_id):
		_pending_section_source_retirement_queue.append(source_id)
	return {"status":"queued", "deduplicated":false}


func _next_section_source_retirement_id() -> int:
	_section_source_retirement_serial += 1
	if _section_source_retirement_serial <= 0:
		_section_source_retirement_serial = 1
	return _section_source_retirement_serial


func _clear_section_source_retirement(source_id: String) -> void:
	_pending_section_source_retirements.erase(source_id)
	var queued_index := _pending_section_source_retirement_queue.find(source_id)
	if queued_index >= 0:
		_pending_section_source_retirement_queue.remove_at(queued_index)


func _advance_pending_section_source_retirements(max_attempts: int,
		budget_usec: int) -> Dictionary:
	if max_attempts < 1 or budget_usec < 1 or _pending_section_source_retirements.is_empty():
		return {"status":"idle", "attempts":0,
			"pendingCount":_pending_section_source_retirements.size()}
	var started_usec := Time.get_ticks_usec()
	var attempts := 0
	var initial_queue_count := _pending_section_source_retirement_queue.size()
	while attempts < max_attempts and attempts < initial_queue_count \
			and not _pending_section_source_retirement_queue.is_empty() \
			and Time.get_ticks_usec() - started_usec < budget_usec:
		var source_id: String = _pending_section_source_retirement_queue.pop_front()
		var obligation: Dictionary = _pending_section_source_retirements.get(source_id, {})
		if obligation.is_empty(): continue
		attempts += 1
		var result := _attempt_section_source_retirement(obligation)
		var current_obligation: Dictionary = _pending_section_source_retirements.get(source_id, {})
		if int(current_obligation.get("obligationId", 0)) != int(obligation.get("obligationId", 0)):
			# A reentrant callback replaced this request while it was being checked.
			# Preserve and retry the newest owner identity instead of erasing it.
			if not current_obligation.is_empty() \
					and not _pending_section_source_retirement_queue.has(source_id):
				_pending_section_source_retirement_queue.append(source_id)
			continue
		if result.get("status") in ["retired", "acknowledged", "stale_dropped"]:
			_pending_section_source_retirements.erase(source_id)
			continue
		var retained := obligation.duplicate(false)
		retained["attempts"] = int(obligation.get("attempts", 0)) + 1
		retained["lastReason"] = String(result.get("reason", "section_source_retirement_pending"))
		retained.make_read_only()
		_pending_section_source_retirements[source_id] = retained
		_pending_section_source_retirement_queue.append(source_id)
	return {"status":"advanced" if attempts > 0 else "idle", "attempts":attempts,
		"pendingCount":_pending_section_source_retirements.size(),
		"elapsedUsec":Time.get_ticks_usec() - started_usec}


func _attempt_section_source_retirement(obligation: Dictionary) -> Dictionary:
	var source_id := String(obligation.get("sourceId", ""))
	var roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
	if roster.is_empty() \
			or String(roster.get("worldId", "")) != String(obligation.get("worldId", "")) \
			or String(roster.get("sourceRevision", "")) != String(obligation.get("sourceRevision", "")) \
			or String(roster.get("sourceIncarnation", "")) != String(obligation.get("sourceIncarnation", "")) \
			or String(roster.get("digest", "")) != String(obligation.get("rosterDigest", "")):
		return {"status":"stale_dropped", "reason":"section_source_retirement_owner_revision_changed"}
	var kind := String(obligation.get("kind", ""))
	if kind == "tree":
		return _acknowledge_tree_section_install(source_id,
			String(obligation.get("siteId", "")), String(obligation.get("memberId", "")))
	if kind == "transform":
		var site_id := String(obligation.get("siteId", ""))
		var member_id := String(obligation.get("memberId", ""))
		var publisher_result: Dictionary = _current_transform_artifact_publisher_for_member(
			site_id, member_id) if member_id.begins_with("furnishing:") \
			else _current_packet_publisher_for_site(site_id)
		if publisher_result.get("status") != "ready":
			return {"status":"pending", "reason":String(publisher_result.get("reason",
				"section_source_retirement_publisher_pending"))}
		var publisher: Object = publisher_result.get("publisher")
		if not is_instance_valid(publisher) \
				or int(obligation.get("ownerInstanceId", 0)) != publisher.get_instance_id():
			return {"status":"stale_dropped", "reason":"section_source_retirement_publisher_replaced"}
		var part_id := _transform_part_id(member_id)
		var source_visuals: Array[GeometryInstance3D] = []
		for visual_value: Variant in _published_legacy_geometry(publisher):
			var visual := visual_value as GeometryInstance3D
			if is_instance_valid(visual) and visual.is_inside_tree() \
					and not visual.is_queued_for_deletion() \
					and String(visual.get_meta("building_source_part_id", "")) == part_id \
					and (visual.visible or _legacy_has_section_ownership(visual)):
				source_visuals.append(visual)
		var retirement := _retire_citadel_visuals_if_section_coverage_is_live(
			source_visuals, site_id, member_id)
		if retirement.get("status") == "retired":
			return {"status":"retired", "retiredVisualCount":int(
				retirement.get("retiredVisualCount", 0))}
		return retirement
	if kind == "removal":
		return _attempt_citadel_removal_retirement(obligation, roster)
	return {"status":"stale_dropped", "reason":"section_source_retirement_kind_invalid"}


func _attempt_citadel_removal_retirement(obligation: Dictionary,
		roster: Dictionary) -> Dictionary:
	var source_id := String(obligation.get("sourceId", ""))
	var removal: Dictionary = obligation.get("removal", {})
	if removal.is_empty() or String(removal.get("sourceId", "")) != source_id \
			or String(removal.get("sourceRevision", "")) != String(roster.get("sourceRevision", "")):
		return {"status":"stale_dropped", "reason":"section_source_removal_identity_changed"}
	var owner: Object = _geometry_completion_owner.get_ref() \
		if _geometry_completion_owner != null else null
	if not is_instance_valid(owner) \
			or _geometry_owner_roster_is_current(source_id, roster, removal).get("status") != "ready":
		return {"status":"pending", "reason":"citadel_removal_owner_currentness_pending"}
	var completion := _request_citadel_geometry_owner_completion(owner, roster,
		_geometry_owner_prior_rosters.get(source_id, []))
	if completion.get("status") != "ready": return completion
	var presentation := _validate_citadel_presentation_completion(source_id,
		String(removal.get("sourceRevision", "")))
	if presentation.get("status") != "ready": return presentation
	var removed_visuals := _current_citadel_removal_visuals(removal)
	if removed_visuals.get("status") != "ready": return removed_visuals
	var retired_count := 0
	for visual_value: Variant in removed_visuals.get("visuals", []):
		var visual := visual_value as GeometryInstance3D
		var retirement := _retire_citadel_visual_if_section_coverage_is_live(visual,
			String(removal.get("siteId", "")), String(removal.get("memberId", "")), removal)
		if retirement.get("status") == "retired":
			retired_count += int(retirement.get("retiredVisualCount", 0))
		else:
			return retirement
	return {"status":"retired", "retiredVisualCount":retired_count}


## Release only the exact provider claim represented by this installed receipt.
## A delayed release for an older slot cannot erase a newer acknowledgement.
func release_section_install(section_key: Vector3i,
		coverage_revision: String, receipt: Dictionary = {}) -> Dictionary:
	if coverage_revision.is_empty() or not receipt.is_read_only() \
			or receipt.get("status") != "installed" \
			or receipt.get("sectionKey") != section_key:
		return {"status":"pending", "reason":"citadel_section_release_receipt_invalid",
			"retryable":true}
	var stored: Dictionary = _section_install_acknowledgements.get(section_key, {})
	if stored.is_empty():
		return {"status":"acknowledged", "sectionKey":section_key,
			"reason":"citadel_section_release_claim_already_absent"}
	if String(stored.get("coverageRevision", "")) != coverage_revision \
			or not _same_citadel_section_receipt_token(
				stored.get("receipt", {}), receipt):
		# A newer receipt has replaced this exact claim; preserve it.
		return {"status":"acknowledged", "sectionKey":section_key,
			"reason":"citadel_section_release_claim_replaced"}
	_section_install_acknowledgements.erase(section_key)
	var restored_visual_count := 0
	var source_revisions: Dictionary = stored.get("sourceRevisions", {})
	for removal_source_value: Variant in stored.get("removalRevisions", {}):
		_clear_section_source_retirement(String(removal_source_value))
	for source_id_value: Variant in source_revisions:
		var source_id := String(source_id_value)
		_clear_section_source_retirement(source_id)
		var site_id := SectionGeometryAdapter._site_id_from_census_source(source_id)
		var member_id := SectionGeometryAdapter._member_id_from_census_source(source_id)
		if site_id.is_empty() or not _is_transform_member(member_id):
			continue
		var owner := _current_transform_artifact_publisher_for_member(site_id, member_id)
		if owner.get("status") != "ready":
			continue
		var publisher = owner.get("publisher")
		if publisher == null or not is_instance_valid(publisher) \
				or not _publisher_node_roster_available(publisher):
			continue
		var part_id := _transform_part_id(member_id)
		for visual_value: Variant in _published_legacy_geometry(publisher):
			var visual := visual_value as GeometryInstance3D
			if not is_instance_valid(visual) or visual.is_queued_for_deletion() \
					or not _legacy_has_section_ownership(visual) \
					or String(visual.get_meta("building_source_part_id", "")) != part_id:
				continue
			var roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
			if section_key not in OwnerCompletion.owner_sections(roster):
				continue
			_citadel_visual_retirement_pending(visual, "citadel_geometry_owner_install_released")
			restored_visual_count += 1
	return {"status":"acknowledged", "sectionKey":section_key,
		"restoredVisualCount":restored_visual_count,
		"reason":"citadel_section_release_exact_claim_removed"}


static func _same_citadel_section_receipt_token(left_value: Variant,
		right: Dictionary) -> bool:
	if not left_value is Dictionary:
		return false
	var left: Dictionary = left_value
	for field: String in ["status", "worldId", "sectionKey", "generation",
			"contentManifestDigest", "backendInstanceId", "chunkInstanceId", "ownerCell"]:
		if left.get(field) != right.get(field):
			return false
	return true


## A receipt can retire only visuals that map back to current census members.
## Unknown visible geometry remains on screen and keeps the provider ack
## retryable; collision bodies and gameplay owners are not in this visual list.
func _validate_visible_citadel_section_visual_inventory(publisher: Object,
		site_id: String, section_key: Vector3i, section_source_ids: Dictionary,
		removal_revisions: Dictionary = {}, indexed_visuals: Array = [],
		use_indexed_visuals := false) -> Dictionary:
	if publisher == null or not is_instance_valid(publisher) \
			or not _publisher_node_roster_available(publisher):
		return {"status":"pending", "reason":"citadel_visual_inventory_unavailable",
			"retryable":true, "waitingVisualCount":1,
			"visualResults":[{"status":"pending",
				"reason":"citadel_visual_inventory_unavailable"}]}
	var waiting_count := 0
	var visual_results: Array[Dictionary] = []
	var visual_values: Array = indexed_visuals if use_indexed_visuals \
		else _published_legacy_geometry(publisher)
	for visual_value: Variant in visual_values:
		var visual := visual_value as GeometryInstance3D
		if not is_instance_valid(visual) or not visual.is_inside_tree() \
				or visual.is_queued_for_deletion():
			continue
		var section_owned := _legacy_has_section_ownership(visual)
		if not visual.visible and not section_owned:
			continue
		var bounds := visual.global_transform * visual.get_aabb()
		var visual_sections: Array[Vector3i] = SectionGrid.keys_intersecting_bounds(bounds)
		if visual_sections.is_empty() or visual_sections.size() > 256:
			waiting_count += 1
			if section_owned:
				_restore_legacy_visual_if_unclaimed(visual)
			var invalid_bounds := {"status":"pending",
				"reason":"citadel_visible_visual_section_bounds_unavailable",
				"siteId":site_id, "nodeInstanceId":visual.get_instance_id()}
			invalid_bounds.make_read_only()
			visual_results.append(invalid_bounds)
			continue
		if section_key not in visual_sections:
			continue
		var part_id := String(visual.get_meta("building_source_part_id", ""))
		if part_id.is_empty():
			waiting_count += 1
			if section_owned:
				_restore_legacy_visual_if_unclaimed(visual)
			var unidentified := {"status":"pending",
				"reason":"citadel_visible_visual_source_identity_unavailable",
				"siteId":site_id, "sectionKey":section_key,
				"nodeInstanceId":visual.get_instance_id()}
			unidentified.make_read_only()
			visual_results.append(unidentified)
			continue
		var source_id := _citadel_census_source_id(site_id,
			_visual_member_id(visual), section_key)
		if not section_source_ids.has(source_id) and not removal_revisions.has(source_id):
			waiting_count += 1
			if section_owned:
				_restore_legacy_visual_if_unclaimed(visual)
			var unrostered := {"status":"pending",
				"reason":"citadel_visible_visual_source_not_in_current_census",
				"siteId":site_id, "sectionKey":section_key,
				"sourcePartId":part_id, "nodeInstanceId":visual.get_instance_id()}
			unrostered.make_read_only()
			visual_results.append(unrostered)
	if waiting_count > 0:
		return {"status":"pending", "reason":"citadel_visual_inventory_unresolved",
			"retryable":true, "waitingVisualCount":waiting_count,
			"visualResults":visual_results}
	return {"status":"ready", "waitingVisualCount":0, "visualResults":visual_results}


## Also inspect every retained scene publisher, including when the current census
## has no building members in this section. This finds visuals left behind by a
## source that disappeared from the current roster; those require an explicit
## removal/tombstone proof before the empty section can be acknowledged.
func _validate_visible_citadel_scene_visual_inventory(section_key: Vector3i,
		section_source_ids: Dictionary, removal_revisions: Dictionary = {},
		removal_records_by_id: Dictionary = {}) -> Dictionary:
	var checked_publishers: Dictionary = {}
	var waiting_count := 0
	var visual_results: Array[Dictionary] = []
	var section_admission_bounds := _citadel_section_admission_bounds(section_key)
	var low_region := Field.region_for_cell(section_admission_bounds.position)
	var high_region := Field.region_for_cell(section_admission_bounds.end - Vector2i.ONE)
	for region_value: Variant in _scenes:
		_count_section_ack_work("retainedSceneRegionsVisited")
		if not region_value is Vector2i:
			return {"status":"pending", "waitingVisualCount":1,
				"visualResults":[{"status":"pending",
					"reason":"citadel_retained_scene_region_unavailable"}]}
		var region: Vector2i = region_value
		var entry_value: Variant = _scenes[region_value]
		if not entry_value is Dictionary:
			return {"status":"pending", "waitingVisualCount":1,
				"visualResults":[{"status":"pending",
					"reason":"citadel_retained_scene_entry_unavailable",
					"region":region}]}
		var entry: Dictionary = entry_value
		var admission_source: Dictionary = _admission.source_state(region) \
			if _admission != null else {"status":"pending"}
		var reservation_value: Variant = admission_source.get("reservationCells", null)
		var possibly_intersects: bool = region.x >= low_region.x and region.x <= high_region.x \
			and region.y >= low_region.y and region.y <= high_region.y
		var reservation_is_current: bool = admission_source.get("status") in ["ready", "prepared"] \
			and admission_source.get("binding", {}) == entry.get("binding", {})
		if reservation_value is Rect2i and reservation_is_current:
			var reservation_cells: Rect2i = reservation_value
			possibly_intersects = reservation_cells.intersects(section_admission_bounds)
		if not possibly_intersects:
			continue
		var site_id := String(entry.get("binding", {}).get("siteId", ""))
		var job = entry.get("job")
		for publisher: Variant in _scene_visual_publishers(job):
			_count_section_ack_work("retainedScenePublishersVisited")
			if publisher == null or not is_instance_valid(publisher) \
				or not _publisher_node_roster_available(publisher):
				waiting_count += 1
				var missing_owner := {"status":"pending",
					"reason":"citadel_retained_scene_visual_owner_unavailable",
					"region":region, "siteId":site_id,
					"sourceStatus":String(admission_source.get("status", "pending"))}
				missing_owner.make_read_only()
				visual_results.append(missing_owner)
				continue
			var publisher_instance_id: int = publisher.get_instance_id()
			if checked_publishers.has(publisher_instance_id):
				continue
			checked_publishers[publisher_instance_id] = true
			var owner_removal_revisions: Dictionary = {}
			var owner_binding_digest := _citadel_owner_binding_digest(entry.get("binding", {}))
			for source_id_value: Variant in removal_records_by_id:
				var source_id := String(source_id_value)
				var removal: Dictionary = removal_records_by_id[source_id]
				if String(removal.get("siteId", "")) == site_id \
						and String(removal.get("ownerBindingDigest", "")) == owner_binding_digest:
					owner_removal_revisions[source_id] = String(removal.get("sourceRevision", ""))
			owner_removal_revisions.make_read_only()
			var scoped_part_ids: Array[String] = []
			for source_id_value: Variant in section_source_ids:
				var source_id := String(source_id_value)
				if SectionGeometryAdapter._site_id_from_census_source(source_id) != site_id:
					continue
				var member_id := SectionGeometryAdapter._member_id_from_census_source(source_id)
				if _is_transform_member(member_id):
					scoped_part_ids.append(_transform_part_id(member_id))
			for removal_id_value: Variant in owner_removal_revisions:
				var member_id := SectionGeometryAdapter._member_id_from_census_source(
					String(removal_id_value))
				if member_id.begins_with("building:"):
					scoped_part_ids.append(_transform_part_id(member_id))
			var indexed_visuals: Dictionary = _legacy_visual_section_index.request_section_sources(
				publisher, section_key, scoped_part_ids)
			if indexed_visuals.get("status") != "ready":
				waiting_count += 1
				var index_pending := {"status":"pending",
					"reason":String(indexed_visuals.get("reason",
						"citadel_visual_inventory_index_pending")),
					"region":region, "siteId":site_id,
					"indexedNodeCount":int(indexed_visuals.get("indexedNodeCount", 0)),
					"pendingNodeCount":int(indexed_visuals.get("pendingNodeCount", 0))}
				index_pending.make_read_only()
				visual_results.append(index_pending)
				continue
			var inventory: Dictionary = _validate_visible_citadel_section_visual_inventory(
				publisher, site_id, section_key, section_source_ids, owner_removal_revisions,
				indexed_visuals.get("visuals", []), true)
			if inventory.get("status") != "ready":
				waiting_count += int(inventory.get("waitingVisualCount", 1))
				for result_value: Variant in inventory.get("visualResults", []):
					if result_value is Dictionary:
						visual_results.append(result_value)
	if waiting_count > 0:
		return {"status":"pending", "waitingVisualCount":waiting_count,
			"visualResults":visual_results}
	# A scene removed from _scenes is still an owner while its incremental
	# retirement job drains. Bypass it only after current complete inventory
	# proves that no retained visual intersects this section.
	for entry_value: Variant in _retiring_scenes:
		if not entry_value is Dictionary:
			return {"status":"pending", "waitingVisualCount":1,
				"visualResults":[{"status":"pending",
					"reason":"citadel_retiring_scene_entry_unavailable"}]}
		var retiring_entry: Dictionary = entry_value
		var retiring_region_value: Variant = retiring_entry.get("region", null)
		if not retiring_region_value is Vector2i:
			return {"status":"pending", "waitingVisualCount":1,
				"visualResults":[{"status":"pending",
					"reason":"citadel_retiring_scene_region_unavailable"}]}
		var retiring_region: Vector2i = retiring_region_value
		var retiring_source: Dictionary = _admission.source_state(retiring_region) \
			if _admission != null else {"status":"pending"}
		var retiring_reservation_value: Variant = retiring_source.get("reservationCells", null)
		var retiring_binding: Dictionary = retiring_entry.get("binding", {})
		var retiring_reservation_is_current: bool = \
			retiring_source.get("status") in ["ready", "prepared"] \
			and retiring_source.get("binding", {}) == retiring_binding
		# reservationCells describes the admitted source envelope, but that alone
		# does not prove every runtime visual stays inside it. Narrow this guard
		# only when the still-live teardown job can enumerate its complete visual
		# owners and their transformed bounds for this exact section.
		var exact_retirement_inventory: Dictionary = {}
		if retiring_reservation_value is Rect2i and retiring_reservation_is_current:
			exact_retirement_inventory = _retiring_citadel_inventory_disjoint_from_section(
				retiring_entry, retiring_source, retiring_binding, section_key)
			if exact_retirement_inventory.get("status") == "ready" \
					and bool(exact_retirement_inventory.get("disjoint", false)):
				continue
		waiting_count += 1
		var retiring_result := {"status":"pending",
			"reason":"citadel_retiring_scene_visual_owner_not_drained",
			"region":retiring_region,
			"siteId":String(retiring_entry.get("binding", {}).get("siteId", "")),
			"sourceStatus":String(retiring_source.get("status", "pending")),
			"inventoryReason":String(exact_retirement_inventory.get("reason", "")),
			"inventoryIntersectingNode":int(exact_retirement_inventory.get("nodeInstanceId", 0))}
		retiring_result.make_read_only()
		visual_results.append(retiring_result)
	if waiting_count > 0:
		return {"status":"pending", "waitingVisualCount":waiting_count,
			"visualResults":visual_results}
	return {"status":"ready", "waitingVisualCount":0, "visualResults":visual_results}


func _retiring_citadel_inventory_disjoint_from_section(retiring_entry: Dictionary,
		retiring_source: Dictionary, retiring_binding: Dictionary,
		section_key: Vector3i) -> Dictionary:
	if retiring_source.get("status") not in ["ready", "prepared"] \
			or retiring_source.get("binding", {}) != retiring_binding:
		return {"status":"pending", "reason":"retiring_admission_binding_stale"}
	var job = retiring_entry.get("job")
	if job == null or not is_instance_valid(job) \
			or not job.has_method("own_node_root") or not job.has_method("status_count") \
			or job.get("_binding") != retiring_binding:
		return {"status":"pending", "reason":"retiring_scene_job_binding_unavailable"}
	var job_status: Dictionary = job.call("status_count")
	if String(job_status.get("phase", "")) not in ["teardown", "detach_publishers", "retired"]:
		return {"status":"pending", "reason":"retiring_scene_phase_unavailable"}
	# These authorities can own visible objects outside the building publisher's
	# published_nodes list. Until their exact retirement claim drains, the scene
	# inventory is not complete enough to narrow the coarse gate.
	for claim_field: String in ["_door_claims", "_tree_retirement_claims", "_registered_tree_ids"]:
		var claims: Variant = job.get(claim_field)
		if not claims is Dictionary or not claims.is_empty():
			return {"status":"pending", "reason":"retiring_external_visual_claims_unresolved",
				"claimField":claim_field}
	var building = job.get("_building")
	var furniture = job.get("_furniture")
	if building == null or not is_instance_valid(building) \
			or not _publisher_node_roster_available(building):
		return {"status":"pending", "reason":"retiring_building_visual_inventory_unavailable"}
	if furniture != null and (not is_instance_valid(furniture) \
			or not furniture.get("published_parts") is Array):
		return {"status":"pending", "reason":"retiring_furniture_visual_inventory_unavailable"}
	if not building.has_method("has_pending_chunk_static_packet_retirement") \
			or bool(building.call("has_pending_chunk_static_packet_retirement")):
		return {"status":"pending", "reason":"retiring_chunk_packet_visual_claim_unresolved"}
	var publisher_site_id := String(building.get("publication_site_id"))
	if publisher_site_id != String(retiring_binding.get("siteId", "")):
		return {"status":"pending", "reason":"retiring_publisher_binding_unavailable"}
	var root_value: Variant = job.call("own_node_root")
	if root_value != null and (not is_instance_valid(root_value) or not root_value is Node3D):
		return {"status":"pending", "reason":"retiring_scene_root_unavailable"}
	var scan_roots: Array[Node] = []
	if root_value is Node:
		scan_roots.append(root_value)
	var publisher_owner_root_count := 0
	for owner_value: Variant in [building, furniture]:
		if owner_value == null:
			continue
		if owner_value is Node:
			if not is_instance_valid(owner_value):
				return {"status":"pending", "reason":"retiring_publisher_owner_unavailable"}
			scan_roots.append(owner_value)
			publisher_owner_root_count += 1
		elif owner_value == building:
			# BuildingPartPublisher is a RefCounted owner. Its live scene parent is
			# the only root that can prove inventory completeness when the job root
			# is absent; published_nodes alone cannot reveal omitted descendants.
			var scene_parent_ref: Variant = owner_value.get("_scene_parent")
			if scene_parent_ref is WeakRef:
				var scene_parent = scene_parent_ref.get_ref()
				if is_instance_valid(scene_parent) and scene_parent is Node:
					scan_roots.append(scene_parent)
					publisher_owner_root_count += 1
		var published: Array = _publisher_node_roster_snapshot(owner_value) if owner_value == building \
				else owner_value.get("published_parts")
		for node_value: Variant in published:
			if node_value == null or not is_instance_valid(node_value):
				continue
			if not node_value is Node:
				return {"status":"pending", "reason":"retiring_published_node_inventory_invalid"}
			scan_roots.append(node_value)
	if root_value == null and publisher_owner_root_count == 0:
		return {"status":"pending", "reason":"retiring_publisher_ancestry_unavailable"}
	if root_value == null and scan_roots.is_empty():
		return {"status":"ready", "disjoint":true, "visualCount":0}
	var visited: Dictionary = {}
	var stack: Array[Node] = scan_roots
	var visual_count := 0
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if not is_instance_valid(node):
			continue
		var node_id: int = node.get_instance_id()
		if visited.has(node_id):
			continue
		visited[node_id] = true
		var visual := node as GeometryInstance3D
		if visual != null and is_instance_valid(visual) and visual.is_inside_tree() \
				and (visual.visible or bool(visual.get_meta("citadel_section_owned", false))):
			var local_bounds := visual.get_aabb()
			if not local_bounds.position.is_finite() or not local_bounds.size.is_finite() \
					or local_bounds.size.x <= 0.0 or local_bounds.size.y <= 0.0 \
					or local_bounds.size.z <= 0.0:
				return {"status":"pending", "reason":"retiring_visual_bounds_unavailable",
					"nodeInstanceId":node_id}
			var world_bounds: AABB = visual.global_transform * local_bounds
			var intersected_sections: Array[Vector3i] = SectionGrid.keys_intersecting_bounds(
				world_bounds)
			if intersected_sections.is_empty() or intersected_sections.size() > 256:
				return {"status":"pending", "reason":"retiring_visual_section_bounds_unavailable",
					"nodeInstanceId":node_id}
			visual_count += 1
			if section_key in intersected_sections:
				return {"status":"pending", "reason":"retiring_visual_intersects_section",
					"nodeInstanceId":node_id, "visualCount":visual_count}
		for child_index: int in node.get_child_count(true):
			var child := node.get_child(child_index, true)
			if child is Node:
				stack.append(child)
	return {"status":"ready", "disjoint":true, "visualCount":visual_count}


func _citadel_section_admission_bounds(section_key: Vector3i) -> Rect2i:
	var origin := SectionGrid.origin_for_key(section_key)
	var section_bounds := AABB(origin, Vector3.ONE * SectionGrid.SECTION_SIZE_METERS)
	var low := Vector2i(floori(origin.x / SitePreparation.CELL) - 2,
		floori(origin.z / SitePreparation.CELL) - 2)
	var high := Vector2i(ceili(section_bounds.end.x / SitePreparation.CELL) + 2,
		ceili(section_bounds.end.z / SitePreparation.CELL) + 2)
	return Rect2i(low, high - low)


func _current_citadel_removal_visuals(removal: Dictionary) -> Dictionary:
	if String(removal.get("memberId", "")).begins_with("tree:"):
		var source_id := String(removal.get("sourceId", ""))
		var current := _current_tree_roster_removal(String(_geometry_owner_rosters.get(source_id, {}).get("worldId", "")),
			source_id, removal.get("sectionKey", Vector3i.ZERO), _geometry_owner_capture_proofs.get(source_id, {}))
		if current.get("status") != "ready" or current.get("removal") != removal:
			return {"status":"pending", "reason":"citadel_tree_removal_changed", "waitingVisualCount":1}
		return {"status":"ready", "visuals":[]}
	var site_id := String(removal.get("siteId", ""))
	var part_id := _transform_part_id(String(removal.get("memberId", "")))
	var source_id := String(removal.get("sourceId", ""))
	var expected_member_binding := String(removal.get("memberBinding", ""))
	var expected_owner_digest := String(removal.get("ownerBindingDigest", ""))
	var expected_bounds: Variant = removal.get("bounds", null)
	if site_id.is_empty() or part_id.is_empty() or source_id.is_empty() \
			or expected_member_binding.is_empty() or expected_owner_digest.length() != 64 \
			or not expected_bounds is Array:
		return {"status":"pending", "reason":"citadel_removal_identity_invalid",
			"retryable":true, "waitingVisualCount":1}
	var matching_entry: Dictionary = {}
	for region: Vector2i in _scenes:
		var entry: Dictionary = _scenes[region]
		var binding: Dictionary = entry.get("binding", {})
		if String(binding.get("siteId", "")) != site_id:
			continue
		if _citadel_owner_binding_digest(binding) != expected_owner_digest:
			continue
		if not matching_entry.is_empty():
			return {"status":"pending", "reason":"citadel_removal_owner_ambiguous",
				"retryable":true, "waitingVisualCount":1}
		matching_entry = entry
	if matching_entry.is_empty():
		return {"status":"pending", "reason":"citadel_removal_owner_changed",
			"retryable":true, "waitingVisualCount":1}
	var region_value: Variant = matching_entry.get("region", null)
	if not region_value is Vector2i:
		return {"status":"pending", "reason":"citadel_removal_owner_region_missing",
			"retryable":true, "waitingVisualCount":1}
	var region: Vector2i = region_value
	var current: Dictionary = _admission.source_state(region)
	if current.get("status") not in ["ready", "prepared"] \
			or current.get("binding", {}) != matching_entry.get("binding", {}):
		return {"status":"pending", "reason":"citadel_removal_owner_binding_stale",
			"retryable":true, "waitingVisualCount":1}
	var job = matching_entry.get("job")
	var publisher = job.get("_furniture" if String(removal.get("memberId", "")).begins_with("furnishing:") else "_building") if job != null else null
	if publisher == null or not is_instance_valid(publisher) \
			or not _publisher_node_roster_available(publisher) \
			or String(publisher.get("publication_site_id")) != site_id:
		return {"status":"pending", "reason":"citadel_removal_publisher_unavailable",
			"retryable":true, "waitingVisualCount":1}
	var retained_identity: Dictionary = publisher.committed_static_visual_source_identity(part_id)
	if retained_identity.get("status") != "ready" \
			or String(retained_identity.get("sourceRevision", "")) != expected_member_binding:
		return {"status":"pending", "reason":"citadel_removal_member_binding_stale",
			"retryable":true, "waitingVisualCount":1}
	var visuals: Array[GeometryInstance3D] = []
	var actual_bounds: Array[AABB] = []
	for visual_value: Variant in _published_legacy_geometry(publisher):
		var visual := visual_value as GeometryInstance3D
		if not is_instance_valid(visual) or not visual.is_inside_tree() \
				or visual.is_queued_for_deletion() \
				or (not visual.visible and not bool(visual.get_meta("citadel_section_owned", false))) \
				or String(visual.get_meta("building_source_part_id", "")) != part_id:
			continue
		var bounds := visual.global_transform * visual.get_aabb()
		var actual_sections: Array[Vector3i] = SectionGrid.keys_intersecting_bounds(bounds)
		if removal.get("sectionKey") not in actual_sections:
			continue
		visuals.append(visual)
		actual_bounds.append(bounds)
	actual_bounds.sort_custom(func(a: AABB, b: AABB) -> bool:
		if a.position.x != b.position.x: return a.position.x < b.position.x
		if a.position.y != b.position.y: return a.position.y < b.position.y
		if a.position.z != b.position.z: return a.position.z < b.position.z
		if a.size.x != b.size.x: return a.size.x < b.size.x
		if a.size.y != b.size.y: return a.size.y < b.size.y
		return a.size.z < b.size.z)
	if actual_bounds != expected_bounds:
		return {"status":"pending", "reason":"citadel_removal_visual_bounds_changed",
			"retryable":true, "waitingVisualCount":1,
			"expectedBounds":expected_bounds, "actualBounds":actual_bounds}
	return {"status":"ready", "visuals":visuals,
		"publisher":publisher, "region":region}


static func _citadel_owner_binding_digest(binding: Dictionary) -> String:
	return Marshalls.raw_to_base64(var_to_bytes([
		String(binding.get("siteId", "")), String(binding.get("sourceKey", "")),
		int(binding.get("generation", -1))])).sha256_text()


func _retire_citadel_visual_if_section_coverage_is_live(visual: GeometryInstance3D,
		site_id: String, member_id: String, removal: Dictionary = {}) -> Dictionary:
	return _retire_citadel_visuals_if_section_coverage_is_live([visual],
		site_id, member_id, removal)


func _request_citadel_geometry_owner_completion(owner: Object, roster: Dictionary,
		prior_rosters: Array) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	if owner == null or not is_instance_valid(owner) \
			or not owner.has_method("request_geometry_owner_completion"):
		_record_section_ack_phase("geometryOwnerProofRequest", started_usec,
			"geometryOwnerProofRequests", 1)
		return {"status":"pending", "reason":"citadel_geometry_owner_request_api_unavailable",
			"retryable":true, "workItems":0}
	var result: Dictionary = owner.call("request_geometry_owner_completion", roster,
		prior_rosters)
	_record_section_ack_phase("geometryOwnerProofRequest", started_usec,
		"geometryOwnerProofRequests", 1)
	if result.get("status") == "ready":
		var receipts_current := _geometry_owner_completion_receipts_are_current(
			owner, roster, result)
		if receipts_current.get("status") != "ready":
			return receipts_current
		return result
	if result.get("status") == "pending":
		var pending := result.duplicate(false)
		pending["reason"] = "citadel_section_ack_source_slice_pending"
		pending["proofRequestReason"] = String(result.get("reason", ""))
		pending["retryable"] = true
		return pending
	return {"status":"pending", "reason":"citadel_geometry_owner_request_rejected",
		"retryable":true, "requestResult":result}


func _geometry_owner_completion_receipts_are_current(owner: Object,
		roster: Dictionary, completion: Dictionary) -> Dictionary:
	if completion.get("status") != "ready" or not is_instance_valid(owner) \
			or not owner.has_method("installed_section_receipt_is_current"):
		return {"status":"pending", "reason":"citadel_geometry_owner_completion_receipts_unavailable",
			"retryable":true}
	var owner_sections: Variant = completion.get("ownerSections", null)
	var receipts_by_section: Variant = completion.get("receiptsBySection", null)
	if not owner_sections is Array or not receipts_by_section is Dictionary \
			or owner_sections.size() != receipts_by_section.size():
		return {"status":"pending", "reason":"citadel_geometry_owner_completion_receipt_set_invalid",
			"retryable":true}
	var source_id := String(roster.get("sourceId", ""))
	var source_part_id := String(roster.get("sourcePartId", ""))
	var source_revision := String(roster.get("sourceRevision", ""))
	var identity_key := SourceRoster._source_part_identity_key(source_id, source_part_id)
	if identity_key.is_empty() or source_revision.is_empty():
		return {"status":"pending", "reason":"citadel_geometry_owner_completion_identity_invalid",
			"retryable":true}
	for section_value: Variant in owner_sections:
		if not section_value is Vector3i:
			return {"status":"pending", "reason":"citadel_geometry_owner_completion_section_invalid",
				"retryable":true}
		var section := Vector3i(section_value)
		var receipt_value: Variant = receipts_by_section.get(section, null)
		if not receipt_value is Dictionary or receipt_value.is_empty() \
				or not bool(owner.call("installed_section_receipt_is_current", section, receipt_value)):
			return {"status":"pending", "reason":"citadel_geometry_owner_completion_receipt_stale",
				"retryable":true, "sectionKey":section}
		var revision_claims: Dictionary = receipt_value.get(
			"removalRevisions" if bool(roster.get("explicitRemoval", false)) \
			else "sourceRevisions", {})
		if String(revision_claims.get(identity_key, "")) != source_revision:
			return {"status":"pending", "reason":"citadel_geometry_owner_completion_revision_unclaimed",
				"retryable":true, "sectionKey":section}
	return {"status":"ready", "receiptCount":owner_sections.size()}


func _retire_citadel_visuals_if_section_coverage_is_live(
		visuals: Array, site_id: String, member_id: String,
		removal: Dictionary = {}, presentation_proof: Dictionary = {}) -> Dictionary:
	var live_visuals: Array[GeometryInstance3D] = []
	for visual_value: Variant in visuals:
		var visual := visual_value as GeometryInstance3D
		if not is_instance_valid(visual) or not visual.is_inside_tree() \
				or visual.is_queued_for_deletion():
			return _citadel_visual_retirement_pending(visual,
				"citadel_visual_owner_changed")
		live_visuals.append(visual)
	if live_visuals.is_empty(): return {"status":"retired", "retiredVisualCount":0}
	var source_id := _citadel_census_source_id(site_id, member_id, Vector3i.ZERO)
	var roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
	var owner: Object = _geometry_completion_owner.get_ref() if _geometry_completion_owner != null else null
	if not is_instance_valid(owner) or roster.is_empty():
		return _citadel_visuals_retirement_pending(live_visuals,
			"citadel_full_geometry_owner_roster_unavailable")
	var current := _geometry_owner_roster_is_current(source_id, roster, removal)
	if current.get("status") != "ready":
		return _citadel_visuals_retirement_pending(live_visuals,
			String(current.get("reason", "citadel_geometry_owner_stale")))
	var expected: Dictionary = current.get("roster", roster)
	var prior: Array = _geometry_owner_prior_rosters.get(source_id, []).duplicate()
	if expected != roster and roster not in prior: prior.append(roster)
	var completion := _request_citadel_geometry_owner_completion(owner, expected, prior)
	if completion.get("status") != "ready":
		return _citadel_visuals_retirement_pending(live_visuals,
			String(completion.get("reason", "citadel_geometry_owner_pending")), completion)
	var presentation_completion: Dictionary = presentation_proof
	if presentation_completion.is_empty():
		presentation_completion = _validate_citadel_presentation_completion(source_id,
			String(expected.get("sourceRevision", "")) if bool(expected.get("explicitRemoval", false)) else "")
	if presentation_completion.get("status") != "ready":
		return _citadel_visuals_retirement_pending(live_visuals,
			String(presentation_completion.get("reason", "citadel_presentation_owner_pending")))
	if _geometry_owner_roster_is_current(source_id, roster, removal).get("status") != "ready":
		return _citadel_visuals_retirement_pending(live_visuals,
			"citadel_geometry_owner_changed_during_completion")
	var receipts_current := _geometry_owner_completion_receipts_are_current(
		owner, expected, completion)
	if receipts_current.get("status") != "ready":
		return _citadel_visuals_retirement_pending(live_visuals,
			String(receipts_current.get("reason", "citadel_geometry_owner_completion_receipt_stale")),
			receipts_current)
	for visual: GeometryInstance3D in live_visuals:
		visual.visible = false
		visual.set_meta("citadel_section_owned", true)
		visual.set_meta("citadel_section_owned_source_id", source_id)
	if not bool(expected.get("explicitRemoval", false)):
		_geometry_owner_prior_rosters.erase(source_id)
		if _geometry_owner_capture_proofs.has(source_id):
			_geometry_owner_capture_proofs[source_id]["priorPresentationMembers"] = []
	return {"status":"retired", "geometryCompletion":completion,
		"retiredVisualCount":live_visuals.size()}


func _citadel_visuals_retirement_pending(visuals: Array[GeometryInstance3D],
		reason: String, details := {}) -> Dictionary:
	for visual: GeometryInstance3D in visuals:
		_citadel_visual_retirement_pending(visual, reason, details)
	var result: Dictionary = details.duplicate(false)
	result["status"] = "pending"
	result["reason"] = reason
	return result


func _validate_citadel_presentation_completion(source_id: String, removal_revision := "") -> Dictionary:
	var proof: Dictionary = _geometry_owner_capture_proofs.get(source_id, {})
	var expected: Array = proof.get("presentationMembers", []) if removal_revision.is_empty() else []
	var previous: Array = proof.get("priorPresentationMembers", []).duplicate()
	if not removal_revision.is_empty():
		for member: Dictionary in proof.get("presentationMembers", []):
			if member not in previous: previous.append(member)
	if expected.is_empty() and previous.is_empty(): return {"status":"ready"}
	var reference: Variant = proof.get("publisher")
	var publisher: Variant = reference.get_ref() if reference is WeakRef else null
	var owner: Variant = _geometry_completion_owner.get_ref() if _geometry_completion_owner != null else null
	if not is_instance_valid(publisher) or not is_instance_valid(owner) \
			or not owner.has_method("validate_presentation_owner_completion"):
		return {"status":"pending", "reason":"citadel_presentation_owner_unavailable"}
	var current := _current_transform_artifact_publisher_for_member(String(proof.get("siteId", "")), _proof_transform_member(proof))
	if current.get("status") != "ready" or current.get("publisher") != publisher \
			or current.get("binding") != proof.get("binding") \
			or current.get("sceneJobInstanceId", 0) != proof.get("sceneJobInstanceId", 0):
		return {"status":"pending", "reason":"citadel_presentation_owner_replaced"}
	if removal_revision.is_empty():
		var plan = _publication_plan_for_binding(current.binding)
		if plan == null or String(plan.output_signature) != String(proof.get("planSignature", "")):
			return {"status":"pending", "reason":"citadel_presentation_plan_changed"}
		var capture: Dictionary = _capture_owner_source_snapshot(publisher, String(proof.partId), String(proof.memberBinding))
		if capture.get("status") != "ready" or _geometry_capture_identity(capture) != proof.get("captureIdentity"):
			return {"status":"pending", "reason":"citadel_presentation_capture_changed"}
	var result: Dictionary = owner.call("validate_presentation_owner_completion", String(proof.get("worldId", "")),
		source_id, source_id, removal_revision if not removal_revision.is_empty() else String(proof.get("sourceRevision", "")), expected, previous)
	return result

func _geometry_capture_identity(capture: Dictionary) -> String:
	var presentation_identity := _captured_presentation_identity(capture)
	if presentation_identity.get("status") != "ready": return ""
	var values: Array = [capture.get("sourcePartId"), capture.get("sourceRevision"), capture.get("visualSourceReceipt", {}),
		presentation_identity.digest, presentation_identity.members, presentation_identity.bindingWitnesses]
	for group: Dictionary in capture.get("groups", []):
		values.append([group.get("sourceId"), group.get("contentDigest"), group.get("sourceToWorld")])
	return Marshalls.raw_to_base64(var_to_bytes(values)).sha256_text()


## Door publishers retain bodies as roots; enumerate their exact legacy child
## geometry while leaving packet-owned attachment roots to native receipts.
static func _scene_visual_publishers(job: Variant) -> Array:
	if not job is Dictionary and not is_instance_valid(job): return [null]
	var owners: Array = [job.get("_building")]
	var furniture: Variant = job.get("_furniture")
	if is_instance_valid(furniture): owners.append(furniture)
	return owners


static func _publisher_node_roster_available(publisher: Object) -> bool:
	return is_instance_valid(publisher) \
		and (publisher.has_method("published_node_roster_snapshot") \
			or publisher.get("published_parts") is Array)


static func _publisher_node_roster_snapshot(publisher: Object) -> Array:
	if not is_instance_valid(publisher): return []
	if publisher.has_method("published_node_roster_snapshot"):
		return publisher.call("published_node_roster_snapshot")
	var parts: Variant = publisher.get("published_parts")
	if not parts is Array: return []
	var snapshot: Array = parts.duplicate()
	snapshot.make_read_only()
	return snapshot


static func _published_legacy_geometry(publisher: Object) -> Array[GeometryInstance3D]:
	var result: Array[GeometryInstance3D] = []
	var stack: Array[Node] = []
	for value: Variant in _publisher_node_roster_snapshot(publisher):
		if is_instance_valid(value) and value is Node: stack.append(value)
	var seen: Dictionary = {}
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if not is_instance_valid(node) or seen.has(node.get_instance_id()): continue
		seen[node.get_instance_id()] = true
		if bool(node.get_meta("section_attachment_native_root", false)): continue
		if node is GeometryInstance3D: result.append(node)
		for child: Node in node.get_children(): stack.append(child)
	return result


func _current_tree_roster_removal(world_id: String, source_id: String,
		section: Vector3i, proof: Dictionary) -> Dictionary:
	var authority := _current_tree_member_artifact_authority(String(proof.get("siteId", "")), String(proof.get("memberId", "")))
	if authority.get("status") != "absent" or authority.get("reason") != "removed_prop" \
			or authority.get("binding") != proof.get("binding") \
			or authority.get("jobInstanceId") != proof.get("jobInstanceId"):
		return {"status":"pending", "reason":"citadel_tree_removal_authority_pending", "retryable":true}
	var roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
	if not OwnerCompletion.validate(roster) or roster.get("worldId") != world_id:
		return {"status":"pending", "reason":"citadel_tree_removal_roster_pending"}
	var revision := String(roster.sourceRevision)
	if not bool(roster.get("explicitRemoval", false)):
		revision = var_to_bytes(["citadel-tree-removal/v1", world_id, source_id,
			proof.binding, authority.get("propId"), roster.sourceRevision]).hex_encode().sha256_text()
		var sealed := OwnerCompletion.seal(world_id, source_id, source_id, revision,
			String(roster.sourceIncarnation), [], true)
		if sealed.get("status") != "ready": return sealed
		_retain_geometry_owner_roster(source_id, sealed.roster, proof)
	var bounds: Array = _geometry_owner_removal_bounds.get(source_id, {}).get(section, []).duplicate()
	bounds.make_read_only()
	var removal := {"sourceId":source_id, "sourcePartId":source_id, "sourceRevision":revision,
		"sectionKey":section, "siteId":String(proof.siteId), "memberId":String(proof.memberId),
		"ownerBindingDigest":_citadel_owner_binding_digest(proof.binding),
		"memberBinding":String(proof.authorityRevision), "bounds":bounds}
	removal.make_read_only()
	return {"status":"ready", "removal":removal}

func _acknowledge_tree_section_install(source_id: String, site_id: String, member_id: String) -> Dictionary:
	var authority := _current_tree_member_artifact_authority(site_id, member_id)
	if authority.get("status") != "ready": return authority
	var roster: Dictionary = _geometry_owner_rosters.get(source_id, {})
	var owner: Variant = _geometry_completion_owner.get_ref() if _geometry_completion_owner != null else null
	if not is_instance_valid(owner) or roster.is_empty():
		return {"status":"pending", "reason":"citadel_tree_geometry_roster_pending"}
	var current := _geometry_owner_roster_is_current(source_id, roster, {})
	if current.get("status") != "ready": return current
	var completion := _request_citadel_geometry_owner_completion(owner, roster,
		_geometry_owner_prior_rosters.get(source_id, []))
	if completion.get("status") != "ready": return completion
	var receipts_current := _geometry_owner_completion_receipts_are_current(
		owner, roster, completion)
	if receipts_current.get("status") != "ready": return receipts_current
	var sections: Array[Vector3i] = []
	for section_value: Variant in completion.get("ownerSections", []):
		if not section_value is Vector3i:
			return {"status":"pending", "reason":"citadel_tree_owner_section_invalid",
				"retryable":true}
		sections.append(section_value)
	var receipts: Dictionary = completion.get("receiptsBySection", {})
	for section: Vector3i in sections:
		var receipt: Dictionary = receipts.get(section, {})
		var proof: Dictionary = _section_install_acknowledgements.get(section, {})
		if proof.get("sourceRevisions", {}).get(source_id) != roster.sourceRevision \
				or proof.get("receipt", {}) != receipt:
			return {"status":"pending", "reason":"citadel_tree_owner_receipt_pending", "sectionKey":section}
	var final_authority := _current_tree_member_artifact_authority(site_id, member_id)
	if final_authority.get("status") != "ready" \
			or final_authority.get("binding") != authority.get("binding") \
			or final_authority.get("jobInstanceId") != authority.get("jobInstanceId") \
			or final_authority.get("artifactAuthorityRevision") \
				!= authority.get("artifactAuthorityRevision") \
			or _geometry_owner_roster_is_current(source_id, roster, {}).get("status") != "ready":
		return {"status":"pending", "reason":"citadel_tree_owner_changed_before_retirement",
			"retryable":true}
	var captured: Dictionary = authority.capture
	var producer: Dictionary = captured.producer
	var queue_reference: Variant = producer.get("queue")
	var queue: Variant = queue_reference.get_ref() if queue_reference is WeakRef else null
	if not is_instance_valid(queue) or queue.get_instance_id() != producer.get("queueInstanceId"):
		return {"status":"pending", "reason":"citadel_tree_queue_owner_changed"}
	var alias_binding := {"job":weakref(authority.job), "jobInstanceId":authority.job.get_instance_id(),
		"binding":authority.binding, "memberId":member_id, "sourceId":source_id,
		"admittedTreeRecord":captured.admittedTreeRecord, "bodyInstanceId":producer.bodyInstanceId,
		"producerSourceId":producer.producerSourceId, "producerRevision":producer.producerRevision,
		"compiledSourceRevision":producer.compiledSourceRevision}
	alias_binding.make_read_only()
	var result: Dictionary = queue.call("acknowledge_prepared_tree_section_install", source_id,
		String(roster.sourceRevision), sections, receipts, alias_binding)
	if result.get("status") == "acknowledged": _geometry_owner_prior_rosters.erase(source_id)
	return result

func _geometry_owner_roster_is_current(source_id: String, roster: Dictionary, removal: Dictionary) -> Dictionary:
	if not _owner_snapshot_active(): return _capture_geometry_owner_roster_currentness(source_id, roster, removal)
	var values := _owner_snapshot_bucket("rosterCurrentness")
	var key := var_to_str([source_id, roster.get("digest", ""), removal])
	var previous: Dictionary = values.get(key, {})
	if not previous.is_empty() and previous.roster == roster: return previous.result
	var result := _capture_geometry_owner_roster_currentness(source_id, roster, removal)
	if result.get("status") == "ready":
		var sealed := result.duplicate(false)
		sealed.make_read_only()
		values[key] = {"roster":roster, "result":sealed}
		return sealed
	return result

func _capture_geometry_owner_roster_currentness(source_id: String, roster: Dictionary, removal: Dictionary) -> Dictionary:
	var proof: Dictionary = _geometry_owner_capture_proofs.get(source_id, {})
	if proof.get("kind") == "tree":
		var current_tree := _current_tree_member_artifact_authority(String(proof.get("siteId", "")), String(proof.get("memberId", "")))
		if bool(roster.get("explicitRemoval", false)):
			if not OwnerCompletion.validate(roster) or current_tree.get("status") != "absent" \
					or current_tree.get("reason") != "removed_prop" \
					or current_tree.get("binding") != proof.get("binding") \
					or current_tree.get("jobInstanceId") != proof.get("jobInstanceId"):
				return {"status":"pending", "reason":"citadel_tree_removal_owner_changed"}
			return {"status":"ready", "roster":roster}
		if current_tree.get("status") != "ready": return current_tree
		if not OwnerCompletion.validate(roster) or current_tree.binding != proof.get("binding") \
				or current_tree.job.get_instance_id() != proof.get("jobInstanceId") \
				or current_tree.artifactAuthorityRevision != proof.get("authorityRevision"):
			return {"status":"pending", "reason":"citadel_tree_geometry_owner_changed"}
		return {"status":"ready", "roster":roster}
	var reference: WeakRef = proof.get("publisher")
	var publisher: Object = reference.get_ref() if reference != null else null
	if not is_instance_valid(publisher) or publisher.get_instance_id() != int(proof.get("publisherId", 0)):
		return {"status":"pending", "reason":"citadel_geometry_owner_publisher_changed"}
	var current := _current_transform_artifact_publisher_for_member(String(proof.get("siteId", "")), _proof_transform_member(proof))
	if current.get("status") != "ready" or current.get("publisher") != publisher \
			or current.get("binding") != proof.get("binding") or current.get("sourceToWorld") != proof.get("sourceToWorld") \
			or current.get("sceneJobInstanceId", 0) != proof.get("sceneJobInstanceId", 0):
		return {"status":"pending", "reason":"citadel_geometry_owner_incarnation_changed"}
	if bool(roster.get("explicitRemoval", false)):
		if not OwnerCompletion.validate(roster): return {"status":"pending", "reason":"citadel_removal_roster_invalid"}
		var previous_owners: Array[Vector3i] = []
		for previous: Dictionary in _geometry_owner_prior_rosters.get(source_id, []):
			for section: Vector3i in OwnerCompletion.owner_sections(previous):
				if section not in previous_owners: previous_owners.append(section)
		for member: Dictionary in proof.get("presentationMembers", []) + proof.get("priorPresentationMembers", []):
			var section := SectionGrid.key_for_world_position(member.neutralParentToWorld.origin)
			if section not in previous_owners: previous_owners.append(section)
		if previous_owners.is_empty(): return {"status":"pending", "reason":"citadel_geometry_owner_prior_members_missing"}
		for section: Vector3i in previous_owners:
			var retained := _current_roster_removal(String(roster.worldId), source_id, section)
			if retained.get("status") != "ready" or retained.get("removal", {}).get("sourceRevision") != roster.sourceRevision:
				return {"status":"pending", "reason":"citadel_geometry_owner_explicit_removal_missing"}
		return {"status":"ready", "roster":roster}
	var part_id := String(proof.get("partId", ""))
	var visual_identity: Dictionary = publisher.committed_static_visual_source_identity(part_id)
	if visual_identity.get("status") != "ready" or visual_identity != proof.get("visualSourceReceipt", {}):
		return {"status":"pending", "reason":"citadel_geometry_owner_member_binding_changed"}
	var sections := OwnerCompletion.owner_sections(roster)
	if sections.is_empty(): return {"status":"pending", "reason":"citadel_geometry_owner_prior_members_missing"}
	var capture: Dictionary = _capture_owner_source_snapshot(publisher, part_id, String(proof.memberBinding))
	if capture.get("status") != "ready" or _geometry_capture_identity(capture) != proof.get("captureIdentity"):
		return {"status":"pending", "reason":"citadel_geometry_owner_full_capture_changed"}
	if _section_ack_census_proves_source_current(source_id, roster):
		_count_section_ack_work("ownerCurrentnessFastPath")
		return {"status":"ready", "roster":roster}
	var census_started := Time.get_ticks_usec()
	var census: Dictionary = capture_static_section_sources(String(roster.worldId), sections)
	_record_section_ack_phase("ownerCurrentnessFullCensus", census_started,
		"ownerCurrentnessFullCensusCount", 1)
	if census.get("status") != "complete": return census
	var revision := String(census.get("sourceRevisions", {}).get(source_id, ""))
	if not removal.is_empty() and revision.is_empty():
		var tombstone_revision := String(removal.get("sourceRevision", ""))
		for section: Vector3i in sections:
			var found := false
			for row: Dictionary in census.get("removalsBySection", {}).get(section, []):
				if row.get("sourceId") == source_id and row.get("sourceRevision") == tombstone_revision \
						and row.get("memberBinding") == removal.get("memberBinding") \
						and row.get("ownerBindingDigest") == removal.get("ownerBindingDigest"): found = true
			if not found: return {"status":"pending", "reason":"citadel_geometry_owner_explicit_removal_missing"}
		var empty := OwnerCompletion.seal(String(roster.worldId), source_id, source_id,
			tombstone_revision, String(roster.sourceIncarnation), [], true)
		return {"status":"ready", "roster":empty.roster} if empty.get("status") == "ready" else empty
	if revision != roster.sourceRevision:
		return {"status":"pending", "reason":"citadel_geometry_owner_authority_revision_changed"}
	return {"status":"ready", "roster":roster}


func _section_ack_census_proves_source_current(source_id: String,
		roster: Dictionary) -> bool:
	if _section_ack_currentness_scope.is_empty() \
			or int(_section_ack_currentness_scope.get("generation", -1)) != _generation:
		return false
	var current: Variant = _section_ack_currentness_scope.get("current", {})
	var section_value: Variant = _section_ack_currentness_scope.get("sectionKey", null)
	if not current is Dictionary or current.get("status") != "complete" \
			or current.get("worldId") != roster.get("worldId") \
			or not section_value is Vector3i:
		return false
	var section_key: Vector3i = section_value
	var row: Dictionary = current.get("sections", {}).get(section_key, {})
	if row.is_empty() or source_id not in row.get("sourcePartIds", []):
		return false
	return String(current.get("sourceRevisions", {}).get(source_id, "")) \
		== String(roster.get("sourceRevision", ""))




## A previously hidden legacy visual is the retained fallback while any section
## in its bounds has stale or missing current installation proof.
func _citadel_visual_retirement_pending(visual: GeometryInstance3D,
		reason: String, details := {}) -> Dictionary:
	if is_instance_valid(visual) and not visual.is_queued_for_deletion() \
			and bool(visual.get_meta("citadel_section_owned", false)):
		_restore_legacy_visual_if_unclaimed(visual)
	var result: Dictionary = details.duplicate(false)
	result["status"] = "pending"
	result["reason"] = reason
	return result


## Reconcile old section-owned visuals while preparing their replacement. This
## makes a retired representation visible again as soon as its owner receipt,
## source revision, or intersected-section closure is no longer current.
static func _native_legacy_claim(visual: GeometryInstance3D) -> Dictionary:
	var backend_id := int(visual.get_meta("section_attachment_native_backend_id", 0))
	if backend_id <= 0 or not is_instance_id_valid(backend_id): return {}
	var backend := instance_from_id(backend_id)
	if not is_instance_valid(backend) or not backend.has_method("legacy_visual_state"): return {}
	var claim: Dictionary = backend.call("legacy_visual_state", visual.get_instance_id())
	return {"backend":backend, "claim":claim}


static func _legacy_has_section_ownership(visual: GeometryInstance3D) -> bool:
	if bool(visual.get_meta("citadel_section_owned", false)): return true
	var native := _native_legacy_claim(visual)
	return native.get("claim", {}).get("status") in ["pending_presentation", "installed", "retained_previous", "retained_suppressed", "stale"]


static func _restore_legacy_visual_if_unclaimed(visual: GeometryInstance3D) -> void:
	var native := _native_legacy_claim(visual)
	var status := String(native.get("claim", {}).get("status", "unowned"))
	# Pending presentation is real ownership, but never an owner-completion ACK.
	if status in ["pending_presentation", "installed", "retained_previous", "retained_suppressed"]: return
	if status == "stale":
		# Native withdraws the complete bundle before restoring exact surviving IDs.
		# Never expose one legacy child alongside its still-visible replacement.
		native.backend.call("restore_legacy_for_visual", visual.get_instance_id())
		return
	if _native_restoration_receipt_is_current(visual): return
	visual.visible = true


## Evidence of a completed native visibility operation only. This never grants
## section readiness or an installed geometry receipt.
static func _native_restoration_receipt_is_current(visual: GeometryInstance3D) -> bool:
	const RECEIPT_META := "section_attachment_legacy_restoration_receipt"
	if not is_instance_valid(visual) or not visual.has_meta(RECEIPT_META): return false
	var value: Variant = visual.get_meta(RECEIPT_META)
	if not value is Dictionary or not value.is_read_only() \
			or value.get("visualInstanceId") != visual.get_instance_id() \
			or visual.get_parent() == null \
			or value.get("parentInstanceId") != visual.get_parent().get_instance_id() \
			or not value.get("originalVisible") is bool \
			or visual.visible != value.originalVisible:
		return false
	var body_id := int(value.get("bodyInstanceId", 0))
	if not is_instance_id_valid(body_id): return false
	var body := instance_from_id(body_id) as Node3D
	if not is_instance_valid(body) or body.is_queued_for_deletion() \
			or not body.has_meta("section_attachment_publisher_instance_id") \
			or not body.has_meta("section_attachment_publication_epoch") \
			or not body.has_meta("section_attachment_source_revision"):
		return false
	return is_instance_valid(body) and not body.is_queued_for_deletion() \
		and body.is_ancestor_of(visual) \
		and value.get("publisherInstanceId") == body.get_meta("section_attachment_publisher_instance_id") \
		and value.get("publicationEpoch") == body.get_meta("section_attachment_publication_epoch") \
		and value.get("producerSourceRevision") == body.get_meta("section_attachment_source_revision")


func _restore_stale_citadel_visuals(publisher, site_id: String,
		member_id: String) -> void:
	if publisher == null or not is_instance_valid(publisher) \
			or not _publisher_node_roster_available(publisher):
		return
	var part_id := _transform_part_id(member_id)
	for visual_value: Variant in _published_legacy_geometry(publisher):
		var visual := visual_value as GeometryInstance3D
		if not is_instance_valid(visual) or not visual.is_inside_tree() \
				or visual.is_queued_for_deletion() \
				or not bool(visual.get_meta("citadel_section_owned", false)) \
				or String(visual.get_meta("building_source_part_id", "")) != part_id:
			continue
		_retire_citadel_visual_if_section_coverage_is_live(visual, site_id, member_id)


func _valid_citadel_section_receipt(world_id: String, section_key: Vector3i,
		authority_revision: String, coverage_revision: String,
		receipt: Dictionary) -> bool:
	if receipt.is_empty() or not receipt.is_read_only() \
			or receipt.get("status") != "installed" \
			or String(receipt.get("worldId", "")) != world_id \
			or receipt.get("sectionKey") != section_key \
			or int(receipt.get("generation", 0)) <= 0 \
			or String(receipt.get("contentManifestDigest", "")).length() != 64 \
			or int(receipt.get("backendInstanceId", 0)) <= 0 \
			or int(receipt.get("chunkInstanceId", 0)) <= 0 \
			or receipt.get("ownerCell") != SectionGrid.chunk_key_for_section(section_key):
		return false
	var provider_coverage: Variant = receipt.get("providerCoverage", [])
	if not provider_coverage is Array:
		return false
	var has_current_citadel_coverage: bool = false
	for entry_value: Variant in provider_coverage:
		if not entry_value is Array or entry_value.size() < 3:
			continue
		var entry: Array = entry_value
		if String(entry[0]) == "blueprint_buildings" \
				and String(entry[1]) == coverage_revision \
				and String(entry[2]) == authority_revision:
			has_current_citadel_coverage = true
			break
	if not has_current_citadel_coverage:
		return false
	var owner_cell := SectionGrid.chunk_key_for_section(section_key)
	var owner: Dictionary = SectionPacketOwner.resolve_existing_static_section_backend(owner_cell)
	if owner.get("status") != "ready":
		return false
	var backend := owner.get("backend") as Node
	var chunk := owner.get("chunk") as Node3D
	if not is_instance_valid(backend) or not is_instance_valid(chunk) \
			or backend.get_instance_id() != int(receipt.backendInstanceId) \
			or chunk.get_instance_id() != int(receipt.chunkInstanceId) \
			or not backend.has_method("installed_snapshot") \
			or not backend.has_method("receipt_installed"):
		return false
	var generation := int(receipt.generation)
	var source_id := SectionInstallSession.slot_id(world_id, section_key)
	var installed: Dictionary = backend.call("installed_snapshot", source_id)
	if installed.get("status") != "ready" \
			or int(installed.get("generation", 0)) != generation \
			or installed.get("ownerCell") != owner_cell \
			or String(installed.get("packetDigest", "")) \
			!= String(receipt.contentManifestDigest):
		return false
	var source_revision := String(installed.get("sourceRevision", ""))
	return not source_revision.is_empty() \
		and bool(backend.call("receipt_installed", source_id, generation,
			source_revision, String(receipt.contentManifestDigest)))


static func _citadel_census_source_id(site_id: String, member_id: String,
		_section_key: Vector3i = Vector3i.ZERO) -> String:
	# World identity is carried by the census; a member keeps the same identity
	# in every section intersected by its geometry.
	return "citadel:%s:member:%s" % [site_id, member_id]


func _current_packet_publisher_for_site(site_id: String) -> Dictionary:
	var match_region := Vector2i.ZERO
	var match_entry: Dictionary = {}
	for region: Vector2i in _scenes:
		var entry: Dictionary = _scenes[region]
		if String(entry.get("binding", {}).get("siteId", "")) != site_id:
			continue
		if not match_entry.is_empty():
			return {"status":"pending", "reason":"citadel_site_has_multiple_scene_owners",
				"siteId":site_id, "retryable":true}
		match_region = region
		match_entry = entry
	if match_entry.is_empty():
		return {"status":"pending", "reason":"citadel_packet_scene_owner_unavailable",
			"siteId":site_id, "retryable":true}
	if not bool(match_entry.get("packetMode", false)) \
			or match_entry.get("phase") != "scene_ready":
		return {"status":"pending", "reason":"citadel_packet_scene_not_ready",
			"siteId":site_id, "phase":match_entry.get("phase"), "retryable":true}
	var current: Dictionary = _admission.source_state(match_region)
	if current.get("status") not in ["ready", "prepared"] \
			or current.get("binding", {}) != match_entry.get("binding", {}):
		return {"status":"pending", "reason":"citadel_packet_scene_binding_stale",
			"siteId":site_id, "retryable":true}
	var job = match_entry.get("job")
	var publisher = job.get("_building") if job != null else null
	if publisher == null or not is_instance_valid(publisher) \
			or String(publisher.get("publication_site_id")) != site_id:
		return {"status":"pending", "reason":"citadel_building_packet_publisher_unavailable",
			"siteId":site_id, "retryable":true}
	if publisher.has_pending_static_flush() \
			or not publisher.get("_chunk_static_packet_pending_expected").is_empty():
		return {"status":"pending", "reason":"citadel_static_packet_flush_pending",
			"siteId":site_id, "retryable":true}
	var profile = match_entry.get("profile")
	if profile == null or not profile.get("origin") is Vector3 \
			or not profile.origin.is_finite():
		return {"status":"pending", "reason":"citadel_packet_root_transform_unavailable",
			"siteId":site_id, "retryable":true}
	return {"status":"ready", "publisher":publisher, "region":match_region,
		"binding":match_entry.binding,
		"sourceToWorld":Transform3D(Basis.IDENTITY, profile.origin)}


static func _seed_hash(value: String) -> int:
	var result := 2166136261
	for index in value.length():
		result = int((result ^ value.unicode_at(index)) * 16777619) & 0xffffffff
	return result

## Camera intent is scheduling state, not spatial/source ownership. Applying it
## must not replay the immutable source manifest or invalidate the currently
## retained packet transaction. The newest view is consumed when that bounded
## window completes and the job asks for its next window.
func set_retained_view_intents(values: Array) -> bool:
	if _closing or values.size()>MAX_RETAINED_BOUNDS: return false
	var by_owner: Dictionary = {}
	for value in values:
		if not value is Dictionary or not value.get("ownerId") is int or int(value.ownerId)<=0 \
				or by_owner.has(int(value.ownerId)) or not value.get("viewIntent",{}) is Dictionary:
			return false
		var raw: Dictionary = value.get("viewIntent",{})
		var normalized: Dictionary = ViewPriority.normalize(raw)
		if not raw.is_empty() and normalized.is_empty(): return false
		by_owner[int(value.ownerId)] = normalized
	var changed := false
	for consumer: Dictionary in _retained_consumers:
		var owner_id := int(consumer.ownerId)
		if not by_owner.has(owner_id): continue
		var next: Dictionary = by_owner[owner_id]
		if consumer.get("viewIntent",{}) == next: continue
		if next.is_empty(): consumer.erase("viewIntent")
		else: consumer["viewIntent"] = next
		changed = true
	if changed: _view_revision += 1
	return true

func _clear_retained_priorities() -> void:
	_retained_navigation_priorities = {}
	_retained_binding_priorities = {}
	_retained_discovery_priorities = {}

static func _priority_binding_key(binding: Dictionary) -> String:
	return JSON.stringify([binding.get("siteId",""),binding.get("sourceKey",""),binding.get("generation",0)])

func _navigation_priority(key: String) -> int:
	return int(_retained_navigation_priorities.get(key,4))

func _preparation_priority(region: Vector2i, source: Dictionary) -> int:
	var priority: int = int(_retained_binding_priorities.get(_priority_binding_key(source.binding),4))
	for key: Vector2i in _retained_discovery_priorities.get(region,{}):
		if source.reservationCells.intersects(Rect2i(key*DISCOVERY_CHUNK_SIZE,Vector2i.ONE*DISCOVERY_CHUNK_SIZE)):
			priority = mini(priority,int(_retained_discovery_priorities[region][key]))
	return priority

static func _bounded_region_rectangle(bounds: Rect2i) -> bool:
	# Use Admission's cell domain before computing end (Vector2i can overflow).
	if not Admission._valid_bounds(bounds): return false
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end - Vector2i.ONE)
	return (high.x-low.x+1)*(high.y-low.y+1) <= MAX_REGIONS


func advance_legacy_visual_inventory(max_nodes := 96,
		budget_usec := LegacyVisualIndex.DEFAULT_ADVANCE_USEC) -> Dictionary:
	return _legacy_visual_section_index.advance(max_nodes, budget_usec)

func advance(observer_bounds: Rect2i = Rect2i(), allow_dispatch := false, budget_usec := 2500) -> Dictionary:
	if budget_usec<1 or budget_usec>4000: return {"status":"rejected","reason":"invalid_slice_budget"}
	if _advancing: return {"status":"rejected","reason":"reentrant_advance"}
	_advancing=true
	var started := Time.get_ticks_usec()
	if _admission != null and int(_admission.stats().generation) != _generation:
		configure(_admission)
	_advance_owner_section_slice_jobs(mini(OWNER_SECTION_SLICE_ADVANCE_BUDGET_USEC,
		budget_usec))
	_advance_pending_section_source_retirements(
		MAX_SECTION_SOURCE_RETIREMENTS_PER_ADVANCE,
		mini(SECTION_SOURCE_RETIREMENT_ADVANCE_BUDGET_USEC, budget_usec))
	advance_legacy_visual_inventory(96,
		mini(LegacyVisualIndex.MAX_ADVANCE_USEC, budget_usec))
	var configuration:=_configuration_serial
	var demand_revision := _demand_revision
	allow_dispatch = allow_dispatch and not _world_reset_pending
	# Draining is independent of native/current-generation readiness. Retired
	# payloads were relinquished by prior calls before the worker starts disposal.
	if _submitted_scene_disposals.is_empty() and not _retired.is_empty() and _worker.retire_external_payload(_retired):
		_retired = {}
		_submitted_scene_disposals=_pending_scene_disposals
		_pending_scene_disposals={}
	var ready: Dictionary = {}
	if allow_dispatch and not _closing and _admission != null:
		ready = _refresh_demand(observer_bounds)
		_prune_unwanted(ready)
		# `_refresh_demand` may advance the observer's closure revision.  That
		# revised demand is already fully owned by this call, so it may dispatch
		# immediately; only later reentrant changes must invalidate this slice.
		demand_revision = _demand_revision
	_prune_invalid_scenes()
	_last_worker_status = _worker.poll()
	_worker_polled_configuration = _configuration_serial
	_prune_invalid_descriptions()
	_collect_description(ready,allow_dispatch and not _closing)
	# A tile can become physically ready while a lower-priority packet owns the
	# only worker. Give its immutable navigation source the next idle slot before
	# scene publication selects another retained background packet.
	if allow_dispatch and _inflight.is_empty(): _dispatch_pending_packet_navigation()
	# The exclusively owned external batch has been accepted; idle with no
	# pending retirement proves its worker disposal/join completed, not merely
	# that scene nodes disappeared. Failed thread starts retain pending claims.
	if not _submitted_scene_disposals.is_empty() and not _last_worker_status.get("busy",true) and not _last_worker_status.get("retirementPending",true):
		_submitted_scene_disposals={}
	_collect(ready, allow_dispatch and not _closing)
	if not _inflight.is_empty() and bool(_last_worker_status.get("workerRunning",false)) \
			and _last_worker_status.get("workerKind") == "preparation":
		var progress: Dictionary = _last_worker_status.get("progress",{})
		if int(progress.get("elapsedUsec",0)) > PREPARATION_TIMEOUT_USEC:
			_failures[_inflight.region] = {"binding":_inflight.binding,"reason":"building_preparation_timeout"}
			_worker.cancel(int(_inflight.token))
			_retire_description(_inflight.region)
			_inflight = {}
	_pump_scenes(ready,allow_dispatch and not _closing,started,budget_usec)
	if _world_reset_release_requested and world_reset_ready():
		_world_reset_pending = false
		_world_reset_release_requested = false
	if allow_dispatch and not _closing and configuration==_configuration_serial and demand_revision==_demand_revision and _retired.is_empty() and _inflight.is_empty():
		# Dispatch has now transferred the mutable producer out of the service
		# entry. Start that queued worker on this same owner advance instead of
		# leaving a known-safe batch idle until a later frame.
		if _dispatch(ready,observer_bounds.get_center()):
			_last_worker_status = _worker.poll()
			_worker_polled_configuration = _configuration_serial
	_max_advance_usec = maxi(_max_advance_usec,Time.get_ticks_usec()-started)
	_advancing=false
	return stats()

func _refresh_demand(bounds: Rect2i) -> Dictionary:
	var desired := {}
	var ready := {}
	_observer_bounds_rejected = bounds != Rect2i() and not _bounded_region_rectangle(bounds)
	# Rejected samples are not departure. Empty explicitly releases the observer.
	if not _observer_bounds_rejected and _observer_region_bounds != bounds:
		_observer_region_bounds = bounds
		# A foreground observer move can change the exact physical closure even
		# when its retained source set is unchanged.  Re-evaluate packet demand on
		# the next owner slice; do not strand a resident packet scene on the old
		# empty closure.
		_demand_revision += 1
	_prefetch_regions = _prefetch_regions_for_views()
	var now_usec := Time.get_ticks_usec()
	for region: Vector2i in _prefetch_regions:
		if not _prefetch_started_usec.has(region): _prefetch_started_usec[region]=now_usec
	_prefetch_rejected = _admission==null or not _admission.set_prefetch_regions(_prefetch_regions)
	var rectangles: Array[Rect2i] = _retained_region_bounds.duplicate()
	if _observer_region_bounds != Rect2i(): rectangles.append(_observer_region_bounds)
	# Original consumer discovery is an exact union of at most256 chunks; the
	# older explicit rectangle API remains bounded at64 rectangles. Never fill
	# gaps or truncate to the resident cap: pending sources remain retained.
	var region_bounds := {}
	for rectangle: Rect2i in rectangles:
		var low := Field.region_for_cell(rectangle.position)
		var high := Field.region_for_cell(rectangle.end-Vector2i.ONE)
		for z in range(low.y,high.y+1):
			for x in range(low.x,high.x+1):
				var region := Vector2i(x,z)
				if not region_bounds.has(region): region_bounds[region] = []
				if not region_bounds[region].has(rectangle): region_bounds[region].append(rectangle)
	for region: Vector2i in region_bounds:
		var candidate: Dictionary = Field.candidate_for_region(_seed,region)
		if candidate.is_empty(): continue
		var influence: Rect2i = Admission.declared_influence(candidate)
		var matching: Array[Rect2i] = []
		for rectangle: Rect2i in region_bounds[region]:
			if influence.intersects(rectangle): matching.append(rectangle)
		if matching.is_empty(): continue
		var source: Dictionary = _admission.source_state(region)
		# A retained gameplay window is durable physical demand.  Camera prefetch
		# may prepare a different, view-ranked region, but it must never be the
		# sole path that starts the exact region whose declared influence the
		# player now occupies.  Promotion happens through the existing admission
		# owner and is retained across later view reversals.
		if source.get("status") not in ["ready", "prepared"]:
			_admission.request_bounds(matching.front(), true)
			desired[region] = true
			continue
		if source.get("status") in ["ready","prepared"]:
			var intersects := false
			for rectangle: Rect2i in matching:
				if source.reservationCells.intersects(rectangle):
					intersects = true
					break
			if not intersects or not _current_binding(source.binding): continue
			# Conservative influence overlap starts/reuses source preparation.  The
			# player-facing demand clock begins only when the exact accepted
			# reservation enters an ordinary retained window.  Keeping these clocks
			# separate makes prefetch lead measurable instead of charging speculative
			# recipe time to visible publication latency.
			if not _demand_started_usec.has(region): _demand_started_usec[region]=now_usec
			ready[region] = source
			if source.status == "prepared" and not _prepared.has(region) and not _scenes.has(region) and not _region_retiring(region) and not _failures.has(region) \
					and (_inflight.is_empty() or _inflight.region != region):
				_admission.request_source(region,true)
		desired[region] = true
	# A completed speculative source can also prepare its compact publication
	# base while it is still ahead of the player.  It is deliberately not added
	# to desired: reversing the view removes it from ready on the next slice and
	# retires/cancels only this speculative publication work.  Exact observer or
	# retained-site overlap remains the sole start of player-facing demand time.
	for region: Vector2i in _prefetch_regions:
		if ready.has(region): continue
		var source: Dictionary = _admission.source_state(region)
		if source.get("status") == "ready" and _current_binding(source.binding):
			ready[region] = source
	_desired = desired
	return ready

func _current_binding(binding: Dictionary) -> bool:
	return int(binding.get("generation",-1)) == _generation \
		and String(_admission.stats().worldSeed) == _seed


## Select at most two deterministic candidate regions intersecting the current
## view corridor. Reversing before real demand cancels only speculative work;
## a promoted physical request remains owned by ordinary admission.
func _prefetch_regions_for_views() -> Array[Vector2i]:
	var rows: Array[Dictionary] = []
	var seen: Dictionary = {}
	for consumer: Dictionary in _retained_consumers:
		var view: Dictionary = ViewPriority.normalize(consumer.get("viewIntent",{}))
		if view.is_empty(): continue
		var origin: Vector3 = view.origin
		var forward: Vector3 = view.forward
		var finish := origin+forward*SOURCE_PREFETCH_LOOKAHEAD_METERS
		var low_cell := Vector2i(floori(minf(origin.x,finish.x)/SitePreparation.CELL),
			floori(minf(origin.z,finish.z)/SitePreparation.CELL))-Vector2i.ONE*SitePreparation.MAX_INFLUENCE_RADIUS_CELLS
		var high_cell := Vector2i(ceili(maxf(origin.x,finish.x)/SitePreparation.CELL),
			ceili(maxf(origin.z,finish.z)/SitePreparation.CELL))+Vector2i.ONE*SitePreparation.MAX_INFLUENCE_RADIUS_CELLS
		var low_region := Field.region_for_cell(low_cell)
		var high_region := Field.region_for_cell(high_cell)
		if (high_region.x-low_region.x+1)*(high_region.y-low_region.y+1)>16: continue
		for z: int in range(low_region.y,high_region.y+1):
			for x: int in range(low_region.x,high_region.x+1):
				var region := Vector2i(x,z)
				if seen.has(region): continue
				var candidate: Dictionary = Field.candidate_for_region(_seed,region)
				if candidate.is_empty(): continue
				var center_cell: Vector2i = candidate.centerCell
				var center := Vector3(float(center_cell.x)*SitePreparation.CELL,origin.y,float(center_cell.y)*SitePreparation.CELL)
				var delta := center-origin
				var depth := Vector3(delta.x,0.0,delta.z).dot(forward)
				if depth < -SOURCE_PREFETCH_LATERAL_METERS or depth > SOURCE_PREFETCH_LOOKAHEAD_METERS+SOURCE_PREFETCH_LATERAL_METERS: continue
				var closest := origin+forward*clampf(depth,0.0,SOURCE_PREFETCH_LOOKAHEAD_METERS)
				var lateral := Vector2(center.x-closest.x,center.z-closest.z).length()
				if lateral>SOURCE_PREFETCH_LATERAL_METERS: continue
				seen[region]=true
				rows.append({"region":region,"depth":maxf(0.0,depth),"lateral":lateral,"siteId":String(candidate.siteId)})
	rows.sort_custom(func(a: Dictionary,b: Dictionary):
		if not is_equal_approx(float(a.depth),float(b.depth)): return float(a.depth)<float(b.depth)
		if not is_equal_approx(float(a.lateral),float(b.lateral)): return float(a.lateral)<float(b.lateral)
		return String(a.siteId)<String(b.siteId))
	var result: Array[Vector2i] = []
	for row: Dictionary in rows:
		result.append(row.region)
		if result.size()>=Admission.MAX_PREFETCH_REGIONS: break
	return result

func _prune_unwanted(ready: Dictionary) -> void:
	for region: Vector2i in _navigation.keys():
		if not ready.has(region) or ready[region].binding != _navigation[region].binding:
			_retire(_navigation[region])
			_navigation.erase(region)
	for region: Vector2i in _packet_bootstrap_bases.keys():
		if not ready.has(region) or ready[region].binding != _packet_bootstrap_bases[region].binding:
			_retire(_packet_bootstrap_bases[region])
			_packet_bootstrap_bases.erase(region)
	for region: Vector2i in _described.keys():
		if not ready.has(region) or ready[region].binding != _described[region].binding:
			_retire_description(region)
	for region: Vector2i in _scenes.keys():
		# Ahead prefetch may retain the compact immutable description/base, but it
		# cannot pin live nodes, colliders, doors or interaction registrations once
		# exact retained demand expires. `_desired` includes coordinator hysteresis,
		# so ordinary reversals still keep the accepted scene for the grace window.
		if not _desired.has(region) or not ready.has(region) or ready[region].binding != _scenes[region].binding:
			_retire_scene(region)
	for region: Vector2i in _prepared.keys():
		# A scene-ready payload is heavier than the reusable speculative base and
		# owns callbacks that only exact demand may activate.
		if not _desired.has(region) or not ready.has(region) or ready[region].binding != _prepared[region].binding:
			_retire(_prepared[region])
			_prepared.erase(region)
	for region: Vector2i in _failures.keys():
		if not _desired.has(region) or ready.has(region) and ready[region].binding != _failures[region].binding:
			_failures.erase(region)
	if not _inflight.is_empty() and (not ready.has(_inflight.region) \
			or ready[_inflight.region].binding != _inflight.binding):
		_worker.cancel(int(_inflight.token))
		_inflight = {}

func _retire_description(region: Vector2i) -> void:
	if not _described.has(region): return
	_retire(_described[region])
	_described.erase(region)
	_description_serial += 1

func _prune_invalid_descriptions() -> void:
	for region: Vector2i in _described.keys():
		var entry: Dictionary = _described[region]
		var current: Dictionary = _admission.source_state(region) if _admission != null else {}
		if _closing or _world_reset_pending or _failures.has(region) or entry.configuration != _configuration_serial \
				or current.get("status") not in ["ready","prepared"] or current.get("binding",{}) != entry.binding \
				or not _current_binding(entry.binding):
			_retire_description(region)

func _collect_description(ready: Dictionary, allow_accept: bool) -> void:
	if _inflight.is_empty() or not allow_accept or _world_reset_pending: return
	var region: Vector2i = _inflight.region
	if _described.has(region): return
	var current: Dictionary = _admission.source_state(region)
	if not ready.has(region) or current.get("status") not in ["ready","prepared"] \
			or current.get("binding",{}) != _inflight.binding or not _current_binding(_inflight.binding): return
	var transfer: Dictionary = _worker.take_description(int(_inflight.token),current.binding)
	if transfer.get("status") != "described": return
	var profile: Dictionary = transfer.get("profile",{})
	var description = transfer.get("description")
	if description == null or description.binding != current.binding or profile.get("siteId") != current.binding.siteId \
			or profile.get("sourceSignature") != current.sourceSignature or profile.get("origin") != description.origin:
		_retire(transfer)
		return
	_description_serial += 1
	_described[region] = {"binding":current.binding,"profile":profile,"description":description,
		"configuration":_configuration_serial,"serial":_description_serial}

func _collect(ready: Dictionary, allow_accept: bool) -> void:
	if _inflight.is_empty() or not allow_accept: return
	var token := int(_inflight.token)
	if int(_last_worker_status.get("completedToken",0)) != token: return
	var region: Vector2i = _inflight.region
	# Read Admission again after join. A stale profile/source must never be
	# accepted just because its token completed successfully.
	var current: Dictionary = _admission.source_state(region)
	if not ready.has(region) or current.get("status") not in ["ready","prepared"] \
			or current.binding != _inflight.binding or not _current_binding(current.binding):
		_worker.cancel(token)
		_retire_description(region)
		_inflight = {}
		return
	var completion: Dictionary = _worker.take_result(token,current.binding)
	if completion.get("status") != "consumed": return
	var result: Dictionary = completion.get("result",{})
	if _inflight.get("kind")=="publication_base":
		_collect_publication_base(region,current,result)
		return
	if _inflight.get("kind")=="publication_base_navigation":
		_collect_publication_base_navigation(region,current,result)
		return
	if _inflight.get("kind")=="physical_group_packet":
		_collect_physical_group_packet(region,current,result,_inflight.get("transactionId",0))
		return
	if _inflight.get("kind", "preparation") == "navigation":
		_collect_navigation(region,current.binding,result,_inflight.get("tileKeys",[]),_inflight.get("tileOrder",[]))
		_inflight = {}
		return
	var prepared_description = result.prepared.describe(current.binding) if result.get("prepared")!=null else null
	var navigation_source: Dictionary = result.get("navigationSource",{})
	var navigation_matches: bool = navigation_source.is_read_only() and navigation_source.get("binding") is Dictionary \
		and navigation_source.binding.is_read_only() and navigation_source.binding==current.binding \
		and navigation_source.get("producer")!=null
	var domain_matches: bool = navigation_matches and _valid_navigation_domain(navigation_source.get("domain"))
	# Legacy preparation deliberately transfers the compact source description
	# before compiling dense navigation.  The completed PreparedSource therefore
	# owns a distinct descriptor object which shares the compact descriptor's
	# immutable source containers.  Require that provenance rather than object
	# identity, then replace the provisional descriptor below so scene startup
	# consumes the exact dense descriptor held by PreparedSource.
	var early_matches := true
	if _described.has(region):
		var early: Dictionary = _described[region]
		var early_description = early.get("description")
		early_matches = prepared_description!=null and early.get("binding",{})==current.binding and early.get("configuration",-1)==_configuration_serial \
			and early.get("profile",{}).get("sourceSignature","")==current.sourceSignature and early_description!=null \
			and early_description.binding==current.binding and early_description.origin==prepared_description.origin \
			and early_description.source_identity_digest.length()==64 \
			and early_description.source_identity_digest==prepared_description.source_identity_digest
	var description_matches: bool = prepared_description!=null and prepared_description.binding==current.binding \
		and prepared_description.origin==result.get("profile",{}).get("origin") \
		and prepared_description.source_identity_digest.length()==64 and early_matches
	if result.get("ready",false) and description_matches and navigation_matches and domain_matches and result.get("profile",{}).get("siteId") == current.binding.siteId \
			and result.profile.get("sourceSignature") == current.sourceSignature:
		_prepared[region] = {"binding":current.binding.duplicate(),"prepared":result.prepared,"profile":result.profile}
		_navigation[region] = {"binding":navigation_source.binding,"domain":navigation_source.domain,
			"navigationSource":navigation_source,"requested":{},"receipts":{},"activeTileKey":"","producerProgress":{}}
		if not _described.has(region):
			_description_serial += 1
			_described[region] = {"binding":current.binding,"profile":result.profile,"description":prepared_description,
				"configuration":_configuration_serial,"serial":_description_serial}
		else:
			# Keep the early descriptor's serial: its source revision has not changed.
			# Only its completed navigation representation is promoted.
			_described[region].profile = result.profile
			_described[region].description = prepared_description
		_accepted_count += 1
	else:
		_retire_description(region)
		_failures[region] = {"binding":current.binding.duplicate(),"reason":String(result.get("reason","building_preparation_failed"))}
		if result.get("ready",false):
			_failures[region].reason = "stale_prepared_description" if not description_matches else ("navigation_source_missing" if not navigation_matches else ("invalid_navigation_source_domain" if not domain_matches else "stale_prepared_profile"))
			_retire(result)
	_inflight = {}

func _packet_group_ids(binding: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for consumer: Dictionary in _retained_consumers:
		for site: Dictionary in consumer.sites:
			if site.binding!=binding: continue
			for id_value in site.groupIds:
				var id := String(id_value)
				if not id.is_empty() and not ids.has(id): ids.append(id)
	ids.sort()
	return ids

func _packet_requested_for_source(region: Vector2i, binding: Dictionary) -> bool:
	for consumer: Dictionary in _retained_consumers:
		for site: Dictionary in consumer.sites:
			if site.binding==binding and (not site.groupIds.is_empty() or not site.get("foregroundNavigationTileKeys",[]).is_empty()): return true
	return false

## A no-site retained source consumer is the coordinator's first pass before
## it has a description from which to derive group membership.  A view-prefetch
## source uses the same compact-base path, including the narrow frame where the
## ordinary observer has reached its reservation but retained membership has
## not caught up.  Legacy observer-only demand keeps its established lifecycle.
func _packet_bootstrap_requested_for_source(region: Vector2i, source: Dictionary) -> bool:
	var has_view_owner := false
	for consumer: Dictionary in _retained_consumers:
		if not ViewPriority.normalize(consumer.get("viewIntent",{})).is_empty():
			has_view_owner = true
			break
	if has_view_owner and (_prefetch_regions.has(region) or (_prefetch_started_usec.has(region) \
			and _observer_region_bounds.has_area() and source.get("reservationCells") is Rect2i \
			and source.reservationCells.intersects(_observer_region_bounds))): return true
	for consumer: Dictionary in _retained_consumers:
		if not consumer.sites.is_empty(): continue
		if source.reservationCells.intersects(consumer.bounds): return true
	return false

func _retain_packet_bootstrap_base(region: Vector2i, current: Dictionary, base, profile: Dictionary) -> void:
	# Keep the worker's original frozen profile.  The base's internal deep copy
	# deliberately owns only source reconstruction data and does not retain the
	# nested frozen-array contract required by scene admission.
	var immutable_profile: Dictionary = profile
	if not immutable_profile.is_read_only(): return
	_packet_bootstrap_bases[region] = {"binding":current.binding.duplicate(),"base":base,"profile":immutable_profile,
		"configuration":_configuration_serial}
	var description = base.description
	if description==null or description.binding!=current.binding or description.origin!=immutable_profile.get("origin"):
		_retire(_packet_bootstrap_bases[region])
		_packet_bootstrap_bases.erase(region)
		return
	if not _described.has(region):
		_description_serial += 1
		_described[region] = {"binding":current.binding.duplicate(),"profile":immutable_profile,"description":description,
			"configuration":_configuration_serial,"serial":_description_serial}

func _packet_foreground_plan(region: Vector2i, binding: Dictionary, description, base = null,
		completed: Dictionary = {}, include_view_progress := true) -> Dictionary:
	if description==null or description.binding!=binding or not description.publication_groups.get("ready",false):
		return {"status":"pending","reason":"packet_foreground_description_pending"}
	var foreground: Dictionary = {}
	var blocked: Dictionary = {}
	var requests: Array[Dictionary] = []
	var boundary_groups: Dictionary = {}
	var census: Dictionary = base.packet_eligibility if base!=null else {}
	var compact_plan = base.publication_plan if base!=null else null
	if base!=null and census.is_empty():
		census=Preparation.classify_physical_group_packet_eligibility(description.publication_groups,base.building_source,base.furnishing_source)
	var consumers: Array = _retained_consumers.duplicate()
	# The foreground observer is a real owner of immediate loading work, even
	# before the streaming coordinator has rebuilt a retained source-members
	# record after admission.  Describe its exact source closure here; this is
	# scheduling input only.  Packet compilation, scene installation and fresh
	# collision validation remain below this boundary.
	var observer_owned_by_consumer := false
	for retained_consumer: Dictionary in consumers:
		if not retained_consumer.get("bounds") is Rect2i or not retained_consumer.bounds.encloses(_observer_region_bounds): continue
		for retained_site: Dictionary in retained_consumer.sites:
			if retained_site.get("binding",{})==binding and retained_site.has("foregroundGroupIds"):
				observer_owned_by_consumer=true
				break
		if observer_owned_by_consumer: break
	var observer_source: Dictionary = _admission.source_state(region) if _admission!=null else {}
	if not observer_owned_by_consumer and _observer_region_bounds.has_area() and observer_source.get("binding",{})==binding \
			and observer_source.get("reservationCells") is Rect2i and observer_source.reservationCells.intersects(_observer_region_bounds):
		var observer_requirements: Dictionary = compact_plan.physical_group_requirements(_observer_region_bounds) \
			if compact_plan!=null else description.physical_group_requirements(_observer_region_bounds)
		if observer_requirements.get("status")!="described":
			return {"status":observer_requirements.get("status","pending"),"reason":observer_requirements.get("reason","packet_observer_description_pending")}
		consumers.append({"ownerId":"observer:%d,%d,%d,%d" % [_observer_region_bounds.position.x,_observer_region_bounds.position.y,
			_observer_region_bounds.size.x,_observer_region_bounds.size.y],"bounds":_observer_region_bounds,"priority":0,
			"sites":[{"binding":binding,"groupIds":observer_requirements.get("groupIds",[]),
			"foregroundGroupIds":observer_requirements.get("groupIds",[])}]})
	var owner_closure_started := Time.get_ticks_usec()
	var owner_group_ids := 0
	var door_lifecycle_available := _door_callbacks_ready()
	var owner_identity := _packet_owner_demand_identity(consumers,binding,door_lifecycle_available)
	var scene_entry: Dictionary = _scenes.get(region,{})
	var owner_cache: Dictionary = scene_entry.get("packetOwnerPlanCache",{})
	if owner_cache.get("binding",{})==binding and owner_cache.get("identity",[])==owner_identity:
		requests=owner_cache.requests
		blocked=owner_cache.blocked
		boundary_groups=owner_cache.boundaryGroups
		owner_group_ids=int(owner_cache.groupCount)
	else:
		var owner_result: Dictionary = _build_packet_owner_demand(region,binding,description,base,census,
			compact_plan,consumers,door_lifecycle_available)
		if owner_result.get("status")!="ready": return owner_result
		requests=owner_result.requests
		blocked=owner_result.blocked
		boundary_groups=owner_result.boundaryGroups
		owner_group_ids=int(owner_result.groupCount)
		if not scene_entry.is_empty():
			scene_entry["packetOwnerPlanCache"]={"binding":binding,"identity":owner_identity,
				"requests":requests,"blocked":blocked,"boundaryGroups":boundary_groups,"groupCount":owner_group_ids}
	_record_scene_unit("demand_owner_closure",owner_closure_started,owner_group_ids)
	var view_window_started := Time.get_ticks_usec()
	var window: Dictionary = _bounded_packet_view_window(description,base,census,consumers,requests,completed,include_view_progress)
	_record_scene_unit("demand_view_window_total",view_window_started,description.publication_groups.groups.size())
	if window.get("status")!="ready": return window
	var blocked_ids: Array[String] = []
	for id: String in blocked:
		blocked_ids.append(id)
	blocked_ids.sort()
	var boundary_ids: Array = boundary_groups.keys()
	boundary_ids.sort()
	for id: String in window.get("blockedGroupIds",[]):
		if not blocked_ids.has(id): blocked_ids.append(id)
	blocked_ids.sort()
	var explicit_deferred: Array[String] = []
	for id: String in window.deferredGroupIds: explicit_deferred.append(id)
	for id: String in blocked_ids:
		if not explicit_deferred.has(id): explicit_deferred.append(id)
	explicit_deferred.sort()
	return {"status":"ready","requests":window.requests,"deferredGroupIds":explicit_deferred,
		"foregroundGroupIds":window.foregroundGroupIds,"readinessGroupIds":window.readinessGroupIds,
		"viewPrioritizedGroupIds":window.viewPrioritizedGroupIds,
		"portalGroupIds":window.portalGroupIds,"blockedGroupIds":blocked_ids,"boundaryGroupIds":boundary_ids,
		"firstUsefulGroupIds":window.get("firstUsefulGroupIds",[]),
		"firstUsefulHomeIds":window.get("firstUsefulHomeIds",[]),
		"firstUsefulDoorGroupId":window.get("firstUsefulDoorGroupId",""),
		"firstUsefulStructuralGroupIds":window.get("firstUsefulStructuralGroupIds",[]),
		"courtyardGroupIds":window.get("courtyardGroupIds",[]),
		"deferredGroupCount":window.get("deferredGroupCount",window.deferredGroupIds.size()),
		"implicitDeferred":window.get("implicitDeferred",false),
		"candidateCount":window.get("candidateCount",description.publication_groups.groups.size()),
		"censusReady":census.get("ready",base==null),"rollingWindow":true}


static func _packet_owner_demand_identity(consumers: Array, binding: Dictionary,
		door_lifecycle_available: bool) -> Array:
	var result: Array = [binding,door_lifecycle_available]
	for consumer: Dictionary in consumers:
		for site: Dictionary in consumer.sites:
			if site.get("binding",{})!=binding: continue
			result.append([consumer.get("ownerId"),consumer.get("priority"),consumer.get("bounds"),
				site.get("groupIds",[]),site.get("foregroundGroupIds",null),
				site.get("foregroundNavigationTileKeys",[])])
	return result


func _build_packet_owner_demand(region: Vector2i, binding: Dictionary, description, base,
		census: Dictionary, compact_plan, consumers: Array, door_lifecycle_available: bool) -> Dictionary:
	var requests: Array[Dictionary] = []
	var blocked: Dictionary = {}
	var boundary_groups: Dictionary = {}
	var owner_group_ids := 0
	for consumer: Dictionary in consumers:
		for site: Dictionary in consumer.sites:
			if site.binding!=binding: continue
			var ids: Dictionary = {}
			var dependency_complete := site.has("foregroundGroupIds")
			var trusted_foreground: bool = compact_plan!=null and door_lifecycle_available \
				and String(site.get("foregroundPlanSignature",""))==String(compact_plan.output_signature) \
				and site.get("foregroundGroupIds",[]).size()>0
			if trusted_foreground:
				requests.append({"ownerId":"region:%s" % str(consumer.ownerId),
					"groupIds":site.foregroundGroupIds,"priority":consumer.priority,"dependencyComplete":true})
				owner_group_ids+=site.foregroundGroupIds.size()
				continue
			if site.has("foregroundGroupIds"):
				if site.foregroundGroupIds.is_empty():
					var boundary: Dictionary = _packet_exterior_boundary_requirements(region,binding,description,consumer,census,compact_plan)
					if boundary.get("status") not in ["described","pending"]:
						return {"status":boundary.get("status","failed"),"reason":boundary.get("reason","packet_exterior_boundary_failed")}
					if boundary.get("status")=="described":
						for id: String in boundary.get("groupIds",[]): ids[id]=true
						if not String(boundary.get("boundaryGroupId","")).is_empty(): boundary_groups[String(boundary.boundaryGroupId)]=true
			else:
				var foreground_tiles: Array = site.get("foregroundNavigationTileKeys",[])
				if foreground_tiles.is_empty():
					for id: String in site.groupIds: ids[id]=true
				else:
					dependency_complete=true
					for key: String in foreground_tiles:
						var coordinates: PackedStringArray = key.split(",",true)
						if coordinates.size()!=2: return {"status":"failed","reason":"invalid_packet_foreground_tile"}
						var tile := Vector2i(int(coordinates[0]),int(coordinates[1]))
						var tile_bounds := Rect2i(tile*NAVIGATION_TILE_CELLS,Vector2i.ONE*NAVIGATION_TILE_CELLS)
						var requirements: Dictionary = compact_plan.physical_group_requirements(tile_bounds) \
							if compact_plan!=null else description.physical_group_requirements(tile_bounds)
						if requirements.get("status")!="described":
							return {"status":requirements.get("status","pending"),"reason":requirements.get("reason","packet_foreground_description_pending")}
						for id: String in requirements.get("groupIds",[]): ids[id]=true
					if ids.is_empty():
						var boundary: Dictionary = _packet_exterior_boundary_requirements(region,binding,description,consumer,census,compact_plan)
						if boundary.get("status") not in ["described","pending"]:
							return {"status":boundary.get("status","failed"),"reason":boundary.get("reason","packet_exterior_boundary_failed")}
						if boundary.get("status")=="described":
							for id: String in boundary.get("groupIds",[]): ids[id]=true
							if not String(boundary.get("boundaryGroupId","")).is_empty(): boundary_groups[String(boundary.boundaryGroupId)]=true
			var ordered: Array[String] = []
			if site.has("foregroundGroupIds") and not site.foregroundGroupIds.is_empty():
				for id: String in site.foregroundGroupIds: ordered.append(id)
			if ordered.is_empty():
				for id: String in ids: ordered.append(id)
				ordered.sort()
			var publishable: Array[String] = []
			for id: String in ordered:
				if not description.publication_groups.groups.has(id):
					return {"status":"failed","reason":"packet_foreground_group_unknown","groupId":id}
				var eligible := false
				if base!=null and census.get("ready",false):
					if compact_plan!=null:
						eligible=compact_plan.eligible_group_ids.has(id) \
							and (description.publication_groups.groups[id].get("doorPartIds",[]).is_empty() or door_lifecycle_available)
					else: eligible=_packet_group_publishable(description,census,id)
				if base==null or eligible: publishable.append(id)
				else: blocked[id]=true
			if not publishable.is_empty():
				requests.append({"ownerId":"region:%s" % str(consumer.ownerId),"groupIds":publishable,
					"priority":consumer.priority,"dependencyComplete":dependency_complete})
			owner_group_ids+=publishable.size()
	return {"status":"ready","requests":requests,"blocked":blocked,
		"boundaryGroups":boundary_groups,"groupCount":owner_group_ids}

## Select one bounded, dependency-complete publication window. Completed groups
## make room for the next window, so a retained city eventually finishes while
## the current view controls which unfinished work advances first.
func _bounded_packet_view_window(description, base, census: Dictionary, consumers: Array,
		base_requests: Array, completed: Dictionary, include_view_progress := true) -> Dictionary:
	var groups: Dictionary = description.publication_groups.groups
	var compact_plan = base.publication_plan if base!=null else null
	var candidates: Dictionary = {}
	var readiness: Dictionary = {}
	for request: Dictionary in base_requests:
		for id: String in request.groupIds:
			# A retained exact closure describes everything the consumer still
			# owns, including groups whose revision-matched physical receipts are
			# already installed.  Completed groups must remain acknowledged but do
			# not consume the next packet's bounded foreground capacity.  Counting
			# them here made dense civic tiles eventually reject their own progress
			# as an oversized request after hundreds of groups had completed.
			if completed.has(id): continue
			candidates[id] = {"id":id,"priority":int(request.priority),"distanceSquared":0.0,"portal":false,"throughPortal":false}
			# Exact member/tile queries already return a complete immutable
			# dependency closure. Do not traverse all of those same closures again
			# merely to label the gameplay-readiness subset.
			if bool(request.get("dependencyComplete",false)): readiness[id]=true
	var first_useful_started := Time.get_ticks_usec()
	var has_view_intent := include_view_progress \
		and consumers.any(func(consumer: Dictionary): return not consumer.get("viewIntent",{}).is_empty())
	var useful: Dictionary = _first_useful_packet_groups(description,base,census,completed,compact_plan) if has_view_intent \
		else {"status":"ready","groupIds":[],"homeIds":[],"doorGroupId":"","structuralGroupIds":[]}
	_record_scene_unit("demand_first_useful",first_useful_started,groups.size())
	if useful.get("status")!="ready": return useful
	for id: String in useful.get("groupIds",[]):
		if not candidates.has(id):
			candidates[id]={"id":id,"priority":0,"distanceSquared":0.0,"portal":false,"throughPortal":false}
	# Only explicit spatial/tile owners gate gameplay readiness. Camera-ranked
	# neighbours remain background presentation work and cannot hold the player
	# until a rolling city window (or the whole source) is installed.
	var readiness_started := Time.get_ticks_usec()
	for id: String in candidates:
		if readiness.has(id): continue
		var readiness_closure: Dictionary = _packet_dependency_window_for_plan(compact_plan,groups,id,completed)
		if readiness_closure.get("status")!="ready": return readiness_closure
		for required_id: String in readiness_closure.groupIds: readiness[required_id]=true
	_record_scene_unit("demand_readiness_closure",readiness_started,candidates.size())
	var view_rank_started := Time.get_ticks_usec()
	var ranked_group_rows := 0
	var ranked_view_keys: Dictionary = {}
	for consumer: Dictionary in consumers:
		if not include_view_progress: break
		var view: Dictionary = ViewPriority.normalize(consumer.get("viewIntent",{}))
		if view.is_empty(): continue
		var view_key := JSON.stringify([view.origin,view.forward,view.predictedOrigin,
			view.horizontalFovDegrees,view.farDistance])
		if ranked_view_keys.has(view_key): continue
		ranked_view_keys[view_key]=true
		var ranked_result: Dictionary = compact_plan.ranked_groups(view,completed) if compact_plan!=null \
			else {"status":"ready","rows":ViewPriority.ranked_groups(groups,view),"candidateCount":groups.size()}
		if ranked_result.get("status")!="ready": return ranked_result
		var ranked: Array[Dictionary] = ranked_result.rows
		ranked_group_rows += ranked.size()
		for row: Dictionary in ranked:
			var id := String(row.id)
			var current: Dictionary = candidates.get(id,{})
			if current.is_empty() or int(row.priority)<int(current.priority) \
					or int(row.priority)==int(current.priority) and float(row.distanceSquared)<float(current.distanceSquared):
				candidates[id]=row.duplicate(true)
	_record_scene_unit("demand_view_rank_and_merge",view_rank_started,ranked_group_rows)
	# Legacy/direct owners without a camera retain their exact source request.
	# A rolling city window exists only when a gameplay consumer supplies view
	# intent; this keeps background tools and navigation-only requests narrow.
	var ordered: Array[Dictionary] = []
	for row: Dictionary in candidates.values():
		# Exact member/semantic readiness is already seeded below in stable ID
		# order.  Sorting those rows again made the first cold view refresh scale
		# with its full dependency closure; only optional ranked rows need ranking.
		if not completed.has(String(row.id)) and not readiness.has(String(row.id)): ordered.append(row)
	var candidate_sort_started := Time.get_ticks_usec()
	ordered.sort_custom(func(a: Dictionary,b: Dictionary):
		if int(a.priority)!=int(b.priority): return int(a.priority)<int(b.priority)
		if not is_equal_approx(float(a.distanceSquared),float(b.distanceSquared)):
			return float(a.distanceSquared)<float(b.distanceSquared)
		return String(a.id)<String(b.id))
	_record_scene_unit("demand_candidate_sort",candidate_sort_started,ordered.size())
	# Exact spatial/semantic readiness is mandatory, not part of the optional
	# presentation-window quota. Seed its complete dependency closure first;
	# ranked view rows then fill only the remaining bounded capacity.
	if readiness.size()>MAX_REQUIRED_FOREGROUND_GROUPS:
		return {"status":"failed","reason":"packet_required_foreground_scope_too_large","groupCount":readiness.size()}
	var selected: Dictionary = readiness.duplicate()
	var selected_priority: Dictionary = {}
	var selected_order: Array[String] = []
	for id: String in selected: selected_order.append(id)
	selected_order.sort()
	for id: String in selected_order: selected_priority[id]=0
	var view_ids: Array[String] = []
	var portal_ids: Array[String] = []
	var blocked: Dictionary = {}
	var selection_started := Time.get_ticks_usec()
	var selection_rows := 0
	for row: Dictionary in ordered:
		selection_rows += 1
		var id := String(row.id)
		if not groups.has(id): return {"status":"failed","reason":"packet_foreground_group_unknown","groupId":id}
		var closure: Dictionary = _packet_dependency_window_for_plan(compact_plan,groups,id,completed)
		if closure.get("status")!="ready": return closure
		var eligible: bool = base==null or compact_plan!=null and compact_plan.publication_closure_eligible(id,_door_callbacks_ready())
		if base!=null and compact_plan==null:
			eligible=true
			for required_id: String in closure.groupIds:
				if not _packet_group_publishable(description,census,required_id): eligible=false
		if not eligible:
			for required_id: String in closure.groupIds:
				if not _packet_group_publishable_from_plan(description,census,required_id,compact_plan): blocked[required_id]=true
		if not eligible: continue
		var additions := 0
		for required_id: String in closure.groupIds:
			if not selected.has(required_id): additions+=1
		if selected.size()+additions>maxi(MAX_INCREMENTAL_FOREGROUND_GROUPS,readiness.size()): continue
		for required_id: String in closure.groupIds:
			if not selected.has(required_id): selected_order.append(required_id)
			selected[required_id]=true
			selected_priority[required_id]=mini(int(selected_priority.get(required_id,row.priority)),int(row.priority))
		if int(row.priority)<4: view_ids.append(id)
		if bool(row.get("portal",false)) or bool(row.get("throughPortal",false)): portal_ids.append(id)
		# Do not scan thousands of lower-ranked closures trying to fill the final
		# few slots. This still publishes a substantial bounded window and the
		# retained job selects another window after acknowledgement.
		if selected.size()>=maxi(readiness.size(),VIEW_WINDOW_PROGRESS_TARGET_GROUPS): break
	_record_scene_unit("demand_selection_closure",selection_started,selection_rows)
	var result_started := Time.get_ticks_usec()
	var by_priority: Dictionary = {}
	for id: String in selected_order:
		var priority := int(selected_priority[id])
		if not by_priority.has(priority): by_priority[priority]=[]
		by_priority[priority].append(id)
	var requests: Array[Dictionary] = []
	for priority: int in range(5):
		if by_priority.has(priority):
			requests.append({"ownerId":"view-window:%d" % priority,"groupIds":by_priority[priority],"priority":priority})
	var deferred: Array[String] = []
	var deferred_count := groups.size()-completed.size()-selected.size()
	if compact_plan==null:
		for id: String in groups:
			if not completed.has(id) and not selected.has(id): deferred.append(id)
		deferred.sort()
		deferred_count=deferred.size()
	view_ids = _unique_sorted_strings(view_ids)
	portal_ids = _unique_sorted_strings(portal_ids)
	var blocked_ids: Array = blocked.keys()
	blocked_ids.sort()
	if compact_plan!=null:
		deferred.clear()
		for id: String in blocked_ids: deferred.append(id)
	var readiness_ids: Array[String] = []
	for id: String in readiness: readiness_ids.append(id)
	readiness_ids.sort()
	_record_scene_unit("demand_result_assembly",result_started,ranked_group_rows)
	return {"status":"ready","requests":requests,"foregroundGroupIds":selected_order,
		"readinessGroupIds":readiness_ids,
		"firstUsefulGroupIds":useful.get("groupIds",[]),
		"firstUsefulHomeIds":useful.get("homeIds",[]),"firstUsefulDoorGroupId":useful.get("doorGroupId",""),
		"firstUsefulStructuralGroupIds":useful.get("structuralGroupIds",[]),
		"courtyardGroupIds":useful.get("courtyardGroupIds",[]),
		"deferredGroupIds":deferred,"deferredGroupCount":deferred_count,"implicitDeferred":compact_plan!=null,
		"candidateCount":ranked_group_rows,"viewPrioritizedGroupIds":view_ids,"portalGroupIds":portal_ids,"blockedGroupIds":blocked_ids}

## Choose semantic first-content anchors from immutable generated source data.
## This is not seed/name choreography: every qualifying Citadel contributes the
## first two complete home furnishing sets, one publishable door closure and a
## real stair/landing support.  The latter keeps first-useful readiness honest:
## a visually useful packet must also expose a live player-capsule clearance
## witness rather than declaring readiness from furniture and one door alone.
func _first_useful_packet_groups(description, base, census: Dictionary, completed: Dictionary, compact_plan = null) -> Dictionary:
	if base==null: return {"status":"ready","groupIds":[],"homeIds":[],"doorGroupId":"","structuralGroupIds":[]}
	if compact_plan==null: compact_plan=base.publication_plan
	if compact_plan!=null:
		if compact_plan.selected_first_useful_structural_group_ids.is_empty():
			return {"status":"failed","reason":"first_useful_structural_group_missing"}
		var roots: Array[String] = []
		for group_id: String in compact_plan.selected_first_useful_home_group_ids: roots.append(group_id)
		for group_id: String in compact_plan.selected_first_useful_structural_group_ids:
			if not roots.has(group_id): roots.append(group_id)
		for group_id: String in compact_plan.selected_courtyard_group_ids:
			if not roots.has(group_id): roots.append(group_id)
		var door_group_id: String = compact_plan.selected_first_useful_door_group_id if _door_callbacks_ready() else ""
		if not door_group_id.is_empty() and not roots.has(door_group_id): roots.append(door_group_id)
		roots.sort()
		return {"status":"ready","groupIds":roots,
			"homeIds":compact_plan.selected_first_useful_home_ids,
			"doorGroupId":door_group_id,
			"structuralGroupIds":compact_plan.selected_first_useful_structural_group_ids,
			"courtyardGroupIds":compact_plan.selected_courtyard_group_ids}
	var groups: Dictionary = description.publication_groups.get("groups",{})
	var by_part: Dictionary = description.publication_groups.get("groupByPart",{})
	var homes: Dictionary = {}
	if compact_plan!=null:
		homes=compact_plan.first_useful_homes
	else:
		var furnishing_source: Dictionary = base.furnishing_source
		var furnishing_parts: Variant = furnishing_source.get("parts",[])
		if not furnishing_parts is Array: return {"status":"failed","reason":"invalid_first_useful_furnishing_source"}
		for raw_part in furnishing_parts:
			if not raw_part is Dictionary: continue
			var part: Dictionary = raw_part
			var recipe: Variant = part.get("recipe",{})
			if not recipe is Dictionary: continue
			var home_id := String(recipe.get("citadelUrbanHomeId",""))
			var archetype := String(part.get("archetype",""))
			var member_id := "furnishing:"+String(part.get("id",""))
			if home_id.is_empty() or archetype not in FIRST_USEFUL_HOME_ARCHETYPES or not by_part.has(member_id): continue
			var group_id := String(by_part[member_id])
			if not _packet_group_closure_publishable(description,census,group_id,completed,compact_plan): continue
			if not homes.has(home_id): homes[home_id]={}
			if not homes[home_id].has(archetype): homes[home_id][archetype]=group_id
	var selected: Dictionary = {}
	var selected_homes: Array[String] = []
	var home_ids: Array = compact_plan.first_useful_home_ids if compact_plan!=null else homes.keys()
	if compact_plan==null: home_ids.sort()
	for home_id_value in home_ids:
		var home_id := String(home_id_value)
		var archetypes: Dictionary = homes[home_id]
		if not FIRST_USEFUL_HOME_ARCHETYPES.all(func(value: String): return archetypes.has(value)): continue
		var home_publishable := true
		for archetype: String in FIRST_USEFUL_HOME_ARCHETYPES:
			if not _packet_group_closure_publishable(description,census,String(archetypes[archetype]),completed,compact_plan): home_publishable=false
		if not home_publishable: continue
		for archetype: String in FIRST_USEFUL_HOME_ARCHETYPES: selected[String(archetypes[archetype])]=true
		selected_homes.append(home_id)
		if selected_homes.size()>=FIRST_USEFUL_HOME_COUNT: break
	var door_group_id := ""
	var ordered_group_ids: Array = compact_plan.door_group_ids if compact_plan!=null else groups.keys()
	if compact_plan==null: ordered_group_ids.sort()
	for group_id_value in ordered_group_ids:
		var group_id := String(group_id_value)
		if groups[group_id].get("doorPartIds",[]).is_empty(): continue
		if _packet_group_closure_publishable(description,census,group_id,completed,compact_plan):
			door_group_id=group_id
			selected[group_id]=true
			break
	var structural_candidates: Dictionary = {}
	if compact_plan!=null:
		for group_id: String in compact_plan.first_useful_structural_group_ids:
			if _packet_group_closure_publishable(description,census,group_id,completed,compact_plan): structural_candidates[group_id]=true
	else:
		var building_parts: Variant = base.building_source.get("parts",[])
		if not building_parts is Array: return {"status":"failed","reason":"invalid_first_useful_building_source"}
		for raw_part in building_parts:
			if not raw_part is Dictionary: continue
			var part: Dictionary = raw_part
			if String(part.get("semantic","")) not in FIRST_USEFUL_STRUCTURAL_SEMANTICS: continue
			var member_id := "building:"+String(part.get("id",""))
			if not by_part.has(member_id): continue
			var group_id := String(by_part[member_id])
			if not _packet_group_closure_publishable(description,census,group_id,completed,compact_plan): continue
			structural_candidates[group_id]=true
	if structural_candidates.is_empty():
		return {"status":"failed","reason":"first_useful_structural_group_missing"}
	var structural_candidate_ids: Array = structural_candidates.keys()
	structural_candidate_ids.sort()
	var structural_group_id := String(structural_candidate_ids[0])
	selected[structural_group_id]=true
	var selected_ids: Array[String] = []
	for group_id: String in selected: selected_ids.append(group_id)
	selected_ids.sort()
	return {"status":"ready","groupIds":selected_ids,"homeIds":selected_homes,"doorGroupId":door_group_id,
		"structuralGroupIds":[structural_group_id]}

func _packet_group_closure_publishable(description, census: Dictionary, group_id: String, completed: Dictionary, compact_plan = null) -> bool:
	if compact_plan!=null: return compact_plan.publication_closure_eligible(group_id,_door_callbacks_ready())
	var closure: Dictionary = _packet_dependency_window_for_plan(compact_plan,description.publication_groups.groups,group_id,completed)
	if closure.get("status")!="ready": return false
	for required_id: String in closure.groupIds:
		if not _packet_group_publishable_from_plan(description,census,required_id,compact_plan): return false
	return true

static func _unique_sorted_strings(values: Array[String]) -> Array[String]:
	var seen: Dictionary = {}
	for value: String in values: seen[value]=true
	var result: Array[String] = []
	for value: String in seen: result.append(value)
	result.sort()
	return result

static func _packet_dependency_window(groups: Dictionary, first_id: String, completed: Dictionary) -> Dictionary:
	var visiting: Dictionary = {}
	var ordered: Array[String] = []
	var stack: Array = [[first_id,false]]
	while not stack.is_empty():
		var frame: Array = stack.pop_back()
		var id := String(frame[0])
		if completed.has(id): continue
		if not groups.has(id): return {"status":"failed","reason":"publication_group_dependency_missing","groupId":id}
		if bool(frame[1]):
			visiting[id]=2
			if not ordered.has(id): ordered.append(id)
			continue
		if int(visiting.get(id,0))==2: continue
		if int(visiting.get(id,0))==1: return {"status":"failed","reason":"publication_group_dependency_cycle","groupId":id}
		visiting[id]=1
		stack.append([id,true])
		var dependencies: Array = groups[id].get("dependencies",[]).duplicate()
		dependencies.sort()
		dependencies.reverse()
		for dependency in dependencies: stack.append([String(dependency),false])
	return {"status":"ready","groupIds":ordered}


static func _packet_dependency_window_for_plan(compact_plan, groups: Dictionary, first_id: String, completed: Dictionary) -> Dictionary:
	return compact_plan.dependency_window(first_id,completed) if compact_plan!=null \
		else _packet_dependency_window(groups,first_id,completed)

func _packet_group_publishable(description, census: Dictionary, group_id: String) -> bool:
	if not bool(census.get("groups",{}).get(group_id,{}).get("eligible",false)):
		return false
	var group: Dictionary = description.publication_groups.get("groups",{}).get(group_id,{})
	# The frozen compiler can describe a door, but it cannot create the ordinary
	# portal lifecycle.  Keep that packet demand retained until the scene owner
	# has supplied both callbacks instead of dispatching work that must fail at
	# installation.
	return group.get("doorPartIds",[]).is_empty() or _door_callbacks_ready()


func _packet_group_publishable_from_plan(description, census: Dictionary, group_id: String, compact_plan = null) -> bool:
	if compact_plan==null: return _packet_group_publishable(description,census,group_id)
	if not compact_plan.eligible_group_ids.has(group_id): return false
	var group: Dictionary = description.publication_groups.get("groups",{}).get(group_id,{})
	return group.get("doorPartIds",[]).is_empty() or _door_callbacks_ready()

## The source reservation is a conservative physical-safety envelope.  When a
## retained consumer already intersects it but has no tile-owned group, request
## the nearest declared structural closure rather than asking the player to
## enter an unpublished collision area.  This only selects immutable source
## membership; `BuildingScenePublicationJob` still validates and acknowledges
## the physical packet when it is installed.
func _packet_exterior_boundary_requirements(region: Vector2i, binding: Dictionary, description, consumer: Dictionary,
		census: Dictionary, compact_plan = null) -> Dictionary:
	if _admission==null or not consumer.get("bounds") is Rect2i:
		return {"status":"pending","reason":"packet_exterior_source_pending"}
	var source: Dictionary = _admission.source_state(region)
	if source.get("binding",{})!=binding or not source.get("reservationCells") is Rect2i:
		return {"status":"pending","reason":"packet_exterior_source_pending"}
	var reservation: Rect2i = source.reservationCells
	if not reservation.intersects(consumer.bounds):
		return {"status":"described","groupIds":[]}
	if compact_plan!=null:
		var indexed: Dictionary = compact_plan.exterior_structural_group_requirements(consumer.bounds)
		if indexed.get("status")=="described":
			for group_id: String in indexed.get("groupIds",[]):
				if not _packet_group_publishable_from_plan(description,census,group_id,compact_plan):
					return {"status":"pending","reason":"exterior_structural_group_unavailable"}
		return indexed
	var eligible: Dictionary = {}
	if census.get("ready",false):
		for group_id: String in census.get("groups",{}):
			if _packet_group_publishable(description,census,group_id): eligible[group_id] = true
	return description.exterior_structural_group_requirements(consumer.bounds,eligible)

func _base_packet_eligible(base, binding: Dictionary, region: Vector2i) -> Dictionary:
	if base==null or not base.matches(binding): return {"status":"failed","reason":"packet_publication_base_stale"}
	var plan: Dictionary = _packet_foreground_plan(region,binding,base.description,base)
	if plan.get("status")!="ready": return plan
	if not plan.get("censusReady",false): return {"status":"failed","reason":"packet_foreground_census_missing"}
	if plan.get("readinessGroupIds",[]).size()>MAX_REQUIRED_FOREGROUND_GROUPS:
		return {"status":"failed","reason":"packet_required_foreground_scope_too_large","groupCount":plan.readinessGroupIds.size()}
	return plan

func _collect_publication_base(region: Vector2i, current: Dictionary, result: Dictionary) -> void:
	var base = result.get("base")
	if result.get("ready",false) and base!=null and _packet_bootstrap_requested_for_source(region,current):
		_retain_packet_bootstrap_base(region,current,base,result.get("profile",{}))
		if _packet_bootstrap_bases.has(region):
			_accepted_count += 1
			_inflight = {}
			return
	var packet_plan: Dictionary = _base_packet_eligible(base,current.binding,region) if result.get("ready",false) and base!=null else {}
	if not result.get("ready",false) or base==null or packet_plan.get("status")!="ready":
		if base!=null:
			_retain_packet_bootstrap_base(region,current,base,result.get("profile",{}))
		if packet_plan.get("status")=="failed":
			_failures[region]={"binding":current.binding.duplicate(),"reason":String(packet_plan.get("reason","packet_publication_plan_failed"))}
		_inflight={}
		return
	# A packet base is sufficient to start the foreground physical scene.  Do
	# not construct its dense navigation producer here: that previously let a
	# retained 64m navigation closure consume the only worker before the player
	# could receive the physical collision packet at their capsule.
	_prepared[region]={"binding":current.binding.duplicate(),"base":base,"profile":result.get("profile",{}),"packetMode":true}
	_packet_bootstrap_bases.erase(region)
	_accepted_count+=1
	_inflight={}

func _collect_publication_base_navigation(region: Vector2i, current: Dictionary, result: Dictionary) -> void:
	var base = _inflight.get("base")
	var source: Dictionary = result.get("navigationSource",{})
	if base==null or not result.get("ready",false) or not source.is_read_only() or source.get("binding",{})!=current.binding:
		_retire({"base":base,"navigation":source}); _inflight={}; return
	_navigation[region]={"binding":current.binding,"domain":source.get("domain"),"navigationSource":source,"requested":{},"receipts":{},"activeTileKey":"","producerProgress":{}}
	_prepared[region]={"binding":current.binding.duplicate(),"base":base,"profile":_inflight.get("profile",{}),"packetMode":true}
	_packet_bootstrap_bases.erase(region)
	_accepted_count+=1
	_inflight={}

func _collect_physical_group_packet(region: Vector2i, current: Dictionary, result: Dictionary, transaction_id: int) -> void:
	_inflight={}
	if not _scenes.has(region) or _scenes[region].binding!=current.binding or not result.get("ready",false):
		_retire(result); return
	var entry: Dictionary = _scenes[region]
	var packet = result.get("packet")
	var offered: Dictionary = entry.job.offer_physical_group_packet(packet,current.binding)
	if offered.get("status")!="retained":
		_failures[region]={"binding":current.binding,"reason":String(offered.get("reason","physical_packet_offer_failed"))}; _retire_scene(region); return
	# Activation is deliberately left to the next main-thread pump. The exact
	# actor-volume guard is re-read there, after worker latency and immediately
	# before any scene/collider publication can advance.

func _dispatch(ready: Dictionary, observer: Vector2i) -> bool:
	var candidates: Array[Dictionary] = _dispatch_candidates(ready,observer,true)
	if candidates.is_empty(): return false
	_dispatch_candidate(candidates[0],ready)
	return not _inflight.is_empty()

## Existing direct-service callers select navigation through the same ranking
## and transfer path. Production _dispatch arbitrates BOTH worker job kinds.
func _dispatch_navigation(ready: Dictionary) -> bool:
	var candidates: Array[Dictionary] = _dispatch_candidates(ready,Vector2i.ZERO,false)
	if candidates.is_empty(): return false
	_dispatch_candidate(candidates[0],ready)
	return true

func _new_dispatch_schedule() -> Dictionary:
	_dispatch_sequence += 1
	return {"firstSequence":_dispatch_sequence,"firstPendingUsec":Time.get_ticks_usec(),
		"lastDispatchTurn":_dispatch_turn,"lastDispatchUsec":0}

func _request_navigation_tile(entry: Dictionary, key: String) -> bool:
	if entry.receipts.has(key): return true
	if entry.requested.has(key): return true
	if entry.requested.size()>=MAX_PENDING_NAVIGATION_TILES: return false
	var schedule: Dictionary = _new_dispatch_schedule()
	# Selection is not execution: an active output may consume the whole worker
	# turn. Waiting outputs retain their first admission age until completion.
	schedule.firstPendingTurn = _dispatch_turn
	entry.requested[key] = schedule
	if not entry.has("schedule"): entry.schedule = _new_dispatch_schedule()
	return true

func _aged_priority(priority: int, schedule: Dictionary) -> int:
	var age: int = maxi(0,_dispatch_turn-int(schedule.lastDispatchTurn))
	return maxi(0,priority-floori(float(age)/float(PRIORITY_AGING_DISPATCH_TURNS)))

func _schedule_before(priority_a: int, a: Dictionary, priority_b: int, b: Dictionary) -> bool:
	var rank_a: int = _aged_priority(priority_a,a)
	var rank_b: int = _aged_priority(priority_b,b)
	if rank_a!=rank_b: return rank_a<rank_b
	if a.lastDispatchTurn!=b.lastDispatchTurn: return a.lastDispatchTurn<b.lastDispatchTurn
	return a.firstSequence<b.firstSequence

func _navigation_tile_before(priority_a: int, a: Dictionary, priority_b: int, b: Dictionary) -> bool:
	var age_a: int = maxi(0,_dispatch_turn-int(a.firstPendingTurn))
	var age_b: int = maxi(0,_dispatch_turn-int(b.firstPendingTurn))
	var rank_a: int = maxi(0,priority_a-floori(float(age_a)/float(PRIORITY_AGING_DISPATCH_TURNS)))
	var rank_b: int = maxi(0,priority_b-floori(float(age_b)/float(PRIORITY_AGING_DISPATCH_TURNS)))
	if rank_a!=rank_b: return rank_a<rank_b
	if a.firstPendingTurn!=b.firstPendingTurn: return a.firstPendingTurn<b.firstPendingTurn
	return a.firstSequence<b.firstSequence

## Explicit diagnostic read. It neither requests a tile nor polls its worker.
## Rank describes the current active-first selection, not a completion deadline.
func navigation_request_observation(region: Vector2i, key: String, binding: Dictionary) -> Dictionary:
	var observed := {"schema":"citadel-navigation-request-observation/v1","observedUsec":Time.get_ticks_usec(),
		"region":region,"tileKey":key.left(23),"dispatchTurn":_dispatch_turn,"status":"absent"}
	if key.is_empty() or key.length()>23: observed.status="invalid_query"; return observed
	if not _navigation.has(region): return observed
	var entry: Dictionary = _navigation[region]
	observed["binding"] = entry.binding.duplicate()
	if entry.binding!=binding: observed.status="stale_binding"; return observed
	observed["pendingCount"] = entry.requested.size()
	observed["completedCount"] = entry.receipts.size()
	observed["activeTileKey"] = entry.get("activeTileKey","")
	observed["selected"] = _inflight.get("kind")=="navigation" and _inflight.get("region")==region \
		and _inflight.get("tileKeys",[]).has(key)
	if entry.receipts.has(key): observed.status="completed"; return observed
	if not entry.requested.has(key): observed.status="unrequested"; return observed
	var request: Dictionary = entry.requested[key]
	var priority: int = _navigation_priority(key)
	var age: int = maxi(0,_dispatch_turn-int(request.firstPendingTurn))
	var ahead := 0
	if observed.activeTileKey!=key:
		for other: String in entry.requested:
			if other!=key and (other==observed.activeTileKey or \
				_navigation_tile_before(_navigation_priority(other),entry.requested[other],priority,request)): ahead+=1
	observed.merge({"status":"pending","firstPendingTurn":int(request.firstPendingTurn),
		"firstSequence":int(request.firstSequence),"queuedUsec":int(request.firstPendingUsec),
		"pendingWaitTurns":age,"basePriority":priority,
		"effectivePriority":maxi(0,priority-floori(float(age)/float(PRIORITY_AGING_DISPATCH_TURNS))),
		"outputsAhead":ahead,"selectionRank":ahead+1},true)
	return observed

func _dispatch_candidates(ready: Dictionary, observer: Vector2i, include_preparation: bool) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	for region: Vector2i in _navigation:
		var entry: Dictionary = _navigation[region]
		if not ready.has(region) or ready[region].binding!=entry.binding or _failures.has(region) \
			or entry.get("navigationSource",{}).is_empty() or entry.requested.is_empty(): continue
		var priority := 4
		for key: String in entry.requested: priority = mini(priority,_navigation_priority(key))
		candidates.append({"kind":"navigation","region":region,"priority":priority,"schedule":entry.schedule})
	# A ready source remains a waiter while its payload is temporarily evicted;
	# only departure, binding replacement or a completed owner removes its age.
	for region: Vector2i in _preparation_schedule.keys():
		if not ready.has(region) or ready[region].binding!=_preparation_schedule[region].binding \
			or _prepared.has(region) or _scenes.has(region) or _region_retiring(region) or _failures.has(region):
			_preparation_schedule.erase(region)
	var can_prepare: bool = include_preparation and _resident_region_count()<MAX_REGIONS
	var regions: Array = ready.keys() if can_prepare else []
	regions.sort_custom(func(a,b):
		var ac: Vector2i = ready[a].reservationCells.get_center()
		var bc: Vector2i = ready[b].reservationCells.get_center()
		var ad := ac.distance_squared_to(observer)
		var bd := bc.distance_squared_to(observer)
		return ad<bd or ad==bd and (a.x<b.x or a.x==b.x and a.y<b.y))
	for region: Vector2i in regions:
		if not can_prepare: break
		if _prepared.has(region) or _scenes.has(region) or _region_retiring(region) or _failures.has(region) or ready[region].status != "ready": continue
		if _packet_bootstrap_bases.has(region) and not _packet_requested_for_source(region,ready[region].binding): continue
		if not _preparation_schedule.has(region):
			_preparation_schedule[region] = {"binding":ready[region].binding.duplicate(),"schedule":_new_dispatch_schedule()}
		candidates.append({"kind":"preparation","region":region,"priority":_preparation_priority(region,ready[region]),
			"schedule":_preparation_schedule[region].schedule})
	candidates.sort_custom(func(a: Dictionary,b: Dictionary): return _schedule_before(a.priority,a.schedule,b.priority,b.schedule))
	return candidates


func _has_dispatchable_navigation(ready: Dictionary) -> bool:
	for region: Vector2i in _navigation:
		var entry: Dictionary = _navigation[region]
		if ready.has(region) and ready[region].binding==entry.binding and not _failures.has(region) \
				and not entry.get("navigationSource",{}).is_empty() and not entry.requested.is_empty():
			return true
	return false


func _navigation_physical_packet_pending(entry: Dictionary) -> bool:
	for group_id: String in entry.get("navigationPhysicalGroups",{}):
		if not entry.job.physical_group_packet_completed_for_scheduling(group_id,entry.binding): return true
	return false

func _dispatch_candidate(candidate: Dictionary, ready: Dictionary) -> void:
	var region: Vector2i = candidate.region
	var keys: Array[String] = []
	var order: Array[String] = []
	var receipt: Dictionary
	if candidate.kind=="navigation":
		var entry: Dictionary = _navigation[region]
		var pending: Array = entry.requested.keys()
		pending.sort_custom(func(a: String,b: String):
			return _navigation_tile_before(_navigation_priority(a),entry.requested[a],_navigation_priority(b),entry.requested[b]))
		var active: String = entry.get("activeTileKey","")
		if not active.is_empty():
			if not entry.requested.has(active):
				_failures[region] = {"binding":entry.binding,"reason":"navigation_active_request_missing"}
				return
			order.append(active)
		for key: String in pending:
			if not order.has(key): order.append(key)
			if order.size()>=Worker.MAX_NAVIGATION_BATCH_TILES: break
		keys.assign(order)
		keys.sort()
		receipt = _worker.dispatch_navigation(entry.navigationSource,keys,entry.binding,order)
		if receipt.get("status") not in ["started","queued"]: return
		if receipt.get("duplicate",false): return
		entry.erase("navigationSource") # Transfer before any subsequent poll.
		_inflight = {"kind":"navigation","region":region,"binding":entry.binding,"token":int(receipt.token),
			"tileKeys":keys,"tileOrder":order}
	else:
		var source: Dictionary = ready[region]
		# The retained-source API is the explicit opt-in for demand-bound packet
		# publication.  Ordinary observer/legacy retention keeps the established
		# source preparation lifecycle, including its early-description transfer
		# and cancellation behavior.  Do not add a base turn to that path: it
		# changes both its worker boundary and its observable dispatch contract.
		var packet_requested: bool = _packet_requested_for_source(region,source.binding)
		var bootstrap_requested: bool = _packet_bootstrap_requested_for_source(region,source)
		if _packet_bootstrap_bases.has(region):
			var bootstrap: Dictionary = _packet_bootstrap_bases[region]
			var base = bootstrap.get("base")
			if packet_requested and _base_packet_eligible(base,source.binding,region).get("status")=="ready":
				receipt = _worker.dispatch_publication_base_navigation(base,source.binding)
				if receipt.get("status") not in ["started","queued"] or receipt.get("duplicate",false): return
				_inflight={"kind":"publication_base_navigation","region":region,"binding":source.binding.duplicate(),
					"token":int(receipt.token),"base":base,"profile":bootstrap.get("profile",{})}
				_dispatch_count += 1
				_record_successful_dispatch(candidate,order)
				return
			if bootstrap_requested and not packet_requested: return
			var packet_state: Dictionary = _base_packet_eligible(base,source.binding,region) if packet_requested else {"status":"pending"}
			if packet_state.get("status")=="failed":
				_failures[region]={"binding":source.binding.duplicate(),"reason":String(packet_state.get("reason","packet_publication_plan_failed"))}
			return
		receipt = _worker.dispatch_publication_base(source.source,source.binding) if packet_requested or bootstrap_requested \
			else _worker.dispatch_scene_source(source.source,source.binding)
		if receipt.get("status") not in ["started","queued"]: return
		if receipt.get("duplicate",false): return
		_inflight = {"kind":"publication_base" if packet_requested or bootstrap_requested else "preparation","region":region,
			"binding":source.binding.duplicate(),"token":int(receipt.token)}
		_dispatch_count += 1
	# A duplicate still belongs to the existing worker turn. Repeated queries,
	# capacity rejection and failed admission cannot reset any waiter's age.
	_record_successful_dispatch(candidate,order)

func _record_successful_dispatch(candidate: Dictionary, order: Array[String]) -> void:
	var schedule: Dictionary = candidate.schedule
	var priority: int = candidate.priority
	var effective: int = _aged_priority(priority,schedule)
	var wait_turns: int = _dispatch_turn-int(schedule.lastDispatchTurn)
	var now: int = Time.get_ticks_usec()
	var first_age: int = maxi(0,now-int(schedule.firstPendingUsec))
	_dispatch_metrics.maxFirstDemandUsecByPriority[priority] = maxi(_dispatch_metrics.maxFirstDemandUsecByPriority[priority],first_age)
	_dispatch_metrics.maxWaitTurnsByPriority[priority] = maxi(_dispatch_metrics.maxWaitTurnsByPriority[priority],wait_turns)
	if effective<priority: _dispatch_metrics.agedDispatches += 1
	_dispatch_turn += 1
	schedule.lastDispatchTurn = _dispatch_turn
	schedule.lastDispatchUsec = now
	var selected: Array[Dictionary] = []
	if candidate.kind=="navigation":
		_dispatch_metrics.navigationDispatches += 1
		for key: String in order:
			var tile: Dictionary = _navigation[candidate.region].requested[key]
			var pending_turns: int = _dispatch_turn-1-int(tile.firstPendingTurn)
			selected.append({"tileKey":key,"priority":_navigation_priority(key),
				"firstDemandUsec":maxi(0,now-int(tile.firstPendingUsec)),"waitTurns":_dispatch_turn-1-int(tile.lastDispatchTurn),
				"firstPendingTurn":int(tile.firstPendingTurn),"pendingWaitTurns":pending_turns,
				"effectivePriority":maxi(0,_navigation_priority(key)-floori(float(pending_turns)/float(PRIORITY_AGING_DISPATCH_TURNS)))})
			tile.lastDispatchTurn = _dispatch_turn
			tile.lastDispatchUsec = now
	else: _dispatch_metrics.preparationDispatches += 1
	_dispatch_metrics.last = {"kind":candidate.kind,"region":candidate.region,"priority":priority,"effectivePriority":effective,
		"waitTurns":wait_turns,"firstDemandUsec":first_age,"dispatchTurn":_dispatch_turn,"selected":selected,
		"scope":"accepted dispatch selection; not proof that selected outputs progressed"}

func _collect_navigation(region: Vector2i, binding: Dictionary, result: Dictionary, requested_keys: Array, requested_order: Array) -> void:
	var source: Dictionary = result.get("navigationSource",{})
	if not _navigation.has(region) or _navigation[region].binding!=binding:
		_retire(result)
		return
	var valid: bool = result.get("ready",false) and result.get("kind")=="navigation_batch" and source.get("binding",{})==binding \
		and result.get("requestedTileKeys",[])==requested_keys and result.get("requestedTileOrder",[])==requested_order \
		and result.get("tileReceipts") is Dictionary and result.get("producerStatus") is Dictionary \
		and is_same(source.get("domain"),_navigation[region].domain)
	var raw_status: Variant = result.get("producerStatus",{})
	var producer_status: Dictionary = raw_status if raw_status is Dictionary else {}
	var active: Variant = producer_status.get("activeTileKey","")
	valid = valid and active is String and (active.is_empty() or requested_keys.has(active))
	if valid:
		for key in result.tileReceipts:
			var receipt: Variant = result.tileReceipts[key]
			if not key is String or not requested_keys.has(key) or not receipt is Dictionary \
					or receipt.get("status")!="ready" or receipt.get("tileKey")!=key \
					or not receipt.get("tile") is Dictionary or not receipt.tile.is_read_only():
				valid = false
				break
		if result.get("batchComplete",false) and result.tileReceipts.size()!=requested_keys.size(): valid = false
		if not active.is_empty() and result.tileReceipts.has(active): valid = false
	if not valid:
		_failures[region] = {"binding":binding,"reason":result.get("reason","navigation_producer_result_invalid")}
		_retire(result)
		return
	var entry: Dictionary = _navigation[region]
	entry.navigationSource = source
	entry.activeTileKey = active
	# Copy bounded scalar progress only. Never query the returned producer here
	# or expose it to diagnostics while the next worker owns its mutable state.
	entry.producerProgress = {}
	for field: String in ["phase","activeTileKey","pendingRequestCount","completedTileCount","compiledProducerCount",
		"producerCount","sampleCount","surfaceCount","preparationUsec"]:
		var value: Variant = producer_status.get(field)
		if value is String or value is int: entry.producerProgress[field] = value
	for key: String in result.get("tileReceipts",{}):
		var receipt: Dictionary = result.tileReceipts[key]
		var bound_receipt := {"status":"ready","binding":source.binding,"tileKey":key,"tile":receipt.get("tile",{}),
			"outputPresent":receipt.get("outputPresent",false)}
		bound_receipt.make_read_only()
		entry.receipts[key] = bound_receipt
		entry.requested.erase(key)
	if entry.requested.is_empty(): entry.erase("schedule")

func _resident_region_count() -> int:
	var regions := {}
	for region: Vector2i in _described: regions[region] = true
	for region: Vector2i in _prepared: regions[region] = true
	for region: Vector2i in _packet_bootstrap_bases: regions[region] = true
	for region: Vector2i in _scenes: regions[region] = true
	if not _inflight.is_empty(): regions[_inflight.region] = true
	for entry: Dictionary in _retiring_scenes: regions[entry.region] = true
	for region: Vector2i in _pending_scene_disposals.values(): regions[region] = true
	for region: Vector2i in _submitted_scene_disposals.values(): regions[region] = true
	return regions.size()

func _retire(value: Dictionary) -> void:
	_retirement_serial += 1
	_retired[_retirement_serial] = value

func _retire_all() -> void:
	_preparation_schedule = {}
	_dispatch_metrics.last = {}
	_pending_packet_navigation = {}
	if not _navigation.is_empty(): _retire(_navigation)
	_navigation = {}
	if not _described.is_empty(): _retire(_described)
	_described = {}
	_description_serial += 1
	if not _prepared.is_empty(): _retire(_prepared)
	_prepared = {}
	if not _packet_bootstrap_bases.is_empty(): _retire(_packet_bootstrap_bases)
	_packet_bootstrap_bases = {}

## Drain old scene callbacks before the ordinary owner replaces NPC registries.
## Configuration alone never opens the fence; the owner explicitly completes
## it after replacing its registries, with a fresh worker poll required too.
func begin_world_reset() -> void:
	if _closing or _world_reset_pending: return
	configure(_admission)
	_world_reset_pending = true

func complete_world_reset() -> void:
	if _world_reset_pending: _world_reset_release_requested = true

func requires_scene_retirement() -> bool:
	return not _scenes.is_empty() or _has_scene_retirements()

func world_reset_ready() -> bool:
	return _world_reset_pending and not requires_scene_retirement() and _retired.is_empty() \
		and _worker_polled_configuration == _configuration_serial \
		and not bool(_last_worker_status.get("busy",true)) and not bool(_last_worker_status.get("retirementPending",true))

func request_shutdown() -> void:
	_closing = true
	_pending_section_source_retirements.clear()
	_pending_section_source_retirement_queue.clear()
	_legacy_visual_section_index.clear()
	_section_contribution_capture_jobs.clear()
	_retained_transform_artifact_captures.clear()
	_retained_source_compile_job = {}
	_retained_region_bounds = []
	_retained_consumers = []
	_clear_retained_priorities()
	_observer_region_bounds = Rect2i()
	_prefetch_regions.clear()
	_prefetch_started_usec.clear()
	_demand_started_usec.clear()
	_demand_revision += 1
	_view_revision += 1
	_retire_all_scenes()
	_desired = {}
	_inflight = {}
	_retire_all()
	_worker.request_shutdown()

func stats() -> Dictionary:
	var constructed := 0
	var scenes: Array[Dictionary] = []
	for entry in _scenes.values():
		if entry.phase=="scene_ready": constructed+=1
		var job = entry.get("job",null)
		var job_status: Dictionary = job.status_count() if job!=null else {}
		var demand: Dictionary = entry.get("packetDemandStatus",{})
		scenes.append({"region":entry.get("region",Vector2i()),"phase":entry.get("phase",""),
			"jobPhase":job_status.get("phase",""),"packetMode":bool(entry.get("packetMode",false)),
			"demandRevision":int(entry.get("demandRevision",-1)),"packetDemandStatus":String(demand.get("status","")),
			"packetDemandReason":String(demand.get("reason","")),"packetDemandRequests":demand.get("requests",[]).size(),
			"packetForegroundGroups":demand.get("foregroundGroupIds",[]).size(),
			"packetDeferredGroups":int(demand.get("deferredGroupCount",demand.get("deferredGroupIds",[]).size())),
			"packetReadinessGroups":demand.get("readinessGroupIds",[]).size(),
			"physicalGroupsComplete":int(job_status.get("physicalGroupsComplete",0)),"physicalGroupsTotal":int(job_status.get("physicalGroupsTotal",0)),
			"retainedGroupRequests":int(job_status.get("retainedGroupRequests",0)),"publicationTransactionId":int(job_status.get("publicationTransactionId",0)),
			"occupiedTransactions":int(job_status.get("occupiedTransactions",0)),"occupancyWaitReason":String(entry.get("occupancyWaitReason","")),
			"occupancyWaitCount":int(entry.get("occupancyWaitCount",0)),
			"occupancyWaitUsec":Time.get_ticks_usec()-int(entry.get("occupancyWaitStartedUsec",Time.get_ticks_usec())) if entry.has("occupancyWaitStartedUsec") else 0,
			"navigationPhysicalGroups":entry.get("navigationPhysicalGroups",{}).size(),
			"navigationPhysicalPending":entry.get("navigationPhysicalPending",{}).duplicate(),
			"publicationMilestones":entry.get("publicationMilestones",{}).duplicate(true)})
	scenes.sort_custom(func(a: Dictionary,b: Dictionary) -> bool:
		var left: Vector2i = a.region
		var right: Vector2i = b.region
		return left.y<right.y if left.y!=right.y else left.x<right.x)
	var scheduling: Dictionary = _dispatch_metrics.duplicate(true)
	scheduling["dispatchTurn"] = _dispatch_turn
	scheduling["priorityAgingDispatchTurns"] = PRIORITY_AGING_DISPATCH_TURNS
	scheduling["sources"] = []
	for region: Vector2i in _navigation:
		var entry: Dictionary = _navigation[region]
		scheduling.sources.append({"region":region,"pendingTiles":entry.requested.size(),"completedTiles":entry.receipts.size(),
			"progress":entry.get("producerProgress",{}).duplicate(),
			"preparationUsecScope":"cumulative wall time inside producer begin/advance calls; excludes time between calls"})
	return {"generation":_generation,"worldSeed":_seed,"desiredSites":_desired.size(),
		"retainedBounds":_retained_region_bounds.size(),"observerBoundsRejected":_observer_bounds_rejected,
		"prefetchRegions":_prefetch_regions.duplicate(),"prefetchRejected":_prefetch_rejected,
		"residentSites":_resident_region_count(),"residentLimit":MAX_REGIONS,
		"worldResetPending":_world_reset_pending,"worldResetReady":world_reset_ready(),
		"preparedSites":_prepared.size(),"bootstrapBases":_packet_bootstrap_bases.size(),"describedSites":_described.size(),"pendingRetirements":_retired.size(),
		"activeToken":_inflight.get("token",0),"failures":_failures.duplicate(true),
		"dispatchCount":_dispatch_count,"acceptedCount":_accepted_count,"maxAdvanceUsec":_max_advance_usec,
		"pendingSectionSourceRetirements":_pending_section_source_retirements.size(),
		"publicationReady":false,"worker":_last_worker_status,"sourceScheduling":scheduling,
		"legacyVisualIndex":_legacy_visual_section_index.stats(),
		"sceneDiagnostics":scenes,"sceneUnitMetrics":_scene_unit_metrics_compact(),"demandRevision":_demand_revision,"viewRevision":_view_revision,
		"doorLifecycleConfigured":_door_lifecycle_configured,"doorLifecycleAvailable":_door_callbacks_ready(),
		"constructionStatus":"available" if _scene_callbacks_ready() else "pending",
		"constructionReason":"" if _scene_callbacks_ready() else "scene_lifecycle_capability_missing",
		"publishingScenes":_scenes.size()-constructed,"constructedScenes":constructed,
		"retiringScenes":_retiring_scenes.size()+_pending_scene_disposals.size()+_submitted_scene_disposals.size(),
		"retiringSceneNodes":_retiring_scenes.size(),"retiringScenePayloads":_pending_scene_disposals.size()+_submitted_scene_disposals.size(),
		"sceneStartedCount":_scene_started_count,"sceneCompletedCount":_scene_completed_count,"sceneMaxStepUsec":_scene_max_step_usec,
		"shutdownComplete":_closing and _scenes.is_empty() and not _has_scene_retirements() and _retired.is_empty() and bool(_last_worker_status.get("shutdownComplete",false))}

func _has_scene_retirements() -> bool:
	return not _retiring_scenes.is_empty() or not _pending_scene_disposals.is_empty() or not _submitted_scene_disposals.is_empty()

func _region_retiring(region: Vector2i) -> bool:
	for entry in _retiring_scenes:
		if entry.region==region: return true
	return _pending_scene_disposals.values().has(region) or _submitted_scene_disposals.values().has(region)

func _retire_scene(region: Vector2i) -> void:
	_pending_packet_navigation.erase(region)
	if not _scenes.has(region): return
	if _navigation.has(region):
		_retire(_navigation[region])
		_navigation.erase(region)
	if not _inflight.is_empty() and _inflight.get("kind")=="navigation" and _inflight.region==region:
		_worker.cancel(int(_inflight.token))
		_inflight = {}
	var entry: Dictionary=_scenes[region]
	entry.job.cancel()
	entry.phase="retiring"
	_retiring_scenes.append(entry)
	_scenes.erase(region)

func _retire_all_scenes() -> void:
	for region: Vector2i in _scenes.keys(): _retire_scene(region)

func _prune_invalid_scenes() -> void:
	# Reset, source revision and parent loss must invalidate even on drain-only
	# calls. Ordinary pause does not pretend a missing demand sample is departure.
	for region: Vector2i in _scenes.keys():
		var entry: Dictionary=_scenes[region]
		var source: Dictionary=_admission.source_state(region) if _admission!=null else {}
		if source.get("binding",{})!=entry.binding or not _current_binding(entry.binding) or not _scene_callbacks_ready():
			_retire_scene(region)
			continue
		var phase: String = entry.job.status_count().phase
		# Packet mode deliberately has no root while its immutable physical
		# packet is still being compiled.  The adapter creates the root only after
		# it receives that exact packet and moves into building_begin.
		if phase!="building_begin" and not (bool(entry.get("packetMode",false)) and phase=="packet_wait"):
			var site: Node3D=entry.job.own_node_root()
			var parent: Node3D=_scene_parent.get_ref() as Node3D
			if not is_instance_valid(site) or site.is_queued_for_deletion() or not site.is_inside_tree() or site.get_parent()!=parent \
					or not site.global_transform.is_equal_approx(Transform3D(Basis.IDENTITY,entry.profile.origin)):
				_failures[region]={"binding":entry.binding,"reason":"constructed_scene_owner_lost" if entry.phase=="scene_ready" else "publication_scene_owner_lost"}
				_retire_scene(region)

func _description_revision_matches(region: Vector2i, binding: Dictionary, profile: Dictionary, description) -> bool:
	if not _described.has(region): return true
	var retained: Dictionary = _described[region]
	var prior = retained.get("description")
	return retained.get("binding",{})==binding and retained.get("configuration",-1)==_configuration_serial \
		and retained.get("profile",{}).get("sourceSignature","")==profile.get("sourceSignature","") \
		and prior!=null and description!=null and prior.binding==binding and description.binding==binding \
		and prior.origin==description.origin and prior.source_identity_digest.length()==64 \
		and prior.source_identity_digest==description.source_identity_digest

func _start_scene(region: Vector2i, source: Dictionary) -> bool:
	if not _scene_callbacks_ready() or _scenes.has(region) or _region_retiring(region): return false
	if not _prepared.has(region) or _scenes.has(region) or _region_retiring(region) or not _scene_callbacks_ready(): return false
	var prepared: Dictionary=_prepared[region]
	# Bind against a fresh non-enqueuing lookup immediately before consumption.
	var current: Dictionary=_admission.source_state(region)
	if current.get("binding",{})!=prepared.binding or source.binding!=prepared.binding or not _current_binding(prepared.binding): return false
	var packet_mode: bool = bool(prepared.get("packetMode",false))
	var description = prepared.base.description if packet_mode else prepared.prepared.describe(prepared.binding)
	if description==null or description.binding!=prepared.binding or description.origin!=prepared.profile.origin \
			or not _description_revision_matches(region,prepared.binding,prepared.profile,description):
		_failures[region] = {"binding":prepared.binding,"reason":"scene_description_identity_mismatch"}
		_retire(prepared)
		_prepared.erase(region)
		return false
	if _described.has(region) and _described[region].description!=description:
		# Revisit reconstruction creates a new immutable descriptor object for the
		# same source revision. Promote that exact owner while preserving the
		# revision serial; object identity is a lifetime fact, not world identity.
		_described[region].profile=prepared.profile
		_described[region].description=description
	var parent: Node3D=_scene_parent.get_ref() as Node3D
	var job=SceneJob.new()
	if not job.set_tree_retire_callback(Callable(_tree_retire_receiver.get_ref(),_tree_retire_method),_require_tree_retirement_ack): return false
	if _door_lifecycle_configured and not job.set_door_callbacks(Callable(_door_receiver.get_ref(),_door_method),Callable(_door_retire_receiver.get_ref(),_door_retire_method)): return false
	var result: Dictionary = job.begin_prepared_base(prepared.base,prepared.profile,prepared.binding,parent,Callable(_tree_receiver.get_ref(),_tree_method)) if packet_mode \
		else job.begin(prepared.prepared,prepared.profile,prepared.binding,parent,Callable(_tree_receiver.get_ref(),_tree_method))
	if result.get("status")!="pending_budget":
		_failures[region]={"binding":prepared.binding,"reason":String(result.get("reason","scene_begin_failed"))}
		_retire(prepared); _prepared.erase(region)
		return false
	var demand_started := int(_demand_started_usec.get(region,Time.get_ticks_usec()))
	var prefetch_started := int(_prefetch_started_usec.get(region,demand_started))
	_scenes[region]={"region":region,"binding":prepared.binding,"profile":prepared.profile,"job":job,"phase":"publishing","packetMode":packet_mode,
		"publicationMilestones":{"sourceDemandStartedUsec":demand_started,
			"prefetchStartedUsec":prefetch_started,"prefetchLeadUsec":maxi(0,demand_started-prefetch_started),
			"sceneStartedAfterDemandUsec":maxi(0,Time.get_ticks_usec()-demand_started),
			"firstSilhouetteUsec":-1,"usableGatePathUsec":-1,"visibleCourtyardUsec":-1,
			"accessibleHomeUsec":-1,"completeDemandedUsec":-1,"fullSourceUsec":-1}}
	_prepared.erase(region)
	_scene_started_count+=1
	return true

func _refresh_scene_group_demand(entry: Dictionary) -> bool:
	if entry.get("demandRevision",-1)==_demand_revision: return true
	if bool(entry.get("packetMode",false)):
		# Camera/bounds revisions may arrive several times while one immutable
		# foreground packet window is still publishing. If that window already
		# contains every new immediate physical and navigation group, retain it and
		# let the latest view select the *next* window. This makes view motion a
		# priority input without withdrawing accepted work or rebuilding closures.
		if _packet_window_covers_current_immediate_demand(entry):
			if not _retain_navigation_physical_demand(entry): return false
			entry["demandRevision"]=_demand_revision
			return true
		var base: Preparation.PreparedPublicationBase = entry.job._cpu.get("publicationBase")
		var completed: Dictionary = entry.job.completed_physical_group_ids(entry.binding)
		_record_publication_milestones(entry,completed,base.description.publication_groups.groups.size() if base!=null else 0)
		var plan_started := Time.get_ticks_usec()
		# View-ranked detail advances once for each distinct camera revision. A
		# navigation/tile refresh with an unchanged camera must publish only its
		# exact physical closure; otherwise every navigation acknowledgement also
		# installs another unrelated presentation window while the player is still.
		var prior_demand: Dictionary=entry.get("packetDemandStatus",{})
		var include_view_progress := _presentation_progress_due(entry,_view_revision,completed.size(),
			int(prior_demand.get("deferredGroupCount",0)),not prior_demand.get("requests",[]).is_empty())
		var plan: Dictionary = _packet_foreground_plan(entry.region,entry.binding,
			base.description if base!=null else null,base,completed,include_view_progress)
		_record_scene_unit("demand_plan_total",plan_started,base.description.publication_groups.groups.size() if base!=null else 0)
		if plan.get("status")!="ready":
			entry["packetDemandStatus"] = plan.duplicate(true)
			return false
		if plan.get("readinessGroupIds",[]).size()>MAX_REQUIRED_FOREGROUND_GROUPS:
			entry["packetDemandStatus"]={"status":"failed","reason":"packet_required_foreground_scope_too_large",
				"groupCount":plan.readinessGroupIds.size()}
			return false
		# Keep the source/view window separate from the rolling navigation
		# supplements. Completed supplements must leave the active slot census;
		# otherwise one full batch permanently consumes the 128-group window and
		# later tile collision closures can never enter after a revisit.
		var source_foreground_group_ids: Array=plan.foregroundGroupIds.duplicate()
		var source_readiness_group_ids: Array=plan.readinessGroupIds.duplicate()
		var navigation_supplemental_group_ids: Array=[]
		var navigation_merge_started := Time.get_ticks_usec()
		var navigation_groups: Dictionary = entry.get("navigationPhysicalGroups",{})
		if not navigation_groups.is_empty():
			# Navigation publication can ask for tiles from both the capsule and the
			# retained background ring.  They share a packet scene, but they must not
			# share foreground priority: otherwise every background physical closure
			# is promoted into the startup gate before the capsule tile can receive a
			# receipt. Preserve the per-tile request priority all the way to group
			# selection. A group shared by tiles keeps its most urgent owner.
			var navigation_ids: Dictionary = {}
			for group_id: String in navigation_groups:
				var priority: int = int(navigation_groups[group_id])
				if priority<0 or priority>4:
					entry["packetDemandStatus"] = {"status":"failed","reason":"invalid_navigation_physical_priority"}
					return false
				navigation_ids[group_id] = true
			var navigation_slots := _navigation_supplement_slots(plan.foregroundGroupIds.size(),0)
			var navigation_selection := _bounded_navigation_group_requests(entry,navigation_groups,
			plan.foregroundGroupIds,navigation_slots,"navigation:%d,%d" % [entry.region.x,entry.region.y],true)
			if navigation_selection.get("status")!="ready":
				entry["packetDemandStatus"] = navigation_selection.duplicate(true)
				return false
			for request: Dictionary in navigation_selection.requests:
				plan.requests.append(request)
				for group_id: String in request.groupIds:
					if not plan.foregroundGroupIds.has(group_id):
						plan.foregroundGroupIds.append(group_id)
						navigation_supplemental_group_ids.append(group_id)
					if int(request.priority)==0 and not plan.readinessGroupIds.has(group_id): plan.readinessGroupIds.append(group_id)
			plan.foregroundGroupIds.sort()
			plan.readinessGroupIds.sort()
			if not bool(plan.get("implicitDeferred",false)):
				var deferred: Array[String] = []
				for group_id: String in plan.deferredGroupIds:
					if not navigation_ids.has(group_id): deferred.append(group_id)
				plan.deferredGroupIds = deferred
		_record_scene_unit("demand_navigation_merge",navigation_merge_started,navigation_groups.size())
		var handoff_started := Time.get_ticks_usec()
		var packet_result: Dictionary = entry.job.replace_packet_foreground_group_demands_compact(plan.requests,plan.deferredGroupIds,entry.binding) \
			if bool(plan.get("implicitDeferred",false)) else entry.job.replace_packet_foreground_group_demands(plan.requests,plan.deferredGroupIds,entry.binding)
		_record_scene_unit("demand_job_handoff",handoff_started,plan.foregroundGroupIds.size()+plan.get("deferredGroupCount",plan.deferredGroupIds.size()))
		if packet_result.get("status")!="retained":
			entry["packetDemandStatus"] = packet_result.duplicate(true)
			return false
		# Gameplay readiness is the semantic first-content closure assembled by the
		# plan (spatial safety, two complete homes and a door). The wider ranked
		# window remains non-blocking presentation work before and after readiness.
		var readiness_group_ids: Array = plan.readinessGroupIds
		var status_copy_started := Time.get_ticks_usec()
		entry["packetDemandStatus"] = {"status":"retained","reason":"packet_foreground_groups_deferred" if not plan.blockedGroupIds.is_empty() and plan.requests.is_empty() else "",
			"requests":plan.requests.duplicate(true),
			"foregroundGroupIds":plan.foregroundGroupIds.duplicate(),"readinessGroupIds":readiness_group_ids.duplicate(),
			"sourceForegroundGroupIds":source_foreground_group_ids,
			"sourceReadinessGroupIds":source_readiness_group_ids,
			"navigationSupplementalGroupIds":navigation_supplemental_group_ids,
			"deferredGroupIds":plan.deferredGroupIds.duplicate(),"deferredGroupCount":packet_result.get("deferredGroups",plan.get("deferredGroupCount",0)),
			"implicitDeferred":plan.get("implicitDeferred",false),"candidateCount":plan.get("candidateCount",0),
			"viewPrioritizedGroupIds":plan.get("viewPrioritizedGroupIds",[]).duplicate(),
			"portalGroupIds":plan.get("portalGroupIds",[]).duplicate(),
			"firstUsefulGroupIds":plan.get("firstUsefulGroupIds",[]).duplicate(),
			"firstUsefulHomeIds":plan.get("firstUsefulHomeIds",[]).duplicate(),
			"firstUsefulDoorGroupId":plan.get("firstUsefulDoorGroupId",""),
			"firstUsefulStructuralGroupIds":plan.get("firstUsefulStructuralGroupIds",[]).duplicate(),
			"courtyardGroupIds":plan.get("courtyardGroupIds",[]).duplicate(),
			"blockedGroupIds":plan.blockedGroupIds.duplicate(),"boundaryGroupIds":plan.boundaryGroupIds.duplicate(),
			"viewProgressIncluded":include_view_progress}
		_record_scene_unit("demand_status_copy",status_copy_started,plan.foregroundGroupIds.size()+plan.deferredGroupIds.size())
		entry["demandRevision"] = _demand_revision
		if include_view_progress: entry["viewRevision"] = _view_revision
		# A previously acknowledged packet scene stays available for its committed
		# closure, but a new foreground demand must not inherit that acknowledgement.
		# Its exact receipt is checked again before the service reports readiness.
		if entry.phase=="scene_ready" and not _packet_foreground_physical_ready(entry.region,entry.binding):
			entry.phase="publishing"
		return true
	var requests: Array[Dictionary] = []
	for consumer: Dictionary in _retained_consumers:
		for site: Dictionary in consumer.sites:
			if site.binding==entry.binding:
				requests.append({"ownerId":"region:%d" % consumer.ownerId,"groupIds":site.groupIds,"priority":consumer.priority})
	var result: Dictionary = entry.job.replace_publication_group_demands(requests,entry.binding)
	if result.get("status") != "retained": return false
	entry["demandRevision"] = _demand_revision
	return true


static func _view_progress_due(entry: Dictionary, current_view_revision: int) -> bool:
	return int(entry.get("viewRevision",-1))!=current_view_revision


static func _presentation_progress_due(entry: Dictionary, current_view_revision: int,
		completed_group_count: int, deferred_group_count: int, has_requests: bool) -> bool:
	return _view_progress_due(entry,current_view_revision) \
		or has_requests and deferred_group_count>0 and completed_group_count<MAX_RESIDENT_PRESENTATION_GROUPS


func _packet_window_covers_current_immediate_demand(entry: Dictionary) -> bool:
	var demand: Dictionary = entry.get("packetDemandStatus",{})
	if demand.get("status")!="retained" or demand.get("foregroundGroupIds",[]).is_empty(): return false
	var retained: Dictionary = {}
	var incomplete := false
	for group_id: String in demand.foregroundGroupIds:
		retained[group_id]=true
		if not entry.job.physical_group_packet_completed_for_scheduling(group_id,entry.binding): incomplete=true
	if not incomplete: return false
	var observer_covered := not _observer_region_bounds.has_area()
	var matched_site := false
	for consumer: Dictionary in _retained_consumers:
		if consumer.get("bounds") is Rect2i and consumer.bounds.encloses(_observer_region_bounds): observer_covered=true
		for site: Dictionary in consumer.sites:
			if site.binding!=entry.binding: continue
			matched_site=true
			if not site.has("foregroundGroupIds"): return false
			for group_id: String in site.foregroundGroupIds:
				if not retained.has(group_id) and not entry.job.physical_group_packet_completed_for_scheduling(group_id,entry.binding): return false
	if not matched_site or not observer_covered: return false
	return true


func _retain_navigation_physical_demand(entry: Dictionary) -> bool:
	var demand: Dictionary=entry.get("packetDemandStatus",{})
	var completed: Dictionary=entry.job.completed_physical_group_ids(entry.binding)
	var source_foreground: Array=demand.get("sourceForegroundGroupIds",demand.get("foregroundGroupIds",[])).duplicate()
	var source_readiness: Array=demand.get("sourceReadinessGroupIds",demand.get("readinessGroupIds",[])).duplicate()
	var supplemental: Array=[]
	for group_id: String in demand.get("navigationSupplementalGroupIds",[]):
		if not completed.has(group_id): supplemental.append(group_id)
	var foreground: Array=source_foreground.duplicate()
	for group_id: String in supplemental:
		if not foreground.has(group_id): foreground.append(group_id)
	var readiness: Array=source_readiness.duplicate()
	var navigation_slots:=_navigation_supplement_slots(source_foreground.size(),supplemental.size())
	var navigation: Dictionary = entry.get("navigationPhysicalGroups",{})
	var selection := _bounded_navigation_group_requests(entry,navigation,foreground,navigation_slots,"navigation-supplement",true)
	if selection.get("status")!="ready":
		entry["packetDemandStatus"]=selection.duplicate(true)
		return false
	var requests: Array=selection.requests
	if requests.is_empty():
		foreground.sort()
		readiness.sort()
		supplemental.sort()
		demand.foregroundGroupIds=foreground
		demand.readinessGroupIds=readiness
		demand.navigationSupplementalGroupIds=supplemental
		entry["packetDemandStatus"]=demand
		return true
	var retained: Dictionary=entry.job.retain_packet_supplemental_group_demands(requests,entry.binding)
	if retained.get("status")!="retained":
		entry["packetDemandStatus"]=retained
		return false
	for request: Dictionary in requests:
		for group_id: String in request.groupIds:
			if not foreground.has(group_id): foreground.append(group_id)
			if not supplemental.has(group_id): supplemental.append(group_id)
			if int(request.priority)==0 and not readiness.has(group_id): readiness.append(group_id)
	foreground.sort()
	readiness.sort()
	supplemental.sort()
	demand.foregroundGroupIds=foreground
	demand.readinessGroupIds=readiness
	demand.navigationSupplementalGroupIds=supplemental
	demand["deferredGroupCount"]=retained.get("deferredGroups",demand.get("deferredGroupCount",0))
	entry["packetDemandStatus"]=demand
	return true


static func _navigation_supplement_slots(source_group_count: int, active_supplement_count: int) -> int:
	return mini(maxi(0,MAX_NAVIGATION_MERGED_FOREGROUND_GROUPS-active_supplement_count),
		maxi(0,MAX_REQUIRED_FOREGROUND_GROUPS-source_group_count-active_supplement_count))


## Navigation owns complete collision closures, but its retained set may be
## wider than the rolling physical window. Apply the cap to whole dependency
## closures rather than individual alphabetic IDs; otherwise the admitted
## subset can strand a requested group behind an intentionally deferred parent.
func _bounded_navigation_group_requests(entry: Dictionary, navigation: Dictionary,
		foreground: Array, slot_limit: int, owner_prefix: String, allow_exact_closure_overflow := false) -> Dictionary:
	if slot_limit<=0: return {"status":"ready","requests":[]}
	var base: Preparation.PreparedPublicationBase = entry.job._cpu.get("publicationBase")
	if base==null or base.description==null: return {"status":"pending","reason":"packet_publication_base_pending"}
	var completed: Dictionary=entry.job.completed_physical_group_ids(entry.binding)
	var compact_plan=base.publication_plan
	var groups: Dictionary=base.description.publication_groups.groups
	var retained: Dictionary={}
	for group_id: String in foreground: retained[group_id]=true
	var selected: Dictionary={}
	var selected_priority: Dictionary={}
	var by_priority: Dictionary={}
	for group_id: String in navigation:
		var priority:=int(navigation[group_id])
		if priority<0 or priority>4: return {"status":"failed","reason":"invalid_navigation_physical_priority"}
		if not by_priority.has(priority): by_priority[priority]=[]
		by_priority[priority].append(group_id)
	var remaining:=slot_limit
	var hard_remaining:=maxi(0,MAX_REQUIRED_FOREGROUND_GROUPS-foreground.size())
	for priority: int in range(5):
		if not by_priority.has(priority): continue
		by_priority[priority].sort()
		for group_id: String in by_priority[priority]:
			if completed.has(group_id) or retained.has(group_id) or selected.has(group_id): continue
			var closure: Dictionary=_packet_dependency_window_for_plan(compact_plan,groups,group_id,completed)
			if closure.get("status")!="ready": return closure
			var additions: Array[String]=[]
			for required_id: String in closure.groupIds:
				if completed.has(required_id) or retained.has(required_id) or selected.has(required_id): continue
				additions.append(required_id)
			if additions.size()>remaining:
				# A physical navigation receipt is an exact collision closure, not
				# optional city presentation.  Its dependencies must either arrive
				# together or remain absent.  Let the first such closure use the
				# reserved hard foreground headroom; otherwise a 129-member civic
				# eave can be deferred forever behind the 128-member rolling window.
				if not allow_exact_closure_overflow or not selected.is_empty() or additions.size()>hard_remaining:
					continue
			for required_id: String in additions:
				selected[required_id]=true
				selected_priority[required_id]=priority
				remaining-=1
				hard_remaining-=1
	var requests: Array[Dictionary]=[]
	for priority: int in range(5):
		var ids: Array[String]=[]
		for group_id: String in selected:
			if int(selected_priority[group_id])==priority: ids.append(group_id)
		ids.sort()
		if not ids.is_empty(): requests.append({"ownerId":"%s:%d" % [owner_prefix,priority],"groupIds":ids,"priority":priority})
	return {"status":"ready","requests":requests,"admittedGroups":selected.size(),"remainingSlots":remaining}

func _record_scene_unit(label: String, started_usec: int, work_units := -1) -> void:
	var elapsed := Time.get_ticks_usec()-started_usec
	var metric: Dictionary = _scene_unit_metrics.get(label,{"calls":0,"totalUsec":0,"maxUsec":0,"lastUsec":0,
		"samples":[],"sampleCursor":0,"workUnitsTotal":0,"workUnitsMax":0,"workUnitsLast":0})
	metric.calls += 1
	metric.totalUsec += elapsed
	metric.maxUsec = maxi(int(metric.maxUsec),elapsed)
	metric.lastUsec = elapsed
	var samples: Array = metric.samples
	if samples.size()<SCENE_UNIT_SAMPLE_CAPACITY:
		samples.append(elapsed)
	else:
		var cursor := int(metric.sampleCursor)%SCENE_UNIT_SAMPLE_CAPACITY
		samples[cursor]=elapsed
		metric.sampleCursor=(cursor+1)%SCENE_UNIT_SAMPLE_CAPACITY
	metric.samples=samples
	if work_units>=0:
		metric.workUnitsTotal += work_units
		metric.workUnitsMax = maxi(int(metric.workUnitsMax),work_units)
		metric.workUnitsLast = work_units
	_scene_unit_metrics[label] = metric


static func _milestone_targets_complete(targets: Array, completed: Dictionary) -> bool:
	if targets.is_empty(): return false
	for raw_id in targets:
		if not raw_id is String or not completed.has(raw_id): return false
	return true


func _record_publication_milestones(entry: Dictionary, completed: Dictionary, total_groups: int) -> void:
	var milestones: Dictionary = entry.get("publicationMilestones",{})
	if milestones.is_empty(): return
	var elapsed := maxi(0,Time.get_ticks_usec()-int(milestones.sourceDemandStartedUsec))
	if int(milestones.firstSilhouetteUsec)<0 and not completed.is_empty(): milestones.firstSilhouetteUsec=elapsed
	var demand: Dictionary = entry.get("packetDemandStatus",{})
	var gate_targets: Array = demand.get("firstUsefulStructuralGroupIds",[]).duplicate()
	var door_id := String(demand.get("firstUsefulDoorGroupId",""))
	if not door_id.is_empty() and not gate_targets.has(door_id): gate_targets.append(door_id)
	if int(milestones.usableGatePathUsec)<0 and _milestone_targets_complete(gate_targets,completed):
		milestones.usableGatePathUsec=elapsed
	if int(milestones.visibleCourtyardUsec)<0 and _milestone_targets_complete(demand.get("courtyardGroupIds",[]),completed):
		milestones.visibleCourtyardUsec=elapsed
	if int(milestones.accessibleHomeUsec)<0 and _milestone_targets_complete(demand.get("firstUsefulGroupIds",[]),completed):
		milestones.accessibleHomeUsec=elapsed
	if int(milestones.completeDemandedUsec)<0 and _milestone_targets_complete(demand.get("foregroundGroupIds",[]),completed):
		milestones.completeDemandedUsec=elapsed
	if int(milestones.fullSourceUsec)<0 and total_groups>0 and completed.size()>=total_groups:
		milestones.fullSourceUsec=elapsed
	entry.publicationMilestones=milestones

func _scene_unit_metrics_snapshot() -> Dictionary:
	var result: Dictionary = {}
	for label: String in _scene_unit_metrics:
		var metric: Dictionary = _scene_unit_metrics[label].duplicate(true)
		var samples: Array = metric.get("samples",[])
		var ordered: Array = samples.duplicate()
		ordered.sort()
		metric.erase("samples")
		metric.erase("sampleCursor")
		metric["sampleCount"] = ordered.size()
		metric["sampleCapacity"] = SCENE_UNIT_SAMPLE_CAPACITY
		metric["sampleScope"] = "bounded_all_calls" if int(metric.calls)<=SCENE_UNIT_SAMPLE_CAPACITY else "bounded_recent_calls"
		metric["p50Usec"] = _scene_unit_percentile(ordered,0.50)
		metric["p95Usec"] = _scene_unit_percentile(ordered,0.95)
		metric["p99Usec"] = _scene_unit_percentile(ordered,0.99)
		result[label]=metric
	return result

## Explicit, bounded diagnostic snapshot. Ordinary stats deliberately omit the
## retained samples so polling cannot sort/copy the profiler's ring every frame.
func profile_scene_unit_metrics() -> Dictionary:
	return _scene_unit_metrics_snapshot()

func _scene_unit_metrics_compact() -> Dictionary:
	var result: Dictionary = {}
	for label: String in _scene_unit_metrics:
		var source: Dictionary = _scene_unit_metrics[label]
		result[label]={"calls":source.calls,"totalUsec":source.totalUsec,"maxUsec":source.maxUsec,"lastUsec":source.lastUsec,
			"workUnitsTotal":source.workUnitsTotal,"workUnitsMax":source.workUnitsMax,"workUnitsLast":source.workUnitsLast}
	return result

static func _scene_unit_percentile(ordered: Array, percentile: float) -> int:
	if ordered.is_empty(): return 0
	var index := clampi(ceili(percentile*float(ordered.size()))-1,0,ordered.size()-1)
	return int(ordered[index])

func _pump_scenes(ready: Dictionary, allow_build: bool, started: int, budget_usec: int) -> void:
	# One shared budget, fair across building and retirement. No per-site budget
	# multiplication. Job.advance itself packs cheap work into its remaining slice.
	var units := 0
	var configuration:=_configuration_serial
	var demand_revision := _demand_revision
	while units==0 or Time.get_ticks_usec()-started<budget_usec:
		if _closing or configuration!=_configuration_serial or demand_revision!=_demand_revision: allow_build=false
		var work_started:=Time.get_ticks_usec()
		var remaining:=maxi(1,budget_usec-int(work_started-started))
		var progressed:=false
		if not _retiring_scenes.is_empty() and (_prefer_retirement or not allow_build or not _has_scene_work(ready)):
			# Keep this owner visible during callbacks, including reentrant reset
			# or attempted root rebinding, until its current unit returns.
			var entry: Dictionary=_retiring_scenes[0]
			var retirement_started := Time.get_ticks_usec()
			entry.job.advance(mini(remaining,SCENE_JOB_SLICE_USEC))
			_record_scene_unit("retirement_advance",retirement_started)
			_retiring_scenes.pop_front()
			if entry.job.status().retirementReady:
				var payload: Dictionary=entry.job.take_retirement_payload()
				_retire({"scenePayload":payload,"sceneEntry":entry})
				_pending_scene_disposals[_retirement_serial]=entry.region
			else: _retiring_scenes.append(entry)
			progressed=true; _prefer_retirement=false
		elif allow_build and _scene_callbacks_ready():
			for region: Vector2i in _prepared.keys():
				if ready.has(region) and not _region_retiring(region) and not _failures.has(region):
					var start_scene_started := Time.get_ticks_usec()
					progressed=_start_scene(region,ready[region])
					_record_scene_unit("scene_start",start_scene_started)
					if progressed or configuration!=_configuration_serial or demand_revision!=_demand_revision or _closing: break
			if not progressed and configuration==_configuration_serial and demand_revision==_demand_revision and not _closing:
				var regions: Array=_scenes.keys()
				for offset in range(regions.size()):
					var index:=(_scene_cursor+offset)%regions.size()
					var region: Vector2i=regions[index]
					if not _scenes.has(region): continue
					var entry: Dictionary=_scenes[region]
					# A packet scene may already satisfy its current foreground physical
					# closure while retaining deferred groups for later streaming or
					# navigation demand.  Keep serving that resident owner after its first
					# readiness acknowledgement; a later demand revision can demote it
					# before it publishes another packet.
					if entry.phase not in ["publishing","scene_ready"] or not ready.has(region): continue
					var replay_started:=Time.get_ticks_usec()
					var replay: Dictionary=entry.job.advance_chunk_static_packet_replay(mini(remaining,SCENE_JOB_SLICE_USEC))
					_record_scene_unit("static_packet_replay",replay_started)
					if replay.get("status")=="failed":
						_failures[region]={"binding":entry.binding,"reason":String(replay.get("reason","static_packet_replay_failed")),
							"sourceId":String(replay.get("sourceId",""))}
						_retire_scene(region)
						progressed=true
						break
					if replay.get("status")=="pending_budget":
						# A replay may be waiting for its owner chunk or native packet
						# backpressure. Rotate immediately so it cannot consume this
						# frame's whole service budget by retrying the same scene.
						_scene_cursor=(index+1)%regions.size()
						_prefer_retirement=true
						return
					if replay.get("status")=="completed":
						_scene_cursor=(index+1)%regions.size()
						progressed=true
						break
					var demand_started := Time.get_ticks_usec()
					var demand_ready := _refresh_scene_group_demand(entry)
					_record_scene_unit("demand_refresh",demand_started)
					if not demand_ready: continue
					# The exact spatial safety closure is sufficient to resume gameplay.
					# This resident owner continues view-ranked/background publication.
					var packet_foreground_ready := bool(entry.get("packetMode",false)) \
							and _packet_foreground_physical_ready(region,entry.binding)
					if packet_foreground_ready:
						var milestone_base: Preparation.PreparedPublicationBase = entry.job._cpu.get("publicationBase")
						_record_publication_milestones(entry,entry.job.completed_physical_group_ids(entry.binding),
							milestone_base.description.publication_groups.groups.size() if milestone_base!=null else 0)
					if entry.phase=="publishing" and packet_foreground_ready:
						entry["firstUsefulWindowReady"]=true
						entry.phase="scene_ready"
						_scene_completed_count+=1
						progressed=true
						break
					var selection_started := Time.get_ticks_usec()
					var transaction: Dictionary = entry.job.pending_publication_transaction()
					_record_scene_unit("transaction_selection",selection_started)
					if transaction.get("status") in ["failed","cancelled"]:
						_failures[region] = {"binding":entry.binding,"reason":transaction.get("reason","publication_transaction_failed")}
						_retire_scene(region)
						progressed = true
						break
					var phase: String = entry.job.status_count().phase
					if bool(entry.get("packetMode",false)) and phase=="packet_wait":
						# A packet-mode transaction intentionally pins as pending until
						# this service submits its immutable packet.  Treat only that
						# precise pending reason as dispatchable; ordinary selection and
						# owner pending states remain retryable without worker work.
						if transaction.get("status")=="pending" and transaction.get("reason")=="physical_packet_foreground_demand_pending" \
								and packet_foreground_ready:
							var demand: Dictionary=entry.get("packetDemandStatus",{})
							var completed_count:=int(entry.job.status_count().get("physicalGroupsComplete",0))
							if _presentation_progress_due(entry,_view_revision,completed_count,
									int(demand.get("deferredGroupCount",0)),not demand.get("requests",[]).is_empty()):
								# Consume one bounded presentation window for the newest view.
								# An unchanged camera may warm only the capped resident working set;
								# exact owner/navigation revisions still refresh beyond that cap.
								entry["demandRevision"]=-1
								progressed=true
								break
							if entry.phase!="scene_ready":
								entry.phase="scene_ready"
								_scene_completed_count+=1
							progressed=true
							break
						if transaction.get("status")=="ready":
							var packet_guard_started := Time.get_ticks_usec()
							var packet_guard_allowed := _construction_transaction_allowed(transaction)
							_record_scene_unit("occupancy_guard",packet_guard_started)
							if not packet_guard_allowed:
								var deferred_occupancy: Dictionary = entry.job.defer_occupied_publication_transaction(int(transaction.transactionId))
								if deferred_occupancy.get("status")!="retained":
									_failures[region]={"binding":entry.binding,"reason":String(deferred_occupancy.get("reason","occupancy_defer_failed"))}
									_retire_scene(region)
								else:
									entry["occupancyWaitReason"]="actor_occupancy"
									entry["occupancyWaitCount"]=int(entry.get("occupancyWaitCount",0))+1
									entry["occupancyWaitStartedUsec"]=int(entry.get("occupancyWaitStartedUsec",Time.get_ticks_usec()))
								_scene_cursor=(index+1)%regions.size()
								progressed=true
								break
							var activated: Dictionary = entry.job.activate_physical_group_packet_scene(int(transaction.transactionId))
							if activated.get("status")!="pending_budget":
								_failures[region]={"binding":entry.binding,"reason":String(activated.get("reason","physical_packet_activate_failed")),
									"diagnostics":activated.duplicate(true),"transaction":transaction.duplicate(true)}
								_retire_scene(region)
							else:
								entry.erase("occupancyWaitReason")
								entry.erase("occupancyWaitStartedUsec")
							progressed=true
							break
						if transaction.get("status") not in ["ready","pending"] \
								or transaction.get("status")=="pending" and transaction.get("reason")!="physical_group_packet_pending": continue
						if not _inflight.is_empty(): continue
						# Navigation already has a prepared immutable source and live gameplay
						# requests. Let the outer shared-worker arbiter claim this idle turn
						# before another view-only physical packet.
						if not _navigation_physical_packet_pending(entry) and _has_dispatchable_navigation(ready): break
						var base: Preparation.PreparedPublicationBase = entry.job._cpu.get("publicationBase")
						var census: Dictionary = base.packet_eligibility
						if census.is_empty(): census=Preparation.classify_physical_group_packet_eligibility(base.description.publication_groups,base.building_source,base.furnishing_source)
						var allowed: bool = bool(census.get("ready",false))
						for group_id: String in transaction.groupIds:
							allowed = allowed and _packet_group_publishable(base.description,census,group_id)
						if not allowed:
							# A source revision can only narrow packet work.  Retain the
							# unsupported closure as deferred and leave the resident packet
							# scene intact; never replay the whole source through a legacy
							# path merely because one foreground tile needs a later family.
							var blocked: Dictionary = entry.get("packetDemandStatus",{}).duplicate(true)
							var ids: Array = blocked.get("blockedGroupIds",[])
							var deferred: Array = blocked.get("deferredGroupIds",[])
							var transaction_ids: Dictionary = {}
							for group_id: String in transaction.groupIds:
								transaction_ids[group_id] = true
								if not _packet_group_publishable(base.description,census,group_id) and not ids.has(group_id): ids.append(group_id)
								if not deferred.has(group_id): deferred.append(group_id)
							var remaining_requests: Array = []
							var remaining_group_ids: Dictionary={}
							for raw_request in blocked.get("requests",[]):
								if not raw_request is Dictionary: continue
								var remaining_ids: Array[String] = []
								for group_id: String in raw_request.get("groupIds",[]):
									if not transaction_ids.has(group_id):
										remaining_ids.append(group_id)
										remaining_group_ids[group_id]=true
								if not remaining_ids.is_empty():
									remaining_requests.append({"ownerId":raw_request.ownerId,"groupIds":remaining_ids,"priority":raw_request.priority})
							# A group previously recorded as explicitly blocked can become part
							# of another retained owner on a later merged navigation revision.
							# Foreground wins; keeping the stale diagnostic copy in both sets
							# would reject an otherwise dependency-complete compact plan.
							if bool(blocked.get("implicitDeferred",false)):
								var normalized_deferred: Array=[]
								for group_id: String in deferred:
									if not remaining_group_ids.has(group_id): normalized_deferred.append(group_id)
								deferred=normalized_deferred
							# Compact packet plans intentionally do not materialize the full
							# source-wide deferred complement.  Preserve that contract when a
							# selected transaction is later found to contain an ineligible
							# member; widening this update through the complete-scope API makes
							# an otherwise valid camera revision fail merely because unrelated
							# groups were implicit.
							var deferred_result: Dictionary = entry.job.replace_packet_foreground_group_demands_compact(
								remaining_requests,deferred,entry.binding) if bool(blocked.get("implicitDeferred",false)) \
								else entry.job.replace_packet_foreground_group_demands(remaining_requests,deferred,entry.binding)
							if deferred_result.get("status")!="retained":
								_failures[region] = {"binding":entry.binding,"reason":String(deferred_result.get("reason","packet_deferred_transaction_rejected"))}
								_retire_scene(region); progressed=true; break
							ids.sort()
							deferred.sort()
							blocked["blockedGroupIds"] = ids
							blocked["deferredGroupIds"] = deferred
							blocked["requests"] = remaining_requests
							blocked["status"] = "retained"
							blocked["reason"] = "packet_foreground_groups_deferred"
							entry["packetDemandStatus"] = blocked
							progressed=true; break
						var dispatch_started := Time.get_ticks_usec()
						var receipt := _worker.dispatch_physical_group_packet(base,transaction.groupIds,entry.binding)
						_record_scene_unit("packet_dispatch",dispatch_started)
						if receipt.get("status") in ["started","queued"] and not receipt.get("duplicate",false):
							_inflight={"kind":"physical_group_packet","region":region,"binding":entry.binding,"token":int(receipt.token),"transactionId":int(transaction.transactionId)}
							progressed=true
						break
					if transaction.get("status")!="ready": continue
					var guard_started := Time.get_ticks_usec()
					var guard_allowed := _construction_transaction_allowed(transaction)
					_record_scene_unit("occupancy_guard",guard_started)
					if not guard_allowed:
						if configuration!=_configuration_serial or demand_revision!=_demand_revision or _closing: break
						if bool(entry.get("packetMode",false)):
							# This packet already owns scene-side cursors/witnesses. Rotating it
							# would replay partial publication. Keep its exact phase pinned and
							# simply stop before the next mutation until the actor clears.
							entry["occupancyWaitReason"]="actor_occupancy_active_transaction"
							entry["occupancyWaitCount"]=int(entry.get("occupancyWaitCount",0))+1
							entry["occupancyWaitStartedUsec"]=int(entry.get("occupancyWaitStartedUsec",Time.get_ticks_usec()))
						else:
							var deferred_occupancy: Dictionary = entry.job.defer_occupied_publication_transaction(int(transaction.transactionId))
							if deferred_occupancy.get("status")!="retained":
								_failures[region]={"binding":entry.binding,"reason":String(deferred_occupancy.get("reason","occupancy_defer_failed"))}
								_retire_scene(region)
							else:
								entry["occupancyWaitReason"]="actor_occupancy"
								entry["occupancyWaitCount"]=int(entry.get("occupancyWaitCount",0))+1
								entry["occupancyWaitStartedUsec"]=int(entry.get("occupancyWaitStartedUsec",Time.get_ticks_usec()))
						_scene_cursor=(index+1)%regions.size()
						progressed=true
						break
					entry.erase("occupancyWaitReason")
					entry.erase("occupancyWaitStartedUsec")
					# Guard callbacks are external owners too: recapture no mutable
					# job from a generation/entry cancelled during the callback.
					# A packet scene remains a live publisher after its first gameplay
					# acknowledgement. Later rolling transactions must advance on that
					# same resident owner instead of being stranded in `building`.
					if not is_same(_scenes.get(region),entry) or entry.phase not in ["publishing","scene_ready"] \
							or entry.job.status_count().phase!=phase: continue
					if _admission.source_state(region).get("binding",{}) != entry.binding or not _scene_callbacks_ready(): continue
					_scene_cursor=(index+1)%regions.size()
					var job_started := Time.get_ticks_usec()
					var result: Dictionary=entry.job.advance(mini(remaining,SCENE_JOB_SLICE_USEC),int(transaction.transactionId))
					_record_scene_unit("job_advance",job_started)
					if not is_same(_scenes.get(region),entry):
						# A callback invalidated/moved this owner. It cannot publish
						# readiness or a failure into its replacement generation.
						progressed=true
						break
					if result.status in ["failed","cancelled"]:
						_failures[region]={"binding":entry.binding,"reason":String(result.reason)}
						_retire_scene(region)
					elif result.sceneReady:
						entry.phase="scene_ready"
						_scene_completed_count+=1
					progressed=true
					break
			_prefer_retirement=true
		if not progressed:
			if not _retiring_scenes.is_empty():
				_prefer_retirement=true
				units+=1
				continue
			break
		units+=1
		_scene_max_step_usec=maxi(_scene_max_step_usec,Time.get_ticks_usec()-work_started)

func _has_scene_work(ready: Dictionary) -> bool:
	if not _scene_callbacks_ready(): return false
	for region: Vector2i in _prepared:
		if ready.has(region) and not _region_retiring(region) and not _failures.has(region): return true
	for region: Vector2i in _scenes:
		if ready.has(region) and _scenes[region].phase in ["publishing","scene_ready"]: return true
	return false

func scene_state(region: Vector2i) -> Dictionary:
	if _scenes.has(region):
		var entry: Dictionary=_scenes[region]
		return {"status":entry.phase,"reason":"door_activation_pending" if entry.phase=="scene_ready" else "scene_publication_pending","binding":entry.binding.duplicate(),"gameplayReady":false}
	if _region_retiring(region): return {"status":"retiring","reason":"scene_retirement_pending","gameplayReady":false}
	if _failures.has(region): return {"status":"failed","reason":_failures[region].reason,"gameplayReady":false}
	if _prepared.has(region) or _desired.has(region): return {"status":"pending","reason":"scene_owner_not_ready" if not _scene_callbacks_ready() else "scene_preparation_pending","gameplayReady":false}
	return {"status":"absent","reason":"","gameplayReady":false}

func scene_root(region: Vector2i) -> Node3D:
	return _scenes[region].job.own_node_root() if _scenes.has(region) else null


## Visual-only description of exact immutable source members. The scene job is
## retained as the receipt publisher; no collision, door or navigation proof is
## consulted here. An absent scene cannot turn a described site into an empty
## source, and a replacement scene cannot inherit its predecessor's receipts.
func visual_source_state(bounds: Rect2i) -> Dictionary:
	if _admission == null or not _bounded_region_rectangle(bounds):
		return {"status":"failed","reason":"invalid_citadel_visual_request"}
	var admitted: Dictionary = _admission.request_bounds(bounds)
	if admitted.get("status") != "ready": return admitted
	if _closing or _world_reset_pending:
		return {"status":"pending","reason":"citadel_visual_world_reset_pending"}
	var candidates: Array[Dictionary] = []
	var source_rows: Array = []
	var cell_world_bounds := Rect2(Vector2(bounds.position)*CitadelPublicationPlan.CELL,
		Vector2(bounds.size)*CitadelPublicationPlan.CELL)
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			# request_bounds returns ready only when every intersecting candidate
			# has a prepared or authoritative absent decision. Unknown states are
			# never interpreted as an empty visual source.
			if source.get("status") == "absent": continue
			if source.get("status") not in ["ready","prepared"]:
				return {"status":"pending","reason":"citadel_visual_source_decision_pending","region":region}
			if not source.get("reservationCells") is Rect2i:
				return {"status":"failed","reason":"citadel_visual_reservation_missing","region":region}
			if not source.reservationCells.intersects(bounds): continue
			if _failures.has(region):
				return {"status":"failed","reason":String(_failures[region].reason),"region":region}
			var binding: Dictionary = source.binding
			var plan = _publication_plan_for_binding(binding)
			if plan == null and _packet_bootstrap_bases.has(region):
				var bootstrap: Dictionary = _packet_bootstrap_bases[region]
				var base = bootstrap.get("base",null)
				if bootstrap.get("binding",{}) == binding and base != null:
					plan = base.publication_plan
			if plan == null and _prepared.has(region):
				var prepared: Dictionary = _prepared[region]
				var base = prepared.get("base",null)
				if prepared.get("binding",{}) == binding and base != null:
					plan = base.publication_plan
			if plan == null or not plan.matches(binding,plan.groups):
				return {"status":"pending","reason":"citadel_visual_description_pending","region":region}
			var described: Dictionary = plan.visual_member_requirements(bounds)
			if described.get("status") != "described": return described
			var job = _scenes[region].job if _scenes.has(region) and _scenes[region].binding == binding \
				and not _region_retiring(region) else null
			var site_id := String(binding.siteId)
			var omitted_members: Array[String] = []
			for record: Dictionary in described.members:
				var member_id := String(record.memberId)
				if job != null and job.visual_member_omitted(member_id,binding):
					omitted_members.append(member_id)
					continue
				if candidates.size() >= 16384:
					return {"status":"pending","reason":"citadel_visual_candidate_capacity","retryable":true}
				var member_bounds: AABB = record.get("visualSupportBounds", record.bounds)
				var member_world_bounds := Rect2(
					Vector2(member_bounds.position.x,member_bounds.position.z),
					Vector2(member_bounds.size.x,member_bounds.size.z))
				var clipped := member_world_bounds.intersection(cell_world_bounds)
				var world_position := clipped.get_center() if clipped.has_area() \
					else member_world_bounds.get_center()
				candidates.append({"candidateId":"citadel:%s:%s" % [site_id,member_id],
					"memberId":member_id,"positionXZ":world_position/CitadelPublicationPlan.CELL,
					"bounds":member_bounds,"binding":binding,"sourceSignature":plan.output_signature,
					"publisher":job})
			source_rows.append([site_id,binding,plan.output_signature,
				job.get_instance_id() if job != null else 0,omitted_members])
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(var_to_bytes([_seed,_generation,source_rows]))
	return {"status":"described","reason":"","descriptionComplete":true,
		"sourceRevision":digest.finish().hex_encode(),"candidates":candidates,
		"siteCount":source_rows.size(),"candidateCount":candidates.size()}

func _source_description_requirements(region: Vector2i, bounds: Rect2i, binding: Dictionary) -> Dictionary:
	if _closing or _world_reset_pending or _region_retiring(region):
		return {"status":"pending","reason":"structure_dependency_source_pending"}
	var description = null
	var profile: Dictionary = {}
	if _described.has(region):
		var entry: Dictionary = _described[region]
		if entry.configuration==_configuration_serial and entry.binding==binding:
			description=entry.description
			profile=entry.profile
	if description==null and _scenes.has(region) and _scenes[region].binding==binding:
		var job = _scenes[region].get("job",null)
		if job!=null and job.has_method("source_dependency_description"):
			description=job.source_dependency_description(binding)
			profile=_scenes[region].get("profile",{})
	if description==null or description.binding!=binding or description.origin!=profile.get("origin",Vector3.INF):
		return {"status":"pending","reason":"structure_dependency_source_stale"}
	# No scene receipt is invented at this earlier source boundary. Ordinary
	# physical/navigation gates still decide whether these obligations are ready.
	if description.has_method("regional_scheduling_requirements"):
		return description.regional_scheduling_requirements(bounds)
	return description.regional_group_requirements(bounds)

## A reservation can cover a navigation tile without contributing any physical
## member or crossing to it.  Such a described source has no scene-owned fact
## to publish for this query; retaining its bootstrap base is sufficient.
static func _requires_scene_publication(requirements: Dictionary) -> bool:
	return not requirements.get("groupIds",[]).is_empty() or not requirements.get("requiredCrossings",{}).is_empty()

func region_dependency_requirements(bounds: Rect2i) -> Dictionary:
	var result := {"status":"described","reason":"","dependencyBounds":[],"sourceRevisions":{},
		"missingSourceIds":[],"unresolvedCrossingIds":[],"requiredCrossings":{},"sites":[],
		"domainBounds":{"terrain":[bounds],"render":[bounds],"navigation":[bounds]},
		"physicalOwnerAcknowledgements":{},"publicationAcknowledged":false}
	if _admission == null or not _bounded_region_rectangle(bounds):
		result.merge({"status":"failed","reason":"invalid_structure_dependency_request"},true)
		return result
	var admitted: Dictionary = _admission.request_bounds(bounds)
	if admitted.get("status") != "ready":
		result.merge({"status":String(admitted.get("status","pending")),"reason":String(admitted.get("reason","structure_source_pending"))},true)
		return result
	if _world_reset_pending or _closing:
		result.merge({"status":"pending","reason":"structure_world_reset_pending"},true)
		return result
	# Preserve first-seen output order while keeping union membership constant
	# time. A Citadel query can contain thousands of dependency rectangles; using
	# Array.has for every insertion made this scheduling-only aggregation
	# quadratic on the gameplay thread.
	var dependency_bounds_seen := {}
	var terrain_bounds_seen := {bounds:true}
	var render_bounds_seen := {bounds:true}
	var navigation_bounds_seen := {bounds:true}
	var missing_source_ids_seen := {}
	var unresolved_crossing_ids_seen := {}
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			if source.get("status") not in ["ready","prepared"] or not source.reservationCells.intersects(bounds): continue
			var site_id := String(source.binding.siteId)
			result.sourceRevisions[site_id] = source.binding.duplicate(true)
			if _failures.has(region):
				result.status = "failed"; result.reason = String(_failures[region].reason)
				continue
			# Scheduling consumes immutable source membership regardless of scene
			# state. Live collision proof belongs to physical_publication_state;
			# moving bounds must never make the scheduler walk scene witnesses.
			var requirements: Dictionary = _source_description_requirements(region,bounds,source.binding)
			# Downstream retention consumes only immutable scheduling identity. Keep
			# the large source description at its owner instead of copying it into
			# every coordinator candidate.
			result.sites.append({"status":requirements.get("status","pending"),
				"reason":requirements.get("reason",""),"binding":source.binding,
				"groupIds":requirements.get("groupIds",[])})
			for dependency: Rect2i in requirements.get("dependencyBounds",[]):
				if not dependency_bounds_seen.has(dependency):
					dependency_bounds_seen[dependency] = true
					result.dependencyBounds.append(dependency)
				if not terrain_bounds_seen.has(dependency):
					terrain_bounds_seen[dependency] = true
					result.domainBounds.terrain.append(dependency)
				if not render_bounds_seen.has(dependency):
					render_bounds_seen[dependency] = true
					result.domainBounds.render.append(dependency)
			var declared_navigation_regions: Array = requirements.get("domainBounds",{}).get("navigation",[])
			if not declared_navigation_regions.is_empty():
				for navigation_region: Rect2i in declared_navigation_regions:
					if not navigation_bounds_seen.has(navigation_region):
						navigation_bounds_seen[navigation_region] = true
						result.domainBounds.navigation.append(navigation_region)
			for field: String in ["missingSourceIds","unresolvedCrossingIds"]:
				for id: String in requirements.get(field,[]):
					var seen: Dictionary = missing_source_ids_seen if field=="missingSourceIds" else unresolved_crossing_ids_seen
					if not seen.has(id):
						seen[id] = true
						result[field].append(id)
			for id: String in requirements.get("requiredCrossings",{}):
				if result.requiredCrossings.has(id) and result.requiredCrossings[id] != requirements.requiredCrossings[id]:
					if not missing_source_ids_seen.has(id):
						missing_source_ids_seen[id] = true
						result.missingSourceIds.append(id)
				else: result.requiredCrossings[id] = requirements.requiredCrossings[id]
				# New regional descriptions explicitly declare their immediate
				# navigation tiles. Fall back to crossing tile metadata only for
				# legacy descriptions that have not supplied that contract yet.
				if not declared_navigation_regions.is_empty(): continue
				for tile_key: String in requirements.requiredCrossings[id].get("tileKeys",[]):
					var coordinates: PackedStringArray = tile_key.split(",")
					if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int():
						if not missing_source_ids_seen.has(id):
							missing_source_ids_seen[id] = true
							result.missingSourceIds.append(id)
						continue
					var tile_bounds: Rect2i = Rect2i(Vector2i(int(coordinates[0]),int(coordinates[1]))*16,Vector2i.ONE*16)
					if not navigation_bounds_seen.has(tile_bounds):
						navigation_bounds_seen[tile_bounds] = true
						result.domainBounds.navigation.append(tile_bounds)
			if requirements.has("physicalOwnerAcknowledgements"):
				result.physicalOwnerAcknowledgements[site_id] = requirements.physicalOwnerAcknowledgements
			if requirements.get("status") != "described" and result.status != "failed":
				result.status = String(requirements.get("status","pending"))
				result.reason = String(requirements.get("reason","structure_dependency_source_pending"))
	if not result.missingSourceIds.is_empty() or not result.unresolvedCrossingIds.is_empty():
		result.status = "failed"; result.reason = "structure_source_dependencies_unresolved"
	return result

func region_publication_readiness(bounds: Rect2i) -> Dictionary:
	var result := region_dependency_requirements(bounds)
	if result.status != "described": return result
	var physical := physical_publication_state(bounds)
	result.status = String(physical.get("status","pending"))
	result.reason = String(physical.get("reason","structure_physical_publication_pending"))
	result["physicalPublication"] = physical
	result.publicationAcknowledged = result.status == "ready"
	result["acknowledgementScope"] = "structures_physical_only"
	return result

func region_dependency_revision(bounds: Rect2i) -> Array:
	var revision: Array = [_seed,_generation,_world_reset_pending,_closing]
	if _admission == null or not _bounded_region_rectangle(bounds): return revision + ["invalid"]
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			revision.append([region,source.get("status","unrequested"),source.get("binding",{}),
				_failures.get(region,{}),_described.get(region,{}).get("serial",0),
				_scenes[region].job.source_dependency_revision() if _scenes.has(region) else []])
	return revision

## Small change token for retained-demand polling. This deliberately omits the
## scene job's physical proof arrays; region_dependency_revision and the live
## publication owners remain authoritative at an acceptance boundary.
func region_dependency_scheduling_revision(bounds: Rect2i) -> Array:
	var revision: Array = [_seed,_generation,_world_reset_pending,_closing]
	if _admission == null or not _bounded_region_rectangle(bounds): return revision + ["invalid"]
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			var failure: Dictionary = _failures.get(region,{})
			revision.append([region,source.get("status","unrequested"),source.get("binding",{}),
				failure.get("status",""),failure.get("reason",""),_described.get(region,{}).get("serial",0),
				_scenes.has(region)])
	return revision

## Validate once at source admission, never per query or per worker turn.
## This is inventory schema validation; it does not certify physical readiness.
static func _valid_navigation_domain(value: Variant) -> bool:
	if not value is Dictionary or not value.is_read_only() or value.size()!=4 \
		or value.get("status")!="complete" or value.get("scope")!="source_navigation_output": return false
	var output_keys := {}
	for field: String in ["tileKeys","producerTileKeys"]:
		var keys: Variant = value.get(field)
		if not keys is Array or not keys.is_read_only() or keys.size()>MAX_NAVIGATION_DOMAIN_KEYS: return false
		var seen := {}
		for key: Variant in keys:
			if not key is String or key.length()>23 or seen.has(key): return false
			var coordinates: PackedStringArray = key.split(",",true)
			if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int(): return false
			var x := int(coordinates[0])
			var z := int(coordinates[1])
			if x < -2147483648 or x > 2147483647 or z < -2147483648 or z > 2147483647 or key!="%d,%d" % [x,z]: return false
			if field=="producerTileKeys" and not output_keys.has(key): return false
			seen[key] = true
		if field=="tileKeys": output_keys = seen
	return true

## Borrow a source inventory independently of cursor ownership. Described is
## neither a completed tile receipt nor scene/physics/navigation readiness.
func navigation_source_domain(region: Vector2i, expected_binding: Dictionary) -> Dictionary:
	if _closing or _world_reset_pending: return {"status":"pending","reason":"structure_world_reset_pending"}
	if not Worker.Preparation.valid_binding(expected_binding): return {"status":"failed","reason":"invalid_publication_binding"}
	if _admission==null or _region_retiring(region):
		return {"status":"pending","reason":"structure_navigation_domain_pending"}
	if _failures.has(region): return {"status":"failed","reason":_failures[region].reason}
	if not _navigation.has(region): return {"status":"pending","reason":"structure_navigation_domain_pending"}
	var current: Dictionary = _admission.source_state(region)
	var entry: Dictionary = _navigation[region]
	if current.get("status") not in ["ready","prepared"] or current.get("binding",{})!=expected_binding \
		or entry.binding!=expected_binding or not _current_binding(expected_binding):
		return {"status":"pending","reason":"structure_navigation_domain_stale"}
	var result := {"status":"described","binding":entry.binding,"domain":entry.domain}
	result.make_read_only()
	return result

func navigation_tile_sources(tile_key: Vector2i) -> Dictionary:
	var bounds := Rect2i(tile_key*16,Vector2i.ONE*16)
	if _admission==null: return {"status":"pending","reason":"structure_navigation_owner_missing","sources":[]}
	if _world_reset_pending or _closing: return {"status":"pending","reason":"structure_world_reset_pending","sources":[]}
	var admitted: Dictionary = _admission.request_bounds(bounds)
	if admitted.get("status")!="ready": return {"status":"pending","reason":"structure_navigation_source_pending","sources":[]}
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	var sources: Array = []
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			if source.get("status") not in ["ready","prepared"] or not source.reservationCells.intersects(bounds): continue
			if _world_reset_pending or _closing:
				return {"status":"pending","reason":"structure_world_reset_pending","sources":[]}
			var physical: Dictionary = _navigation_tile_physical_requirements(region,bounds,source.binding)
			if physical.get("status")!="described":
				return {"status":"pending","reason":physical.get("reason","structure_navigation_source_pending"),"sources":[]}
			# A packet-mode Citadel scene deliberately has no root until a physical
			# group is requested. This tile has no such group, so Citadel contributes
			# no source here and terrain remains the sole navigation authority.
			if physical.get("groupIds",[]).is_empty(): continue
			if not _scenes.has(region):
				return {"status":"pending","reason":"structure_navigation_scene_pending","sources":[]}
			var key := "%d,%d" % [tile_key.x,tile_key.y]
			var tile_receipt: Variant = null
			# A prepared navigation producer does not acknowledge scene collision.
			# Retain and freshly prove this tile's physical closure on every path,
			# including when another tile already caused the source to be prepared.
			if not _packet_navigation_physical_ready(region,source.binding,physical.get("groupIds",[]),_navigation_priority(key)):
				return {"status":"pending","reason":"structure_collision_publication_pending","sources":[]}
			if not _navigation.has(region):
				if not _begin_packet_navigation_source(region,source.binding,_navigation_priority(key)):
					return {"status":"pending","reason":"structure_navigation_source_pending","sources":[]}
				return {"status":"pending","reason":"structure_navigation_source_pending","sources":[]}
			if _navigation.has(region):
				var entry: Dictionary = _navigation[region]
				if entry.binding!=source.binding: return {"status":"pending","reason":"structure_navigation_source_stale","sources":[]}
				if not _request_navigation_tile(entry,key):
					return {"status":"pending","reason":"structure_navigation_request_capacity","sources":[]}
				tile_receipt = entry.receipts.get(key)
				if tile_receipt==null: return {"status":"pending","reason":"structure_navigation_tile_uncompiled","sources":[]}
			var artifact: Dictionary = _scenes[region].job.navigation_tile_artifact(key,source.binding,tile_receipt)
			if artifact.get("status")!="ready": return artifact
			sources.append(artifact)
	return {"status":"ready","sources":sources}


## Lightweight current-owner identity for navigation source-key validation.
## This never retains demand, scans physical receipts, or constructs an
## artifact. `navigation_tile_sources` remains the mandatory physical/crossing
## proof before capture; accepted installation checks may use this identity to
## reject a retired/replaced scene without replaying that proof on Main.
func navigation_tile_source_identity(tile_key: Vector2i) -> Dictionary:
	var bounds := Rect2i(tile_key*16,Vector2i.ONE*16)
	if _admission==null or _world_reset_pending or _closing:
		return {"status":"pending","reason":"structure_world_reset_pending","sources":[]}
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end-Vector2i.ONE)
	var sources: Array = []
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			if source.get("status") not in ["ready","prepared"] or not source.get("reservationCells") is Rect2i \
					or not source.reservationCells.intersects(bounds): continue
			var physical: Dictionary = _navigation_tile_physical_requirements(region,bounds,source.binding)
			if physical.get("status")!="described":
				return {"status":"pending","reason":physical.get("reason","structure_navigation_description_pending"),"sources":[]}
			if physical.get("groupIds",[]).is_empty(): continue
			if not _scenes.has(region) or _scenes[region].binding!=source.binding or _region_retiring(region):
				return {"status":"pending","reason":"structure_navigation_scene_pending","sources":[]}
			sources.append({"binding":source.binding})
	return {"status":"ready","sources":sources}

func _navigation_tile_physical_requirements(region: Vector2i, bounds: Rect2i, binding: Dictionary) -> Dictionary:
	var described: Dictionary = _described.get(region,{})
	var description = described.get("description",null)
	if description==null or described.get("binding",{})!=binding:
		var base_entry: Dictionary = _packet_bootstrap_bases.get(region,{})
		var base = base_entry.get("base",null)
		description = base.description if base!=null else null
	if description==null and _scenes.has(region) and _scenes[region].binding==binding:
		var job = _scenes[region].get("job",null)
		var live_base = job._cpu.get("publicationBase",null) if job!=null else null
		description = live_base.description if live_base!=null else null
	if description==null or description.binding!=binding:
		return {"status":"pending","reason":"structure_navigation_description_pending"}
	# This query gates physical scene/collider publication only. The navigation
	# producer below still owns topology and crossing dependencies. Use the
	# conservative exact-member plan so a single tile cannot inherit the much
	# wider navigation-domain region closure.
	var base_entry: Dictionary = _packet_bootstrap_bases.get(region,{})
	var base = base_entry.get("base",null)
	if base==null and _scenes.has(region):
		var job = _scenes[region].get("job",null)
		base = job._cpu.get("publicationBase",null) if job!=null else null
	var compact_plan = base.publication_plan if base!=null else null
	return compact_plan.physical_group_requirements(bounds) if compact_plan!=null \
		else description.physical_group_requirements(bounds)

## Dense navigation remains deferred until the already-demanded foreground
## physical packet has a real scene receipt.  The packet scene still owns the
## exact source and binding; this only decides when the independent immutable
## navigation producer may take the shared worker.
func _packet_foreground_physical_ready(region: Vector2i, binding: Dictionary) -> bool:
	if not _scenes.has(region) or _scenes[region].binding!=binding: return false
	var entry: Dictionary = _scenes[region]
	if not bool(entry.get("packetMode",false)): return true
	var demand: Dictionary = entry.get("packetDemandStatus",{})
	if demand.get("status")!="retained": return false
	var receipt: Dictionary = entry.job.physical_groups_receipt(
		demand.get("readinessGroupIds",demand.get("foregroundGroupIds",[])),binding)
	return receipt.get("status")=="ready"

## A navigation tile receives its own exact physical group request.  It must
## not wait behind other retained tiles merely because they share a source.
func _packet_navigation_physical_ready(region: Vector2i, binding: Dictionary, group_ids: Array, priority: int) -> bool:
	if not _scenes.has(region) or _scenes[region].binding!=binding: return false
	var entry: Dictionary = _scenes[region]
	if not bool(entry.get("packetMode",false)): return true
	if priority<0 or priority>4: return false
	var required: Dictionary = entry.get("navigationPhysicalGroups",{})
	var changed := false
	# This map is a bounded active scheduling window, not a lifetime census.
	# Completed groups stay installed in the resident scene and need no retained
	# heap entry. Without pruning, a 64-tile background ring promoted thousands
	# of unrelated groups into every demand refresh and delayed the current tile.
	for retained_id: String in required.keys():
		if entry.job.physical_group_packet_completed_for_scheduling(retained_id,binding):
			required.erase(retained_id)
			changed = true
	var pending_ids: Array[String] = []
	for group_id: String in group_ids:
		# Scheduling asks only whether the packet transaction completed. The
		# navigation artifact immediately below performs one consolidated live
		# node/collision proof for the exact group closure. Repeating a standalone
		# physical proof for every group made a 100+ group tile scale quadratically.
		if not entry.job.physical_group_packet_completed_for_scheduling(group_id,binding):
			pending_ids.append(group_id)
	pending_ids.sort()
	if not pending_ids.is_empty():
		# A newly urgent tile may replace unstarted lower-priority scheduling
		# demand. Pinned worker/scene transactions remain owned and complete; only
		# the mutable next-work window changes.
		for retained_id: String in required.keys():
			if int(required[retained_id])>priority:
				required.erase(retained_id)
				changed = true
		var more_urgent_pending := false
		for retained_id: String in required:
			if int(required[retained_id])<priority:
				more_urgent_pending = true
				break
		if not more_urgent_pending:
			var additions := 0
			for group_id: String in pending_ids:
				if not required.has(group_id): additions+=1
			# A tile closure is atomic. Deferring the whole closure preserves its
			# dependency proof; inserting a prefix can strand a group whose support
			# was left outside the active window.
			if required.size()+additions<=MAX_ACTIVE_NAVIGATION_PHYSICAL_GROUPS:
				for group_id: String in pending_ids:
					if not required.has(group_id) or int(required[group_id])>priority:
						required[group_id]=priority
						changed=true
	if changed:
		entry["navigationPhysicalGroups"] = required
		entry["demandRevision"] = -1
	var pending: Dictionary = {}
	for group_id: String in pending_ids:
		if pending.size()<32:
			pending[group_id]="structure_collision_publication_pending"
	entry["navigationPhysicalPending"] = pending
	return pending.is_empty()

func _queue_packet_navigation_source(region: Vector2i, binding: Dictionary, priority: int) -> void:
	if priority<0 or priority>4: return
	var existing: Dictionary = _pending_packet_navigation.get(region,{})
	if existing.is_empty() or existing.get("binding",{})!=binding or int(existing.get("priority",4))>priority:
		_pending_packet_navigation[region] = {"binding":binding.duplicate(),"priority":priority}

func _dispatch_pending_packet_navigation() -> bool:
	if not _inflight.is_empty() or _pending_packet_navigation.is_empty(): return false
	var regions: Array[Vector2i] = []
	for region: Vector2i in _pending_packet_navigation:
		var pending: Dictionary = _pending_packet_navigation[region]
		if _scenes.has(region) and _scenes[region].binding==pending.get("binding",{}): regions.append(region)
		else: _pending_packet_navigation.erase(region)
	regions.sort_custom(func(a: Vector2i,b: Vector2i) -> bool:
		var pa: int = int(_pending_packet_navigation[a].priority)
		var pb: int = int(_pending_packet_navigation[b].priority)
		return pa<pb if pa!=pb else (a.y<b.y if a.y!=b.y else a.x<b.x))
	for region: Vector2i in regions:
		var pending: Dictionary = _pending_packet_navigation[region]
		if _begin_packet_navigation_source(region,pending.binding,int(pending.priority)):
			_pending_packet_navigation.erase(region)
			return true
	return false

func _begin_packet_navigation_source(region: Vector2i, binding: Dictionary, priority := 4) -> bool:
	if _navigation.has(region): return _navigation[region].binding==binding
	if not _scenes.has(region) or _scenes[region].binding!=binding: return false
	if not _inflight.is_empty():
		_queue_packet_navigation_source(region,binding,priority)
		return false
	var base: Preparation.PreparedPublicationBase = _scenes[region].job._cpu.get("publicationBase")
	var receipt := _worker.dispatch_publication_base_navigation(base,binding)
	if receipt.get("status") not in ["started","queued"] or receipt.get("duplicate",false): return false
	_inflight={"kind":"publication_base_navigation","region":region,"binding":binding,"token":int(receipt.token),"base":base,"profile":_scenes[region].profile}
	return true

## Readiness only, consumed by ordinary collision/loading gates. It never moves
## a player, invents geometry, publishes routes or upgrades diagnostic callbacks.
func physical_publication_state(bounds: Rect2i) -> Dictionary:
	if _admission == null: return {"status":"failed", "reason":"landmark_source_missing"}
	var source_ready: Dictionary = _admission.request_bounds(bounds)
	if source_ready.get("status") != "ready": return source_ready
	if _world_reset_pending or _closing: return {"status":"pending", "reason":"landmark_world_reset_pending"}
	var low := Field.region_for_cell(bounds.position)
	var high := Field.region_for_cell(bounds.end - Vector2i.ONE)
	var required := false
	var scene_ids: Array[int] = []
	for z in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var region := Vector2i(x,z)
			var source: Dictionary = _admission.source_state(region)
			if source.get("status") not in ["ready", "prepared"]: continue
			if not source.reservationCells.intersects(bounds): continue
			var requirements: Dictionary
			if _scenes.has(region):
				requirements = _scenes[region].job.source_dependency_requirements(bounds,source.binding)
			else:
				requirements = _source_description_requirements(region,bounds,source.binding)
			if requirements.get("status")!="described":
				return {"status":"pending","reason":requirements.get("reason","landmark_group_description_pending")}
			if not _requires_scene_publication(requirements): continue
			required = true
			var state := scene_state(region)
			if state.status == "failed": return {"status":"failed", "reason":state.reason}
			if not _door_callbacks_ready() or not _require_tree_retirement_ack or not _scene_callbacks_ready():
				return {"status":"pending", "reason":"landmark_runtime_owners_pending"}
			if not _scenes.has(region) or _region_retiring(region) or state.get("binding",{}) != source.binding:
				return {"status":"pending", "reason":"landmark_structures_pending"}
			var job = _scenes[region].job
			if not requirements.get("groupDescriptionComplete",false):
				return {"status":"pending","reason":"landmark_group_description_pending"}
			# source_dependency_requirements just performed one nonyielding, fresh
			# batched proof for this acceptance operation. Consume those exact
			# receipts instead of immediately walking every witness a second time.
			var acknowledgements: Dictionary = requirements.get("physicalOwnerAcknowledgements",{})
			if acknowledgements.get("binding",{}) != source.binding or not acknowledgements.get("groups") is Dictionary:
				return {"status":"pending","reason":"landmark_physical_owner_acknowledgement_pending"}
			for group_id: String in requirements.get("groupIds",[]):
				var receipt: Dictionary = acknowledgements.groups.get(group_id,{})
				if receipt.get("status")!="ready": return receipt if not receipt.is_empty() else \
					{"status":"pending","reason":"structure_collision_publication_pending"}
			var site := scene_root(region)
			var parent: Node3D = _scene_parent.get_ref() as Node3D
			if not is_instance_valid(site) or site.is_queued_for_deletion() or not site.is_inside_tree() \
					or site.get_parent() != parent or not site.global_transform.is_equal_approx(Transform3D(Basis.IDENTITY,_scenes[region].profile.origin)):
				return {"status":"failed", "reason":"landmark_scene_owner_lost"}
			scene_ids.append(site.get_instance_id())
	return {"status":"ready", "reason":"landmark_physical_publication_complete", "required":required, "sceneInstanceIds":scene_ids}
