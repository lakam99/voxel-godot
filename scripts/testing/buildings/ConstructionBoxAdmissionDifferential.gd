extends SceneTree
const Admission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var old = load("res://artifacts/citadel-runtime-integration/support-query-baseline/ConstructionBoxAdmission.gd")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1393179273
	var pairs := []
	for i in range(2000):
		var a := Transform3D(Basis.from_scale(Vector3(rng.randf_range(0.001,100),rng.randf_range(0.001,100),rng.randf_range(0.001,100))),Vector3(rng.randf_range(-100,100),rng.randf_range(-100,100),rng.randf_range(-100,100)))
		var b := Transform3D(Basis.from_scale(Vector3(rng.randf_range(0.001,100),rng.randf_range(0.001,100),rng.randf_range(0.001,100))),Vector3(rng.randf_range(-100,100),rng.randf_range(-100,100),rng.randf_range(-100,100)))
		if i % 4 == 0: b.origin = a.origin
		if i % 4 == 1: b.origin = a.origin + Vector3((a.basis.x.x+b.basis.x.x)*0.5,0,0)
		if i % 5 == 0: b.basis = Basis(Vector3(0,1,0),Vector3(-1,0,0),Vector3(0,0,1)) * b.basis
		if i % 7 == 0: b.basis = Basis.from_euler(Vector3(0.1,0.4,-0.2)) * b.basis
		pairs.append([a,b])
	var expected := []
	# Small overlap remains rejected but retains the original diagnostic reason,
	# whose guard includes large coordinates on any world axis.
	var tiny := Transform3D(Basis.from_scale(Vector3.ONE * 0.001), Vector3(0,100000,0))
	var near := tiny
	near.origin.x = 0.000999
	pairs.append([tiny,near])
	var started := Time.get_ticks_usec()
	for pair in pairs: expected.append(old.measure(pair[0],pair[1]))
	var baseline_usec := Time.get_ticks_usec()-started
	var actual := []
	started = Time.get_ticks_usec()
	for pair in pairs: actual.append(Admission.measure(pair[0],pair[1]))
	var candidate_usec := Time.get_ticks_usec()-started
	var mismatches := []
	for i in pairs.size():
		if var_to_bytes(expected[i]) != var_to_bytes(actual[i]): mismatches.append({"index":i,"old":expected[i],"new":actual[i]})
	var file := FileAccess.open(OS.get_environment("BOX_ADMISSION_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed":mismatches.is_empty(),"checks":{"exact_results":mismatches.is_empty()},"pairs":pairs.size(),"baselineUsec":baseline_usec,"candidateUsec":candidate_usec,"mismatches":mismatches.slice(0,8),"scope":"Synthetic differential, not gameplay acceptance."},"\t"));file.close()
	quit(0 if mismatches.is_empty() else 1)
