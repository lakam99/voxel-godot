extends SceneTree

## Source/service-only impossibility certificate, not gameplay acceptance.
## Reads a SHA-bound post-shop snapshot and completed-build failure report.
## It relaxes socket Y/Z and rootedness ONLY in its mathematical exclusion
## domain: if one rigid board hits a blocker throughout that larger domain,
## every legal finite/rooted socket is excluded too. No recipe is applied.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Signs = preload("res://scripts/buildings/HouseholdSignMountRecipe.gd")
const Heads = preload("res://scripts/buildings/OpeningHeadConnectionRecipe.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const MAX_BYTES := 32 * 1024 * 1024
const PROOF_GUARD := 0.00001
var checks := {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var started := Time.get_ticks_usec()
	var input := OS.get_environment("VOXEL_SIGN_BOUNDS_INPUT")
	var failure_path := OS.get_environment("VOXEL_SIGN_BOUNDS_FAILURE")
	var launch_path := OS.get_environment("VOXEL_SIGN_BOUNDS_LAUNCH")
	var output := OS.get_environment("VOXEL_SIGN_BOUNDS_REPORT")
	var input_sha := OS.get_environment("VOXEL_SIGN_BOUNDS_INPUT_SHA").to_lower()
	var failure_sha := OS.get_environment("VOXEL_SIGN_BOUNDS_FAILURE_SHA").to_lower()
	var launch_sha := OS.get_environment("VOXEL_SIGN_BOUNDS_LAUNCH_SHA").to_lower()
	var recipe_sha := OS.get_environment("VOXEL_SIGN_BOUNDS_RECIPE_SHA").to_lower()
	var arm_id := OS.get_environment("VOXEL_SIGN_BOUNDS_ARM")
	var blocker_id := OS.get_environment("VOXEL_SIGN_BOUNDS_BLOCKER")
	if not _bound(input, input_sha) or not _bound(failure_path, failure_sha) or not _bound(launch_path, launch_sha) or not _fresh(output) or recipe_sha.length() != 64:
		quit(2); return
	var file := FileAccess.open(input, FileAccess.READ)
	var raw: Variant = file.get_var(false)
	file.close()
	var failure: Variant = JSON.parse_string(FileAccess.get_file_as_string(failure_path))
	var launch: Variant = JSON.parse_string(FileAccess.get_file_as_string(launch_path))
	if not raw is Dictionary or not raw.get("blueprint") is Dictionary or not failure is Dictionary or not launch is Dictionary:
		quit(2); return
	var authorities := {}
	for name: String in ["BuildingPart", "BuildingBlueprint", "HouseholdSignMountRecipe", "OpeningHeadConnectionRecipe", "OpeningHeadBandRecipe", "LowerFacadeBearingRecipe", "CitadelStructuralCompletionRecipe"]:
		var path := "res://scripts/buildings/" + name + ".gd"
		authorities[path] = FileAccess.get_sha256(path)
	checks["geometry_authorities_match_completed_failure_run"] = authorities.keys().all(func(path): return authorities[path] == launch.get("dependencies", {}).get(path))
	var b = Copy.copy_blueprint(raw.blueprint)
	var frozen := var_to_bytes(b.snapshot())
	var arm = b.find_part(arm_id)
	var board = b.find_part(arm_id.trim_suffix("_sign_arm") + "_hanging_sign")
	var blocker = b.find_part(blocker_id)
	if arm == null or board == null or blocker == null: quit(2); return
	var prefix := arm_id.trim_suffix("_sign_arm")
	var owner: Dictionary = b.recipe.get("citadelStreetHouseStructuralRecipes", {}).get(prefix, {})
	if owner.is_empty(): quit(2); return
	var completed: Dictionary = failure.get("sourceFailure", {}).get("structuralCompletionFailure", {})
	var stages: Array = completed.get("stages", []).filter(func(s): return s.get("kind") == "sign")
	if stages.size() != 1: quit(2); return
	var pending: Array = stages[0].get("pending", []).filter(func(p): return p.get("id") == arm_id)
	if pending.size() != 1: quit(2); return
	var candidates: Array = pending[0].get("detail", {}).get("candidates", [])
	if candidates.is_empty() or candidates.size() > Signs.MAX_FACADES: quit(2); return
	checks["original_recipe_unchanged"] = FileAccess.get_sha256("res://scripts/buildings/HouseholdSignMountRecipe.gd") == recipe_sha
	checks["actual_source_run_failed_with_stable_dependencies"] = failure.get("sourcesStable", false) and not failure.get("passed", true)
	checks["axis_aligned_rigid_assembly_and_solid_blocker"] = arm.rotation == Vector3.ZERO and board.rotation == Vector3.ZERO and blocker.rotation == Vector3.ZERO and blocker.collision_enabled and arm.semantic == "citadel_household_sign" and board.semantic == arm.semantic and not arm.collision_enabled and not board.collision_enabled
	var failures: Array = completed.get("physicalFailureEvidence", {}).get("failures", []).filter(func(f): return f.get("partId") == arm_id)
	checks["final_report_arm_pose_matches_snapshot"] = failures.size() == 1 and failures[0].part.records.size() == 1 and failures[0].part.records[0].position == str(arm.position) and failures[0].part.records[0].size == str(arm.size) and failures[0].part.records[0].rotation == str(arm.rotation)
	var panel_ids: Array = []
	for key: String in owner.facadeDeclarationKeys:
		panel_ids.append_array(b.recipe.facadeApertures[key].partIds)
	var panels: Array = panel_ids.map(func(id): return b.find_part(id))
	if panels.is_empty() or panels.has(null): quit(2); return
	var plane = panels[0]
	checks["all_declared_panels_share_exact_x_plane"] = panels.all(func(p): return p.rotation == Vector3.ZERO and p.position.x == plane.position.x and p.size.x == plane.size.x)
	# This calls the production pure body-fitting service, not full facade
	# completion. Only its X-plane invariant is tested; this is NOT an authored
	# or accepted reconstruction of the missing post-completion head geometry.
	var probe: Dictionary = arm.snapshot()
	probe.size = Vector3(0.30, 0.24, 1.0)
	probe.collision = true
	var fitted := Heads.fit_body(probe, plane, [])
	checks["opening_head_service_uses_same_x_plane"] = fitted.ready and fitted.body.position.x == plane.position.x and fitted.body.size.x == plane.size.x
	var side := signf(arm.position.x - plane.position.x)
	var mount_x: float = plane.position.x + side * (plane.size.x * 0.5 + arm.size.x * 0.5 - (Signs.SOCKET_HALF.x * 2.0 + Signs.SOCKET_INSET))
	var board_record: Dictionary = board.snapshot()
	board_record.position = Vector3(mount_x, arm.position.y, arm.position.z) + (board.position - arm.position)
	var relocated_board = Part.new(board_record)
	var board_bounds: AABB = b.transformed_part_bounds(relocated_board)
	var blocker_bounds: AABB = b.transformed_part_bounds(blocker)
	var certificate := exclusion(board_bounds, blocker_bounds, Signs.MAX_IN_PLANE_TRANSLATION)
	checks["entire_relaxed_square_blocked_so_entire_disk_blocked"] = certificate.proven
	var rows: Array = []
	var seen := {}
	for candidate: Dictionary in candidates:
		var id: String = candidate.get("anchorId", "")
		var owned_panel := panel_ids.has(id)
		var owned_head: bool = owner.signAnchorIds.has(id)
		var over_limit: bool = candidate.get("reason") == "in_plane_translation_limit" and float(candidate.get("distance", 0.0)) > Signs.MAX_IN_PLANE_TRANSLATION
		var blocked: bool = candidate.get("reason") in ["arm_intrudes_source", "board_intrudes_source"] and candidate.get("partId") == blocker.id
		var covered: bool = not seen.has(id) and (owned_panel or owned_head) and (over_limit or blocked and certificate.proven)
		seen[id] = true
		rows.append({"anchorId": id, "reportedReason": candidate.get("reason"), "covered": covered,
			"proof": "nearest_point_already_outside_disk" if over_limit else "rigid_board_excludes_entire_relaxed_square",
			"distance": candidate.get("distance", 0.0), "headPlaneServiceOnly": owned_head and not owned_panel})
	checks["every_final_candidate_covered_without_root_or_socket_waiver"] = rows.all(func(r): return r.covered)
	# Independent service spot checks at the four corners of the SUPERSET square;
	# the interval certificate, not sampling, proves its continuous interior.
	var corners: Array = []
	for y in [-Signs.MAX_IN_PLANE_TRANSLATION, Signs.MAX_IN_PLANE_TRANSLATION]:
		for z in [-Signs.MAX_IN_PLANE_TRANSLATION, Signs.MAX_IN_PLANE_TRANSLATION]:
			var record: Dictionary = board_record.duplicate(true)
			record.position += Vector3(0, y, z)
			var part = Part.new(record)
			corners.append({"dy": y, "dz": z, "satIntersects": b.transformed_boxes_intersect(part, blocker, 0.0)})
	checks["unchanged_exact_sat_agrees_at_superset_corners"] = corners.all(func(c): return c.satIntersects)
	_controls()
	checks["no_source_mutation"] = frozen == var_to_bytes(b.snapshot()) and _bound(input, input_sha) and _bound(failure_path, failure_sha) and _bound(launch_path, launch_sha) and authorities.keys().all(func(path): return authorities[path] == FileAccess.get_sha256(path))
	var passed: bool = checks.values().all(func(c): return c == true)
	var report := {"passed": passed, "outcome": "infeasible_under_existing_sign_translation_bounds" if passed else "certificate_failed",
		"checks": checks, "inputSha256": input_sha, "failureReportSha256": failure_sha, "recipeSha256": recipe_sha,
		"launchSha256": launch_sha, "authoritySha256": authorities,
		"candidate": failure.get("candidate"), "armId": arm.id, "boardId": board.id, "blockerId": blocker.id,
		"boardAtFacadeBounds": _box(board_bounds), "blockerBounds": _box(blocker_bounds), "certificate": certificate,
		"coveredCandidates": rows, "satCornerChecks": corners, "elapsedUsec": Time.get_ticks_usec() - started,
		"sourceStage": "post_shop_before_facade; completed_source_report supplies final rejected-anchor inventory",
		"headPlaneAuthority": "OpeningHeadConnectionRecipe.fit_body sets X from facade; retained panel fitting preserves horizontal geometry. No final head geometry or rootedness reconstructed.",
		"limitations": "Source/service analytic exclusion only. No new full source build, completed post-facade snapshot, published geometry, headed playtest, gameplay, navigation or engineering acceptance. The single blocker suffices; other collision, finite socket and protected-volume constraints can only further restrict placements."}
	file = FileAccess.open(output, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	print("SIGN BOUNDS ", report.outcome, " passed=", passed, " anchors=", rows.size(), " usec=", report.elapsedUsec)
	quit(0 if passed and written else 1)

## For a translated axis-aligned board, positive overlap with the blocker
## holds iff each delta lies strictly between these Minkowski-difference
## faces. Containing [-R,R]^2 strictly proves that the radius-R disk cannot
## escape. The guard makes the certificate stricter, never collision looser.
static func exclusion(board: AABB, blocker: AABB, radius: float) -> Dictionary:
	if not _valid(board) or not _valid(blocker) or not is_finite(radius) or radius < 0.0:
		return {"proven": false, "reason": "invalid_bounds"}
	var low_y: float = blocker.position.y - board.end.y
	var high_y: float = blocker.end.y - board.position.y
	var low_z: float = blocker.position.z - board.end.z
	var high_z: float = blocker.end.z - board.position.z
	var x_overlap: float = minf(board.end.x, blocker.end.x) - maxf(board.position.x, blocker.position.x)
	var nearest: float = minf(minf(-low_y, high_y), minf(-low_z, high_z))
	return {"proven": x_overlap > PROOF_GUARD and nearest > radius + PROOF_GUARD,
		"radius": radius, "blockedDyOpenInterval": [low_y, high_y], "blockedDzOpenInterval": [low_z, high_z],
		"xOverlap": x_overlap, "minimumTranslationToAnyBoardExitFace": nearest,
		"minimumExcessOverCap": nearest - radius, "proofGuard": PROOF_GUARD}

func _controls() -> void:
	var board := AABB(Vector3(-0.1, -0.1, -0.1), Vector3(0.2, 0.2, 0.2))
	var wall := AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	checks["control_proves_contained_domain"] = exclusion(board, wall, 0.5).proven
	checks["control_does_not_claim_infeasible_if_edge_reachable"] = not exclusion(board, wall, 1.2).proven
	checks["control_touching_exit_not_certified"] = not exclusion(board, wall, 1.1).proven
	checks["control_x_separated_not_certified"] = not exclusion(AABB(Vector3(2, 0, 0), Vector3.ONE), wall, 0.5).proven
	checks["control_invalid_geometry_not_certified"] = not exclusion(AABB(), wall, 0.5).proven

static func _valid(box: AABB) -> bool:
	return box.position.is_finite() and box.size.is_finite() and box.end.is_finite() and box.size.x > 0 and box.size.y > 0 and box.size.z > 0

func _bound(path: String, sha: String) -> bool:
	if not path.is_absolute_path() or sha.length() != 64 or not FileAccess.file_exists(path): return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return false
	var length := file.get_length()
	file.close()
	return length > 0 and length <= MAX_BYTES and FileAccess.get_sha256(path) == sha

func _fresh(path: String) -> bool:
	return path.is_absolute_path() and path.get_extension() == "json" and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path) and DirAccess.dir_exists_absolute(path.get_base_dir())

func _box(box: AABB) -> Dictionary:
	return {"min": [box.position.x, box.position.y, box.position.z], "max": [box.end.x, box.end.y, box.end.z]}
