extends SceneTree

## Exact accepted-source CPU cut inventory; never scene or gameplay acceptance.
const Source = preload("res://scripts/buildings/BuildingPublicationSource.gd")
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Cuts = preload("res://scripts/buildings/MasonryApertureGeometry.gd")
const Publication = preload("res://scripts/buildings/MasonryAperturePublication.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate-recipe-23/source.bin"
const SHA := "d42e865f39b5142e7e1582f566858b1c997364b31100c54fd072b956e18db70e"

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("CITADEL_APERTURE_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.get_sha256(INPUT)!=SHA: quit(2); return
	var deadline := Time.get_ticks_msec()+90000
	var source: Dictionary=FileAccess.open(INPUT,FileAccess.READ).get_var(false)
	var furniture: Dictionary=source.furnishingPlan.duplicate(true)
	furniture.accessReservations=source.accessReservations.duplicate(true)
	var restored := Source.restore(source.blueprint,furniture)
	if not restored.ready: print("RESTORE FAILED: ",restored.reason); quit(2); return
	var blueprint=restored.blueprint
	var publisher=Publisher.new()
	publisher.source_blueprint_id=publisher.canonical_source_blueprint_id(blueprint)
	publisher.surface_history.configure(blueprint.recipe,blueprint.parts)
	var rows: Array=[]
	var examples: Array=[]
	var failures: Dictionary={}
	var precision_rows: Array=[]
	var bricks := 0
	var vertices := 0
	var fragments := 0
	var work := 0
	var expected := 0
	for part in blueprint.parts:
		if part.recipe.has("masonryApertureSource"): expected+=1
	for part in blueprint.parts:
		if not part.recipe.has("masonryApertureSource"): continue
		if Time.get_ticks_msec()>=deadline: break
		var volumes: Array[AABB]=[]
		for opening in blueprint.recipe.facadeApertures[part.recipe.masonryApertureSource].openings:
			volumes.append(opening.fullVolume)
		var geometry: Dictionary=publisher.describe_masonry(part)
		var solids: Array=publisher.masonry_brick_solids(part,geometry)
		var reasons: Dictionary={}
		var checked := 0
		for solid: Dictionary in solids:
			if Time.get_ticks_msec()>=deadline: break
			var result := Cuts.prepare([solid],volumes,publisher.unit_box)
			bricks+=1; checked+=1
			if result.ready:
				vertices+=int(result.vertexCount)
				work+=int(result.clippingWork)+int(result.verificationWork)
				for entry in result.entries: fragments+=entry.cells.size()
			if not result.ready:
				var reason := String(result.reason)
				var raw := Cuts.Cut.subtract_boxes([solid],volumes)
				var planes: Array=[]
				for aperture: AABB in volumes:
					var low: Vector3 = aperture.position-solid.transform.origin
					var high: Vector3 = aperture.end-solid.transform.origin
					var translated := AABB(low,high-low)
					for axis in range(3):
						planes.append({"axis":axis,"origin":float(solid.transform.origin[axis]),"declaredLow":float(aperture.position[axis]),"declaredHigh":float(aperture.end[axis]),"low":float(low[axis]),"high":float(high[axis]),"reconstructedHigh":float(translated.end[axis])})
				precision_rows.append({"partId":part.id,"solidId":solid.id,"planes":planes,"originalFrameCompleted":raw.get("completed",false),"originalFrameReason":raw.get("reason",""),"originalFrameChanged":raw.get("entries",[]).any(func(entry):return not entry.unchanged)})
				if not failures.has(reason) or examples.size()<8:
					examples.append({"partId":part.id,"solid":solid,"apertures":volumes,"reason":reason,"diagnostic":result.get("diagnostic",{})})
				failures[reason]=int(failures.get(reason,0))+1
				reasons[reason]=int(reasons.get(reason,0))+1
			if bricks%128==0: await process_frame
		rows.append({"partId":part.id,"bricks":solids.size(),"checked":checked,"failures":reasons})
		await process_frame
	var complete := rows.size()==expected and rows.all(func(row):return row.checked==row.bricks)
	var unchanged := FileAccess.get_sha256(INPUT)==SHA
	var within_limits := expected<=Publication.MAX_PARTS and bricks<=Publication.MAX_BRICKS and vertices<=Publication.MAX_VERTICES and fragments<=Publication.MAX_FRAGMENTS and work<=Publication.MAX_WORK
	var binary := FileAccess.open(output.get_base_dir().path_join("failures.bin"),FileAccess.WRITE)
	binary.store_var(examples,false); binary.flush(); var binary_ok := binary.get_error()==OK; binary.close()
	var report := {"passed":complete and unchanged and binary_ok,"checks":{"complete_inventory":complete,"source_unchanged":unchanged,"examples_written":binary_ok},
		"constructionReady":complete and failures.is_empty() and within_limits,"withinPublicationLimits":within_limits,"vertices":vertices,"fragments":fragments,"work":work,
		"expectedParts":expected,"bricks":bricks,"failures":failures,"rows":rows,"precision":precision_rows,"exampleCount":examples.size(),"sourceSha256":SHA,
		"scope":"Exact accepted-source CPU aperture inventory; failures remain production blockers. A completed diagnostic is not construction or gameplay acceptance."}
	var file := FileAccess.open(output,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "));file.flush();var written := file.get_error()==OK;file.close()
	quit(0 if report.passed and written else 1)
