extends "res://scripts/testing/buildings/CastleWalkthroughRunner.gd"

## Synthetic failure-injection contract, never a gameplay acceptance fixture.
## Exercise the real caller's early abort with a deliberately null blueprint.
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
var rejected_source = null

func read_arguments() -> void:
	super.read_arguments()
	report_path = OS.get_environment("VOXEL_BLUEPRINT_FAILURE_REPORT")

func build_castle_blueprint():
	if OS.get_cmdline_user_args().has("--late-roof-collision"):
		rejected_source = super.build_castle_blueprint()
		if rejected_source == null:
			return null
		# Deliberate collision at the known fixture's LAST house: the first 15
		# frames must have been assembled when composition rejects this one.
		rejected_source.add_part({"id": "urban_perimeter_east_02_purlin_frame_purlin_0_0_post_0", "kind": "beam", "size": Vector3.ONE})
		return Urban.compose(rejected_source, selected_seed)
	return null

func spawn_player() -> void:
	push_error("CONTRACT FAILURE: spawned player after rejected blueprint")

func write_automated_report() -> void:
	push_error("CONTRACT FAILURE: continued automated act after rejected blueprint")

func _exit_tree() -> void:
	var earlier_members := 0
	if rejected_source != null:
		for part in rejected_source.parts:
			if String(part.recipe.get("physicalAssemblyRole", "")) in ["gable_roof_post", "gable_roof_purlin"]:
				earlier_members += 1
	var late_failure := OS.get_cmdline_user_args().has("--late-roof-collision")
	var checks := {"blueprint_rejected": blueprint == null, "no_publisher": building_publisher == null,
		"no_player": player == null, "no_published_root": cottage_root == null,
		"earlier_frames_really_completed": earlier_members == (180 if late_failure else 0)}
	var file := FileAccess.open(report_path + ".contract.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"evidenceLevel": "synthetic_failure_injection", "lateRoofCollision": late_failure,
			"earlierFrameMemberCount": earlier_members, "checks": checks,
			"passed": checks.values().all(func(value): return bool(value)),
			"doesNotProve": "No live gameplay acceptance; deliberately corrupt source exercises actual composition and caller abort."}, "\t"))
	print("SYNTHETIC null-blueprint abort: no building publisher=", building_publisher == null,
		" no player=", player == null, " no published root=", cottage_root == null, " earlier frame members=", earlier_members)
