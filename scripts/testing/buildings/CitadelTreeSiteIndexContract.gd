extends SceneTree
const Composer = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var path := "res://artifacts/citadel-runtime-integration/landscape-cancellation-baseline-01/baseline.bin"
	if FileAccess.get_sha256(path)!="89afc07894548b0541cdc6919be0825c8c2c4e1b1929846839cbf0e1b9640ee1": quit(2); return
	var frozen: Dictionary=FileAccess.open(path,FileAccess.READ).get_var(false)
	var old_path:="res://artifacts/citadel-runtime-integration/landscape-cancellation-baseline-01/FrozenComposer.gd"
	if FileAccess.get_sha256(old_path)!="ff43d1ad151527c86b123e8db728d160094ff1b15ae4ae08ec8ae32d75402123": quit(2); return
	var old=load(old_path)
	var b=Copy.copy_blueprint(frozen.treeInput)
	var before:=var_to_bytes(b.snapshot())
	var started:=Time.get_ticks_usec()
	var expected: Array=old.select_open_paving_tree_sites(b,int(frozen.seed))
	var baseline_usec:=Time.get_ticks_usec()-started
	started=Time.get_ticks_usec()
	var actual:=Composer.select_open_paving_tree_sites(b,int(frozen.seed))
	var candidate_usec:=Time.get_ticks_usec()-started
	var checks: Dictionary={"historical_exact":var_to_bytes(expected)==var_to_bytes(actual),"input_unchanged":before==var_to_bytes(b.snapshot())}
	var fixture:=Blueprint.new()
	fixture.add_part({"id":"paving-first","kind":"foundation","material":"cobblestone","position":Vector3(0,2,0),"size":Vector3(24,1,24),"semantic":"citadel_market_plaza"})
	fixture.add_part({"id":"paving-second","kind":"foundation","material":"cobblestone","position":Vector3(0,5,0),"size":Vector3(24,1,24),"semantic":"citadel_market_plaza"})
	for i in range(5):
		fixture.add_part({"id":"obstacle-%d"%i,"kind":"wall" if i!=3 else "floor","material":"cobblestone" if i==1 else "stone_foundation","position":Vector3(i*3-6,3,0),"size":Vector3(1,0.1 if i==2 else 3,1),"recipe":{"visual":i!=4}})
	var index=Composer._tree_site_index(fixture)
	var equal:=true
	for x in [-12.01,-12.0,-8.0,-6.0,-4.1,-3.0,0.0,0.5,1.22,1.9,3.0,6.0,8.0,12.0,12.01]:
		for z in [-12.0,-8.0,-1.9,-0.5,0.0,0.5,1.9,8.0,12.0]:
			var p:=Vector3(x,3,z)
			equal=equal and index.site_open(p)==old.tree_site_is_open(fixture,p) and index.sample_open(p)==old.tree_paving_sample_is_open(fixture,p) and index.surface_at(p)==old.primary_paving_surface_at(fixture,p) and index.clear_run(p)==old.tree_site_has_clear_paving_run(fixture,p)
	checks["boundaries_filters_and_paving_order"]=equal
	fixture.add_part({"id":"oversized","kind":"wall","size":Vector3(2000000,3,2000000),"position":Vector3(0,3,0)})
	index=Composer._tree_site_index(fixture)
	for x in [0.0,1000000.0,2000000.0]:
		var point:=Vector3(x,3,0)
		checks["overflow_%s"%x]=not index.sites.overflow.is_empty() and index.site_open(point)==old.tree_site_is_open(fixture,point) and index.sample_open(point)==old.tree_paving_sample_is_open(fixture,point)
	checks["empty_selection"]=Composer.select_open_paving_tree_sites(Blueprint.new(),1).is_empty()
	for stage in ["landscape_tree_candidate","landscape_tree_selection_completed"]:
		var changed=Copy.copy_blueprint(frozen.treeInput)
		var status: Dictionary={}
		var sites:=Composer.select_open_paving_tree_sites(changed,int(frozen.seed),func(label):
			if label==stage: changed.parts[0].position.x+=1
			return true,status)
		checks["mutation_"+stage]=sites.is_empty() and status.get("reason")=="tree_selection_source_changed"
	for stage in ["landscape_tree_selection_started","landscape_tree_candidate","landscape_tree_sort_started","landscape_tree_spacing","landscape_tree_selection_completed"]:
		var trace: Dictionary={"stopped":false,"late":0}
		var sites:=Composer.select_open_paving_tree_sites(b,int(frozen.seed),func(label):
			if trace.stopped: trace.late+=1
			if label==stage: trace.stopped=true; return false
			return true)
		checks["cancel_"+stage]=trace.stopped and trace.late==0 and sites.is_empty() and var_to_bytes(b.snapshot())==before
	var output:=FileAccess.open(OS.get_environment("TREE_SITE_INDEX_REPORT"),FileAccess.WRITE)
	output.store_string(JSON.stringify({"passed":not checks.values().has(false),"checks":checks,"baselineUsec":baseline_usec,"candidateUsec":candidate_usec,"scope":"Historical source selection parity and synthetic query/cancellation controls; no gameplay acceptance."},"\t"));output.close()
	quit(1 if checks.values().has(false) else 0)
