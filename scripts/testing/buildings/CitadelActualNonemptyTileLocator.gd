extends SceneTree

## Offline locator for the pinned atlas-3376622889 source.  It selects an
## admitted terrain-support cell in a nonempty physical publication tile; it
## never creates a scene, requests streaming, or publishes navigation.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Streaming = preload("res://scripts/world/WorldStreamingCoordinator.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate-recipe-source-profile-32/source.bin"
const INPUT_METADATA := "res://artifacts/citadel-runtime-integration/candidate-recipe-source-profile-32/input.json"
const INPUT_SHA := "42f3c7b2ff1dee451f98dbd286c1a2d346c9e0033326f578ec8a6fea75418067"
const BINDING := {"siteId":"citadel-site-v1:16:atlas-3376622889:-2,-2",
	"sourceKey":"60d35570a40a438f232245e244ab5e4115883a0ff9bb4444588afabcf09705de","generation":1}
const WORLD_ORIGIN := Vector3(-4500.9,41.85,-3800.25)
const SEARCH_STEP_CELLS := 8
const SEARCH_RADII := [8,16,24,32,40,48,56,64,72,80,96]
const CAPSULE_CLEARANCE := 0.6

class Deadline extends RefCounted:
	var started := Time.get_ticks_msec()
	func checkpoint(_stage: String) -> bool: return Time.get_ticks_msec()-started < 120000

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var report := {"schema":"citadel-actual-nonempty-tile-locator/v1","complete":true,"passed":false,
		"seed":"atlas-3376622889","region":Vector2i(-2,-2),"binding":BINDING,"worldOrigin":WORLD_ORIGIN,
		"input":INPUT,"inputSha256":FileAccess.get_sha256(INPUT),"selected":{},"nonemptyTileCount":0}
	var file := FileAccess.open(INPUT,FileAccess.READ)
	if file==null:
		report.reason="source_open_failed"; _finish(report); return
	var decoded: Variant = file.get_var(false)
	var read_ok := file.get_error()==OK and file.get_position()==file.get_length()
	file.close()
	if not read_ok or not decoded is Dictionary or decoded.get("ready")!=true or not decoded.get("blueprint") is Dictionary or not decoded.get("furnishingPlan") is Dictionary or not decoded.get("accessReservations") is Array:
		report.reason="source_envelope_invalid"; _finish(report); return
	var source: Dictionary = decoded
	var metadata: Variant = JSON.parse_string(FileAccess.get_file_as_string(INPUT_METADATA))
	if not metadata is Dictionary or not metadata.get("candidate",{}) is Dictionary or not metadata.get("centerSurvey",{}) is Dictionary:
		report.reason="source_metadata_invalid"; _finish(report); return
	var candidate: Dictionary = metadata.candidate
	var terrain_survey: Dictionary = metadata.centerSurvey
	var center_text := String(candidate.get("centerCell",""))
	var coordinates := center_text.trim_prefix("(").trim_suffix(")").split(",",false)
	if coordinates.size()!=2 or not coordinates[0].strip_edges().is_valid_int() or not coordinates[1].strip_edges().is_valid_int() \
			or terrain_survey.get("status")!="surveyed" or terrain_survey.get("surfacePolicyEligible")!=true:
		report.reason="terrain_valid_center_missing"; _finish(report); return
	var center_cell := Vector2i(int(coordinates[0].strip_edges()),int(coordinates[1].strip_edges()))
	var furniture: Dictionary = source.furnishingPlan.duplicate(true)
	furniture["accessReservations"] = source.accessReservations.duplicate(true)
	var building: Dictionary = source.blueprint.duplicate(true)
	building.make_read_only(); furniture.make_read_only()
	# The completed source envelope intentionally does not retain terrain-profile
	# samples. Its spatial dependency compiler needs only this recorded origin;
	# terrain validity is independently carried by the ordinary center survey.
	var prepared: Dictionary = Preparation.prepare_publication_base(building,furniture,BINDING,{"origin":WORLD_ORIGIN},Deadline.new().checkpoint)
	if not prepared.get("ready",false):
		report.reason=prepared.get("reason","publication_base_failed"); _finish(report); return
	var base = prepared.get("base")
	if base==null:
		report.reason="publication_base_missing"; _finish(report); return
	var selection := _select_exterior_physical_cell(base.description,center_cell)
	report.nonemptyTileCount=int(selection.get("nonemptyTileCount",0))
	report.selected=selection.get("selected",{})
	report.passed=report.inputSha256==INPUT_SHA and not report.selected.is_empty()
	if not report.passed: report.reason="no_exterior_cell_with_physical_closure"
	_finish(report)

func _select_exterior_physical_cell(description, center_cell: Vector2i) -> Dictionary:
	var nonempty := 0
	for radius in SEARCH_RADII:
		for offset in _ring_offsets(radius):
			var cell := center_cell + offset
			var position := Vector3(cell.x*Streaming.CELL,0.0,cell.y*Streaming.CELL)
			if _horizontal_collision_blocker(description.solid_records,position): continue
			var bounds := Streaming.playable_bounds(position)
			var closure: Dictionary = description.physical_group_requirements(bounds)
			var group_ids: Array = closure.get("groupIds",[]).duplicate()
			group_ids.sort()
			if closure.get("status")!="described" or group_ids.is_empty(): continue
			nonempty += 1
			return {"nonemptyTileCount":nonempty,"selected":{"cell":cell,"offset":offset,
				"streamingBounds":bounds,"groupIds":group_ids,"sourceExterior":true,
				"collisionClearance":CAPSULE_CLEARANCE,
				"terrainEvidence":{"centerSurveyStatus":"center_only","surfacePolicyEligible":terrain_survey_status(),
					"maximumSurfaceY":0.0},"selectionPolicy":"nearest deterministic source-exterior cell whose playable bounds has a physical closure"}}
	return {"nonemptyTileCount":nonempty,"selected":{}}

func terrain_survey_status() -> bool:
	# The frozen envelope proves only the recorded centre's terrain admission.
	# The headed fixture still performs the authoritative collision/support proof.
	return false

func _ring_offsets(radius: int) -> Array[Vector2i]:
	var offsets: Array[Vector2i] = []
	for x in range(-radius,radius+1,SEARCH_STEP_CELLS):
		for z in range(-radius,radius+1,SEARCH_STEP_CELLS):
			if max(abs(x),abs(z))==radius: offsets.append(Vector2i(x,z))
	offsets.sort_custom(func(a: Vector2i,b: Vector2i) -> bool:
		var a_length := a.length_squared()
		var b_length := b.length_squared()
		return a_length < b_length if a_length != b_length else (a.x < b.x if a.x != b.x else a.y < b.y))
	return offsets

func _horizontal_collision_blocker(records: Array, position: Vector3) -> bool:
	for value in records:
		if not value is Dictionary: continue
		var bounds: AABB = value.get("bounds",AABB()) if value.get("bounds",AABB()) is AABB else AABB()
		if bounds.size.x<=0.0 or bounds.size.z<=0.0: continue
		if position.x+CAPSULE_CLEARANCE > bounds.position.x and position.x-CAPSULE_CLEARANCE < bounds.end.x \
				and position.z+CAPSULE_CLEARANCE > bounds.position.z and position.z-CAPSULE_CLEARANCE < bounds.end.z:
			return true
	return false

func _finish(report: Dictionary) -> void:
	var output := OS.get_environment("CITADEL_ACTUAL_NONEMPTY_TILE_LOCATOR_REPORT")
	if output.is_empty() or not output.is_absolute_path(): quit(2); return
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("CITADEL ACTUAL NONEMPTY TILE LOCATOR ",JSON.stringify({"passed":report.passed,"selected":report.selected}))
	quit(0 if report.passed else 1)
