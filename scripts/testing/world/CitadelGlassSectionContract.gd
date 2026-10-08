extends "res://scripts/testing/world/CitadelSectionGeometryServiceContract.gd"
## Synthetic admitted census; real window publisher, service, assembler and GPU
## frame callbacks. No traversal or ordinary startup acceptance is claimed.
const GlassAdapter := preload("res://scripts/world/CitadelSectionGeometryAdapter.gd")
const GlassPreparation := preload("res://scripts/world/StaticTranslucentMeshPreparation.gd")

class GlassService extends FixtureService:
	func capture_static_section_sources(_world_id: String, sections: Array) -> Dictionary:
		var result := census_fixture.duplicate(true)
		var selected: Dictionary = {}
		for section: Vector3i in sections:
			if not result.sections.has(section): return {"status":"pending", "reason":"fixture_section_not_admitted"}
			selected[section] = result.sections[section]
		result["sections"] = selected
		return result

func run() -> void:
	var scene := AttachmentScene.new()
	root.add_child(scene)
	current_scene = scene
	var coordinator := Coordinator.new()
	scene.world_static_section_coordinator = coordinator
	coordinator.configure("glass-section-contract")
	coordinator.configure_source_roster(["blueprint_buildings"])
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.position = Vector3(9,6,13)
	camera.look_at(Vector3(21.4,4,4))
	camera.current = true
	coordinator.refresh_visible_section_demand_priorities(camera.global_position)
	var parent := Node3D.new()
	scene.add_child(parent)
	var publisher := BuildingPublisher.new()
	publisher.unit_box = BoxMesh.new()
	publisher.source_blueprint_id = "glass-section-contract"
	publisher.publication_site_id = "glass-service"
	publisher._scene_parent = weakref(parent)
	var part := BuildingPart.new({"id":"urban_perimeter_west_00_projecting_bay_window", "kind":"window",
		"material":"window_glass", "position":Vector3(SectionGrid.SECTION_SIZE_METERS-0.08,4,4),
		"size":Vector3(1.8,2.2,0.18), "collision":true, "recipe":{"visual":true}})
	publisher.publish_static_part(part,parent)
	publisher._record_completed_source_part(part)
	publisher._begin_static_flush(parent,false)
	for turn in range(1024):
		if not publisher.has_pending_static_flush(): break
		publisher.advance_static_flush(parent,1000)
	var revision := Preparation.static_record_binding(part.snapshot())
	var captured: Dictionary = publisher.capture_committed_static_visual_source(part.id,revision)
	check("actual_window_capture",captured.get("status")=="ready",captured)
	var section := SectionGrid.key_for_world_position(part.position)
	var neighbor := section+Vector3i.RIGHT
	var source := "citadel:glass-service:member:building:"+part.id
	var service := GlassService.new()
	service.owner_fixture = {"status":"ready","publisher":publisher,"sourceToWorld":parent.global_transform}
	var binding := {"siteId":"glass-service", "generation":1}
	service.visual_plan = FixtureVisualPlan.new()
	service.visual_plan.binding = binding
	service.visual_plan.visual_source_revisions = {part.id:revision}
	service.visual_plan.visual_source_revisions.make_read_only()
	var admission := FixtureAdmission.new()
	admission.binding = binding
	service._admission = admission
	service._scenes = {Vector2i.ZERO:{"binding":binding,"packetMode":false,"phase":"scene_ready",
		"job":{"_building":publisher},"profile":{"origin":parent.global_position}}}
	service.census_fixture = {"status":"complete", "worldId":"glass-section-contract", "authorityRevision":"glass-authority",
		"sourceRevisions":{source:"glass-source-v1"}, "sections":{
		section:{"status":"complete","coverageRevision":"glass-coverage","sourcePartIds":[source]},
		neighbor:{"status":"complete","coverageRevision":"glass-coverage","sourcePartIds":[source]}}}
	coordinator.register_source_provider("blueprint_buildings",service,"capture_static_section_sources")
	var census: Dictionary = coordinator.capture_authoritative_source_census([section])
	GlassPreparation.clear_cache()
	var started := Time.get_ticks_usec()
	var capture: Dictionary = service.capture_static_section_contribution(census,section)
	var elapsed := Time.get_ticks_usec()-started
	var bake_usec := 0
	var cache_evidence: Dictionary = {}
	for group: Dictionary in captured.get("groups",[]):
		if group.get("renderLayer") == "translucent":
			var pov := coordinator.current_translucent_pov_snapshot(section)
			var warm := GlassPreparation.prepare(group,pov)
			GlassPreparation.clear_cache()
			var cold := GlassPreparation.prepare(group,pov)
			var cached := GlassPreparation.prepare(group,pov)
			var other_pov := pov.duplicate()
			other_pov["cameraPosition"] = part.position + Vector3(100,100,100)
			other_pov["revision"] = 27
			var resort := GlassPreparation.prepare(group,other_pov)
			bake_usec = int(cold.get("bakeUsec",0))
			cache_evidence = {"cold":cold.get("phases",{}),"coldUsec":bake_usec,
				"warm":warm.get("phases",{}),"warmUsec":warm.get("bakeUsec"),
				"cached":cached.get("phases",{}),"cachedUsec":cached.get("bakeUsec"),
				"resort":resort.get("phases",{}),"resortUsec":resort.get("bakeUsec"),
				"cache":GlassPreparation.cache_diagnostics()}
			check("glass_cache_reuses_completed_same_pov_mesh",cached.get("status")=="ready"
				and cached.get("phases",{}).get("sortedHits",0)==1
				and is_same(cold.groups[0].mesh,cached.groups[0].mesh),cache_evidence)
			check("glass_resort_reuses_canonical_arrays",resort.get("status")=="ready"
				and resort.get("phases",{}).get("canonicalHits",0)==1
				and not is_same(cold.groups[0].mesh,resort.groups[0].mesh),cache_evidence)
			GlassPreparation.clear_cache()
			check("glass_cache_clear_preserves_candidate_resources",
				is_instance_valid(cold.groups[0].mesh)
				and GlassPreparation.cache_diagnostics().entryCount==0,{})
	check("glass_service_contribution",capture.get("status")=="ready",{"capture":capture,"prepareUsec":elapsed})
	if capture.get("status")=="ready":
		var contributions: Array = [capture.contribution]
		contributions.make_read_only()
		var assembled := Assembler.assemble(census,section,contributions,1)
		check("glass_candidate_assembled",assembled.get("status")=="ready",assembled)
		var translucent_batches := 0
		if assembled.get("status")=="ready":
			for batch: Dictionary in assembled.candidate.candidate.snapshot.batches.values():
				if batch.renderLayer=="translucent":
					translucent_batches += 1
					check("glass_descriptor_real_quad_coverage",batch.translucentSortDescriptor.surfaces[0].faceGroups.size()==6, {})
					var bad_batch := batch.duplicate(false)
					var bad_descriptor: Dictionary = batch.translucentSortDescriptor.duplicate(false)
					var bad_surfaces: Array[Dictionary] = []
					for surface: Dictionary in bad_descriptor.surfaces:
						var bad_surface := surface.duplicate(false)
						var bad_groups: Array[Dictionary] = []
						for face: Dictionary in surface.faceGroups:
							var bad_face := face.duplicate(false)
							bad_face["centroid"] = face.centroid+Vector3(0.2,0,0)
							bad_face.make_read_only()
							bad_groups.append(bad_face)
						bad_groups.make_read_only()
						bad_surface["faceGroups"] = bad_groups
						bad_surface.make_read_only()
						bad_surfaces.append(bad_surface)
					bad_surfaces.make_read_only()
					bad_descriptor["surfaces"] = bad_surfaces
					bad_descriptor.make_read_only()
					bad_batch["translucentSortDescriptor"] = bad_descriptor
					var validation := InstallSession.new()._validate_translucent_sort_descriptor(bad_batch,
						assembled.candidate.meshBindings[batch.meshKey],section,1)
					check("malformed_glass_sort_rejected",validation.get("reason")=="section_translucent_face_group_centroid_mismatch",validation)
			check("glass_keeps_translucent_layer",translucent_batches==1,{})
			var legacy: Array = Service._published_legacy_geometry(publisher)
			var submitted: Dictionary = coordinator.submit_complete_section_candidate(assembled.candidate)
			var outcome: Dictionary = submitted
			var pending_seen := false
			for frame in range(180):
				if submitted.get("status")!="queued": break
				outcome = coordinator.advance_complete_section_candidate(section,8)
				if outcome.get("stage")=="awaiting_frame": pending_seen = true
				if outcome.get("status") in ["installed","failed","rollback_failed"]: break
				await process_frame
			check("glass_real_native_frame_install",outcome.get("status")=="installed" and pending_seen,outcome)
			check("partial_owner_keeps_legacy_visible",not legacy.is_empty() and legacy[0].visible,{})
			var neighbor_census := coordinator.capture_authoritative_source_census([neighbor])
			var other: Dictionary = service.capture_static_section_contribution(neighbor_census,neighbor)
			check("neighbor_owner_contribution",other.get("status")=="ready",other)
			if other.get("status")=="ready":
				var other_values: Array = [other.contribution]
				other_values.make_read_only()
				var other_candidate := Assembler.assemble(neighbor_census,neighbor,other_values,1)
				var other_result: Dictionary = coordinator.submit_complete_section_candidate(other_candidate.get("candidate",{})) if other_candidate.get("status")=="ready" else other_candidate
				for frame in range(180):
					if other_result.get("status") in ["installed","failed","rollback_failed"]: break
					other_result = coordinator.advance_complete_section_candidate(neighbor,8)
					await process_frame
				check("neighbor_real_native_install",other_result.get("status")=="installed",other_result)
			var complete_ack: Dictionary = {}
			for turn in range(8):
				for owner_section: Vector3i in [section,neighbor]:
					complete_ack = coordinator.source_install_acknowledgement_proof(owner_section,
						coordinator._production_candidate_receipts.get(owner_section,{}))
				coordinator.advance_queued_complete_section_candidates(2,8)
				await process_frame
			var retired := not legacy.is_empty()
			for visual: GeometryInstance3D in legacy: retired = retired and not visual.visible
			check("glass_complete_owner_ack_retires_legacy",retired and complete_ack.get("status")=="ready",
				{"retired":retired,"ack":complete_ack,
				"ownerCompletion":coordinator.validate_geometry_owner_completion(service._geometry_owner_rosters.get(source,{}),[]),
				"provider":service.acknowledge_section_install(neighbor,"glass-coverage",coordinator._production_candidate_receipts.get(neighbor,{}))})
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(OS.get_environment("VOXEL_CITADEL_SECTION_SERVICE_REPORT").get_base_dir().path_join("glass-native.png"))
			# Prepare against the old POV, then invalidate before native upload.
			var old_pov := coordinator.current_translucent_pov_snapshot(section)
			var repeated: Dictionary = service.capture_static_section_contribution(census,section)
			var values: Array = [repeated.get("contribution",{})]
			values.make_read_only()
			var replacement := Assembler.assemble(census,section,values,2)
			var candidate: Dictionary = replacement.get("candidate",{})
			var begin: Dictionary = PacketOwner.begin_static_section_install(candidate,
				candidate.get("materialBindings",{}),candidate.get("meshBindings",{}),coordinator) if replacement.get("status")=="ready" else replacement
			if begin.get("status")=="ready":
				var stale: Dictionary = begin.session.advance(8,int(old_pov.revision)+100)
				check("stale_pov_rejected_before_upload",stale.get("status")=="failed" and stale.get("reason")=="section_translucent_pov_revision_stale",stale)
			else: check("stale_pov_session_admitted",false,begin)
			check("source_revision_independent_of_pov",publisher.capture_committed_static_visual_source(part.id,revision).get("status")=="ready",{})
	var drain := coordinator.drain_section_compiles()
	var frames: Dictionary = await coordinator.drain_pending_frame_presentations()
	check("owned_sessions_drained",drain.get("status")=="drained" and frames.get("status")=="drained",{"compile":drain,"frames":frames})
	var passed := true
	for row: Dictionary in checks: passed = passed and bool(row.passed)
	var report := {"schema":"citadel-glass-section-contract/v1","complete":true,"passed":passed,
		"checkCount":checks.size(),"checks":checks,"prepareUsec":elapsed,"glassBakeUsec":bake_usec,"cacheEvidence":cache_evidence,
		"evidenceLevel":"synthetic_census_real_window_producer_service_native_renderer_frame_callback"}
	var file := FileAccess.open(OS.get_environment("VOXEL_CITADEL_SECTION_SERVICE_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	if drain.get("status")=="drained" and frames.get("status")=="drained": scene.free()
	quit(0 if passed else 1)
