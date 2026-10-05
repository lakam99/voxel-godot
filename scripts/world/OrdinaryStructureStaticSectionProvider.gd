extends RefCounted
class_name OrdinaryStructureStaticSectionProvider

## Section-source census and prepared geometry for generated ordinary
## structures. StructureSystem remains authoritative for generated membership,
## removals, collision and interaction. This provider only adapts the existing
## visible static geometry into immutable section candidate values.

const Adapter := preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const SourceCapture := preload("res://scripts/world/OrdinaryStructureVisualSourceCapture.gd")
const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const VisualRecipe := preload("res://scripts/world/OrdinaryStructureBlockVisualRecipe.gd")

const PROVIDER_ID := "ordinary-structures"
const SCHEMA := "ordinary-structure-static-section-provider/v1"
const MAX_SECTIONS_PER_CAPTURE := 8
const DISCOVERY_MARGIN_CELLS := int(Adapter.MAX_HORIZONTAL_SUPPORT_CELLS)
const DISCOVERY_ATOMS_PER_TURN := 512
const MEMBERS_PER_TURN := 32
const CENSUS_WINDOW_SECTIONS := 2
const MAX_MEMBERSHIP_CENSUS_ENTRIES := 8
const MAX_MEMBERSHIP_CENSUS_BYTES := 8 * 1024 * 1024
const MAX_GEOMETRY_CAPTURE_CACHE_ENTRIES := 512
const MAX_GEOMETRY_CAPTURE_CACHE_BYTES := 16 * 1024 * 1024

var _world_id := ""
var _system_ref: WeakRef
var _system_id := 0
var _main_ref: WeakRef
var _main_id := 0
var _jobs: Dictionary = {}
var _membership_censuses: Dictionary = {}
var _membership_census_jobs: Dictionary = {}
var _membership_census_clock := 0
var _membership_census_build_count := 0
var _membership_census_reuse_count := 0
var _membership_census_overlap_reuse_count := 0
var _membership_census_member_rows_built := 0
var _membership_census_bytes := 0
var _membership_census_advance_count := 0
var _membership_census_advance_usec := 0
var _membership_census_currentness_invalidations := 0
var _geometry_capture_cache: Dictionary = {}
var _geometry_capture_cache_bytes := 0
var _geometry_capture_cache_clock := 0
var _geometry_capture_cache_hits := 0
var _geometry_capture_cache_misses := 0
var _geometry_capture_cache_evictions := 0
var _geometry_capture_cache_resource_bindings: Dictionary = {}
var _installed_members_by_section: Dictionary = {}
var _latest_by_section: Dictionary = {}


func configure(world_id: String, structure_system: Object, main: Object) -> Dictionary:
	if world_id.strip_edges().is_empty() or not is_instance_valid(structure_system) \
			or not is_instance_valid(main) or structure_system.get("main") != main:
		return _failed("invalid_ordinary_section_provider_owner")
	if not structure_system.has_method("region_dependency_scheduling_revision") \
			or not structure_system.has_method("_ordinary_visual_block_key"):
		return _failed("ordinary_section_provider_authority_contract_missing")
	if not _world_id.is_empty() and (_world_id != world_id \
			or _system_id != structure_system.get_instance_id() \
			or _main_id != main.get_instance_id()):
		return _failed("ordinary_section_provider_already_bound")
	_world_id = world_id
	_system_ref = weakref(structure_system)
	_system_id = structure_system.get_instance_id()
	_main_ref = weakref(main)
	_main_id = main.get_instance_id()
	return {"status":"ready", "providerId":PROVIDER_ID, "worldId":_world_id}


func membership_census_stats() -> Dictionary:
	return {"buildCount":_membership_census_build_count,
		"reuseCount":_membership_census_reuse_count,
		"overlapReuseCount":_membership_census_overlap_reuse_count,
		"memberRowsBuilt":_membership_census_member_rows_built,
		"cachedEntryCount":_membership_censuses.size(),
		"activeCaptureCount":_membership_census_jobs.size(),
		"cachedBytes":_membership_census_bytes,
		"censusAdvanceCount":_membership_census_advance_count,
		"censusAdvanceUsec":_membership_census_advance_usec,
		"censusCurrentnessInvalidations":_membership_census_currentness_invalidations,
		"geometryCaptureCacheHits":_geometry_capture_cache_hits,
		"geometryCaptureCacheMisses":_geometry_capture_cache_misses,
		"geometryCaptureCacheEvictions":_geometry_capture_cache_evictions,
		"geometryCaptureCacheEntries":_geometry_capture_cache.size(),
		"geometryCaptureCacheBytes":_geometry_capture_cache_bytes}


func _advance_membership_census(window: Rect2i, membership_token: Array,
		section: Vector3i, context: Dictionary) -> Dictionary:
	var window_id := _window_id(window)
	var token_digest := _sha256(var_to_bytes(membership_token))
	if token_digest.is_empty():
		return _failed("ordinary_membership_currentness_digest_failed", {
			"section":section, "censusWindow":window})
	var cache_key := window_id + "|" + token_digest
	for existing_key_value: Variant in _membership_censuses.keys():
		var existing_key := String(existing_key_value)
		if existing_key.begins_with(window_id + "|") and existing_key != cache_key:
			_remove_membership_census(existing_key)
	for existing_key_value: Variant in _membership_census_jobs.keys():
		var existing_key := String(existing_key_value)
		if existing_key.begins_with(window_id + "|") and existing_key != cache_key:
			_membership_census_jobs.erase(existing_key)
	var cached: Dictionary = _membership_censuses.get(cache_key, {})
	if not cached.is_empty():
		if cached.get("membershipToken") == membership_token:
			_membership_census_clock += 1
			cached["lastUse"] = _membership_census_clock
			_membership_censuses[cache_key] = cached
			_membership_census_reuse_count += 1
			return {"status":"complete", "census":cached.census,
				"censusWindow":window, "cacheHit":true}
		_remove_membership_census(cache_key)
	var capture_job: Dictionary = _membership_census_jobs.get(cache_key, {})
	if capture_job.is_empty():
		if not _make_membership_census_room():
			return _pending("ordinary_membership_census_capacity", {
				"section":section, "censusWindow":window,
				"activeCensusCount":_membership_censuses.size()})
		var capture := SourceCapture.new()
		capture.begin_membership(context.system, window)
		if capture.advance(1, 1000).get("status") == "failed":
			return _failed("ordinary_membership_census_begin_failed", {
				"section":section, "censusWindow":window})
		_membership_census_clock += 1
		capture_job = {"window":window,
			"membershipToken":membership_token.duplicate(true),
			"tokenDigest":token_digest, "capture":capture,
			"lastUse":_membership_census_clock}
		_membership_census_jobs[cache_key] = capture_job
		_membership_census_build_count += 1
	var current_token := _membership_currentness_token(window, context)
	if current_token.is_empty() or current_token != capture_job.get("membershipToken", []):
		_membership_census_currentness_invalidations += 1
		_remove_membership_census(cache_key)
		return _pending("ordinary_membership_census_currentness_changed", {
			"section":section, "censusWindow":window, "restart":true})
	var capture: Object = capture_job.get("capture") as Object
	if not is_instance_valid(capture):
		_remove_membership_census(cache_key)
		return _pending("ordinary_membership_census_capture_missing", {
			"section":section, "censusWindow":window, "restart":true})
	var advanced: Dictionary = capture.advance(DISCOVERY_ATOMS_PER_TURN, 3000)
	_membership_census_advance_count += 1
	_membership_census_advance_usec += int(advanced.get("sliceUsec", 0))
	if advanced.get("status") == "pending":
		var reason := String(advanced.get("reason", "ordinary_visual_capture_budget"))
		if reason != "ordinary_visual_capture_budget":
			_remove_membership_census(cache_key)
			return _pending(reason, {"section":section,
				"censusWindow":window, "restart":true,
				"stage":String(advanced.get("stage", "")),
				"cursor":int(advanced.get("cursor", 0)),
				"sourceId":String(advanced.get("sourceId", "")),
				"cell":advanced.get("cell"),
				"pendingSourceIds":advanced.get("pendingSourceIds", [])})
		_membership_census_jobs[cache_key] = capture_job
		return _pending(reason, {"section":section, "censusWindow":window,
			"stage":String(advanced.get("stage", "")),
			"cursor":int(advanced.get("cursor", 0)), "restart":false,
			"cacheKey":token_digest,
			"continuationHint":_continuation_hint("membership_census",
				int(advanced.get("cursor", 0)))})
	if advanced.get("status") != "described" or not _membership_census_is_value_only(advanced):
		_remove_membership_census(cache_key)
		return _failed("ordinary_membership_census_result_invalid", {
			"section":section, "censusWindow":window})
	current_token = _membership_currentness_token(window, context)
	if current_token.is_empty() or current_token != capture_job.get("membershipToken", []):
		_membership_census_currentness_invalidations += 1
		_remove_membership_census(cache_key)
		return _pending("ordinary_membership_census_currentness_changed", {
			"section":section, "censusWindow":window, "restart":true})
	var census: Dictionary = advanced
	var estimated_bytes := var_to_bytes(census).size()
	_membership_census_member_rows_built += int(census.get("memberCount", 0))
	if estimated_bytes <= MAX_MEMBERSHIP_CENSUS_BYTES:
		_membership_census_jobs.erase(cache_key)
		while _membership_census_bytes + estimated_bytes > MAX_MEMBERSHIP_CENSUS_BYTES:
			if not _evict_oldest_complete_census(cache_key):
				break
		if _membership_census_bytes + estimated_bytes <= MAX_MEMBERSHIP_CENSUS_BYTES:
			_membership_census_clock += 1
			var sealed_membership_token: Array = _freeze_value(membership_token.duplicate(true))
			var cached_entry := {"state":"complete",
				"membershipToken":sealed_membership_token,
				"census":census, "estimatedBytes":estimated_bytes,
				"lastUse":_membership_census_clock}
			_membership_census_bytes += estimated_bytes
			_membership_censuses[cache_key] = cached_entry
			return {"status":"complete", "census":census,
				"censusWindow":window, "cacheHit":false}
	# A large but valid snapshot may satisfy this request; it is not retained for
	# reuse. The normal producer demand remains retryable if later sections need it.
	_membership_census_jobs.erase(cache_key)
	return {"status":"complete", "census":census,
		"censusWindow":window, "cacheHit":false, "retained":false}


func _make_membership_census_room() -> bool:
	while _membership_census_jobs.size() + _membership_censuses.size() \
			>= MAX_MEMBERSHIP_CENSUS_ENTRIES:
		if not _evict_oldest_complete_census(""):
			return false
	return true


func _evict_oldest_complete_census(excluded_key: String) -> bool:
	var selected_key := ""
	var selected_use := 9223372036854775807
	for key_value: Variant in _membership_censuses:
		var key := String(key_value)
		if key == excluded_key:
			continue
		var entry: Dictionary = _membership_censuses[key]
		if entry.get("state") != "complete":
			continue
		var last_use := int(entry.get("lastUse", 0))
		if last_use < selected_use:
			selected_key = key
			selected_use = last_use
	if selected_key.is_empty():
		return false
	_remove_membership_census(selected_key)
	return true


func _remove_membership_census(cache_key: String) -> void:
	_membership_census_jobs.erase(cache_key)
	var entry: Dictionary = _membership_censuses.get(cache_key, {})
	if entry.is_empty():
		return
	_membership_census_bytes = maxi(0, _membership_census_bytes
		- int(entry.get("estimatedBytes", 0)))
	_membership_censuses.erase(cache_key)


func _invalidate_membership_window(window: Rect2i) -> void:
	var window_prefix := _window_id(window) + "|"
	for key_value: Variant in _membership_censuses.keys():
		var key := String(key_value)
		if key.begins_with(window_prefix):
			_remove_membership_census(key)
	for key_value: Variant in _membership_census_jobs.keys():
		var key := String(key_value)
		if key.begins_with(window_prefix):
			_membership_census_jobs.erase(key)


func _invalidate_section_snapshot(section_id: String) -> void:
	_jobs.erase(section_id)
	_latest_by_section.erase(section_id)


func _invalidate_stale_section_jobs(window: Rect2i, current_token: Array) -> void:
	for section_id_value: Variant in _jobs.keys():
		var section_id := String(section_id_value)
		var job: Dictionary = _jobs.get(section_id, {})
		if job.get("censusWindow") == window \
				and job.get("membershipToken", []) != current_token:
			_invalidate_section_snapshot(section_id)


func _membership_census_is_value_only(census: Dictionary) -> bool:
	return _value_tree_is_sealed(census)


static func _freeze_value(value: Variant) -> Variant:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for key: Variant in dictionary.keys():
			dictionary[key] = _freeze_value(dictionary[key])
		dictionary.make_read_only()
		return dictionary
	if value is Array:
		var array: Array = value
		for index in array.size():
			array[index] = _freeze_value(array[index])
		array.make_read_only()
		return array
	return value


func _value_tree_is_sealed(value: Variant) -> bool:
	if value is Object or value is WeakRef or value is RID or value is Callable:
		return false
	if value is Dictionary:
		var dictionary: Dictionary = value
		if not dictionary.is_read_only():
			return false
		for key: Variant in dictionary:
			if not _value_tree_is_sealed(key) \
					or not _value_tree_is_sealed(dictionary[key]):
				return false
		return true
	if value is Array:
		var array: Array = value
		if not array.is_read_only():
			return false
		for item: Variant in array:
			if not _value_tree_is_sealed(item):
				return false
		return true
	# Packed arrays are mutable and cannot be made read-only in Godot 4.6.
	var value_type := typeof(value)
	if value_type >= TYPE_PACKED_BYTE_ARRAY and value_type <= TYPE_PACKED_VECTOR4_ARRAY:
		return false
	return true


func _membership_currentness_token(bounds: Rect2i, context: Dictionary) -> Array:
	if context.is_empty() or not context.main.get("town_region_cache") is Dictionary:
		return []
	var main: Object = context.main
	var system: Object = context.system
	var town_size := int(main.get("TOWN_REGION_CELLS"))
	var structure_size := int(main.get("STRUCTURE_REGION_CELLS"))
	var spawn_chance := float(main.get("STRUCTURE_SPAWN_CHANCE"))
	if town_size <= 0 or structure_size <= 0 or not is_finite(spawn_chance):
		return []
	var town_low := Vector2i(floori(float(bounds.position.x) / town_size),
		floori(float(bounds.position.y) / town_size)) - Vector2i.ONE
	var town_high := Vector2i(floori(float(bounds.end.x - 1) / town_size),
		floori(float(bounds.end.y - 1) / town_size)) + Vector2i.ONE
	var standalone_low := Vector2i(floori(float(bounds.position.x) / structure_size),
		floori(float(bounds.position.y) / structure_size)) - Vector2i.ONE
	var standalone_high := Vector2i(floori(float(bounds.end.x - 1) / structure_size),
		floori(float(bounds.end.y - 1) / structure_size)) + Vector2i.ONE
	if (town_high.x - town_low.x + 1) * (town_high.y - town_low.y + 1) > 256 \
			or (standalone_high.x - standalone_low.x + 1) \
			* (standalone_high.y - standalone_low.y + 1) > 256:
		return []
	var town_cache: Dictionary = main.get("town_region_cache")
	var town_membership: Array = []
	for z in range(town_low.y, town_high.y + 1):
		for x in range(town_low.x, town_high.x + 1):
			var key := Vector2i(x, z)
			if not town_cache.has(key):
				town_membership.append([key, false])
				continue
			var town: Variant = town_cache[key]
			if not town is Dictionary:
				return []
			var row := [key, true]
			if not town.is_empty():
				var town_bounds: Variant = system.call("_regional_town_bounds", town)
				var town_id := String(system.call("town_key_for", town))
				if not town_bounds is Rect2i or town_id.is_empty():
					return []
				row.append([town_id, town_bounds])
			town_membership.append(row)
	var generated_value: Variant = system.get("generated_structures")
	if not generated_value is Dictionary:
		return []
	var generated_structures: Dictionary = generated_value
	var standalone_membership: Array = []
	for z in range(standalone_low.y, standalone_high.y + 1):
		for x in range(standalone_low.x, standalone_high.x + 1):
			var key := Vector2i(x, z)
			# Only this eligibility bit affects the ordinary source ID set. The
			# candidate's spawn/influence bounds are deterministic from the seed.
			standalone_membership.append([key, generated_structures.get(key, null) != false])
	return [String(main.get("seed_text")), _world_id, bounds,
		int(system.get("regional_source_generation")),
		int(system.get("regional_source_revision")),
		int(system.get("ordinary_visual_revision")), town_size, structure_size,
		spawn_chance, town_membership, standalone_membership]


func _membership_census_bounds_for_section(section: Vector3i) -> Rect2i:
	var group_x := floori(float(section.x) / CENSUS_WINDOW_SECTIONS) * CENSUS_WINDOW_SECTIONS
	var group_z := floori(float(section.z) / CENSUS_WINDOW_SECTIONS) * CENSUS_WINDOW_SECTIONS
	var margin := DISCOVERY_MARGIN_CELLS
	var low := Vector2i(group_x * Grid.SECTION_SIZE_CELLS - margin,
		group_z * Grid.SECTION_SIZE_CELLS - margin)
	var size := CENSUS_WINDOW_SECTIONS * Grid.SECTION_SIZE_CELLS + margin * 2
	return Rect2i(low, Vector2i.ONE * size)


func _section_discovery_bounds(section: Vector3i) -> Rect2i:
	var margin := DISCOVERY_MARGIN_CELLS
	var low := Vector2i(section.x * Grid.SECTION_SIZE_CELLS - margin,
		section.z * Grid.SECTION_SIZE_CELLS - margin)
	var size := Grid.SECTION_SIZE_CELLS + margin * 2
	return Rect2i(low, Vector2i.ONE * size)


func _window_id(bounds: Rect2i) -> String:
	return "%d,%d,%d,%d" % [bounds.position.x, bounds.position.y,
		bounds.size.x, bounds.size.y]


## Implements StaticSectionSourceRoster.capture_method. A section is complete
## only after deterministic source discovery is described, every intersecting
## expected visual has either a supported immutable geometry input or a
## durable-removal tombstone, and the source capture still matches its owner.
func capture_static_section_sources(world_id: String,
		requested_sections: Array) -> Dictionary:
	var context := _context(world_id)
	if context.is_empty() or requested_sections.is_empty() \
			or requested_sections.size() > MAX_SECTIONS_PER_CAPTURE:
		return _pending("ordinary_section_provider_world_or_query_invalid")
	var sections: Array[Vector3i] = []
	for value: Variant in requested_sections:
		if not value is Vector3i or value in sections:
			return _failed("invalid_or_duplicate_ordinary_section_key")
		sections.append(value)
	sections.sort_custom(_section_less)
	var section_rows: Dictionary = {}
	var source_revisions: Dictionary = {}
	var prepared_sections: Dictionary = {}
	var authority_rows: Array = []
	# Capture and advance each shared window only once per provider call. This
	# allows a batched multi-section request to make bounded progress without
	# accidentally granting the same census one slice per section.
	var census_by_window: Dictionary = {}
	for section: Vector3i in sections:
		var window := _membership_census_bounds_for_section(section)
		var window_id := _window_id(window)
		if census_by_window.has(window_id):
			_membership_census_overlap_reuse_count += 1
			continue
		var membership_token := _membership_currentness_token(window, context)
		if membership_token.is_empty():
			return _pending("ordinary_membership_window_authority_unavailable", {
				"section":section, "censusWindow":window})
		_invalidate_stale_section_jobs(window, membership_token)
		var census_result := _advance_membership_census(window, membership_token, section, context)
		if census_result.get("status") != "complete":
			return census_result
		census_by_window[window_id] = census_result.census
	for section: Vector3i in sections:
		var section_id := _section_id(section)
		var job: Dictionary = _jobs.get(section_id, {})
		var window := _membership_census_bounds_for_section(section)
		var census: Dictionary = census_by_window.get(_window_id(window), {})
		if census.is_empty():
			return _pending("ordinary_membership_window_census_missing", {
				"section":section, "censusWindow":window})
		if job.is_empty() or not _job_is_current(job, context):
			job = _begin_job(section, context, census)
			if job.get("status") != "pending":
				return job
			_jobs[section_id] = job
		var advanced := _advance_job(job, context)
		if advanced.get("status") != "complete":
			if advanced.get("status") == "failed" or bool(advanced.get("restart", false)):
				_jobs.erase(section_id)
			return advanced
		var snapshot: Dictionary = advanced.snapshot
		_latest_by_section[section_id] = snapshot
		var member_ids: Array[String] = snapshot.memberIds.duplicate()
		member_ids.sort()
		member_ids.make_read_only()
		var coverage_revision := _coverage_revision(section, snapshot)
		if coverage_revision.is_empty():
			return _failed("ordinary_section_coverage_revision_failed")
		var status := "empty" if member_ids.is_empty() else "complete"
		var row := {"status":status, "sourcePartIds":member_ids,
			"coverageRevision":coverage_revision}
		row.make_read_only()
		section_rows[section] = row
		for part_id: String in member_ids:
			var revision := String(snapshot.sourceRevisions.get(part_id, ""))
			if revision.is_empty():
				return _failed("ordinary_section_member_revision_missing", {
					"sourcePartId":part_id})
			if source_revisions.has(part_id) and String(source_revisions[part_id]) != revision:
				return _failed("ordinary_section_member_revision_conflict", {
					"sourcePartId":part_id})
			source_revisions[part_id] = revision
		prepared_sections[section] = snapshot.prepared
		authority_rows.append([[section.x, section.y, section.z],
			String(snapshot.discoveryRevision), coverage_revision])
	var authority_digest := _sha256(var_to_bytes([SCHEMA, _world_id, authority_rows]))
	if authority_digest.is_empty():
		return _failed("ordinary_section_authority_revision_failed")
	var revisions: Dictionary = {}
	for section: Vector3i in sections:
		var snapshot: Dictionary = _latest_by_section[_section_id(section)]
		var revision: String = String(section_rows[section].coverageRevision)
		revisions[section] = _removals_for(section, snapshot, revision)
	section_rows.make_read_only()
	source_revisions.make_read_only()
	prepared_sections.make_read_only()
	revisions.make_read_only()
	sections.make_read_only()
	var result := {"status":"complete", "schema":SCHEMA,
		"providerId":PROVIDER_ID, "worldId":_world_id,
		"authorityRevision":authority_digest,
		"sections":section_rows, "sourceRevisions":source_revisions,
		"preparedSections":prepared_sections,
		"removalsBySection":revisions}
	result.make_read_only()
	return result


## Returns the exact immutable geometry admitted by the most recent census for
## one section. The world coordinator can combine this with other providers
## and run a single cross-domain partition; this method never publishes or
## retires the current per-cell visuals.
func capture_static_section_contribution(census: Dictionary,
		section_key: Vector3i) -> Dictionary:
	if census.get("status") != "complete" or census.get("worldId") != _world_id \
			or not census.get("providerSnapshotRevisions") is Dictionary \
			or not census.get("providerCoverageRevisions") is Dictionary:
		return _pending("ordinary_section_contribution_census_unavailable")
	var section_id := _section_id(section_key)
	var snapshot: Dictionary = _latest_by_section.get(section_id, {})
	if snapshot.is_empty() or snapshot.get("sectionKey") != section_key:
		return _pending("ordinary_section_contribution_snapshot_missing")
	var context := _context(_world_id)
	if context.is_empty() or not _snapshot_lifecycle_is_current(snapshot, context):
		return _pending("ordinary_section_contribution_snapshot_stale")
	var prepared: Dictionary = snapshot.get("prepared", {})
	if prepared.is_empty() or prepared.get("sectionKey") != section_key:
		return _pending("ordinary_section_contribution_geometry_missing")
	var provider_coverage: Dictionary = census.providerCoverageRevisions.get(PROVIDER_ID, {})
	var coverage_revision := String(provider_coverage.get(section_key, ""))
	var provider_revision := String(census.providerSnapshotRevisions.get(PROVIDER_ID, ""))
	if coverage_revision.is_empty() or provider_revision.is_empty() \
			or coverage_revision != _coverage_revision(section_key, snapshot):
		return _pending("ordinary_section_contribution_revision_stale")
	var authority_revisions: Dictionary = snapshot.get("sourceRevisions", {})
	if not authority_revisions.is_read_only() \
			or not prepared.get("inputs", []) is Array \
			or not prepared.get("inputs", []).is_read_only() \
			or not prepared.get("compatibilityByKey", {}) is Dictionary \
			or not prepared.get("compatibilityByKey", {}).is_read_only():
		return _pending("ordinary_section_contribution_snapshot_unsealed")
	var live_owners: Dictionary = prepared.get("liveOwnersByPart", {})
	for part_id_value: Variant in prepared.get("memberIds", []):
		var part_id := String(part_id_value)
		var owner_row: Dictionary = live_owners.get(part_id, {})
		if owner_row.is_empty() or _current_live_recipe_visual(context, owner_row,
				section_key).get("status") != "ready":
			_invalidate_section_snapshot(section_id)
			return _pending("ordinary_section_contribution_live_owner_stale", {
				"sourcePartId":part_id})
	var contribution := {"providerId":PROVIDER_ID, "sectionKey":section_key,
		"coverageRevision":coverage_revision, "authorityRevision":provider_revision,
		"authoritySourceRevisions":authority_revisions,
		"inputs":prepared.get("inputs", []),
		"compatibilityByKey":prepared.get("compatibilityByKey", {}),
		"materialBindings":prepared.get("materialBindings", {}),
		"meshBindings":prepared.get("meshBindings", {}),
		"resourceBindings":prepared.get("resourceBindings", {})}
	contribution.make_read_only()
	return {"status":"ready", "contribution":contribution}


## Called only after the section coordinator accepts the installed replacement.
## Keeping this separate prevents an unaccepted candidate from consuming its
## tombstone and losing the retryable removal demand.
func acknowledge_section_install(section_key: Vector3i,
		coverage_revision: String, receipt: Dictionary = {}) -> Dictionary:
	var section_id := _section_id(section_key)
	var snapshot: Dictionary = _latest_by_section.get(section_id, {})
	if snapshot.is_empty() or coverage_revision.is_empty() \
			or _coverage_revision(section_key, snapshot) != coverage_revision:
		return _failed("ordinary_section_install_acknowledgement_stale")
	if receipt.is_empty() or (not receipt.is_read_only() \
			or receipt.get("status") != "installed" \
			or receipt.get("sectionKey") != section_key \
			or String(receipt.get("contentManifestDigest", "")).is_empty()):
		return _failed("ordinary_section_install_receipt_invalid")
	var installed: Dictionary = {}
	var declarations: Variant = snapshot.prepared.get("declarations", [])
	if not declarations is Array:
		return _failed("ordinary_section_install_declarations_missing")
	for declaration_value: Variant in declarations:
		if not declaration_value is Dictionary:
			return _failed("ordinary_section_install_declaration_invalid")
		var declaration: Dictionary = declaration_value
		var part_id := String(declaration.get("sourcePartId", ""))
		var source_id := String(declaration.get("sourceId", ""))
		var authority_source_id := String(declaration.get("authoritySourceId", ""))
		var revision := String(declaration.get("sourceRevision", ""))
		if part_id.is_empty() or source_id != part_id or authority_source_id.is_empty() \
				or revision.is_empty() \
				or String(snapshot.sourceRevisions.get(part_id, "")) != revision \
				or installed.has(part_id):
			return _failed("ordinary_section_install_declaration_binding_invalid", {
				"sourcePartId":part_id, "sourceId":source_id})
		installed[part_id] = {"sourceId":source_id,
			"authoritySourceId":authority_source_id, "sourceRevision":revision}
	if installed.size() != snapshot.sourceRevisions.size():
		return _failed("ordinary_section_install_member_declaration_count_mismatch")
	var context := _context(_world_id)
	if context.is_empty():
		return _pending("ordinary_section_install_owner_changed")
	if not _snapshot_lifecycle_is_current(snapshot, context):
		return _pending("ordinary_section_install_lifecycle_stale", {
			"section":section_key})
	var retirements: Array[Dictionary] = []
	var live_owners: Dictionary = snapshot.prepared.get("liveOwnersByPart", {})
	for part_id_value: Variant in installed:
		var part_id := String(part_id_value)
		var owner_row: Dictionary = live_owners.get(part_id, {})
		if String(owner_row.get("sourceRevision", "")) \
				!= String(installed[part_id].get("sourceRevision", "")):
			return _pending("ordinary_section_live_owner_revision_mismatch", {
				"sourcePartId":part_id, "section":section_key})
		var live_check := _current_live_recipe_visual(context, owner_row, section_key)
		if live_check.get("status") != "ready":
			return _pending(String(live_check.get("reason",
				"ordinary_section_visual_retirement_owner_stale")), {
				"sourcePartId":part_id, "section":section_key})
		retirements.append({"partId":part_id, "visuals":live_check.visuals,
			"sourceRevision":String(owner_row.get("sourceRevision", ""))})
	# The roster calls this only after the coordinator validates the live native
	# receipt. Validate every body and source revision before retiring any visual.
	for retirement: Dictionary in retirements:
		for visual_value: Variant in retirement.visuals:
			var visual := visual_value as MeshInstance3D
			if not is_instance_valid(visual):
				continue
			visual.visible = false
			visual.set_meta("ordinary_structure_section_owned", true)
			visual.set_meta("ordinary_structure_section_retired_source_revision",
				String(retirement.sourceRevision))
	installed.make_read_only()
	_installed_members_by_section[section_id] = {
		"coverageRevision":coverage_revision, "members":installed}
	return {"status":"acknowledged", "section":section_key,
		"coverageRevision":coverage_revision, "memberCount":installed.size()}


func _capture_or_reuse_block(context: Dictionary, raw: Dictionary,
		cell: Vector3i, block_type: String) -> Dictionary:
	if context.is_empty():
		return _pending("ordinary_geometry_cache_world_owner_unavailable")
	var system: Object = context.system
	var main: Object = context.main
	var source_id := String(raw.get("sourceId", ""))
	var source_revision := int(raw.get("sourceRevision", -1))
	var recipe_digest := String(raw.get("recipeDigest", ""))
	var sources_value: Variant = system.get("ordinary_visual_sources")
	var blocks_value: Variant = main.get("blocks")
	if source_id.is_empty() or source_revision < 0 or recipe_digest.is_empty() \
			or not sources_value is Dictionary or not blocks_value is Dictionary:
		return _pending("ordinary_geometry_cache_identity_unavailable")
	var source: Dictionary = sources_value.get(source_id, {})
	var expected: Dictionary = source.get("expected", {})
	var recipe_inputs: Dictionary = source.get("visualRecipeInputs", {})
	var recipe_input: Dictionary = recipe_inputs.get(cell, {})
	if int(source.get("revision", -2)) != source_revision \
			or String(expected.get(cell, "")) != block_type \
			or String(recipe_input.get("digest", "")) != recipe_digest:
		return _pending("ordinary_geometry_cache_authority_revision_changed")
	var body := blocks_value.get(cell) as StaticBody3D
	if not _valid_ordinary_owner_body(body, source_id, block_type) \
			or body.get_meta("cell", null) != cell:
		return _pending("ordinary_geometry_cache_live_body_unavailable")
	var cache_key := _geometry_capture_cache_key(source_id, cell, block_type,
		source_revision, recipe_digest, body)
	if cache_key.is_empty():
		return _pending("ordinary_geometry_cache_key_failed")
	var cached: Dictionary = _geometry_capture_cache.get(cache_key, {})
	if not cached.is_empty():
		var cached_capture: Dictionary = cached.get("capture", {})
		var cached_body_ref: WeakRef = cached_capture.get("body") as WeakRef
		var cached_body := cached_body_ref.get_ref() as StaticBody3D \
			if cached_body_ref != null else null
		if is_instance_valid(cached_body) and cached_body == body \
				and cached_body.get_instance_id() == int(cached.get("bodyInstanceId", 0)):
			var live_visual := _capture_live_recipe_visual(main, cached_capture, cell, block_type)
			if live_visual.get("status") == "ready":
				_geometry_capture_cache_clock += 1
				cached["lastUse"] = _geometry_capture_cache_clock
				_geometry_capture_cache[cache_key] = cached
				_geometry_capture_cache_hits += 1
				return {"status":"ready", "capture":cached_capture,
					"liveVisual":live_visual, "cacheHit":true}
		_remove_geometry_capture_cache_entry(cache_key)
	_geometry_capture_cache_misses += 1
	var captured: Dictionary = Adapter.capture_block(system, main, source_id, cell)
	if captured.get("status") != "ready":
		return {"status":String(captured.get("status", "pending")),
			"reason":String(captured.get("reason", "ordinary_geometry_capture_pending"))}
	var live_visual := _capture_live_recipe_visual(main, captured, cell, block_type)
	if live_visual.get("status") != "ready":
		return {"status":"pending", "reason":String(live_visual.get("reason",
			"ordinary_section_live_recipe_visual_pending"))}
	_retain_geometry_capture(cache_key, captured, body, live_visual)
	return {"status":"ready", "capture":captured,
		"liveVisual":live_visual, "cacheHit":false}


func _geometry_capture_cache_key(source_id: String, cell: Vector3i,
		block_type: String, source_revision: int, recipe_digest: String,
		body: StaticBody3D) -> String:
	if not is_instance_valid(body):
		return ""
	var context := HashingContext.new()
	var payload := ["ordinary-source-capture-cache/v1", _world_id, source_id,
		cell, block_type, source_revision, recipe_digest, body.get_instance_id(),
		body.global_transform, Adapter.SCHEMA]
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(payload)) != OK:
		return ""
	return context.finish().hex_encode()


func _retain_geometry_capture(cache_key: String, captured: Dictionary,
		body: StaticBody3D, live_visual: Dictionary) -> void:
	if cache_key.is_empty() or not is_instance_valid(body):
		return
	var inputs: Array = captured.get("sourceInputs", [])
	var manifest: Dictionary = captured.get("manifest", {})
	var estimated_bytes := var_to_bytes([inputs, manifest]).size() \
		+ int(captured.get("memberBindings", []).size()) * 512
	if estimated_bytes <= 0 or estimated_bytes > MAX_GEOMETRY_CAPTURE_CACHE_BYTES:
		return
	while _geometry_capture_cache.size() >= MAX_GEOMETRY_CAPTURE_CACHE_ENTRIES \
			or _geometry_capture_cache_bytes + estimated_bytes \
			> MAX_GEOMETRY_CAPTURE_CACHE_BYTES:
		if not _evict_oldest_geometry_capture(cache_key):
			return
	var resource_ids: Array[int] = []
	for binding_value: Variant in captured.get("memberBindings", []):
		if not binding_value is Dictionary:
			return
		var binding: Dictionary = binding_value
		for resource_value: Variant in [binding.get("mesh"), binding.get("material")]:
			var resource := resource_value as Resource
			if not is_instance_valid(resource):
				return
			var resource_id := resource.get_instance_id()
			if resource_id not in resource_ids:
				resource_ids.append(resource_id)
				_track_geometry_cache_resource(resource, cache_key)
	_geometry_capture_cache_clock += 1
	var entry := {"capture":captured, "bodyInstanceId":body.get_instance_id(),
		"bodyTransform":live_visual.get("bodyTransform", Transform3D.IDENTITY),
		"contentDigest":String(live_visual.get("contentDigest", "")),
		"resourceIds":resource_ids, "estimatedBytes":estimated_bytes,
		"lastUse":_geometry_capture_cache_clock}
	_geometry_capture_cache[cache_key] = entry
	_geometry_capture_cache_bytes += estimated_bytes


func _track_geometry_cache_resource(resource: Resource, cache_key: String) -> void:
	var resource_id := resource.get_instance_id()
	var tracked: Dictionary = _geometry_capture_cache_resource_bindings.get(resource_id, {})
	if tracked.is_empty():
		var provider_ref: WeakRef = weakref(self)
		var callback: Callable = func(changed_resource_id: int) -> void:
			var provider: OrdinaryStructureStaticSectionProvider = \
				provider_ref.get_ref() as OrdinaryStructureStaticSectionProvider
			if is_instance_valid(provider):
				provider._on_geometry_cache_resource_changed(changed_resource_id)
		callback = callback.bind(resource_id)
		if not resource.changed.is_connected(callback):
			resource.changed.connect(callback)
		tracked = {"resource":resource, "callback":callback, "cacheKeys":{}}
	var cache_keys: Dictionary = tracked.get("cacheKeys", {})
	cache_keys[cache_key] = true
	tracked["cacheKeys"] = cache_keys
	_geometry_capture_cache_resource_bindings[resource_id] = tracked


func _on_geometry_cache_resource_changed(resource_id: int) -> void:
	var tracked: Dictionary = _geometry_capture_cache_resource_bindings.get(resource_id, {})
	var cache_keys: Array = (tracked.get("cacheKeys", {}) as Dictionary).keys()
	for cache_key_value: Variant in cache_keys:
		_remove_geometry_capture_cache_entry(String(cache_key_value))


func _remove_geometry_capture_cache_entry(cache_key: String) -> void:
	var entry: Dictionary = _geometry_capture_cache.get(cache_key, {})
	if entry.is_empty():
		return
	_geometry_capture_cache.erase(cache_key)
	_geometry_capture_cache_bytes = maxi(0, _geometry_capture_cache_bytes
		- int(entry.get("estimatedBytes", 0)))
	for resource_id_value: Variant in entry.get("resourceIds", []):
		var resource_id := int(resource_id_value)
		var tracked: Dictionary = _geometry_capture_cache_resource_bindings.get(resource_id, {})
		var cache_keys: Dictionary = tracked.get("cacheKeys", {})
		cache_keys.erase(cache_key)
		if cache_keys.is_empty():
			var resource := tracked.get("resource") as Resource
			var callback: Callable = tracked.get("callback", Callable())
			if is_instance_valid(resource) and callback.is_valid() \
					and resource.changed.is_connected(callback):
				resource.changed.disconnect(callback)
		else:
			tracked["cacheKeys"] = cache_keys
			_geometry_capture_cache_resource_bindings[resource_id] = tracked
		if cache_keys.is_empty():
			_geometry_capture_cache_resource_bindings.erase(resource_id)


func _evict_oldest_geometry_capture(excluded_key: String) -> bool:
	var selected_key := ""
	var selected_use := 9223372036854775807
	for key_value: Variant in _geometry_capture_cache:
		var key := String(key_value)
		if key == excluded_key:
			continue
		var entry: Dictionary = _geometry_capture_cache[key]
		var last_use := int(entry.get("lastUse", 0))
		if last_use < selected_use:
			selected_key = key
			selected_use = last_use
	if selected_key.is_empty():
		return false
	_remove_geometry_capture_cache_entry(selected_key)
	_geometry_capture_cache_evictions += 1
	return true


func _capture_live_recipe_visual(main: Object, captured: Dictionary,
		cell: Vector3i, block_type: String) -> Dictionary:
	var body_ref: WeakRef = captured.get("body") as WeakRef
	var body := body_ref.get_ref() as StaticBody3D if body_ref != null else null
	var inputs: Array = captured.get("sourceInputs", [])
	if inputs.is_empty():
		inputs = [captured.get("sourceInput", {})]
	var input: Dictionary = inputs[0] if inputs[0] is Dictionary else {}
	var recipe_input: Dictionary = input.get("visualRecipeInput", {})
	var options: Dictionary = recipe_input.get("options", {})
	var recipe: Dictionary = VisualRecipe.resolve_member(main, block_type, cell, options)
	if not is_instance_valid(body) or recipe.get("status") != "ready":
		return _pending("ordinary_section_live_recipe_visual_owner_or_recipe_missing")
	var expected_digest := String(recipe.get("contentDigest", ""))
	if expected_digest.is_empty() \
			or String(body.get_meta("ordinary_structure_recipe_content_digest", "")) != expected_digest:
		return _pending("ordinary_section_live_recipe_visual_body_digest_mismatch")
	var mesh_nodes: Array[MeshInstance3D] = []
	var visuals_by_segment: Dictionary = {}
	var stack: Array[Node] = [body]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child_value: Variant in node.get_children():
			if child_value is Node:
				stack.append(child_value)
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			mesh_nodes.append(mesh_node)
			var segment_id := String(mesh_node.get_meta(
				"ordinary_structure_recipe_segment_id", ""))
			if mesh_node.get_parent() == body \
					and String(mesh_node.get_meta("ordinary_structure_recipe_content_digest", "")) == expected_digest \
				and not segment_id.is_empty():
				visuals_by_segment[segment_id] = mesh_node
	var recipe_members: Array = recipe.get("members", [])
	var bindings: Array = captured.get("memberBindings", [])
	if mesh_nodes.size() != recipe_members.size() \
			or inputs.size() != recipe_members.size() \
			or bindings.size() != recipe_members.size() \
			or visuals_by_segment.size() != recipe_members.size():
		return _pending("ordinary_section_live_recipe_visual_cardinality_mismatch", {
			"meshNodeCount":mesh_nodes.size(), "expectedMemberCount":recipe_members.size(),
			"matchingNodeCount":visuals_by_segment.size()})
	var visual_rows: Array[Dictionary] = []
	for index in recipe_members.size():
		var member: Dictionary = recipe_members[index]
		var source_input: Dictionary = inputs[index]
		var binding: Dictionary = bindings[index]
		var segment_id := String(member.get("segmentId", ""))
		var visual := visuals_by_segment.get(segment_id) as MeshInstance3D
		var input_buffer: Array = source_input.get("buffer", [])
		var expected_transform := Attributes.decode_transform(input_buffer, 0)
		if binding.get("mesh") != member.get("mesh") \
				or binding.get("material") != member.get("material") \
				or not String(source_input.get("segmentId", "")).ends_with(":" + segment_id) \
				or not is_instance_valid(visual) or visual.mesh != member.get("mesh") \
				or visual.material_override != member.get("material") \
				or not _transform_approximately_equal(visual.transform, expected_transform) \
				or (not visual.visible \
					and not bool(visual.get_meta("ordinary_structure_section_owned", false))):
			return _pending("ordinary_section_live_recipe_visual_resource_mismatch", {
				"segmentId":segment_id})
		var row := {"segmentId":segment_id, "visual":weakref(visual),
			"visualInstanceId":visual.get_instance_id(), "mesh":member.get("mesh"),
			"material":member.get("material"), "transform":visual.transform,
			"sourceRevision":String(source_input.get("sourceRevision", "")),
			"sourceInput":source_input,
			"sectionKey":Grid.key_for_world_position(
				(member.worldBounds as AABB).get_center())}
		row.make_read_only()
		visual_rows.append(row)
	visual_rows.make_read_only()
	var body_transform: Transform3D = recipe.get("sourceToWorld", Transform3D.IDENTITY)
	return {"status":"ready", "bodyInstanceId":body.get_instance_id(),
		"visualMembers":visual_rows, "contentDigest":expected_digest,
		"bodyTransform":body_transform}


func _current_live_recipe_visual(context: Dictionary, owner_row: Dictionary,
		section_key: Vector3i) -> Dictionary:
	if context.is_empty() or owner_row.is_empty():
		return _pending("ordinary_section_live_owner_binding_missing")
	var body_ref: WeakRef = owner_row.get("body") as WeakRef
	var body := body_ref.get_ref() as StaticBody3D if body_ref != null else null
	var visual_members: Array = owner_row.get("visualMembers", [])
	var source_id := String(owner_row.get("authoritySourceId", ""))
	var cell: Variant = owner_row.get("cell")
	var block_type := String(owner_row.get("blockType", ""))
	var source_revision := String(owner_row.get("sourceRevision", ""))
	if not is_instance_valid(body) or visual_members.is_empty() \
			or not cell is Vector3i or source_id.is_empty() or source_revision.is_empty() \
			or body.get_instance_id() != int(owner_row.get("bodyInstanceId", 0)) \
			or not body.is_inside_tree() or body.is_queued_for_deletion():
		return _pending("ordinary_section_live_owner_replaced")
	var sources: Dictionary = context.system.get("ordinary_visual_sources")
	var source: Dictionary = sources.get(source_id, {})
	var blocks: Dictionary = context.main.get("blocks")
	if source.is_empty() or int(source.get("revision", -1)) \
			!= int(owner_row.get("authoritySourceRevision", -2)) \
			or blocks.get(cell) != body \
			or body.get_meta("cell", null) != cell \
			or String(body.get_meta("generated_visual_source_id", "")) != source_id \
			or String(body.get_meta("block_type", "")) != block_type \
			or bool(body.get_meta("player_placed", false)) \
			or String(body.get_meta("ordinary_structure_recipe_content_digest", "")) \
				!= String(owner_row.get("visualContentDigest", "")) \
			or not _transform_approximately_equal(body.global_transform,
				owner_row.get("sourceToWorld")):
		return _pending("ordinary_section_live_owner_revision_changed")
	var visuals: Array[MeshInstance3D] = []
	for row_value: Variant in visual_members:
		if not row_value is Dictionary:
			return _pending("ordinary_section_live_visual_member_invalid")
		var row: Dictionary = row_value
		var visual_ref: WeakRef = row.get("visual") as WeakRef
		var visual := visual_ref.get_ref() as MeshInstance3D if visual_ref != null else null
		if not is_instance_valid(visual) or visual.get_instance_id() \
				!= int(row.get("visualInstanceId", 0)) or visual.get_parent() != body \
				or visual.is_queued_for_deletion() \
				or visual.mesh != row.get("mesh") \
				or visual.material_override != row.get("material") \
				or not _transform_approximately_equal(visual.transform,
					row.get("transform")) \
				or String(visual.get_meta("ordinary_structure_recipe_segment_id", "")) \
					!= String(row.get("segmentId", "")) \
				or (not visual.visible and not bool(visual.get_meta(
					"ordinary_structure_section_owned", false))):
			return _pending("ordinary_section_live_visual_member_stale", {
				"segmentId":String(row.get("segmentId", ""))})
		if row.get("sectionKey") == section_key:
			visuals.append(visual)
	return {"status":"ready", "visuals":visuals}


func _transform_approximately_equal(a: Transform3D, b: Transform3D) -> bool:
	return a.origin.distance_squared_to(b.origin) <= 0.000001 \
		and a.basis.x.distance_squared_to(b.basis.x) <= 0.000001 \
		and a.basis.y.distance_squared_to(b.basis.y) <= 0.000001 \
		and a.basis.z.distance_squared_to(b.basis.z) <= 0.000001


func _input_owned_by_section(input: Dictionary, section: Vector3i) -> bool:
	var source_to_world: Variant = input.get("sourceToWorld")
	var buffer_value: Variant = input.get("buffer")
	var bounds_value: Variant = input.get("meshLocalBounds")
	if not source_to_world is Transform3D or not buffer_value is Array \
			or not bounds_value is AABB:
		return false
	var local_transform := Attributes.decode_transform(buffer_value, 0)
	var world_bounds: AABB = source_to_world * local_transform * bounds_value
	return Grid.key_for_world_position(world_bounds.get_center()) == section


func _snapshot_lifecycle_is_current(snapshot: Dictionary, context: Dictionary) -> bool:
	var prepared: Dictionary = snapshot.get("prepared", {})
	var lifecycle: Dictionary = prepared.get("lifecycle", {})
	var bounds: Variant = lifecycle.get("bounds")
	if lifecycle.is_empty() or not bounds is Rect2i:
		return false
	var system: Object = context.system
	return String(context.main.get("seed_text")) == String(lifecycle.get("seed", "")) \
		and int(system.get("ordinary_visual_revision")) == int(lifecycle.get("ordinaryRevision", -1)) \
		and int(system.get("regional_source_generation")) == int(lifecycle.get("generation", -1)) \
		and int(system.get("regional_source_revision")) == int(lifecycle.get("regionalRevision", -1)) \
		and _membership_currentness_token(bounds, context) == lifecycle.get("membershipToken", [])


func _begin_job(section: Vector3i, context: Dictionary, census: Dictionary) -> Dictionary:
	var window_value: Variant = census.get("bounds", null)
	var bounds := _section_discovery_bounds(section)
	if not window_value is Rect2i or bounds.size.x <= 0 or bounds.size.y <= 0 \
			or census.get("censusSchema") != "ordinary-source-membership-census/v1" \
			or not census.get("members") is Array \
			or not census.get("members").is_read_only():
		return _failed("ordinary_section_membership_census_invalid")
	var census_window: Rect2i = window_value
	var membership_token := _membership_currentness_token(census_window, context)
	var candidates: Array[Dictionary] = []
	for member_value: Variant in census.members:
		if not member_value is Dictionary or not member_value.is_read_only():
			return _failed("ordinary_section_membership_row_unsealed")
		var member: Dictionary = member_value
		var cell_value: Variant = member.get("cell", null)
		var source_id := String(member.get("sourceId", ""))
		var block_type := String(member.get("blockType", ""))
		var part_id := String(member.get("memberId", ""))
		if not cell_value is Vector3i or source_id.is_empty() or block_type.is_empty() \
				or part_id.is_empty() or String(member.get("recipeDigest", "")).length() != 64 \
				or not member.get("recipeInput") is Dictionary \
				or not member.get("recipeInput").is_read_only():
			return _failed("ordinary_section_membership_row_invalid")
		var cell: Vector3i = cell_value
		var body := (context.main.get("blocks") as Dictionary).get(cell) as Node3D
		if not _valid_ordinary_owner_body(body, source_id, block_type): body = null
		var representation := context.system.call("_ordinary_visible_renderable", body) as Node3D \
			if is_instance_valid(body) else null
		candidates.append({"candidateId":part_id,
			"positionXZ":Vector2(float(cell.x) + 0.5, float(cell.z) + 0.5),
			"cell":cell, "sourceId":source_id, "blockType":block_type,
			"sourceRevision":int(member.get("sourceRevision", -1)),
			"recipeDigest":String(member.get("recipeDigest", "")),
			"recipeInput":member.get("recipeInput"),
			"owner":weakref(body) if is_instance_valid(body) else null,
			"ownerId":body.get_instance_id() if is_instance_valid(body) else 0,
			"representation":weakref(representation) if is_instance_valid(representation) else null,
			"representationId":representation.get_instance_id() \
				if is_instance_valid(representation) else 0})
	return {"status":"pending", "phase":"capture_geometry", "section":section,
		"bounds":census_window, "censusWindow":census_window,
		"membershipToken":membership_token,
		"candidateIndex":0, "candidates":candidates,
		"seed":String(context.main.get("seed_text")),
		"ordinaryRevision":int(context.system.get("ordinary_visual_revision")),
		"generation":int(context.system.get("regional_source_generation")),
		"regionalRevision":int(context.system.get("regional_source_revision")),
		"inputs":[], "sourceRevisions":{}, "resourcesByBatch":{},
		"meshBindings":{}, "materialBindings":{},
		"compatibilityByKey":{}, "sourceRows":{},
		"discoveryRevision":String(census.get("sourceRevision", "")), "snapshot":{}}


func _advance_job(job: Dictionary, context: Dictionary) -> Dictionary:
	if not _job_is_current(job, context):
		return _pending("ordinary_section_source_revision_changed", {
			"section":job.get("section", Vector3i.ZERO), "restart":true})
	if String(job.phase) == "capture_geometry":
		var processed := 0
		while int(job.candidateIndex) < job.candidates.size() and processed < MEMBERS_PER_TURN:
			var raw_value: Variant = job.candidates[int(job.candidateIndex)]
			job.candidateIndex = int(job.candidateIndex) + 1
			processed += 1
			if not raw_value is Dictionary:
				return _failed("ordinary_section_source_candidate_invalid")
			var raw: Dictionary = raw_value
			if not _candidate_intersects_section(raw, Vector3i(job.section), context.main):
				continue
			var source_id := String(raw.get("sourceId", ""))
			var cell_value: Variant = raw.get("cell")
			if source_id.is_empty() or not cell_value is Vector3i:
				return _failed("ordinary_section_source_candidate_identity_invalid")
			var captured_result := _capture_or_reuse_block(context, raw,
				Vector3i(cell_value), String(raw.get("blockType", "")))
			if captured_result.get("status") != "ready":
				if captured_result.get("status") == "empty":
					continue
				job.candidateIndex = int(job.candidateIndex) - 1
				return _pending(String(captured_result.get("reason",
					"ordinary_section_member_geometry_pending")), {
					"sourceId":source_id, "cell":cell_value,
					"blockType":String(raw.get("blockType", ""))})
			var captured: Dictionary = captured_result.get("capture", {})
			if captured.get("status") == "empty":
				continue
			if captured.get("status") != "ready":
				job.candidateIndex = int(job.candidateIndex) - 1
				return _pending(String(captured.get("reason", "ordinary_section_member_geometry_pending")), {
					"sourceId":source_id, "cell":cell_value,
					"blockType":String(raw.get("blockType", ""))})
			var inputs: Array = captured.get("sourceInputs", [])
			var bindings: Array = captured.get("memberBindings", [])
			var part_id := String(captured.get("sourcePartId", ""))
			if part_id.is_empty() or job.sourceRows.has(part_id):
				return _failed("ordinary_section_duplicate_or_missing_source_part")
			if inputs.is_empty() or bindings.size() != inputs.size():
				return _failed("ordinary_section_member_binding_count_mismatch")
			var source_record: Dictionary = (context.system.get("ordinary_visual_sources") as Dictionary).get(source_id, {})
			var current_recipe: Dictionary = inputs[0].get("visualRecipeInput", {})
			if int(source_record.get("revision", -1)) != int(raw.get("sourceRevision", -2)) \
					or String(inputs[0].get("visualRecipeDigest", "")) != String(raw.get("recipeDigest", "")) \
					or String(current_recipe.get("digest", "")) != String(raw.get("recipeDigest", "")):
				job.candidateIndex = int(job.candidateIndex) - 1
				_invalidate_membership_window(job.censusWindow)
				return _pending("ordinary_section_membership_member_revision_changed", {
					"sourceId":source_id, "cell":cell_value, "restart":true})
			var live_visual: Dictionary = captured_result.get("liveVisual", {})
			for binding_value: Variant in bindings:
				if not binding_value is Dictionary:
					return _failed("ordinary_section_member_binding_invalid")
				var binding: Dictionary = binding_value
				var bound_input: Dictionary = binding.get("input", {})
				var compatibility: Dictionary = binding.get("compatibility", {})
				var batch_key := String(bound_input.get("batchKey", ""))
				if batch_key.is_empty() or compatibility.is_empty():
					return _failed("ordinary_section_batch_key_missing")
				var resource := {"mesh":binding.get("mesh"),
					"material":binding.get("material"),
					"meshDigest":String(binding.get("meshDigest", "")),
					"materialDigest":String(binding.get("materialDigest", ""))}
				resource.make_read_only()
				job.resourcesByBatch[batch_key] = resource
				job.compatibilityByKey[batch_key] = compatibility
				job.meshBindings[String(compatibility.meshResourceKey)] = binding.mesh
				job.materialBindings[String(compatibility.materialKey)] = binding.material
			job.sourceRevisions[part_id] = String(captured.get("sourceRevision", ""))
			job.sourceRows[part_id] = {"bindings":bindings,
				"manifest":captured.manifest,
				"liveOwner":{"body":captured.body,
					"bodyInstanceId":int(live_visual.get("bodyInstanceId", 0)),
					"visualMembers":live_visual.get("visualMembers", []),
					"sourceToWorld":live_visual.get("bodyTransform", Transform3D.IDENTITY),
					"authoritySourceId":source_id,
					"authoritySourceRevision":int(source_record.get("revision", -1)),
					"cell":Vector3i(cell_value),
					"blockType":String(raw.get("blockType", "")),
					"visualContentDigest":String(live_visual.get("contentDigest", "")),
					"sourceRevision":String(captured.get("sourceRevision", ""))}}
		if int(job.candidateIndex) < job.candidates.size():
			return _pending("ordinary_section_geometry_capture_budget", {
				"section":job.section, "cursor":int(job.candidateIndex),
				"candidateCount":job.candidates.size(),
				"continuationHint":_continuation_hint("section_geometry",
					int(job.candidateIndex))})
		if not _job_is_current(job, context):
			return _pending("ordinary_section_source_revision_changed", {
				"section":job.section, "restart":true})
		var inputs: Array[Dictionary] = []
		for row_value: Variant in job.sourceRows.values():
			var row: Dictionary = row_value
			for binding_value: Variant in row.get("bindings", []):
				if not binding_value is Dictionary:
					return _failed("ordinary_section_member_binding_invalid")
				inputs.append(binding_value.input)
		inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.sourcePartId) < String(b.sourcePartId))
		inputs.make_read_only()
		var partitioned: Dictionary = Partitioner.partition(inputs)
		if partitioned.get("status") != "ready":
			return _failed("ordinary_section_partition_failed:" + String(partitioned.get("reason", "unknown")))
		var partition: Dictionary = partitioned.get("result", {})
		var section: Vector3i = job.section
		var member_ids: Dictionary = {}
		for output_value: Variant in partition.get("outputs", []):
			if not output_value is Dictionary:
				return _failed("ordinary_section_partition_output_invalid")
			var output: Dictionary = output_value
			if output.get("sectionKey") == section:
				var part_id := String(output.get("sourcePartId", ""))
				if part_id.is_empty() or not job.sourceRows.has(part_id):
					return _failed("ordinary_section_partition_member_unbound")
				member_ids[part_id] = true
		var ordered_ids: Array[String] = []
		for part_id_value: Variant in member_ids:
			ordered_ids.append(String(part_id_value))
		ordered_ids.sort()
		var owned_inputs: Array[Dictionary] = []
		var owned_compatibility: Dictionary = {}
		var owned_resources: Dictionary = {}
		var owned_meshes: Dictionary = {}
		var owned_materials: Dictionary = {}
		var owned_revisions: Dictionary = {}
		var live_owners_by_part: Dictionary = {}
		var declarations: Array[Dictionary] = []
		var prepared_segments: Array[Dictionary] = []
		for part_id: String in ordered_ids:
			var source_row: Dictionary = job.sourceRows[part_id]
			var bindings: Array = source_row.get("bindings", [])
			if bindings.is_empty():
				return _failed("ordinary_section_member_binding_list_empty")
			var first_input: Dictionary = bindings[0].input
			var segment_declarations: Array[Dictionary] = []
			for binding_value: Variant in bindings:
				if not binding_value is Dictionary:
					return _failed("ordinary_section_member_binding_invalid")
				var binding: Dictionary = binding_value
				var input: Dictionary = binding.input
				var compatibility: Dictionary = binding.compatibility
				if not _input_owned_by_section(input, section):
					continue
				if String(input.sourcePartId) != part_id \
						or String(input.sourceRevision) != String(first_input.sourceRevision):
					return _failed("ordinary_section_member_source_identity_conflict")
				owned_inputs.append(input)
				var batch_key := String(input.batchKey)
				owned_compatibility[batch_key] = compatibility
				owned_resources[batch_key] = job.resourcesByBatch[batch_key]
				owned_meshes[String(compatibility.meshResourceKey)] = job.meshBindings[String(compatibility.meshResourceKey)]
				owned_materials[String(compatibility.materialKey)] = job.materialBindings[String(compatibility.materialKey)]
				var segment_declaration := _segment_declaration(input, compatibility)
				segment_declaration.make_read_only()
				segment_declarations.append(segment_declaration)
				prepared_segments.append(input)
			if segment_declarations.is_empty():
				return _failed("ordinary_section_member_has_no_owned_render_segments", {
					"sourcePartId":part_id, "section":section})
			owned_revisions[part_id] = String(first_input.sourceRevision)
			var live_owner: Dictionary = source_row.get("liveOwner", {})
			if live_owner.is_empty() \
					or String(live_owner.get("sourceRevision", "")) != String(first_input.sourceRevision):
				return _failed("ordinary_section_live_owner_binding_missing", {
					"sourcePartId":part_id})
			live_owner.make_read_only()
			live_owners_by_part[part_id] = live_owner
			segment_declarations.make_read_only()
			var declaration := {"sourceId":String(first_input.sourceId),
			"sourcePartId":part_id, "sourceRevision":String(first_input.sourceRevision),
			"authoritySourceId":String(first_input.get("authoritySourceId", "")),
			"sourceToWorld":first_input.sourceToWorld, "ownerCell":first_input.ownerCell,
				"segments":segment_declarations}
			declaration.make_read_only()
			declarations.append(declaration)
		owned_inputs.make_read_only()
		owned_compatibility.make_read_only()
		owned_resources.make_read_only()
		owned_meshes.make_read_only()
		owned_materials.make_read_only()
		owned_revisions.make_read_only()
		live_owners_by_part.make_read_only()
		declarations.make_read_only()
		prepared_segments.make_read_only()
		var owned_partition: Dictionary = Partitioner.partition(owned_inputs).get("result", {})
		if owned_partition.is_empty():
			return _failed("ordinary_section_owned_partition_missing")
		var lifecycle := {"seed":String(job.seed),
			"ordinaryRevision":int(job.ordinaryRevision),
			"generation":int(job.generation),
			"regionalRevision":int(job.regionalRevision),
			"membershipToken":job.membershipToken,
			"bounds":job.bounds}
		lifecycle.make_read_only()
		var prepared := {"schema":SCHEMA, "sectionKey":section,
			"coverageScope":"ordinary_generated_static_geometry",
			"lifecycle":lifecycle,
			"memberIds":ordered_ids, "sourceRevisions":owned_revisions,
			"liveOwnersByPart":live_owners_by_part,
			"inputs":owned_inputs, "declarations":declarations,
			"preparedSegments":prepared_segments,
			"partition":owned_partition,
			"compatibilityByKey":owned_compatibility,
			"resourceBindings":owned_resources,
			"meshBindings":owned_meshes,
			"materialBindings":owned_materials}
		prepared.memberIds.make_read_only()
		prepared.make_read_only()
		var source_rows: Array = []
		for part_id: String in ordered_ids:
			source_rows.append([part_id, String(owned_revisions[part_id])])
		var tombstones: Array[Dictionary] = []
		tombstones.make_read_only()
		var snapshot := {"sectionKey":section, "discoveryRevision":String(job.discoveryRevision),
			"memberIds":ordered_ids, "sourceRevisions":owned_revisions,
			"sourceRows":source_rows, "prepared":prepared, "tombstones":tombstones}
		snapshot.memberIds.make_read_only()
		snapshot.sourceRows.make_read_only()
		snapshot.make_read_only()
		job.snapshot = snapshot
		job.phase = "complete"
		return {"status":"complete", "snapshot":snapshot}
	if String(job.phase) == "complete":
		if not _job_is_current(job, context):
			return _pending("ordinary_section_source_revision_changed", {
				"section":job.section, "restart":true})
		return {"status":"complete", "snapshot":job.snapshot}
	return _failed("ordinary_section_provider_job_phase_invalid")


func _segment_declaration(input: Dictionary, compatibility: Dictionary) -> Dictionary:
	return {"segmentId":String(input.segmentId),
		"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":String(compatibility.materialKey),
		"renderTier":String(compatibility.renderTier),
		"meshKey":String(compatibility.meshResourceKey),
		"meshContentDigest":String(compatibility.meshContentDigest),
		"meshLocalBounds":compatibility.meshLocalBounds,
		"pipelineRevision":String(compatibility.pipelineRevision),
		"renderLayer":String(compatibility.renderLayer),
		"translucentSortPolicy":String(compatibility.translucentSortPolicy),
		"castShadows":bool(compatibility.castShadows),
		"visibilityRangeEnd":float(compatibility.visibilityRangeEnd),
		"fadeMargin":float(compatibility.fadeMargin),
		"compatibilityKey":String(compatibility.batchKey)}


func _candidate_intersects_section(candidate: Dictionary, section: Vector3i,
		main: Object) -> bool:
	var section_origin := Grid.origin_for_key(section)
	var section_bounds := AABB(section_origin, Vector3.ONE * Grid.SECTION_SIZE_METERS)
	var owner_ref: WeakRef = candidate.get("owner") as WeakRef
	var body: Node3D = owner_ref.get_ref() as Node3D if owner_ref != null else null
	if is_instance_valid(body):
		var stack: Array[Node] = [body]
		var found_mesh := false
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			for child_value: Variant in node.get_children():
				if child_value is Node:
					stack.append(child_value)
			if node is MeshInstance3D:
				var mesh_node := node as MeshInstance3D
				# Visibility changes after receipt retirement, but the recipe geometry
				# still determines its owner section during unload/replay census.
				if mesh_node.mesh != null:
					found_mesh = true
					if section_bounds.intersects(mesh_node.global_transform * mesh_node.mesh.get_aabb()):
						return true
		if found_mesh:
			return false
	var cell_value: Variant = candidate.get("cell")
	if not cell_value is Vector3i:
		return true
	var scale := float(main.get("CELL"))
	if not is_finite(scale) or scale <= 0.0:
		return true
	var cell: Vector3i = cell_value
	var fallback_bounds := AABB(Vector3(cell) * scale, Vector3.ONE * scale)
	return section_bounds.intersects(fallback_bounds)


func _job_is_current(job: Dictionary, context: Dictionary) -> bool:
	if context.is_empty() or job.is_empty() or not job.get("censusWindow") is Rect2i \
			or not job.get("membershipToken") is Array:
		return false
	return String(context.main.get("seed_text")) == String(job.get("seed", 
		context.main.get("seed_text"))) \
		and int(context.system.get("ordinary_visual_revision")) == int(job.get("ordinaryRevision", -1)) \
		and int(context.system.get("regional_source_generation")) == int(job.get("generation", -1)) \
		and int(context.system.get("regional_source_revision")) == int(job.get("regionalRevision", \
			context.system.get("regional_source_revision"))) \
		and _membership_currentness_token(job.censusWindow, context) == job.membershipToken


func _context(world_id: String) -> Dictionary:
	if world_id != _world_id or _world_id.is_empty():
		return {}
	var system: Object = _system_ref.get_ref() if _system_ref != null else null
	var main: Object = _main_ref.get_ref() if _main_ref != null else null
	if not is_instance_valid(system) or not is_instance_valid(main) \
			or system.get_instance_id() != _system_id or main.get_instance_id() != _main_id \
			or system.get("main") != main:
		return {}
	return {"system":system, "main":main}


func _valid_ordinary_owner_body(body: Node3D, source_id: String,
		block_type: String) -> bool:
	return is_instance_valid(body) and body.is_inside_tree() \
		and not body.is_queued_for_deletion() \
		and String(body.get_meta("generated_visual_source_id", "")) == source_id \
		and String(body.get_meta("block_type", "")) == block_type


static func _continuation_hint(stage: String, cursor: int) -> Dictionary:
	var hint := {"schema":"static-section-provider-continuation/v1",
		"stage":stage, "cursor":clampi(cursor, 0, 1_000_000)}
	hint.make_read_only()
	return hint


func _coverage_revision(section: Vector3i, snapshot: Dictionary) -> String:
	var context := _context(_world_id)
	if context.is_empty(): return ""
	var payload := [SCHEMA, _world_id, section, String(snapshot.discoveryRevision),
		int(context.system.get("ordinary_visual_revision")), snapshot.sourceRows]
	return _sha256(var_to_bytes(payload))


func _removals_for(section: Vector3i, snapshot: Dictionary,
		coverage_revision: String) -> Array[Dictionary]:
	var previous: Dictionary = _installed_members_by_section.get(_section_id(section), {})
	var old_members: Dictionary = previous.get("members", {})
	var current_members: Dictionary = snapshot.get("sourceRevisions", {})
	var removals: Array[Dictionary] = []
	var old_ids: Array[String] = []
	for part_id_value: Variant in old_members:
		old_ids.append(String(part_id_value))
	old_ids.sort()
	var context := _context(_world_id)
	var authority_serial := int(context.system.get("ordinary_visual_revision")) if not context.is_empty() else -1
	for part_id: String in old_ids:
		if current_members.has(part_id): continue
		var prior_member: Dictionary = old_members.get(part_id, {})
		var source_id := String(prior_member.get("sourceId", ""))
		var authority_source_id := String(prior_member.get("authoritySourceId", ""))
		if source_id.is_empty():
			continue
		var revision := _sha256(var_to_bytes([SCHEMA, _world_id, section, part_id,
			String(prior_member.get("sourceRevision", "")), authority_serial, coverage_revision]))
		var row := {"sourceId":source_id, "sourcePartId":part_id,
			"authoritySourceId":authority_source_id, "sourceRevision":revision,
			"sectionKey":section, "reason":"ordinary_generated_visual_removed"}
		row.make_read_only()
		removals.append(row)
	removals.make_read_only()
	return removals


func _section_id(section: Vector3i) -> String:
	return "%d,%d,%d" % [section.x, section.y, section.z]


func _section_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x: return a.x < b.x
	if a.y != b.y: return a.y < b.y
	return a.z < b.z


func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "worldId":_world_id,
		"providerId":PROVIDER_ID, "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


func _failed(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"failed", "worldId":_world_id,
		"providerId":PROVIDER_ID, "reason":reason, "retryable":false}
	result.merge(detail, true)
	return result
