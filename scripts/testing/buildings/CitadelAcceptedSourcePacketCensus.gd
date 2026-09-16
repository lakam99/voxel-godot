extends SceneTree
## Read-only packet eligibility census over a headed runner's accepted source.
## This diagnostic does not generate, publish, render, route, or mutate a world.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")

func _initialize() -> void:
	var input_path := OS.get_environment("CITADEL_ACCEPTED_SOURCE_INPUT")
	var output_path := OS.get_environment("CITADEL_ACCEPTED_SOURCE_CENSUS_REPORT")
	if not input_path.is_absolute_path() or not FileAccess.file_exists(input_path) or not output_path.is_absolute_path():
		quit(2)
		return
	var file := FileAccess.open(input_path,FileAccess.READ)
	var source: Variant = file.get_var(false) if file!=null else null
	if file!=null: file.close()
	var report := {"schema":"citadel-frozen-source-packet-census/v2","passed":false,
		"evidenceLevel":"frozen source packet census only; no generation, publication, rendering, NavigationServer acknowledgement, movement, or gameplay acceptance",
		"input":{"path":input_path,"sha256":FileAccess.get_sha256(input_path)},"checks":{}}
	var binding: Dictionary = source.get("binding",{}) if source is Dictionary else {}
	if source is Dictionary:
		report["sourceKeys"]=source.keys()
		for profile_key: String in ["profile","publicationProfile","placementProfile"]:
			if source.has(profile_key): report[profile_key]=source[profile_key]
	var direct_recipe_source := source is Dictionary and source.get("blueprint") is Dictionary \
		and source.get("furnishingPlan") is Dictionary and binding.is_empty()
	if direct_recipe_source:
		# Recipe diagnostics predate site admission and therefore intentionally have
		# no runtime ownership binding. Supply a diagnostic-only identity derived
		# from this immutable file; it cannot be confused with a live generation.
		binding={"siteId":"source-census:"+String(source.blueprint.get("id","citadel")),
			"sourceKey":FileAccess.get_sha256(input_path),"generation":1}
	report.checks.source_shape=source is Dictionary and source.get("blueprint") is Dictionary \
		and source.get("furnishingPlan") is Dictionary and Preparation.valid_binding(binding)
	report["sourceFormat"]="direct_recipe_diagnostic" if direct_recipe_source else "admitted_runtime_source"
	if report.checks.source_shape:
		var building: Dictionary=source.blueprint.duplicate(true)
		var furnishing: Dictionary=source.furnishingPlan.duplicate(true)
		if direct_recipe_source and not furnishing.has("accessReservations"):
			furnishing["accessReservations"]=source.get("accessReservations",[]).duplicate(true)
		building.make_read_only()
		furnishing.make_read_only()
		var origin:=Vector3.ZERO
		var origin_fields:=OS.get_environment("CITADEL_ACCEPTED_SOURCE_ORIGIN").split(",",false)
		var valid_origin:=origin_fields.size()==3
		for field: String in origin_fields: valid_origin=valid_origin and field.is_valid_float()
		if valid_origin:
			origin=Vector3(float(origin_fields[0]),float(origin_fields[1]),float(origin_fields[2]))
		report["publicationOrigin"]=origin
		var base_result:=Preparation.prepare_publication_base(building,furnishing,binding,{"origin":origin})
		report.checks.base_ready=base_result.get("ready",false)
		report["baseReason"]=base_result.get("reason","")
		if report.checks.base_ready:
			var base=base_result.base
			var requested_groups:=OS.get_environment("CITADEL_ACCEPTED_SOURCE_GROUP_IDS").split(";",false)
			if not requested_groups.is_empty():
				var dependency_windows: Array[Dictionary]=[]
				for group_id: String in requested_groups:
					var window: Dictionary=base.publication_plan.dependency_window(group_id,{})
					dependency_windows.append({"groupId":group_id,"status":window.get("status",""),
						"reason":window.get("reason",""),"groupCount":window.get("groupIds",[]).size(),
						"groupIds":window.get("groupIds",[])})
				report["requestedDependencyWindows"]=dependency_windows
			var nav_tile:=OS.get_environment("CITADEL_ACCEPTED_SOURCE_NAV_TILE")
			if not nav_tile.is_empty():
				var nav_result:=Preparation.prepare_navigation_source(base,binding)
				var nav_probe:={"requestedTile":nav_tile,"sourceReady":nav_result.get("ready",false),
					"reason":nav_result.get("reason","")}
				if nav_result.get("ready",false):
					var producer=nav_result.navigationSource.producer
					producer.request(nav_tile)
					var nav_selection: Array[String]=[nav_tile]
					for index in range(10000):
						var receipt: Dictionary=producer.take(nav_tile)
						if receipt.get("status") in ["ready","failed","cancelled"]: break
						producer.advance(4000,Callable(),nav_selection)
					var receipt: Dictionary=producer.take(nav_tile)
					nav_probe["receiptStatus"]=receipt.get("status","")
					nav_probe["receiptReason"]=receipt.get("reason","")
					var tile: Dictionary=receipt.get("tile",{})
					nav_probe["requiredCrossingIds"]=tile.get("requiredCrossingIds",[])
					nav_probe["crossingLinkIds"]=tile.get("crossingLinks",[]).map(func(link):return String(link.get("id","")))
				report["navigationTileProbe"]=nav_probe
			var ground_course_parts: Array[Dictionary]=[]
			var egress_parts: Array[Dictionary]=[]
			for part_value in building.get("parts",[]):
				if not part_value is Dictionary: continue
				var part: Dictionary=part_value
				var recipe: Variant=part.get("recipe",{})
				if String(part.get("semantic","")) in ["castle_courtyard_foundation","castle_courtyard_paving"]:
					ground_course_parts.append({"id":part.get("id",""),"position":part.get("position"),
						"size":part.get("size"),"collision":part.get("collision",false),"recipe":recipe})
				if recipe is Dictionary and not String(recipe.get("doorEgressFor","")).is_empty():
					egress_parts.append({"id":part.get("id",""),"kind":part.get("kind",""),
						"position":part.get("position"),"rotation":part.get("rotation",Vector3.ZERO),
						"size":part.get("size"),"doorEgressFor":recipe.get("doorEgressFor","")})
			ground_course_parts.sort_custom(func(a: Dictionary,b: Dictionary)->bool:return String(a.id)<String(b.id))
			egress_parts.sort_custom(func(a: Dictionary,b: Dictionary)->bool:return String(a.id)<String(b.id))
			report["groundCourse"]={"parts":ground_course_parts,"egressParts":egress_parts}
			var unresolved_doors: Array[Dictionary]=[]
			for door: Dictionary in base.description.navigation.get("doors",[]):
				if not bool(door.get("sourcePortalReady",false)):
					unresolved_doors.append({"id":door.get("id",""),"sourcePartId":door.get("sourcePartId",""),
						"ownerTileKey":door.get("ownerTileKey",""),"portalSupportResolution":door.get("portalSupportResolution",{}),
						"doorEgress":door.get("doorEgress",{}),"egressResolution":door.get("egressResolution",{})})
			var unresolved_vertical: Array[Dictionary]=[]
			var vertical_links: Array[Dictionary]=[]
			for link: Dictionary in base.description.navigation.get("verticalLinks",[]):
				vertical_links.append({"id":link.get("id",""),"sourcePartId":link.get("sourcePartId",""),
					"ownerTileKey":link.get("ownerTileKey",""),"tileKeys":link.get("tileKeys",[]),
					"startSupportPartId":link.get("startSupportPartId",""),
					"endSupportPartId":link.get("endSupportPartId",""),
					"endpointCertification":link.get("endpointCertification",{})})
				if not bool(link.get("endpointCertification",{}).get("resolved",false)):
					unresolved_vertical.append({"id":link.get("id",""),"sourcePartId":link.get("sourcePartId",""),
						"ownerTileKey":link.get("ownerTileKey",""),"startSupportPartId":link.get("startSupportPartId",""),
						"endSupportPartId":link.get("endSupportPartId",""),"endpointCertification":link.get("endpointCertification",{})})
			var support_seam_links: Array[Dictionary]=[]
			for link: Dictionary in base.description.navigation.get("supportSeamLinks",[]):
				support_seam_links.append(link.duplicate(true))
			report["navigationManifest"]={"doorCount":base.description.navigation.get("doors",[]).size(),
				"verticalLinkCount":base.description.navigation.get("verticalLinks",[]).size(),
				"unresolvedDoors":unresolved_doors,"unresolvedVerticalLinks":unresolved_vertical,
				"verticalLinks":vertical_links,"supportSeamLinks":support_seam_links}
			report.checks.doors_resolved=unresolved_doors.is_empty()
			report.checks.vertical_links_resolved=unresolved_vertical.is_empty()
			var census: Dictionary=base.packet_eligibility
			report.checks.census_ready=census.get("ready",false)
			var blocked: Array[Dictionary]=[]
			var eligible:=0
			var reasons: Dictionary={}
			for group_id: String in base.description.publication_groups.groups:
				var entry: Dictionary=census.groups.get(group_id,{})
				if entry.get("eligible",false):
					eligible+=1
					continue
				var group: Dictionary=base.description.publication_groups.groups[group_id]
				for reason: String in entry.get("reasons",[]): reasons[reason]=int(reasons.get(reason,0))+1
				blocked.append({"groupId":group_id,"reasons":entry.get("reasons",[]),"families":entry.get("families",[]),
					"buildingIndices":group.get("buildingIndices",[]),"furnitureIndices":group.get("furnitureIndices",[]),
					"treeIndices":group.get("treeIndices",[]),"dependencies":group.get("dependencies",[]),
					"bounds":group.get("bounds",AABB()),"collisionBounds":group.get("collisionBounds",AABB())})
			report["counts"]={"groups":base.description.publication_groups.groups.size(),"eligible":eligible,"blocked":blocked.size(),
				"buildingParts":building.get("parts",[]).size(),"furnishingParts":furnishing.get("parts",[]).size()}
			report["blockedReasons"]=reasons
			report["blockedGroups"]=blocked
			var probe_fields:=OS.get_environment("CITADEL_ACCEPTED_SOURCE_LOCAL_PROBE").split(",",false)
			var probe_valid:=probe_fields.size()==3
			for probe_field in probe_fields: probe_valid=probe_valid and String(probe_field).is_valid_float()
			if probe_valid:
				var probe:=Vector3(float(probe_fields[0]),float(probe_fields[1]),float(probe_fields[2]))
				var nearby: Array[Dictionary]=[]
				for part_value in building.get("parts",[]):
					if not part_value is Dictionary: continue
					var part: Dictionary=part_value
					var size: Variant=part.get("size")
					var position: Variant=part.get("position")
					var rotation: Variant=part.get("rotation",Vector3.ZERO)
					if not size is Vector3 or not position is Vector3 or not rotation is Vector3: continue
					var bounds:=Transform3D(Basis.from_euler(rotation),position)*AABB(-size*0.5,size)
					var horizontal:=Rect2(Vector2(bounds.position.x,bounds.position.z)-Vector2.ONE,
						Vector2(bounds.size.x,bounds.size.z)+Vector2.ONE*2.0)
					if horizontal.has_point(Vector2(probe.x,probe.z)) and probe.y>=bounds.position.y-2.0 and probe.y<=bounds.end.y+2.0:
						nearby.append({"id":part.get("id",""),"kind":part.get("kind",""),"semantic":part.get("semantic",""),
							"material":part.get("material",part.get("materialId","")),"collision":part.get("collision",false),
							"bounds":bounds,"recipe":part.get("recipe",{})})
				report["probe"]={"localPosition":probe,"nearbyParts":nearby}
	report.passed=report.checks.values().all(func(value): return value==true)
	var output_file:=FileAccess.open(output_path,FileAccess.WRITE)
	if output_file==null:
		quit(2)
		return
	output_file.store_string(JSON.stringify(report,"  ",true,true))
	output_file.flush()
	var saved:=output_file.get_error()==OK
	output_file.close()
	print("CITADEL ACCEPTED SOURCE PACKET CENSUS ",JSON.stringify(report.get("counts",{})))
	quit(0 if saved and report.passed else 1)
