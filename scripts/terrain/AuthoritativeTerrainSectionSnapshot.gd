extends RefCounted
class_name AuthoritativeTerrainSectionSnapshot

## Captures a section-local Transvoxel input from the existing deterministic
## generator and the current terrain-volume deltas. It does not read or require
## a resident Voxel Tools mesh block.

const GENERATOR_SCRIPT := preload("res://scripts/terrain/VoxelTerrainGenerator.gd")
const SECTION_SIZE := 16
const HALO_MIN := Vector3i.ONE
const HALO_MAX := Vector3i(2, 2, 2)
const CAPTURE_SIZE := Vector3i(SECTION_SIZE + 3, SECTION_SIZE + 3, SECTION_SIZE + 3)
const CELL := 1.35

## Worker inputs may be superseded while generation is in flight. Cancellation
## is synchronized because the owner and generation thread share this token.
class CancellationToken extends RefCounted:
	var _mutex := Mutex.new()
	var _cancelled := false
	var _generation_active := false

	func cancel() -> void:
		_mutex.lock()
		_cancelled = true
		_mutex.unlock()

	func is_cancelled() -> bool:
		_mutex.lock()
		var value := _cancelled
		_mutex.unlock()
		return value

	func set_generation_active(active: bool) -> void:
		_mutex.lock()
		_generation_active = active
		_mutex.unlock()

	func is_generation_active() -> bool:
		_mutex.lock()
		var value := _generation_active
		_mutex.unlock()
		return value


## Captures all mutable owners on their owning thread. The returned preparation
## contains only a detached generator context and deeply read-only values.
static func prepare(generator: Object, volume: Object, section_key: Vector3i,
		world_id: String, mesher_material_revision: String,
		fluid_proof: Dictionary) -> Dictionary:
	if generator == null or not is_instance_valid(generator) \
			or volume == null or not is_instance_valid(volume):
		return _pending("terrain_authority_source_unavailable")
	if world_id.is_empty() or mesher_material_revision.is_empty():
		return _failed("terrain_authority_identity_incomplete")
	if not _fluid_proof_is_valid(fluid_proof, section_key):
		return _pending("terrain_exact_fluid_proof_unavailable")
	if not generator.has_method("get"):
		return _pending("terrain_generator_context_unavailable")
	var template: Variant = generator.get("context_template")
	if template == null or not template is Object or not template.has_method("clone_for_worker"):
		return _pending("terrain_generator_context_unavailable")
	var seed_text := String(template.get("seed_text"))
	var seed_hash := int(template.get("seed_hash"))
	if seed_text.is_empty():
		return _pending("terrain_generator_seed_unavailable")
	var profile_before := _profile_revision(template)
	if profile_before.get("status") != "ready":
		return _pending(String(profile_before.get("reason", "terrain_profile_snapshot_unavailable")))
	var capture_origin := section_key * SECTION_SIZE - HALO_MIN
	var revision_rows := _section_revision_rows(volume, capture_origin, CAPTURE_SIZE)
	if revision_rows.get("status") != "ready":
		return revision_rows
	var override_values := _capture_override_values(volume, capture_origin, CAPTURE_SIZE)
	if override_values.get("status") != "ready":
		return override_values
	var context = template.call("clone_for_worker", profile_before, true)
	if context == null or not context is Object or context == template:
		return _pending("terrain_generator_context_clone_failed")
	# The context's initial edit map is a setup-time snapshot. Clear that clone and
	# apply the current TerrainVolumeService edits below, so late edits and edit
	# removals are both represented without changing generation authority.
	context.set("initial_terrain_edits", {})
	var pinned_towns_value: Variant = context.get("pinned_town_regions")
	if not pinned_towns_value is Dictionary:
		return _pending("terrain_worker_town_snapshot_invalid")
	var pinned_towns: Dictionary = pinned_towns_value.duplicate(true)
	_make_read_only_recursive(pinned_towns)
	context.set("pinned_town_regions", pinned_towns)
	var empty_edits: Dictionary = context.get("initial_terrain_edits")
	if not empty_edits is Dictionary or not empty_edits.is_empty():
		return _pending("terrain_worker_initial_edits_not_cleared")
	empty_edits.make_read_only()
	context.set("initial_terrain_edits", empty_edits)
	var profile_values: Variant = context.get("generated_site_profiles")
	if not profile_values is Array:
		return _pending("terrain_worker_profile_snapshot_invalid")
	var detached_profiles: Array = profile_values.duplicate(true)
	_make_read_only_recursive(detached_profiles)
	context.set("generated_site_profiles", detached_profiles)
	if not _detached_context_is_safe(context) \
			or not _worker_context_owns_resources(context, template) \
			or _profiles_digest(context.get("generated_site_profiles")) \
				!= _profiles_digest(profile_before.get("profiles", [])):
		return _pending("terrain_worker_context_not_detached")
	var profile_snapshot := profile_before.duplicate(false)
	profile_snapshot.make_read_only()
	override_values.make_read_only()
	revision_rows.make_read_only()
	var prepared := {
		"schema":"authoritative-terrain-section-input/v1",
		"worldId":world_id, "sectionKey":section_key, "origin":capture_origin,
		"size":CAPTURE_SIZE, "seed":seed_text, "seedHash":seed_hash,
		"generatorInstanceId":generator.get_instance_id(),
		"volumeInstanceId":volume.get_instance_id(),
		"context":context, "profileRevision":int(profile_before.revision),
		"profileDigest":String(profile_before.digest),
		"profileSnapshot":profile_snapshot,
		"sectionRevisions":revision_rows,
		"editOverlay":override_values,
		"mesherMaterialRevision":mesher_material_revision,
		"fluidProof":fluid_proof
	}
	prepared.make_read_only()
	return {"status":"ready", "prepared":prepared}


## Metadata-only source revision used by the terrain census. It is computed from
## the exact authorities that `prepare` later seals and does not require a
## resident Voxel Tools mesh block.
static func current_source_revision(generator: Object, volume: Object,
		section_key: Vector3i, world_id: String, mesher_material_revision: String,
		fluid_proof: Dictionary) -> Dictionary:
	if generator == null or not is_instance_valid(generator) \
			or volume == null or not is_instance_valid(volume):
		return _pending("terrain_authority_source_unavailable")
	if world_id.is_empty() or mesher_material_revision.is_empty() \
			or not _fluid_proof_is_valid(fluid_proof, section_key):
		return _pending("terrain_authority_revision_identity_incomplete")
	var template: Variant = generator.get("context_template")
	if template == null or not template is Object:
		return _pending("terrain_generator_context_unavailable")
	var profile := _profile_revision(template)
	var origin := section_key * SECTION_SIZE - HALO_MIN
	var revisions := _section_revision_rows(volume, origin, CAPTURE_SIZE)
	if profile.get("status") != "ready" or revisions.get("status") != "ready":
		return _pending("terrain_authoritative_source_revision_pending")
	var revision := _source_revision(world_id, section_key,
		String(template.get("seed_text")), int(template.get("seed_hash")),
		profile, revisions, mesher_material_revision, fluid_proof)
	return {"status":"ready", "sourceRevision":revision,
		"profileRevision":int(profile.revision), "profileDigest":String(profile.digest),
		"sectionRevisionDigest":String(revisions.digest)}


## A prepared worker input can be cancelled before its queued task begins or
## rejected after an edit/profile/owner change. This check is intentionally
## cheap and does not recreate the detached worker context.
static func prepared_is_current(prepared: Dictionary, generator: Object,
		volume: Object, world_id: String, mesher_material_revision: String,
		fluid_proof: Dictionary) -> bool:
	if not prepared.is_read_only() \
			or String(prepared.get("schema", "")) != "authoritative-terrain-section-input/v1" \
			or generator == null or not is_instance_valid(generator) \
			or volume == null or not is_instance_valid(volume) \
			or generator.get_instance_id() != int(prepared.get("generatorInstanceId", 0)) \
			or volume.get_instance_id() != int(prepared.get("volumeInstanceId", 0)) \
			or world_id != String(prepared.get("worldId", "")) \
			or mesher_material_revision != String(prepared.get("mesherMaterialRevision", "")):
		return false
	var section_value: Variant = prepared.get("sectionKey")
	var origin_value: Variant = prepared.get("origin")
	if not section_value is Vector3i or not origin_value is Vector3i:
		return false
	var template: Variant = generator.get("context_template")
	if template == null or not template is Object \
			or String(template.get("seed_text")) != String(prepared.get("seed", "")) \
			or int(template.get("seed_hash")) != int(prepared.get("seedHash", -1)):
		return false
	var profile := _profile_revision(template)
	var revisions := _section_revision_rows(volume, origin_value, CAPTURE_SIZE)
	var overrides := _capture_override_values(volume, origin_value, CAPTURE_SIZE)
	return profile.get("status") == "ready" \
		and int(profile.get("revision", -1)) == int(prepared.get("profileRevision", -2)) \
		and String(profile.get("digest", "")) == String(prepared.get("profileDigest", "")) \
		and revisions.get("status") == "ready" \
		and String(revisions.get("digest", "")) == String(prepared.get("sectionRevisions", {}).get("digest", "")) \
		and overrides.get("status") == "ready" \
		and String(overrides.get("digest", "")) == String(prepared.get("editOverlay", {}).get("digest", "")) \
		and _fluid_proof_is_valid(fluid_proof, section_value) \
		and String(fluid_proof.get("signature", "")) == String(prepared.get("fluidProof", {}).get("signature", "")) \
		and int(fluid_proof.get("volumeRevision", -1)) == int(prepared.get("fluidProof", {}).get("volumeRevision", -2)) \
		and int(fluid_proof.get("fluidRevision", -1)) == int(prepared.get("fluidProof", {}).get("fluidRevision", -2)) \
		and bool(fluid_proof.get("hasFluid", false)) == bool(prepared.get("fluidProof", {}).get("hasFluid", true))


## Worker-only operation. No live Node, volume service, or renderer is read here.
static func generate_prepared(prepared: Dictionary,
		cancellation: CancellationToken = null) -> Dictionary:
	if not prepared.is_read_only() \
			or String(prepared.get("schema", "")) != "authoritative-terrain-section-input/v1":
		return _failed("terrain_prepared_input_identity_invalid")
	if is_instance_valid(cancellation) and cancellation.is_cancelled():
		return {"status":"cancelled", "reason":"terrain_section_generation_cancelled"}
	var context: Variant = prepared.get("context", null)
	var origin_value: Variant = prepared.get("origin", null)
	var section_value: Variant = prepared.get("sectionKey", null)
	var edit_overlay: Variant = prepared.get("editOverlay", null)
	if context == null or not context is Object or not _detached_context_is_safe(context) \
			or not origin_value is Vector3i \
			or not section_value is Vector3i or not edit_overlay is Dictionary:
		return _failed("terrain_prepared_input_shape_invalid")
	var worker = GENERATOR_SCRIPT.new()
	worker.setup(context)
	var buffer := _new_buffer(CAPTURE_SIZE)
	var started_usec := Time.get_ticks_usec()
	if is_instance_valid(cancellation):
		cancellation.set_generation_active(true)
	worker._generate_block(buffer, origin_value, 0)
	if is_instance_valid(cancellation):
		cancellation.set_generation_active(false)
	var generated_usec := Time.get_ticks_usec() - started_usec
	# VoxelTerrainGenerator currently exposes one whole-block operation. A newer
	# section can supersede this task while that native/GDScript call is running;
	# discard its result at the next safe boundary instead of sealing stale work.
	if is_instance_valid(cancellation) and cancellation.is_cancelled():
		return {"status":"cancelled", "reason":"terrain_section_generation_cancelled",
			"generationUsec":generated_usec}
	var override_result := _apply_overrides(buffer, edit_overlay.values,
		origin_value)
	if override_result.get("status") != "ready":
		return override_result
	var sdf_bytes: PackedByteArray = buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF)
	var indices_bytes: PackedByteArray = buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_INDICES)
	var data5_bytes: PackedByteArray = buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_DATA5)
	var voxel_count := CAPTURE_SIZE.x * CAPTURE_SIZE.y * CAPTURE_SIZE.z
	if sdf_bytes.size() != voxel_count * 2 or indices_bytes.size() != voxel_count \
			or data5_bytes.size() != voxel_count:
		return _failed("terrain_authority_channel_size_mismatch", {
			"sdfBytes":sdf_bytes.size(), "indicesBytes":indices_bytes.size(),
			"data5Bytes":data5_bytes.size(), "voxelCount":voxel_count})
	var result := {"schema":"authoritative-terrain-section-generated/v1",
		# Strings make the asynchronous payload immutable; PackedByteArray aliases
		# can be modified through another GDScript reference.
		"sdf16LeBase64":Marshalls.raw_to_base64(sdf_bytes),
		"indices8Base64":Marshalls.raw_to_base64(indices_bytes),
		"data5_8Base64":Marshalls.raw_to_base64(data5_bytes),
		"payloadDigest":_payload_digest(sdf_bytes, indices_bytes, data5_bytes),
		"generationUsec":generated_usec, "sampleCount":voxel_count}
	result.make_read_only()
	return {"status":"ready", "generated":result}


static func _detached_context_is_safe(context: Object) -> bool:
	if context.get("generator_ref") != null \
			or context.get("generated_site_profile_store") != null:
		return false
	var town_cache: Variant = context.get("town_region_cache")
	var slope_cache: Variant = context.get("town_slope_apron_cache")
	var pinned: Variant = context.get("pinned_town_regions")
	var initial_edits: Variant = context.get("initial_terrain_edits")
	var profiles: Variant = context.get("generated_site_profiles")
	if not town_cache is Dictionary or not (town_cache as Dictionary).is_empty() \
			or not slope_cache is Dictionary or not (slope_cache as Dictionary).is_empty() \
			or not pinned is Dictionary or not (pinned as Dictionary).is_read_only() \
			or not initial_edits is Dictionary or not (initial_edits as Dictionary).is_read_only() \
			or not (initial_edits as Dictionary).is_empty() \
			or not profiles is Array or not (profiles as Array).is_read_only():
		return false
	for profile_value: Variant in profiles:
		if not profile_value is Dictionary or not (profile_value as Dictionary).is_read_only():
			return false
		for field in ["supportMask", "distanceCells", "groundRootPoints"]:
			var rows: Variant = profile_value.get(field, null)
			if not rows is Array or not (rows as Array).is_read_only():
				return false
	return true


## Section workers may retain Godot Resource objects inside their private
## context, but none may alias the live generator's mutable Resource graph.
## After dispatch, the owner only reads source revisions; it never accesses or
## mutates this worker context. The worker is its sole caller until join.
static func _worker_context_owns_resources(context: Object,
		template: Object) -> bool:
	for property_name in ["height_noise", "ridge_noise", "flat_noise",
			"moisture_noise", "temp_noise"]:
		var worker_noise: Variant = context.get(property_name)
		var source_noise: Variant = template.get(property_name)
		if not worker_noise is FastNoiseLite or worker_noise == source_noise:
			return false
	var worker_cave: Variant = context.get("cave_field")
	var source_cave: Variant = template.get("cave_field")
	return worker_cave != null and worker_cave != source_cave


## Main-owner operation. Rejects changed identities/revisions before sealing the
## worker payload as a candidate input.
static func seal(prepared: Dictionary, generated_result: Dictionary,
		generator: Object, volume: Object, world_id: String,
		mesher_material_revision: String, fluid_proof: Dictionary) -> Dictionary:
	if String(prepared.get("schema", "")) != "authoritative-terrain-section-input/v1" \
			or generated_result.get("status") != "ready":
		return _pending("terrain_authoritative_section_worker_result_unavailable")
	var generated: Dictionary = generated_result.get("generated", {})
	if not generated.is_read_only() \
			or String(generated.get("schema", "")) != "authoritative-terrain-section-generated/v1":
		return _failed("terrain_authoritative_section_worker_result_invalid")
	var section_key: Vector3i = prepared.sectionKey
	var capture_origin: Vector3i = prepared.origin
	var seed_text := String(prepared.seed)
	var seed_hash := int(prepared.seedHash)
	var profile_before: Dictionary = prepared.profileSnapshot
	var revision_rows: Dictionary = prepared.sectionRevisions
	var override_values: Dictionary = prepared.editOverlay
	if generator == null or not is_instance_valid(generator) or volume == null \
			or not is_instance_valid(volume) \
			or generator.get_instance_id() != int(prepared.generatorInstanceId) \
			or volume.get_instance_id() != int(prepared.volumeInstanceId) \
			or world_id != String(prepared.worldId) \
			or mesher_material_revision != String(prepared.mesherMaterialRevision):
		return _pending("terrain_authoritative_section_owner_replaced")
	var template: Variant = generator.get("context_template")
	if template == null or not template is Object \
			or String(template.get("seed_text")) != seed_text \
			or int(template.get("seed_hash")) != seed_hash:
		return _pending("terrain_authoritative_section_generator_changed")
	var profile_after := _profile_revision(template)
	var after_revisions := _section_revision_rows(volume, capture_origin, CAPTURE_SIZE)
	var after_overrides := _capture_override_values(volume, capture_origin, CAPTURE_SIZE)
	if profile_after.get("status") != "ready" \
			or profile_after.get("revision") != profile_before.get("revision") \
			or profile_after.get("digest") != profile_before.get("digest") \
			or after_revisions.get("status") != "ready" \
			or after_revisions.get("digest") != revision_rows.get("digest") \
			or after_overrides.get("status") != "ready" \
			or after_overrides.get("digest") != override_values.get("digest") \
			or not _fluid_proof_is_valid(fluid_proof, section_key) \
			or String(fluid_proof.get("signature", "")) != String(prepared.fluidProof.get("signature", "")) \
			or int(fluid_proof.get("volumeRevision", -1)) != int(prepared.fluidProof.get("volumeRevision", -2)) \
			or int(fluid_proof.get("fluidRevision", -1)) != int(prepared.fluidProof.get("fluidRevision", -2)) \
			or bool(fluid_proof.get("hasFluid", false)) != bool(prepared.fluidProof.get("hasFluid", true)):
		return _pending("terrain_authority_changed_during_capture")
	var sdf_bytes := Marshalls.base64_to_raw(String(generated.get("sdf16LeBase64", "")))
	var indices_bytes := Marshalls.base64_to_raw(String(generated.get("indices8Base64", "")))
	var data5_bytes := Marshalls.base64_to_raw(String(generated.get("data5_8Base64", "")))
	if sdf_bytes.size() != CAPTURE_SIZE.x * CAPTURE_SIZE.y * CAPTURE_SIZE.z * 2 \
			or indices_bytes.size() != CAPTURE_SIZE.x * CAPTURE_SIZE.y * CAPTURE_SIZE.z \
			or data5_bytes.size() != CAPTURE_SIZE.x * CAPTURE_SIZE.y * CAPTURE_SIZE.z \
			or _payload_digest(sdf_bytes, indices_bytes, data5_bytes) \
				!= String(generated.get("payloadDigest", "")):
		return _failed("terrain_authoritative_section_payload_digest_invalid")
	var payload_digest := String(generated.payloadDigest)
	var source_revision := _source_revision(world_id, section_key, seed_text,
		seed_hash, profile_before, revision_rows, mesher_material_revision, fluid_proof)
	var result := {
		"schema":"authoritative-terrain-section/v1",
		"status":"ready",
		"worldId":world_id,
		"sectionKey":section_key,
		"block":section_key,
		"origin":capture_origin,
		"size":CAPTURE_SIZE,
		"seed":seed_text,
		"seedHash":seed_hash,
		"generatorInstanceId":generator.get_instance_id(),
		"volumeInstanceId":volume.get_instance_id(),
		"sourceIdentity":"authoritative-terrain:%d" % generator.get_instance_id(),
		"generatorSchema":"voxel-terrain-generator:sdf-material/v1",
		"profileRevision":int(profile_before.revision),
		"profileDigest":String(profile_before.digest),
		"mesherMaterialRevision":mesher_material_revision,
		"mesherSchema":"transvoxel-section-16-halo-min1-max2/v1",
		"sectionRevisions":revision_rows.rows,
		"sectionRevisionDigest":String(revision_rows.digest),
		"editOverlayDigest":String(override_values.digest),
		"editOverlayCount":int(override_values.count),
		"fluidProofSignature":String(fluid_proof.signature),
		"fluidVolumeRevision":int(fluid_proof.volumeRevision),
		"fluidRevision":int(fluid_proof.fluidRevision),
		"hasFluid":bool(fluid_proof.hasFluid),
		"sdf16LeBase64":String(generated.sdf16LeBase64),
		"indices8Base64":String(generated.indices8Base64),
		"data5_8Base64":String(generated.data5_8Base64),
		"payloadDigest":payload_digest,
		"sourceRevision":source_revision,
		"sampleCount":int(generated.sampleCount),
		"generationUsec":int(generated.generationUsec),
		"captureIsTerrainOnly":true,
		"collisionAuthority":"VoxelTerrainRuntime"
	}
	result.make_read_only()
	return {"status":"ready", "capture":result}


static func is_current(capture: Dictionary, generator: Object, volume: Object,
		world_id: String, mesher_material_revision: String,
		fluid_proof: Dictionary) -> bool:
	if not capture.is_read_only() \
			or String(capture.get("schema", "")) != "authoritative-terrain-section/v1" \
			or String(capture.get("worldId", "")) != world_id \
			or String(capture.get("mesherMaterialRevision", "")) != mesher_material_revision \
			or generator == null or not is_instance_valid(generator) \
			or volume == null or not is_instance_valid(volume) \
			or int(capture.get("generatorInstanceId", 0)) != generator.get_instance_id() \
			or int(capture.get("volumeInstanceId", 0)) != volume.get_instance_id():
		return false
	var section_value: Variant = capture.get("sectionKey")
	if not section_value is Vector3i:
		return false
	var section_key: Vector3i = section_value
	if not _fluid_proof_is_valid(fluid_proof, section_key) \
			or String(capture.get("fluidProofSignature", "")) != String(fluid_proof.signature) \
			or int(capture.get("fluidVolumeRevision", -1)) != int(fluid_proof.volumeRevision) \
			or int(capture.get("fluidRevision", -1)) != int(fluid_proof.fluidRevision) \
			or bool(capture.get("hasFluid", false)) != bool(fluid_proof.hasFluid):
		return false
	var template: Variant = generator.get("context_template")
	if template == null or not template is Object:
		return false
	if String(template.get("seed_text")) != String(capture.get("seed", "")) \
			or int(template.get("seed_hash")) != int(capture.get("seedHash", -1)) \
			or String(capture.get("generatorSchema", "")) \
				!= "voxel-terrain-generator:sdf-material/v1" \
			or String(capture.get("mesherSchema", "")) \
				!= "transvoxel-section-16-halo-min1-max2/v1":
		return false
	var profile := _profile_revision(template)
	if profile.get("status") != "ready" \
			or int(capture.get("profileRevision", -1)) != int(profile.revision) \
			or String(capture.get("profileDigest", "")) != String(profile.digest):
		return false
	var origin_value: Variant = capture.get("origin")
	var size_value: Variant = capture.get("size")
	if not origin_value is Vector3i or size_value != CAPTURE_SIZE \
			or origin_value != section_key * SECTION_SIZE - HALO_MIN:
		return false
	var revisions := _section_revision_rows(volume, origin_value, CAPTURE_SIZE)
	var overrides := _capture_override_values(volume, origin_value, CAPTURE_SIZE)
	if revisions.get("status") != "ready" or overrides.get("status") != "ready" \
			or String(revisions.digest) != String(capture.get("sectionRevisionDigest", "")) \
			or String(overrides.digest) != String(capture.get("editOverlayDigest", "")):
		return false
	var sdf_value := Marshalls.base64_to_raw(String(capture.get("sdf16LeBase64", "")))
	var indices_value := Marshalls.base64_to_raw(String(capture.get("indices8Base64", "")))
	var data5_value := Marshalls.base64_to_raw(String(capture.get("data5_8Base64", "")))
	if sdf_value.size() != CAPTURE_SIZE.x * CAPTURE_SIZE.y * CAPTURE_SIZE.z * 2 \
			or indices_value.size() != CAPTURE_SIZE.x * CAPTURE_SIZE.y * CAPTURE_SIZE.z \
			or data5_value.size() != CAPTURE_SIZE.x * CAPTURE_SIZE.y * CAPTURE_SIZE.z \
			or _payload_digest(sdf_value, indices_value, data5_value) \
				!= String(capture.get("payloadDigest", "")):
		return false
	var expected_source_revision := _source_revision(world_id, section_key,
		String(capture.get("seed", "")), int(capture.get("seedHash", -1)),
		profile, revisions, mesher_material_revision, fluid_proof)
	return String(capture.get("sourceRevision", "")) == expected_source_revision \
		and int(capture.get("editOverlayCount", -1)) == int(overrides.count)


static func _new_buffer(size: Vector3i) -> VoxelBuffer:
	var buffer := VoxelBuffer.new()
	buffer.create(size.x, size.y, size.z)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	return buffer


static func _apply_overrides(buffer: VoxelBuffer, rows: Array, origin: Vector3i) -> Dictionary:
	for row_value in rows:
		if not row_value is Dictionary:
			return _failed("terrain_override_row_invalid")
		var row: Dictionary = row_value
		if not bool(row.get("affectsTerrainMesh", false)):
			continue
		var cell_value: Variant = row.get("cell")
		var state_value: Variant = row.get("state")
		if not cell_value is Vector3i or not state_value is Dictionary:
			return _failed("terrain_override_state_missing")
		var state: Dictionary = state_value
		var density_value: Variant = state.get("density", null)
		var material := String(state.get("material", ""))
		if not density_value is float and not density_value is int:
			return _failed("terrain_override_density_missing", {"cell":cell_value})
		if not is_finite(float(density_value)) or not GENERATOR_SCRIPT.MATERIAL_IDS.has(material):
			return _failed("terrain_override_material_or_density_invalid", {"cell":cell_value,
				"material":material})
		var local: Vector3i = cell_value - origin
		if local.x < 0 or local.y < 0 or local.z < 0 \
				or local.x >= buffer.get_size().x or local.y >= buffer.get_size().y \
				or local.z >= buffer.get_size().z:
			return _failed("terrain_override_outside_capture_bounds", {"cell":cell_value})
		var material_id := int(GENERATOR_SCRIPT.MATERIAL_IDS[material])
		buffer.set_voxel_f(-float(density_value) / CELL, local.x, local.y, local.z,
			VoxelBuffer.CHANNEL_SDF)
		buffer.set_voxel(material_id, local.x, local.y, local.z, VoxelBuffer.CHANNEL_INDICES)
		buffer.set_voxel(material_id, local.x, local.y, local.z, VoxelBuffer.CHANNEL_DATA5)
	return {"status":"ready"}


static func _capture_override_values(volume: Object, origin: Vector3i,
		size: Vector3i) -> Dictionary:
	var edited_value: Variant = volume.get("edited_cells")
	var overlays_value: Variant = volume.get("scene_block_cells")
	if not edited_value is Dictionary or not overlays_value is Dictionary \
			or not volume.has_method("cell_state_affects_terrain_mesh"):
		return _pending("terrain_edit_overlay_authority_unavailable")
	var bounds_max := origin + size - Vector3i.ONE
	var rows: Array = []
	var count := 0
	var cells: Dictionary = {}
	for cell_value: Variant in edited_value:
		if cell_value is Vector3i and _cell_in_bounds(cell_value, origin, bounds_max):
			cells[cell_value] = true
	for cell_value: Variant in overlays_value:
		if cell_value is Vector3i and _cell_in_bounds(cell_value, origin, bounds_max):
			cells[cell_value] = true
	var ordered_cells: Array[Vector3i] = []
	for cell_value: Variant in cells:
		ordered_cells.append(cell_value)
	ordered_cells.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	for cell: Vector3i in ordered_cells:
		if edited_value.has(cell):
			var edited_value_row: Variant = edited_value.get(cell)
			if not edited_value_row is Dictionary or edited_value_row.is_empty():
				return _failed("terrain_edit_state_invalid", {"cell":cell})
			var edited: Dictionary = edited_value_row
			var edited_mesh_affects := bool(volume.call("cell_state_affects_terrain_mesh", edited))
			rows.append(_override_row("edit", cell, edited, edited_mesh_affects))
			count += 1
		if overlays_value.has(cell):
			var overlay_value: Variant = overlays_value.get(cell)
			if not overlay_value is Dictionary or overlay_value.is_empty():
				return _failed("terrain_scene_overlay_state_invalid", {"cell":cell})
			var overlay: Dictionary = overlay_value
			var overlay_mesh_affects := bool(volume.call("cell_state_affects_terrain_mesh", overlay))
			rows.append(_override_row("scene_overlay", cell, overlay, overlay_mesh_affects))
			count += 1
	var digest := Marshalls.raw_to_base64(var_to_bytes([
		"terrain-edit-overlay-capture/v1", origin, size, rows])).sha256_text()
	for row_value: Variant in rows:
		_make_read_only_recursive(row_value)
	rows.make_read_only()
	var result := {"status":"ready", "values":rows, "count":count, "digest":digest}
	result.make_read_only()
	return result


static func _cell_in_bounds(cell: Vector3i, minimum: Vector3i, maximum: Vector3i) -> bool:
	return cell.x >= minimum.x and cell.x <= maximum.x \
		and cell.y >= minimum.y and cell.y <= maximum.y \
		and cell.z >= minimum.z and cell.z <= maximum.z


static func _override_row(kind: String, cell: Vector3i, state: Dictionary,
		affects_terrain_mesh: bool) -> Dictionary:
	var row := {"kind":kind, "cell":cell, "affectsTerrainMesh":affects_terrain_mesh,
		"density":state.get("density", null), "material":String(state.get("material", "")),
		"solid":bool(state.get("solid", false)), "fluid":String(state.get("fluid", "")),
		"source":String(state.get("metadata", {}).get("source", "")) \
			if state.get("metadata", {}) is Dictionary else "",
		"terrainMeshAffects":bool(state.get("metadata", {}).get("terrainMeshAffects", false)) \
			if state.get("metadata", {}) is Dictionary else false,
		"renderedBySceneBlock":bool(state.get("metadata", {}).get("renderedBySceneBlock", false)) \
			if state.get("metadata", {}) is Dictionary else false,
		"state":state.duplicate(true)}
	_make_read_only_recursive(row.state)
	row.make_read_only()
	return row


static func _make_read_only_recursive(value: Variant) -> void:
	if value is Dictionary:
		for nested_value: Variant in value.values():
			_make_read_only_recursive(nested_value)
		(value as Dictionary).make_read_only()
	elif value is Array:
		for nested_value: Variant in value:
			_make_read_only_recursive(nested_value)
		(value as Array).make_read_only()


static func _section_revision_rows(volume: Object, origin: Vector3i,
		size: Vector3i) -> Dictionary:
	var values: Variant = volume.get("section_revisions")
	var overlay_values: Variant = volume.get("scene_overlay_section_revisions")
	if not values is Dictionary or not overlay_values is Dictionary:
		return _pending("terrain_neighbor_revision_authority_unavailable")
	var end := origin + size - Vector3i.ONE
	var min_section := Vector3i(floori(float(origin.x) / SECTION_SIZE),
		floori(float(origin.y) / SECTION_SIZE), floori(float(origin.z) / SECTION_SIZE))
	var max_section := Vector3i(floori(float(end.x) / SECTION_SIZE),
		floori(float(end.y) / SECTION_SIZE), floori(float(end.z) / SECTION_SIZE))
	var rows: Array[Dictionary] = []
	for y in range(min_section.y, max_section.y + 1):
		for z in range(min_section.z, max_section.z + 1):
			for x in range(min_section.x, max_section.x + 1):
				var key := Vector3i(x, y, z)
				var row := {"sectionKey":key, "revision":int(values.get(key, 0)),
					"sceneOverlayRevision":int(overlay_values.get(key, 0))}
				row.make_read_only()
				rows.append(row)
	rows.make_read_only()
	var digest := Marshalls.raw_to_base64(var_to_bytes([
		"terrain-section-revisions/v1", origin, size, rows])).sha256_text()
	return {"status":"ready", "rows":rows, "digest":digest}


static func _profile_revision(context: Object) -> Dictionary:
	var store: Variant = context.get("generated_site_profile_store")
	if store != null:
		if not store is Object or not store.has_method("snapshot_with_revision"):
			return _pending("terrain_profile_revision_authority_invalid")
		var snapshot: Variant = store.call("snapshot_with_revision")
		if not snapshot is Dictionary or not snapshot.get("profiles") is Array \
				or not snapshot.get("revision") is int:
			return _pending("terrain_profile_snapshot_invalid")
		var profile_hash := _profiles_digest(snapshot.profiles as Array)
		var digest := "%s:%d:%s" % [String(store.call("world_seed")
			if store.has_method("world_seed") else ""), int(snapshot.revision), profile_hash]
		return {"status":"ready", "revision":int(snapshot.revision),
			"digest":digest, "profiles":snapshot.profiles}
	var profiles: Variant = context.get("generated_site_profiles")
	if not profiles is Array:
		return _pending("terrain_profile_snapshot_unavailable")
	return {"status":"ready", "revision":0,
		"digest":"%s:0:%s" % [String(context.get("seed_text")), _profiles_digest(profiles)],
		"profiles":profiles}


static func _profiles_digest(profiles: Array) -> String:
	return Marshalls.raw_to_base64(var_to_bytes(profiles)).sha256_text()


static func _fluid_proof_is_valid(proof: Dictionary, section_key: Vector3i) -> bool:
	return proof.is_read_only() \
		and String(proof.get("schema", "")) == "terrain-fluid-section-proof/v2" \
		and proof.get("sectionKey") == section_key \
		and proof.get("hasFluid") is bool \
		and int(proof.get("volumeRevision", -1)) >= 0 \
		and int(proof.get("fluidRevision", -1)) >= 0 \
		and not String(proof.get("signature", "")).is_empty()


static func _payload_digest(sdf: PackedByteArray, indices: PackedByteArray,
		data5: PackedByteArray) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(sdf)
	hasher.update(indices)
	hasher.update(data5)
	return hasher.finish().hex_encode()


static func _source_revision(world_id: String, section_key: Vector3i,
		seed_text: String, seed_hash: int, profile: Dictionary,
		revisions: Dictionary, mesher_revision: String,
		fluid_proof: Dictionary) -> String:
	return Marshalls.raw_to_base64(var_to_bytes([
		"authoritative-terrain-source/v1", world_id, section_key, seed_text,
		seed_hash, int(profile.revision), String(profile.digest),
		String(revisions.digest), mesher_revision,
		String(fluid_proof.signature), int(fluid_proof.volumeRevision),
		int(fluid_proof.fluidRevision), bool(fluid_proof.hasFluid),
		"transvoxel-section-16-halo-min1-max2/v1"
	])).sha256_text()


static func _pending(reason: String) -> Dictionary:
	return {"status":"pending", "reason":reason, "retryable":true}


static func _failed(reason: String, detail := {}) -> Dictionary:
	return {"status":"failed", "reason":reason, "detail":detail}
