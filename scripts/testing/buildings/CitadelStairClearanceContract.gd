extends SceneTree
## Producer/physics contract. No live-world or player traversal acceptance.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
var checks := {}
var evidence := {}
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("CITADEL_STAIR_REPORT")
	if not output.is_absolute_path(): quit(2); return
	var full_source_path := "res://artifacts/citadel-runtime-integration/candidate-recipe-25/source.bin"
	checks.composed_keep_source_pinned=FileAccess.get_sha256(full_source_path)=="3a324e02b9c61d5249ea97b119caed19a98bce3d0158ec8d0f23c113682dc34f"
	if not checks.composed_keep_source_pinned: quit(2); return
	var full_source: Dictionary=FileAccess.open(full_source_path,FileAccess.READ).get_var(false)
	for spec in [{"id":"keep", "width":4.3,"depth":6.4,"base":4.42,"rise":3.457142857,"levels":2}, {"id":"gatehouse","width":2.38,"depth":7.84,"base":0.82,"rise":3.0,"levels":4}, {"id":"castle_keep_stair","width":4.3,"composed":true}]:
		var b = Blueprint.new(spec.id,1,"stone")
		if spec.get("composed",false):
			var recipe: Dictionary=full_source.blueprint.recipe
			var g: Dictionary=recipe.compound.castleGrammar
			var center := Vector3(0,0,float(g.courtyardDepth)*float(g.keepOffset.z))
			checks.composed_keep_generated=Castle.add_keep(b,center,minf(g.keepWidth,g.courtyardWidth-g.towerSpan*2.5),minf(g.keepDepth,g.courtyardDepth-g.towerSpan*2.5),g.keepHeight,recipe.keepStoreyCount,recipe.keepFloorHeight,0.62+Castle.citadel_keep_terrace_elevation(g),float(int(recipe.compound.seed)%19)/100.0-0.09,g.citadelMasonry.fortification,g.palaceGrammar)
			var banners: Array = b.parts.filter(func(p): return p.id == "castle_keep_banner")
			var old_banners: Array = full_source.blueprint.parts.filter(func(p): return p.id == "castle_keep_banner")
			checks.composed_keep_banner_preserved = banners.size() == 1 and old_banners.size() == 1 and not banners[0].collision_enabled and banners[0].position.is_equal_approx(old_banners[0].position) and banners[0].size.is_equal_approx(old_banners[0].size)
		else:
			Castle.add_switchback_stair_flights(b,spec.id,Vector3.ZERO,spec.width,spec.depth,spec.base,spec.rise,spec.levels,"stone_foundation",0.0,spec.id)
			var physical: Dictionary = b.validate_physical_integrity()
			checks[spec.id+"_physical"] = physical.passed
			evidence[spec.id+"_physical_failures"] = physical.get("violations",[])
		var world := Node3D.new()
		root.add_child(world)
		var pub := Publisher.new()
		var correspondence := true
		for part in b.parts:
			var body: StaticBody3D = pub.publish_part(part,world)
			if body==null: correspondence=false; continue
			if part.collision_enabled:
				var shapes := body.find_children("*","CollisionShape3D",true,false).filter(func(shape):return shape.get_parent()==body)
				correspondence = correspondence and shapes.size()==1 and shapes[0].shape.size==part.size and shapes[0].global_transform.is_equal_approx(b.part_transform(part))
		checks[spec.id+"_published_collision_matches"] = correspondence
		await physics_frame
		await physics_frame
		var capsule := CapsuleShape3D.new()
		capsule.radius=0.42; capsule.height=1.72
		var lateral: float = minf(spec.width*0.20,maxf(0.34,spec.width*0.5-clampf(spec.width*0.30,0.70,1.10)*0.60))
		for part in b.parts:
			if not (part.semantic==spec.id+"_landing" or part.semantic==spec.id+"_exit"): continue
			var collisions := []
			for x: float in [-lateral,0.0,lateral]:
				var expected: Vector3=part.position+Vector3(x,part.size.y*0.5,0)
				var support := world.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(expected+Vector3.UP*0.24,expected-Vector3.UP*0.24))
				if support.is_empty(): collisions.append("missing_walkable_support"); continue
				var query := PhysicsShapeQueryParameters3D.new()
				query.shape=capsule
				# A capsule rests above an inclined plane by r*(sec(angle)-1).
				# Testing its flat-floor pose would intersect its intended ramp.
				var slope_lift: float=capsule.radius*(1.0/maxf(support.normal.y,0.01)-1.0)
				query.transform=Transform3D(Basis.IDENTITY,support.position+Vector3.UP*(capsule.height*0.5+slope_lift+0.02))
				for hit in world.get_world_3d().direct_space_state.intersect_shape(query,32):
					collisions.append(String(hit.collider.get_meta("building_part_id","unknown")))
			checks[part.id+"_standing_and_turning_clear"] = collisions.is_empty()
			evidence[part.id+"_blockers"] = collisions
		world.free(); pub.published_nodes.clear()
		# Real physical-validator negative controls for the revised two-seat frame.
		for fault in ["missing","duplicate","floating","outside_patch"]:
			var test = Blueprint.new("negative",1,"stone")
			Castle.add_stair_landing_frame(test,"frame","post",Vector3.ZERO,3.0,2.2,"stone_foundation",0.0,"test")
			var frame = test.parts.back()
			match fault:
				"missing": frame.recipe.physicalRequiredSeatFacts.pop_back()
				"duplicate": frame.recipe.physicalRequiredSeatFacts[1]=frame.recipe.physicalRequiredSeatFacts[0].duplicate(true)
				"floating": test.parts[0].position.y+=1.0
				"outside_patch": frame.recipe.physicalRequiredSeatFacts[0].localPatchCenter.x=0.0
			checks[spec.id+"_reject_"+fault] = not test.validate_physical_integrity().passed
	for has_lane in [false,true]:
		var house = Blueprint.new("dressing",1,"timber")
		Urban.reset_street_house_structural_manifest(house)
		checks["dressing_house_"+str(has_lane)] = Urban.add_street_house(house,"urban_row_03_left",Vector3.ZERO,8.0,10.0,7.2,1.0,3.9,"painted_brick_cream",0.0)
		if has_lane: Urban.add_grounded_foundation(house,"lane",Vector3(6,0,0),6.4,12.0,3.9,0.0,"citadel_upper_lane")
		Urban.settle_household_ground_dressing(house)
		var dressing: Array = house.parts.filter(func(p): return p.semantic in ["citadel_household_storage","citadel_household_firewood"])
		checks["supported_dressing_retained" if has_lane else "unsupported_dressing_rejected"] = not dressing.is_empty() if has_lane else dressing.is_empty()
		checks["no_residential_market_"+str(has_lane)] = house.parts.all(func(p): return not p.semantic in ["citadel_shopfront","citadel_shopfront_goods"])
	var old_path := "res://artifacts/citadel-runtime-integration/candidate-recipe-23/source.bin"
	checks.old_source_pinned=FileAccess.get_sha256(old_path)=="d42e865f39b5142e7e1582f566858b1c997364b31100c54fd072b956e18db70e"
	if checks.old_source_pinned:
		var old: Dictionary=FileAccess.open(old_path,FileAccess.READ).get_var(false)
		var by_id := {}
		for part in old.blueprint.parts: by_id[part.id]=part
		var exit_part: Dictionary=by_id.castle_keep_stair_exit_00
		var pier: Dictionary=by_id.castle_keep_stair_exit_pier_01
		var capsule_bounds := AABB(exit_part.position+Vector3(-0.42,exit_part.size.y*0.5+0.01,-0.42),Vector3(0.84,1.72,0.84))
		checks.captured_lower_exit_blockage_rejected=AABB(pier.position-pier.size*0.5,pier.size).intersects(capsule_bounds)
		var stair: Dictionary=by_id.urban_street_climb_225_07
		var sample: Vector3=stair.position+Vector3(0,stair.size.y*0.5,stair.size.z*0.5+0.1)
		var support_y := -INF
		for part in old.blueprint.parts:
			if not part.collision or part.rotation!=Vector3.ZERO: continue
			var box: AABB=AABB(part.position-part.size*0.5,part.size)
			if sample.x>box.position.x and sample.x<box.end.x and sample.z>box.position.z and sample.z<box.end.z and box.end.y<=sample.y+0.01: support_y=maxf(support_y,box.end.y)
		checks.captured_street_drop_rejected=sample.y-support_y>1.4
		evidence.captured_street_drop=sample.y-support_y
	var passed := not checks.values().has(false)
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify({"passed":passed,"checks":checks,"evidence":evidence,"scope":"Producer, physical-validator and published collision contract. No world streaming or live player traversal acceptance."},"\t")); file.close()
	quit(0 if passed else 1)
