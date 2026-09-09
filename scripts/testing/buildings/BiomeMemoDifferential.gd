extends SceneTree
const Current = preload("res://scripts/world/BiomeRegionField.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	if FileAccess.get_sha256("res://artifacts/citadel-runtime-integration/biome-sampling-01/FrozenBiomeRegionField.gd")!="251f30bf0e746ec8889753d0d6833a889680cc79959f5780ff2e06c6434e317d": quit(2); return
	var old=load("res://artifacts/citadel-runtime-integration/biome-sampling-01/FrozenBiomeRegionField.gd").new()
	var current=Current.new()
	var exact := true
	var count := 0
	var old_usec := 0
	var new_usec := 0
	for seed in ["atlas-3376622889",""," default ","memo-other-world"]:
		for i in range(5000):
			var p := Vector2(-4700+(i%100)*1.35,-4000+(i/100)*1.35) if i<2500 else Vector2((i-3750)*6100.0,(i%17-8)*6000.0)
			var started := Time.get_ticks_usec()
			var expected: Dictionary=old.sample(seed,p)
			old_usec+=Time.get_ticks_usec()-started
			started=Time.get_ticks_usec()
			var actual: Dictionary=current.sample(seed,p)
			new_usec+=Time.get_ticks_usec()-started
			exact=exact and var_to_bytes(expected)==var_to_bytes(actual)
			count+=1
	var checks := {"all_fields_exact":exact,"bounded_sites":current._site_memo.size()<=Current.MEMO_LIMIT,"bounded_climate":current._climate_memo.size()<=Current.MEMO_LIMIT}
	var threads: Array[Thread] = []
	for worker in range(4):
		var thread := Thread.new()
		thread.start(_parallel_compare.bind(current,old,worker))
		threads.append(thread)
	var parallel_exact := true
	for thread in threads:
		parallel_exact = bool(thread.wait_to_finish()) and parallel_exact
	checks["shared_instance_parallel_exact"] = parallel_exact
	checks["parallel_cache_bounds"] = current._site_memo.size()<=Current.MEMO_LIMIT and current._climate_memo.size()<=Current.MEMO_LIMIT
	var file := FileAccess.open(OS.get_environment("BIOME_MEMO_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed":not checks.values().has(false),"checks":checks,"samples":count,"oldUsec":old_usec,"newUsec":new_usec,"scope":"Pure biome differential, clustered and distant points, multiple seeds and cache eviction; not gameplay acceptance."},"\t"));file.close()
	quit(1 if checks.values().has(false) else 0)

func _parallel_compare(current, old, worker: int) -> bool:
	for i in range(2000):
		var seed := "parallel-%d" % (i%3)
		var point := Vector2((i-1000)*6100.0,(worker-2)*6000.0)
		if var_to_bytes(current.sample(seed,point))!=var_to_bytes(old.sample(seed,point)): return false
	return true
