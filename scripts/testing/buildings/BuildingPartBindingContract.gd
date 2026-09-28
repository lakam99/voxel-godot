extends SceneTree
## Pure binding controls plus a targeted historical-input microbenchmark on
## one owned worker. No preparation, generation, Nodes/GPU or live acceptance.
const Binding = preload("res://scripts/buildings/BuildingPartBinding.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const PART_SHA := "4d1a63bf1e4224a39eb6dcb8bec995ba31cf78da9cb766dd6d1295bfcb8a546d"
const PART_BLOB := "4133a7ca4b027fc7d39e8ac0929a7d4d6ea61d97"
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const INPUT_SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"

class InheritedPart extends "res://scripts/buildings/BuildingPart.gd":
	pass

class OverridePart extends "res://scripts/buildings/BuildingPart.gd":
	var snapshot_calls := 0
	func snapshot() -> Dictionary:
		snapshot_calls+=1
		return {"customFirst":73,"recipe":recipe,"id":id,"customLast":Vector3.ONE}

class Duck extends RefCounted:
	var snapshot_calls := 0
	var value: Dictionary = {"duck":[1,2,3]}
	func snapshot() -> Dictionary:
		snapshot_calls+=1
		return value

# Frozen original snapshot body from PART_BLOB. It does not call the helper.
static func original_snapshot(part) -> Dictionary:
	return {
		"id": part.id,
		"kind": part.kind,
		"material": part.material_id,
		"position": part.position,
		"rotation": part.rotation,
		"size": part.size,
		"collision": part.collision_enabled,
		"semantic": part.semantic,
		"physicalIntent": part.physical_intent,
		"recipe": part.recipe.duplicate(true)
	}

static func check(checks: Dictionary, label: String, passed: bool) -> void:
	checks[label]=passed
	if not passed: print("PART BINDING FAILURE ",label)

static func parity(checks: Dictionary, label: String, part) -> PackedByteArray:
	var expected := var_to_bytes(original_snapshot(part))
	var live_original := var_to_bytes(part.snapshot())
	var actual := Binding.encode(part)
	check(checks,label+"_original_oracle",expected==live_original)
	check(checks,label+"_raw_bytes",actual==expected)
	return actual

static func normalized_for_diagnosis(value: Variant) -> PackedByteArray:
	# TEST ONLY: detect semantic/type/order equality despite the old engine's
	# uninitialized NodePath padding. Production still returns raw var_to_bytes.
	var bytes := var_to_bytes(value)
	bytes.fill(0)
	bytes.encode_var(0,value)
	return bytes

static func difference(a: PackedByteArray, b: PackedByteArray) -> Dictionary:
	var offsets: Array = []
	for i in mini(a.size(),b.size()):
		if a[i]!=b[i] and offsets.size()<16: offsets.append({"offset":i,"old":a[i],"new":b[i]})
	return {"oldSize":a.size(),"newSize":b.size(),"offsets":offsets}

static func node_path_control(checks: Dictionary, metrics: Dictionary) -> void:
	var part := Part.new()
	part.recipe={"path":NodePath("a/b"),"named":&"name","paths":[NodePath("root:prop"),NodePath("/root/child")]}
	var old_variants := {}
	var new_variants := {}
	var mismatches := 0
	var semantic_exact := true
	var first_diff := {}
	var baseline := normalized_for_diagnosis(original_snapshot(part))
	for i in 128:
		var old := var_to_bytes(original_snapshot(part))
		var again := var_to_bytes(original_snapshot(part))
		var observed := Binding.encode(part)
		old_variants[old.hex_encode()]=true
		old_variants[again.hex_encode()]=true
		new_variants[observed.hex_encode()]=true
		if old!=observed:
			mismatches+=1
			if first_diff.is_empty(): first_diff=difference(old,observed)
		semantic_exact=semantic_exact and normalized_for_diagnosis(bytes_to_var(old))==baseline and normalized_for_diagnosis(bytes_to_var(observed))==baseline
	check(checks,"nodepath_semantic_type_order_exact",semantic_exact)
	check(checks,"nodepath_raw_exact_or_old_old_unstable",mismatches==0 or old_variants.size()>1)
	# Independently expose the native encoder's unwritten padding bytes.
	var path := NodePath("a/b")
	var zero := normalized_for_diagnosis(path)
	var poison := zero.duplicate()
	poison.fill(165)
	poison.encode_var(0,path)
	var offsets: Array = []
	for i in zero.size():
		if poison[i]!=zero[i]: offsets.append(i)
	check(checks,"nodepath_padding_evidence",offsets==[21,22,23,29,30,31] and bytes_to_var(poison)==path)
	metrics.nodePath={"samples":128,"rawMismatches":mismatches,"oldDistinctRaw":old_variants.size(),"newDistinctRaw":new_variants.size(),"firstDifference":first_diff,"nativeUnwrittenPadding":offsets,"rawByteLimitationObserved":mismatches>0,"semanticsTypesOrderExact":semantic_exact,"policy":"Raw encoder unchanged; unstable old-old bytes are not claimed byte-stable."}

static func controls(checks: Dictionary, metrics: Dictionary) -> void:
	var part := Part.new({"id":"part","kind":"wall","material":"fired_brick","size":Vector3(2,3,0.4)})
	parity(checks,"empty",part)
	var typed: Array[int] = [3,1,2]
	var typed_dict: Dictionary[String,int] = {"z":3,"a":1}
	var object_array: Array[Resource] = []
	part.recipe={"nested":[{"z":1,"a":[true,null,1.25]}],"typed":typed,"typedDictionary":typed_dict,"emptyObjectTyped":object_array,
		"packed":[PackedByteArray([1,7]),PackedInt32Array([1,-2]),PackedInt64Array([3,-4]),PackedFloat32Array([1.25,-2.5]),PackedFloat64Array([3.5]),PackedStringArray(["a","bb"]),PackedVector2Array([Vector2.ONE]),PackedVector3Array([Vector3.ONE]),PackedColorArray([Color.RED]),PackedVector4Array([Vector4.ONE])],
		"values":[&"named",Vector2(1,2),Vector2i(3,4),Rect2(1,2,3,4),Rect2i(1,2,3,4),Vector3i(1,2,3),Vector4(1,2,3,4),Vector4i(1,2,3,4),Transform2D.IDENTITY,Plane(Vector3.UP,3),Quaternion.IDENTITY,AABB(Vector3.ZERO,Vector3.ONE),Basis.IDENTITY,Transform3D.IDENTITY,Projection.IDENTITY,Color(0.1,0.2,0.3,0.4)]}
	var original := parity(checks,"nested_typed_packed",part)
	check(checks,"input_not_frozen",not part.recipe.is_read_only() and not typed.is_read_only() and not typed_dict.is_read_only())
	typed[0]=99
	check(checks,"typed_alias_mutation_observed",parity(checks,"typed_mutation",part)!=original)
	part.recipe.nested[0].a[0]=false
	parity(checks,"nested_mutation",part)
	part.recipe.packed[0][0]=9
	parity(checks,"packed_mutation",part)
	typed_dict.z=19
	parity(checks,"typed_dictionary_mutation",part)
	var before := Binding.encode(part)
	part.recipe.typed=[99,1,2]
	check(checks,"typed_to_untyped_distinguished",parity(checks,"typed_replacement",part)!=before)
	part.recipe={"z":1,"a":2}
	before=parity(checks,"order_initial",part)
	part.recipe.erase("z"); part.recipe.z=1
	check(checks,"dictionary_order_distinguished",parity(checks,"order_changed",part)!=before)
	part.recipe={"a":2,"z":1}
	check(checks,"equal_replacement_exact",parity(checks,"equal_replacement",part)==Binding.encode(part))
	for field: String in ["id","kind","material_id","position","rotation","size","collision_enabled","semantic","physical_intent"]:
		before=Binding.encode(part)
		match field:
			"id": part.id=" Changed ID "
			"kind": part.kind="NotNormalized"
			"material_id": part.material_id="OTHER Material"
			"position": part.position=Vector3(-1,2,3)
			"rotation": part.rotation=Vector3(0.1,0.2,0.3)
			"size": part.size=Vector3(0.001,-2,0)
			"collision_enabled": part.collision_enabled=false
			"semantic": part.semantic="Changed semantic"
			"physical_intent": part.physical_intent="different"
		check(checks,field+"_live_change",parity(checks,field,part)!=before)
	var read_only: Array[int]=[7,8]
	read_only.make_read_only()
	part.recipe={"readOnly":read_only}
	part.recipe.make_read_only()
	parity(checks,"readonly",part)
	check(checks,"readonly_identity_preserved",is_same(part.recipe.readOnly,read_only))
	var object := RefCounted.new()
	var resource := Resource.new()
	part.recipe={"object":object,"resource":resource,"typedObjects":[object]}
	parity(checks,"objects_default_id_encoding",part)
	var held: WeakRef=weakref(object)
	object=null
	part.recipe={}
	check(checks,"helper_retains_no_recipe_object",held.get_ref()==null)
	var inherited := InheritedPart.new()
	inherited.recipe={"inherited":[1,2]}
	check(checks,"inherited_exact_script_excluded",inherited.get_script()!=Part)
	check(checks,"inherited_fallback_exact",Binding.encode(inherited)==var_to_bytes(inherited.snapshot()))
	var overridden := OverridePart.new()
	var expected := var_to_bytes(overridden.snapshot())
	overridden.snapshot_calls=0
	check(checks,"override_fallback_exact",Binding.encode(overridden)==expected)
	check(checks,"override_called_once",overridden.snapshot_calls==1)
	var duck := Duck.new()
	expected=var_to_bytes(duck.snapshot())
	duck.snapshot_calls=0
	check(checks,"duck_fallback_exact",Binding.encode(duck)==expected)
	check(checks,"duck_called_once",duck.snapshot_calls==1)
	node_path_control(checks,metrics)

static func benchmark(checks: Dictionary, metrics: Dictionary) -> void:
	check(checks,"historical_input_hash",FileAccess.get_sha256(INPUT)==INPUT_SHA)
	if not checks.historical_input_hash: return
	var file := FileAccess.open(INPUT,FileAccess.READ)
	var input: Dictionary=file.get_var(false)
	file.close()
	var ranked: Array = []
	for snapshot: Dictionary in input.blueprint.parts:
		ranked.append({"size":var_to_bytes(snapshot.recipe).size(),"snapshot":snapshot})
	ranked.sort_custom(func(a,b): return a.size>b.size)
	var selected: Array = []
	var ids: Array = []
	for i in mini(16,ranked.size()):
		var part := Part.new(ranked[i].snapshot)
		selected.append(part)
		ids.append(part.id)
		parity(checks,"historical_"+str(i),part)
	# Balanced alternating rounds; output consumed, no timing acceptance limit.
	var old_usec: Array[int] = []
	var new_usec: Array[int] = []
	var checksum := 0
	for warm in 2:
		for part in selected:
			checksum+=var_to_bytes(part.snapshot()).size()+Binding.encode(part).size()
	for round_index in 8:
		for pass_index in 2:
			var old := (round_index+pass_index)%2==0
			var start := Time.get_ticks_usec()
			for repeat_index in 32:
				for part in selected:
					checksum+=(var_to_bytes(part.snapshot()) if old else Binding.encode(part)).size()
			var elapsed := Time.get_ticks_usec()-start
			if old: old_usec.append(elapsed)
			else: new_usec.append(elapsed)
	var old_sorted := old_usec.duplicate()
	var new_sorted := new_usec.duplicate()
	old_sorted.sort(); new_sorted.sort()
	metrics.historicalBenchmark={"input":"historical actual05 raw snapshot parts, not postdiagnostic preparation","sourceSha256":INPUT_SHA,"partIds":ids,"parts":selected.size(),"callsPerRound":selected.size()*32,"oldUsec":old_usec,"newUsec":new_usec,"oldMedianUsec":(old_sorted[3]+old_sorted[4])/2.0,"newMedianUsec":(new_sorted[3]+new_sorted[4])/2.0,"checksum":checksum,"hardPerformanceAcceptance":false}
	check(checks,"historical_benchmark_completed",old_usec.size()==8 and new_usec.size()==8 and checksum>0)
	# These source references and temporary bindings are all released on worker.

static func run_worker() -> Dictionary:
	var checks := {}
	var metrics := {}
	check(checks,"original_snapshot_source_hash",FileAccess.get_sha256("res://scripts/buildings/BuildingPart.gd")==PART_SHA)
	controls(checks,metrics)
	benchmark(checks,metrics)
	return {"checks":checks,"metrics":metrics,"workerThreadId":OS.get_thread_caller_id()}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var worker := Thread.new()
	var started := Time.get_ticks_msec()
	var error := worker.start(run_worker)
	if error!=OK:
		print("PART BINDING WORKER START FAILED ",error)
		quit(1); return
	while worker.is_alive(): await process_frame
	var report: Dictionary=worker.wait_to_finish()
	check(report.checks,"owned_worker_not_main",report.workerThreadId!=OS.get_thread_caller_id())
	var failures: Array = []
	for key in report.checks:
		if not report.checks[key]: failures.append(key)
	report.merge({"schema":"building-part-binding-contract/v1","complete":true,"passed":failures.is_empty(),"checkCount":report.checks.size(),"failures":failures,"elapsedMsec":Time.get_ticks_msec()-started,"originalPartBlob":PART_BLOB,"originalPartSha256":PART_SHA,
		"helperSha256":FileAccess.get_sha256("res://scripts/buildings/BuildingPartBinding.gd"),"contractSha256":FileAccess.get_sha256(get_script().resource_path),"evidenceLevel":"synthetic raw binding controls and historical-input CPU microbenchmark only","doesNotProve":"No source generation/preparation, publication, live gameplay or hard-budget acceptance. Cyclic graphs already unsupported by original snapshot/encoder are not made safe or scanned by this helper."})
	var file := FileAccess.open(OS.get_environment("BUILDING_PART_BINDING_OUTPUT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("PART BINDING COMPLETE ",JSON.stringify({"passed":report.passed,"checks":report.checkCount,"failures":failures,"elapsedMsec":report.elapsedMsec,"nodePathRawMismatches":report.metrics.nodePath.rawMismatches}))
	quit(0 if report.passed else 1)
