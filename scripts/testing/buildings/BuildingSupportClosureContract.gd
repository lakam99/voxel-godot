extends SceneTree
## Synthetic exact-box source proof; no live player or publisher acceptance.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Elevation = preload("res://scripts/buildings/TerminalShopElevationRecipe.gd")
var checks := {}
var public_cases: Array = []
var output_directory := ""
const ROW_IDS := ["row_jamb_left", "row_jamb_right", "row_header"]
const SOURCE_PATHS := [
	"res://scripts/buildings/TerminalShopElevationRecipe.gd",
	"res://scripts/buildings/BuildingBlueprint.gd",
	"res://scripts/buildings/BuildingPart.gd",
	"res://scripts/buildings/MarketCanopyFrameBuilder.gd",
	"res://scripts/testing/buildings/BuildingSupportClosureContract.gd"
]
func _initialize() -> void: call_deferred("run")
func fixture():
	var b = Blueprint.new("narrow-seat-wide-support",1)
	for x in [-4,0,4]:
		b.add_part({"id":"root%d"%x,"kind":"foundation","position":Vector3(x,0.5,0),"size":Vector3(4,1,4)})
	b.add_part({"id":"wide","kind":"foundation","position":Vector3(0,1.1,0),"size":Vector3(12,0.2,4)})
	b.add_part({"id":"seat","kind":"foundation","position":Vector3(0,1.3,0),"size":Vector3(2,0.2,2)})
	return b
func closure(b) -> Dictionary:
	var records := {}
	for part in b.parts:
		var bounds: AABB = b.transformed_part_bounds(part)
		records[part.id] = {"part":part,"bounds":bounds,"footprint":Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z))}
	return Elevation._support_closure(b,records,{},"seat")
func run() -> void:
	var path := OS.get_environment("VOXEL_SUPPORT_CLOSURE_REPORT")
	if path.is_empty() or FileAccess.file_exists(path): quit(2); return
	output_directory = path.get_base_dir()
	var sources_before := source_hashes()
	var started := Time.get_ticks_usec()
	var b = fixture()
	var original := var_to_bytes(b.snapshot())
	var result := closure(b)
	checks["wide_dependency_roots_included"] = result.ready and result.partIds == ["root-4","root0","root4","seat","wide"]
	checks["all_source_unchanged"] = original == var_to_bytes(b.snapshot())
	checks["every_physical_check_passes"] = result.checks.size() == 5 and result.checks.all(func(row): return row.passed)
	var again := closure(b)
	checks["exact_replay"] = var_to_bytes(result) == var_to_bytes(again)
	b.parts.reverse()
	checks["input_order_independence"] = var_to_bytes(result) == var_to_bytes(closure(b))
	b.parts = b.parts.filter(func(part): return part.id != "root-4")
	var missing := closure(b)
	checks["missing_root_fails_closed"] = not missing.ready
	var forged = fixture()
	forged.parts[3].physical_intent = "structural_root"
	checks["forged_elevated_root_fails_closed"] = not closure(forged).ready
	var disabled = fixture()
	disabled.parts[4].collision_enabled = false
	checks["noncolliding_seat_rejected"] = closure(disabled).get("reason") == "invalid_selected_support"
	var excessive = fixture()
	for index in range(Elevation.MAX_SUPPORT_CONTEXT):
		excessive.add_part({"id":"extra%d"%index,"kind":"foundation","position":Vector3(4,0.5,0),"size":Vector3(0.1,1,0.1)})
	checks["unchanged_context_cap_enforced"] = closure(excessive).get("reason") == "support_context_limit"
	var original_nine := checks.duplicate(true)
	public_contracts()
	checks["original_nine_checks_retained"] = original_nine.size() == 9 and not original_nine.values().has(false)
	var sources_after := source_hashes()
	checks["sources_unchanged_during_run"] = sources_before == sources_after
	var passed := not checks.values().has(false)
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed":passed,"complete":true,"checks":checks,"originalNineChecks":original_nine,"evidenceLevel":"synthetic_actual_box_support_proof_not_gameplay","supportClosure":result,"publicCases":public_cases,"sourceSha256Before":sources_before,"sourceSha256After":sources_after,"elapsedUsec":Time.get_ticks_usec()-started,"doesNotProve":["Synthetic complete three-piece pre-frame row, not the actual generated terminal-shop producer or real candidate.","No frame joint assembly, renderer, physics, navigation, live publication, gameplay, or full Source/Site acceptance.","Support proof uses actual public plan/apply; typed snapshot pairs prove only source mutation/atomicity and exact field preservation."]},"\t"))
	file.close()
	print("SUPPORT CLOSURE ",passed," ",checks)
	quit(0 if passed else 1)

func terminal_fixture() -> Dictionary:
	var b = fixture()
	b.recipe = {"preserveBlueprint": {"values": [1, "original", Vector3(2, 3, 4)]}}
	b.rooms = [{"id": "unchanged_courtyard", "role": "courtyard", "bounds": AABB(Vector3(-8, 0, -8), Vector3(16, 8, 16)), "accesses": []}]
	# ENTIRE synthetic pre-frame row: two vertical jambs and their one header.
	# Original jamb base is approximately 1.2; the selected narrow seat tops 1.4.
	for x in [-0.6, 0.6]:
		b.add_part({"id": "row_jamb_left" if x < 0 else "row_jamb_right",
			"kind": "beam", "semantic": "citadel_terminal_shop_frame",
			"material": "timber", "position": Vector3(x, 1.8, 0),
			"size": Vector3(0.2, 1.2, 0.2), "collision": true,
			"recipe": {"preserveMember": {"values": [x, "jamb"]}}})
	b.add_part({"id": "row_header", "kind": "beam", "semantic": "citadel_terminal_shop_frame",
		"material": "timber", "position": Vector3(0, 2.5, 0),
		"size": Vector3(1.4, 0.2, 0.2), "collision": true,
		"recipe": {"preserveMember": {"values": ["header", 3]}}})
	# Match the established elevation fixture's source lookup registration.
	for part in b.parts:
		b.physical_parts_by_id[part.id] = part
	return {"b": b, "ids": ROW_IDS.duplicate()}

func public_contracts() -> void:
	print("SUPPORT CLOSURE PUBLIC: complete pre-frame row")
	var f := terminal_fixture()
	var b = f.b
	var before: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(part): return part.recipe)
	var plan: Dictionary = Elevation.plan(b, f.ids)
	checks["public_plan_readonly_complete_snapshot"] = var_to_bytes(before) == var_to_bytes(b.snapshot())
	var ready: bool = plan.get("ready", false)
	checks["public_plan_complete_row_on_narrow_seat"] = ready and plan.get("supportId") == "seat" and plan.get("memberIds") == ["row_header", "row_jamb_left", "row_jamb_right"] and (plan.get("changes", []) as Array).size() == 3 and is_equal_approx(float(plan.get("originalBaseY", 0)), 1.2) and is_equal_approx(float(plan.get("standingY", 0)), 1.4)
	checks["public_plan_whole_dependency_footprint_proven"] = ready and plan.get("upstreamIds") == ["root-4", "root0", "root4", "wide"] and plan.get("supportClosure", {}).get("partIds") == ["root-4", "root0", "root4", "seat", "wide"]
	var applied: Dictionary = Elevation.apply(b, f.ids)
	checks["public_apply_ready_matches_plan"] = ready and bool(applied.get("ready", false)) and bool(applied.get("applied", false)) and var_to_bytes(applied.get("changes")) == var_to_bytes(plan.get("changes"))
	var expected := before.duplicate(true)
	var uniform := ready
	var delta: Vector3 = plan.get("translation", Vector3.ZERO)
	for record in expected.parts:
		if f.ids.has(record.id):
			record.position += delta
			var actual = b.find_part(record.id)
			uniform = uniform and actual != null and actual.position == record.position
	checks["public_apply_whole_row_uniform_nonzero_rise"] = uniform and delta.y > 0.0 and delta.x == 0.0 and delta.z == 0.0
	checks["public_apply_every_nonposition_field_and_nonmember_exact"] = ready and var_to_bytes(expected) == var_to_bytes(b.snapshot())
	var identities: bool = b.parts.size() == aliases.size()
	for index in range(b.parts.size()):
		identities = identities and is_same(aliases[index], b.parts[index]) and is_same(recipes[index], b.parts[index].recipe)
	checks["public_apply_preserves_part_recipe_identity_and_order"] = identities
	record_public_case("positive_apply", before, b.snapshot(), plan, applied)
	var once: Dictionary = b.snapshot()
	var repeat_plan: Dictionary = Elevation.plan(b, f.ids)
	checks["public_repeat_plan_ready_no_changes_readonly"] = bool(repeat_plan.get("ready", false)) and (repeat_plan.get("changes", []) as Array).is_empty() and var_to_bytes(once) == var_to_bytes(b.snapshot())
	var repeat_apply: Dictionary = Elevation.apply(b, f.ids)
	checks["public_repeat_apply_exact_idempotence"] = bool(repeat_apply.get("ready", false)) and bool(repeat_apply.get("applied", false)) and (repeat_apply.get("changes", []) as Array).is_empty() and var_to_bytes(once) == var_to_bytes(b.snapshot())
	record_public_case("idempotent_repeat", once, b.snapshot(), repeat_plan, repeat_apply)
	for mode in ["missing_root", "forged_root", "context_cap", "foreign_obstacle", "protected_reservation", "upstream_collision", "duplicate_seat"]:
		public_negative(mode)
	for quarter in range(4):
		public_lateral(quarter)

func public_negative(mode: String) -> void:
	print("SUPPORT CLOSURE PUBLIC: negative ", mode)
	var f := terminal_fixture()
	var b = f.b
	var obstacles: Array = []
	match mode:
		"missing_root":
			b.parts = b.parts.filter(func(part): return part.id != "root-4")
		"forged_root":
			b.find_part("wide").physical_intent = "structural_root"
		"context_cap":
			for index in range(Elevation.MAX_SUPPORT_CONTEXT):
				b.add_part({"id": "context_extra%d" % index, "kind": "foundation", "position": Vector3(4, 0.5, 0), "size": Vector3(0.1, 1, 0.1)})
		"foreign_obstacle":
			# Covers every translated member position on the selected 2x2 seat.
			b.add_part({"id": "foreign_all_positions", "kind": "wall", "position": Vector3(0, 2.2, 0), "size": Vector3(4, 1.4, 4), "collision": true})
		"protected_reservation":
			obstacles.append({"id": "protected_all_positions", "bounds": AABB(Vector3(-2, 1.5, -2), Vector3(4, 1.4, 4))})
		"upstream_collision":
			# A deliberately low whole-row detail intersects the proven wide
			# foundation after the jambs rise. Upstream membership is no exemption.
			b.add_part({"id": "row_low_detail", "kind": "beam", "semantic": "citadel_terminal_shop",
				"position": Vector3(0, 1.05, 0), "size": Vector3(0.2, 0.4, 0.2)})
			f.ids.append("row_low_detail")
		"duplicate_seat":
			# A small row detail lies within the selected seat's contact margin.
			# Prove this source is accepted before adding the IDENTICAL foreign
			# foundation: only the selected seat may receive that allowance.
			b.add_part({"id": "row_contact_detail", "kind": "beam", "semantic": "citadel_terminal_shop",
				"position": Vector3(0, 1.23, 0), "size": Vector3(0.2, 0.1, 0.2)})
			f.ids.append("row_contact_detail")
			var contact_before: Dictionary = b.snapshot()
			var contact_plan: Dictionary = Elevation.plan(b, f.ids)
			checks["public_duplicate_seat:single_seat_contact_precondition_ready"] = bool(contact_plan.get("ready", false)) and contact_plan.get("supportId") == "seat" and var_to_bytes(contact_before) == var_to_bytes(b.snapshot())
			var duplicate: Dictionary = b.find_part("seat").snapshot()
			duplicate.id = "seat_duplicate"
			b.add_part(duplicate)
	var before: Dictionary = b.snapshot()
	var obstacles_before := var_to_bytes(obstacles)
	var plan: Dictionary = Elevation.plan(b, f.ids, obstacles)
	checks["public_" + mode + ":plan_rejects_readonly"] = not bool(plan.get("ready", true)) and (plan.get("changes", []) as Array).is_empty() and var_to_bytes(before) == var_to_bytes(b.snapshot())
	var applied: Dictionary = Elevation.apply(b, f.ids, obstacles)
	checks["public_" + mode + ":apply_rejects_complete_snapshot_exact"] = not bool(applied.get("ready", true)) and not bool(applied.get("applied", false)) and (applied.get("changes", []) as Array).is_empty() and var_to_bytes(before) == var_to_bytes(b.snapshot())
	checks["public_" + mode + ":plan_apply_rejection_exact"] = var_to_bytes(plan) == var_to_bytes(applied)
	checks["public_" + mode + ":reservations_unchanged"] = obstacles_before == var_to_bytes(obstacles)
	if mode in ["missing_root", "forged_root", "context_cap"]:
		checks["public_" + mode + ":support_proof_is_rejection_owner"] = plan.get("reason") == "support_closure_unproven" and not bool(plan.get("supportClosure", {}).get("ready", true))
		if mode == "forged_root":
			checks["public_forged_root:exact_reason"] = plan.get("supportClosure", {}).get("reason") == "ungrounded_declared_root"
		elif mode == "context_cap":
			checks["public_context_cap:exact_reason"] = plan.get("supportClosure", {}).get("reason") == "support_context_limit"
	else:
		var lateral: Dictionary = plan.get("lateralClearance", {})
		var support: Dictionary = plan.get("supportClosure", {})
		checks["public_" + mode + ":valid_closure_does_not_exempt_blockers"] = bool(support.get("ready", false)) and support.get("partIds") == ["root-4", "root0", "root4", "seat", "wide"] and plan.get("supportId") == "seat" and plan.get("reason") == "no_lateral_row_clearance" and lateral.get("reason") == "support_footprint_fully_obstructed"
		var wanted := "wide" if mode == "upstream_collision" else ("protected_all_positions" if mode == "protected_reservation" else ("seat_duplicate" if mode == "duplicate_seat" else "foreign_all_positions"))
		checks["public_" + mode + ":actual_blocker_reported"] = (lateral.get("forbiddenRectangles", []) as Array).any(func(row): return row.get("partId") == wanted)
	record_public_case(mode, before, b.snapshot(), plan, applied)

func record_public_case(name: String, before: Dictionary, after: Dictionary, plan: Dictionary, applied: Dictionary) -> void:
	var file_path := output_directory.path_join(name + "-snapshots.bin")
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		checks["snapshot_artifact_" + name] = false
		return
	file.store_var({"before": before, "after": after}, false)
	file.close()
	public_cases.append({"name": name, "plan": plan, "apply": applied,
		"beforeSha256": bytes_sha256(var_to_bytes(before)), "afterSha256": bytes_sha256(var_to_bytes(after)),
		"completeSnapshotExact": var_to_bytes(before) == var_to_bytes(after),
		"typedSnapshotPair": file_path, "typedSnapshotPairSha256": FileAccess.get_sha256(file_path)})

func bytes_sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK: return ""
	context.update(bytes)
	return context.finish().hex_encode()

func source_hashes() -> Dictionary:
	var result := {}
	for path in SOURCE_PATHS:
		result[path] = FileAccess.get_sha256(path)
	return result

func public_lateral(quarter: int) -> void:
	var label := "public_lateral_%d" % quarter
	print("SUPPORT CLOSURE PUBLIC: lateral orientation ", quarter)
	var f := terminal_fixture()
	var b = f.b
	var turn := Basis.IDENTITY
	match quarter:
		1: turn = Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0))
		2: turn = Basis(Vector3(-1, 0, 0), Vector3.UP, Vector3(0, 0, -1))
		3: turn = Basis(Vector3(0, 0, 1), Vector3.UP, Vector3(-1, 0, 0))
	for id in f.ids:
		var part = b.find_part(id)
		part.position = turn * part.position
		part.rotation = turn.get_euler()
	var unobstructed: Dictionary = Elevation.plan(b, f.ids)
	checks[label + ":unobstructed_ready"] = bool(unobstructed.get("ready", false))
	# Covers the whole available depth, leaving a real lateral solution on the
	# same seat. Quarter turns exercise both axes and both displacement signs.
	b.add_part({"id": "lateral_foreign", "kind": "wall", "position": turn * Vector3(0.75, 2.2, 0),
		"rotation": turn.get_euler(), "size": Vector3(0.2, 1.4, 4.0), "collision": true})
	var before: Dictionary = b.snapshot()
	var plan: Dictionary = Elevation.plan(b, f.ids)
	checks[label + ":plan_readonly"] = var_to_bytes(before) == var_to_bytes(b.snapshot())
	var applied: Dictionary = Elevation.apply(b, f.ids)
	checks[label + ":public_plan_apply_ready_same_changes"] = bool(plan.get("ready", false)) and bool(applied.get("ready", false)) and bool(applied.get("applied", false)) and var_to_bytes(plan.get("changes")) == var_to_bytes(applied.get("changes"))
	var delta: Vector3 = plan.get("translation", Vector3.ZERO)
	var expected_direction := turn * Vector3.LEFT
	var horizontal := Vector3(delta.x, 0, delta.z)
	checks[label + ":entire_row_moves_away_from_foreign_obstacle"] = horizontal.dot(expected_direction) > 0.0 and horizontal.cross(expected_direction).is_zero_approx() and delta.y > 0.0 and plan.get("supportId") == "seat" and (plan.get("changes", []) as Array).size() == f.ids.size()
	var expected := before.duplicate(true)
	for record in expected.parts:
		if f.ids.has(record.id):
			record.position += delta
	checks[label + ":only_all_member_positions_change"] = bool(plan.get("ready", false)) and var_to_bytes(expected) == var_to_bytes(b.snapshot())
	var reverse_b = Blueprint.new(before.id, before.seed, before.style)
	reverse_b.recipe = before.recipe.duplicate(true)
	reverse_b.rooms = before.rooms.duplicate(true)
	for record in before.parts:
		reverse_b.add_part(record)
	reverse_b.parts.reverse()
	var reverse_ids: Array = f.ids.duplicate()
	reverse_ids.reverse()
	var replay: Dictionary = Elevation.plan(reverse_b, reverse_ids)
	checks[label + ":reversed_source_and_members_exact_plan"] = bool(plan.get("ready", false)) and var_to_bytes(plan) == var_to_bytes(replay)
	record_public_case("lateral_quarter_%d" % quarter, before, b.snapshot(), plan, applied)
