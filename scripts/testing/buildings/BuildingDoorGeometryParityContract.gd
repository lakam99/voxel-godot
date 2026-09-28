extends "res://scripts/testing/buildings/CitadelChimneyPublishedContract.gd"

## Actual CPU-publisher regression against immutable pre-extraction evidence.
## Reads the existing successful facade artifact; never regenerates its oracle.
## No movement, door-controller commands, scene acceptance or screenshots.
const DoorGeometry = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const SOURCE_SHA := "be38b8a4a2a29689c4edd68d8877aa99a634da676adf3f51353df3ffc39a6776"
const PUBLICATION_SHA := "c4807ecc63af987573b481b75a1a6ef937707fa9314867db232da6c9164bfc79"
const OLD_PUBLISHER_SHA := "859fe179d577612a03be1585e71e87deb4db7128cf8191e8a9826d12d85d3837"

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var output := OS.get_environment("VOXEL_DOOR_GEOMETRY_REPORT")
	var source_path := OS.get_environment("VOXEL_FACADE_CANDIDATE")
	var baseline_path := OS.get_environment("VOXEL_DOOR_PUBLICATION_BASELINE")
	var reference_path := OS.get_environment("VOXEL_DOOR_REFERENCE_REPORT")
	var reference_sha := OS.get_environment("VOXEL_DOOR_REFERENCE_SHA256")
	var reference: Dictionary = {}
	if not reference_path.is_empty():
		if reference_sha.length() != 64 or FileAccess.get_sha256(reference_path) != reference_sha:
			quit(2)
			return
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(reference_path))
		if not parsed is Dictionary or not parsed.get("passed", false) or parsed.get("mode") != "pre_extraction_capture" or parsed.get("currentPublisherSha256") != OLD_PUBLISHER_SHA or parsed.get("sourceSha256") != SOURCE_SHA:
			quit(2)
			return
		for row in parsed.cases: reference[row.partId] = row
	elif FileAccess.get_sha256("res://scripts/buildings/BuildingPartPublisher.gd") != OLD_PUBLISHER_SHA:
		push_error("Pre-extraction capture requires the unchanged original publisher")
		quit(2)
		return
	if not output.is_absolute_path() or output.get_extension() != "json" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()) or FileAccess.get_sha256(source_path) != SOURCE_SHA or FileAccess.get_sha256(baseline_path) != PUBLICATION_SHA:
		quit(2)
		return
	var file := FileAccess.open(source_path, FileAccess.READ)
	if file == null or file.get_length() > 33554432:
		quit(2)
		return
	var length := file.get_length()
	var encoded := file.get_buffer(length)
	var read_ok: bool = encoded.size() == length and file.get_error() == OK
	file.close()
	var archive: Variant = bytes_to_var(encoded)
	var baseline: Variant = JSON.parse_string(FileAccess.get_file_as_string(baseline_path))
	if not read_ok or not archive is Dictionary or not baseline is Dictionary or not baseline.get("diagnosticCompleted", false) or not baseline.get("allOriginalPayloadsExact", false):
		quit(2)
		return
	var b = Shops.copy_source(archive.afterSnapshot)
	var publisher = _configured_publisher(b)
	var collider := ColliderPublisher.new()
	var inventory: Dictionary = {}
	for row in baseline.payloadInventory: inventory[row.partId] = row
	var cases: Array = []
	var expected := 0
	var ordinary := 0
	for part in b.parts:
		if part.kind != "door": continue
		expected += 1
		if not _within_budget(): break
		var visual := _extract_overlap_payload(publisher, b, part, "door_parity_replay")
		var collision := _collision_payload(collider, part)
		var row := {"partId": part.id, "checks": {}}
		row["visualPayloadDigest"] = _stable_digest(visual)
		row["collisionPayloadDigest"] = _stable_digest(collision)
		row.checks["baseline_has_door"] = inventory.has(part.id)
		row.checks["complete_valid_payloads"] = _valid_payload(visual) and _valid_payload(collision)
		if inventory.has(part.id):
			# Material cache keys quantize variation; a door-only replay cannot
			# use a differently ordered whole-world material cache as its oracle.
			# Preserve this observation; compare the identical door sequence with
			# a genuine pre-extraction capture for extraction acceptance instead.
			row["wholeWorldContextVisualDigestEqual"] = row.visualPayloadDigest == inventory[part.id].visual.digest
			row.checks["exact_collision_and_interaction_shapes"] = _stable_digest(collision) == inventory[part.id].collision.digest
		if not reference_path.is_empty():
			row.checks["exact_pre_extraction_visual_payload"] = reference.has(part.id) and reference[part.id].visualPayloadDigest == row.visualPayloadDigest
			row.checks["exact_pre_extraction_collision_payload"] = reference.has(part.id) and reference[part.id].collisionPayloadDigest == row.collisionPayloadDigest
		if part.recipe.get("doorPresentation", "") != "portcullis":
			ordinary += 1
			var described := DoorGeometry.closed_primitives(part.size, b.part_transform(part))
			var unmatched: Array = visual.primitives.duplicate()
			var exact: bool = described.size() == visual.primitives.size()
			for piece in described:
				var transform: Transform3D = piece.transform * Transform3D(Basis.IDENTITY.scaled(piece.size), Vector3.ZERO)
				var match_index := -1
				for index in range(unmatched.size()):
					if unmatched[index].type == "box" and unmatched[index].transform == transform:
						match_index = index
						break
				if match_index < 0: exact = false
				else: unmatched.remove_at(match_index)
			row.checks["shared_descriptions_match_every_actual_closed_primitive"] = exact and unmatched.is_empty()
		row["passed"] = row.checks.values().all(func(value): return bool(value))
		cases.append(row)
	var unchanged: bool = FileAccess.get_sha256(source_path) == SOURCE_SHA and FileAccess.get_sha256(baseline_path) == PUBLICATION_SHA and (reference_path.is_empty() or FileAccess.get_sha256(reference_path) == reference_sha)
	var passed: bool = _within_budget() and unchanged and expected > 0 and ordinary > 0 and cases.size() == expected and (reference_path.is_empty() or reference.size() == expected) and cases.all(func(row): return bool(row.passed))
	var report := {"passed": passed, "cases": cases, "expectedDoorCount": expected, "ordinaryDoorCount": ordinary,
		"immutableSourcesUnchanged": unchanged, "sourceSha256": SOURCE_SHA, "baselinePublicationSha256": PUBLICATION_SHA,
		"preExtractionPublisherSha256": OLD_PUBLISHER_SHA, "currentPublisherSha256": FileAccess.get_sha256("res://scripts/buildings/BuildingPartPublisher.gd"),
		"mode": "pre_extraction_capture" if reference_path.is_empty() else "post_extraction_replay", "referenceReport": reference_path, "referenceSha256": reference_sha,
		"elapsedMsec": Time.get_ticks_msec() - _started_msec, "evidenceLevel": "actual_CPU_door_publication_parity_contract",
		"doesNotProve": "No open-door sweep, gameplay, navigation, visual acceptance or facade fit. Door-only pre/post parity uses identical publication order; the prior whole-world cache order can produce different material digests before any extraction. Oracle covers the fixed candidate, not arbitrary dimensions or seeds."}
	file = FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_overlap_json(report), "\t"))
	file.close()
	quit(0 if passed else 1)
