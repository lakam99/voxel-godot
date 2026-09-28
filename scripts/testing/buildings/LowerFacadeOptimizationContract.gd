extends SceneTree
## Synthetic exact differential of private optimizations. The callback oracle
## forces every original connection measurement; the empty-index oracle scans
## every support target with the original exact predicate. No gameplay claim.
const Lower = preload("res://scripts/buildings/LowerFacadeBearingRecipe.gd")
const Connection = preload("res://scripts/buildings/OpeningHeadConnectionRecipe.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
var checks: Dictionary = {}
var metrics: Dictionary = {}

func _initialize() -> void: call_deferred("_run")
func check(label: String, passed: bool) -> void:
	checks[label] = passed
	if not passed: print("LOWER OPTIMIZATION FAILURE ",label)

func _part(id: String, position: Vector3, size: Vector3 = Vector3.ONE, rotation: Vector3 = Vector3.ZERO, recipe: Dictionary = {}):
	return Part.new({"id":id,"kind":"beam","position":position,"size":size,"rotation":rotation,"collision":true,
		"recipe":recipe})

func _box(id: String, position: Vector3, size: Vector3 = Vector3.ONE, rotation: Vector3 = Vector3.ZERO) -> Dictionary:
	return Connection._obstacles([_part(id,position,size,rotation)]).boxes[0]

func _connection(label: String, obstacles: Array, initial_work: int = 0, body: Array = [0.0,0.0,0.0,1.0,0.2,0.2], neutral: Vector3 = Vector3(0.5,0.1,0.1)) -> Dictionary:
	var core: Array = [-1.0,0.0,0.0,2.0,0.2,0.2]
	var half: Vector3 = Vector3(0.07,0.04,0.07)
	var source: PackedByteArray = var_to_bytes([body,core,neutral,half,obstacles])
	var expected_work: Dictionary = {"satPairs":initial_work}
	var actual_work: Dictionary = expected_work.duplicate()
	var calls: Array[int] = [0]
	var expected: Dictionary = Connection._place_connection(body,core,neutral,half,obstacles,expected_work,func(first: Transform3D, second: Transform3D) -> Dictionary:
		calls[0] += 1
		return Connection.Admission.measure(first,second))
	var actual: Dictionary = Connection._place_connection(body,core,neutral,half,obstacles,actual_work)
	check(label+"_complete_result_exact",var_to_bytes(expected)==var_to_bytes(actual))
	check(label+"_ordered_work_exact",var_to_bytes(expected_work)==var_to_bytes(actual_work) and calls[0]==int(expected_work.satPairs)-initial_work)
	check(label+"_caller_unchanged",source==var_to_bytes([body,core,neutral,half,obstacles]))
	return actual

func _connections() -> void:
	var far: Dictionary = _box("far",Vector3(100,0,0))
	var farther: Dictionary = _box("farther",Vector3(-100,0,0))
	var blocker: Dictionary = _box("blocker",Vector3(0.5,0.1,0.1),Vector3(4,4,4))
	check("far_connection_ready",_connection("far",[far,farther]).get("ready",false))
	check("empty_connection_ready",_connection("empty",[]).get("ready",false))
	_connection("rotated_far",[_box("rotated",Vector3(100,0,0),Vector3.ONE,Vector3(0,0.3,0))])
	var reflected: Dictionary = far.duplicate(true)
	reflected.pose = Transform3D(Basis.from_scale(Vector3(-1,1,1)),Vector3(100,0,0))
	_connection("reflected_far",[reflected])
	var permutation: Dictionary = far.duplicate(true)
	permutation.pose = Transform3D(Basis(Vector3(0,1,0),Vector3(0,0,1),Vector3(1,0,0)),Vector3(100,0,0))
	_connection("permuted_cardinal_far",[permutation])
	var mismatch: Dictionary = blocker.duplicate(true)
	mismatch.bounds = far.bounds.duplicate()
	check("misleading_far_bounds_cannot_hide_actual_blocker",not _connection("far_bounds_near_pose",[mismatch]).get("ready",false))
	var reverse_mismatch: Dictionary = far.duplicate(true)
	reverse_mismatch.bounds = blocker.bounds.duplicate()
	_connection("near_bounds_far_pose",[reverse_mismatch])
	var invalid: Dictionary = far.duplicate(true)
	invalid.pose = Transform3D(Basis.from_scale(Vector3.ZERO),Vector3(100,0,0))
	check("invalid_pose_still_fails_in_order",_connection("invalid_after_clear",[far,invalid]).get("reason")=="invalid_connection_measurement")
	check("earlier_blocker_preserves_exhaustive_rejection",_connection("blocker_before_invalid",[blocker,invalid]).get("reason")=="no_clear_connection_in_socket_domain")
	check("work_exhaustion_includes_certified_clear_pairs",_connection("work_boundary",[far,farther],Connection.MAX_SAT_WORK-1).get("reason")=="connection_sat_work_limit")
	_connection("work_already_exhausted",[far],Connection.MAX_SAT_WORK)
	check("invalid_candidate_not_certified",_connection("invalid_candidate",[far],0,[100001.0,0.0,0.0,100002.0,0.2,0.2],Vector3(100001.5,0.1,0.1)).get("reason")=="invalid_connection_measurement")
	var envelope: Array = [0.0,0.0,0.0,1.0,1.0,1.0]
	check("certificate_far_valid_cardinal",Connection._clear_of_connection_envelope(envelope,far.pose))
	check("certificate_rejects_rotated_and_invalid",not Connection._clear_of_connection_envelope(envelope,_box("rot",Vector3(100,0,0),Vector3.ONE,Vector3(0,0.2,0)).pose)
		and not Connection._clear_of_connection_envelope(envelope,invalid.pose))
	for offset: float in [0.0,0.0005,0.002]:
		var pose: Transform3D = Transform3D(Basis.IDENTITY,Vector3(1.5+offset,0.5,0.5))
		check("certificate_contact_guard_"+str(offset),Connection._clear_of_connection_envelope(envelope,pose)==(offset>0.001))
	var calls: Array[int] = [0]
	var meter: Dictionary = {"satPairs":0}
	var overridden: Dictionary = Connection._place_connection([0.0,0.0,0.0,1.0,0.2,0.2],[-1.0,0.0,0.0,2.0,0.2,0.2],
		Vector3(0.5,0.1,0.1),Vector3(0.07,0.04,0.07),[far,farther],meter,func(_a: Transform3D,_b: Transform3D) -> Dictionary:
			calls[0] += 1
			return {"valid":false,"clear":false,"reason":"synthetic_override_failure"})
	check("override_not_bypassed_for_far_certificate",calls[0]==1 and meter.satPairs==1 and overridden.get("blockingPartId")=="far"
		and overridden.get("measurement",{}).get("reason")=="synthetic_override_failure")

func _support_pair(label: String, parts: Array, influences: Array, index: Dictionary, panel_id: String = "excluded_panel") -> void:
	var records: Array = parts.map(func(part) -> Dictionary: return part.snapshot())
	var before: PackedByteArray = var_to_bytes([records,influences.map(func(part) -> Dictionary: return part.snapshot())])
	var expected: Dictionary = Lower._support_targets_for_additions(records,influences,panel_id,parts)
	var actual: Dictionary = Lower._support_targets_for_additions(records,influences,panel_id,parts,index)
	check(label+"_all_exact_target_ids",var_to_bytes(expected)==var_to_bytes(actual))
	check(label+"_caller_unchanged",before==var_to_bytes([parts.map(func(part) -> Dictionary: return part.snapshot()),influences.map(func(part) -> Dictionary: return part.snapshot())]))

func _support_index() -> void:
	var parts: Array = []
	for x: float in [-12.0,-4.0,0.0,4.0,12.0]:
		for z: float in [-4.0,0.0,4.0]:
			parts.append(_part("target_"+str(100-parts.size()),Vector3(x,1.5,z),Vector3(2,1,2)))
	parts.append(_part("rotated_target",Vector3(30,1.5,0),Vector3(2,1,2),Vector3(0,0.4,0)))
	parts.append(_part("oversized_target",Vector3(50,1.5,0),Vector3(100,1,100)))
	parts.append(_part("unbounded_target",Vector3(100001,1.5,0),Vector3(2,1,2)))
	parts.append(_part("excluded_panel",Vector3(0,1.5,0),Vector3(2,1,2)))
	parts.append(_part("declared_dependent",Vector3(0,1.5,0),Vector3(2,1,2),Vector3.ZERO,{"physicalSupportsPartId":"beam"}))
	parts.append(_part("enclosing_target",Vector3(0,1.5,0),Vector3(2,1,2),Vector3.ZERO,{"allowEnclosingStructuralSupport":true}))
	var disabled = _part("disabled",Vector3(0,1.5,0)); disabled.collision_enabled = false; parts.append(disabled)
	var portal = _part("portal",Vector3(0,1.5,0)); portal.physical_intent = "portal"; parts.append(portal)
	var index: Dictionary = Lower._build_support_target_index(parts)
	var source: PackedByteArray = var_to_bytes(parts.map(func(part) -> Dictionary: return part.snapshot()))
	var beam = _part("beam",Vector3(0,0.5,0),Vector3(2,1,2))
	var ordinals: Array = Lower._support_target_ordinals(index,[beam])
	var sorted: Array = ordinals.duplicate(); sorted.sort()
	check("index_reduces_cardinal_candidates_and_preserves_source_order",ordinals.size()<parts.size() and ordinals==sorted)
	check("uncertified_targets_always_present",ordinals.has(15) and ordinals.has(16) and ordinals.has(17))
	_support_pair("local",parts,[beam],index)
	_support_pair("exclusion",parts,[beam],index,"target_93")
	_support_pair("ordered_two_influences",parts,[_part("negative",Vector3(-4,0.5,-4),Vector3(2,1,2)),beam],index)
	for x: float in [-4.102,-4.101,-4.1,-4.0,3.9,4.0,4.1,4.101,4.102]:
		_support_pair("cell_boundary_"+str(x),parts,[_part("boundary",Vector3(x,0.5,0),Vector3(2,1,2))],index)
	for value: Dictionary in [{"id":"rotated_influence","position":Vector3(30,0.5,0),"size":Vector3(2,1,2),"rotation":Vector3(0,0.4,0)},
		{"id":"large_influence","position":Vector3(50,0.5,0),"size":Vector3(100,1,100),"rotation":Vector3.ZERO},
		{"id":"unbounded_influence","position":Vector3(100001,0.5,0),"size":Vector3(2,1,2),"rotation":Vector3.ZERO}]:
		var influence = _part(value.id,value.position,value.size,value.rotation)
		check(value.id+"_uses_complete_scan",Lower._support_target_ordinals(index,[influence])==range(parts.size()))
		_support_pair(value.id,parts,[influence],index)
	var enclosing = _part("enclosing_root",Vector3(0,1.5,0),Vector3(3,4,3),Vector3.ZERO,{"physicalRoot":true})
	_support_pair("enclosing_root",parts,[enclosing],index)
	_support_pair("empty_influences",parts,[],index)
	check("indexed_input_values_unchanged",source==var_to_bytes(parts.map(func(part) -> Dictionary: return part.snapshot())))
	var limited: Dictionary = Lower._build_support_target_index([])
	limited.entries = Lower.MAX_SUPPORT_TARGET_ENTRIES
	Lower._set_support_target(limited,0,beam)
	limited.count = 1
	check("entry_limit_spills_without_dropping_target",limited.overflow==[0] and limited.cells.is_empty() and Lower._support_target_ordinals(limited,[beam])==[0])
	metrics.supportParts = parts.size(); metrics.localCandidates = ordinals.size()

func _commit_and_binding() -> void:
	var blueprint = Blueprint.new("transaction",1,"stone")
	blueprint.parts = [_part("m_panel",Vector3(0,1.5,0),Vector3(2,1,2)),_part("z_target",Vector3(4,1.5,0),Vector3(2,1,2))]
	var obstacles: Array = Connection._obstacles(blueprint.parts).boxes
	var alias: Array = obstacles
	var index: Dictionary = Lower._build_support_target_index(blueprint.parts)
	var input: Dictionary = {"blueprint":blueprint,"obstacles":obstacles,"supportTargetIndex":index}
	var panel = _part("m_panel",Vector3(40,1.5,0),Vector3(2,1,2))
	var additions: Array = [_part("a_member",Vector3(0,1.5,0),Vector3(2,1,2)),
		_part("n_member",Vector3(4,1.5,0),Vector3(2,1,2)),_part("y_member",Vector3(-4,1.5,0),Vector3(2,1,2))]
	var added_obstacles: Array = Connection._obstacles(additions).boxes
	var expected: Array = obstacles.duplicate(); expected.append_array(added_obstacles)
	expected.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return a.id<b.id)
	var added_before: PackedByteArray = var_to_bytes(added_obstacles)
	Lower._commit_prepared_members(input,0,panel,additions,added_obstacles)
	check("merge_exact_order_and_array_alias",var_to_bytes(obstacles)==var_to_bytes(expected) and is_same(alias,input.obstacles))
	check("merge_keeps_additions_unchanged",added_before==var_to_bytes(added_obstacles))
	check("commit_part_order_and_identity",blueprint.parts.map(func(part) -> String: return part.id)==["m_panel","z_target","a_member","n_member","y_member"]
		and is_same(index.parts,blueprint.parts) and index.count==5 and blueprint.physical_parts_by_id.m_panel==panel)
	var near = _part("query",Vector3(0,0.5,0),Vector3(2,1,2))
	check("replacement_removes_old_membership_and_adds_new_members",not Lower._support_target_ordinals(index,[near]).has(0) and Lower._support_target_ordinals(index,[near]).has(2))
	_support_pair("committed_near",blueprint.parts,[near],index)
	_support_pair("committed_remote",blueprint.parts,[_part("remote_query",Vector3(40,0.5,0),Vector3(2,1,2))],index)
	var foreign_parts: Array = blueprint.parts.duplicate()
	_support_pair("foreign_array_binding_falls_back",foreign_parts,[near],index)
	var stale: Dictionary = index.duplicate(); stale.count = 0
	_support_pair("stale_count_falls_back",blueprint.parts,[near],stale)
	for values: Array in [[[],[]],[[{"id":"a"}],[]],[[],[{"id":"a"}]],[ [{"id":"b"},{"id":"d"}], [{"id":"a"},{"id":"c"},{"id":"e"}] ]]:
		var left: Array = values[0].duplicate(true)
		var ordered: Array = left.duplicate(); ordered.append_array(values[1]); ordered.sort_custom(func(a,b): return a.id<b.id)
		Lower._merge_prepared_obstacles(left,values[1])
		check("merge_boundary_"+str(checks.size()),var_to_bytes(left)==var_to_bytes(ordered))

func _run() -> void:
	_connections()
	_support_index()
	_commit_and_binding()
	var report: Dictionary = {"schema":"lower-facade-optimization-contract/v1","complete":true,"passed":not checks.values().has(false),
		"checks":checks,"metrics":metrics,"scope":"Synthetic exact connection work/failure/override and support-index/merge differential. No full source, physical acceptance, timings or gameplay."}
	var file: FileAccess = FileAccess.open(OS.get_environment("LOWER_OPTIMIZATION_REPORT"),FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("LOWER OPTIMIZATION COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size()}))
	quit(0 if report.passed else 1)
