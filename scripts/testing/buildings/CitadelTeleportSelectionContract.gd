extends SceneTree
## Pure test-harness selection checks; never instantiates Main or a viewport.
const Runner = preload("res://scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
var checks: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var first := Field.candidate_for_region("atlas-30895044",Vector2i(0,-1))
	var second := Field.candidate_for_region("atlas-30895044",Vector2i(-1,0))
	var found: Array[Dictionary]=[{"candidate":first},{"candidate":second}]
	var before := var_to_bytes(found)
	checks.default_is_first=Runner.select_candidate(found,"")==first
	checks.explicit_first=Runner.select_candidate(found,"0,-1")==first
	checks.explicit_second=Runner.select_candidate(found,"-1,0")==second
	checks.nonmember_rejects=Runner.select_candidate(found,"1,1").is_empty()
	checks.empty_rejects=Runner.select_candidate([],"-1,0").is_empty()
	checks.existing_records_unchanged=before==var_to_bytes(found)
	var discovery_rows: Array=[
		{"candidate":{"siteId":"zeta","centerCell":Vector2i(-10,0)}},
		{"candidate":{"siteId":"alpha","centerCell":Vector2i(10,0)}},
		{"candidate":{"siteId":"nearest","centerCell":Vector2i(3,0)}}]
	var discovery_before := var_to_bytes(discovery_rows)
	var nearest := Runner.select_nearest_untried_candidate(discovery_rows,Vector3(2,7,0),{})
	checks.discovery_uses_live_player_distance=nearest.get("candidate",{}).get("siteId","")=="nearest" and nearest.get("selectionPolicy","")=="nearest_untried_at_current_position"
	var after_rejection := Runner.select_nearest_untried_candidate(discovery_rows,Vector3(2,7,0),{"nearest":true})
	checks.discovery_excludes_only_production_rejected_site=after_rejection.get("candidate",{}).get("siteId","")=="alpha"
	var after_current_rejection := Runner.select_next_discovery_candidate(discovery_rows,Vector3(2,7,0),{},"nearest")
	checks.discovery_excludes_current_before_record_append=after_current_rejection.get("candidate",{}).get("siteId","")=="alpha"
	var tie_rows: Array=[{"candidate":{"siteId":"z","centerCell":Vector2i(-2,0)}},{"candidate":{"siteId":"a","centerCell":Vector2i(2,0)}}]
	checks.discovery_tie_breaks_by_stable_site_id=Runner.select_nearest_untried_candidate(tie_rows,Vector3.ZERO,{}).get("candidate",{}).get("siteId","")=="a"
	var escape_origin:=Vector3(2,7,3)
	var escape_target:=Vector3(2,11,-97)
	var escape_waypoints: Array[Vector3]=[]
	for attempt in range(7): escape_waypoints.append(Runner.discovery_escape_waypoint(escape_origin,escape_target,attempt,48.0))
	checks.discovery_escape_sweep_is_finite_and_bounded=escape_waypoints.all(func(point: Vector3):
		return point.is_finite() and is_equal_approx(Vector2(point.x-escape_origin.x,point.z-escape_origin.z).length(),48.0) and is_equal_approx(point.y,escape_origin.y))
	var escape_directions: Dictionary={}
	for point: Vector3 in escape_waypoints:
		var direction:=Vector2(point.x-escape_origin.x,point.z-escape_origin.z).normalized()
		escape_directions[Vector2(snappedf(direction.x,0.001),snappedf(direction.y,0.001))]=true
	checks.discovery_escape_sweep_covers_distinct_headings=escape_directions.size()==7
	checks.discovery_escape_sweep_starts_by_backtracking=escape_waypoints[0].z>escape_origin.z
	var contact_normals: Array=[Vector3(0.864663,0.0,0.501577),Vector3(-0.07294,0.0,-0.997336)]
	var contact_escape:=Runner.discovery_local_steering_direction(Vector2(-1.0,0.25),contact_normals,0)
	checks.discovery_contact_steering_uses_local_escape_wedge=contact_escape.length()>0.99 \
		and contact_escape.dot(Vector2(contact_normals[0].x,contact_normals[0].z).normalized())>0.0 \
		and contact_escape.dot(Vector2(contact_normals[1].x,contact_normals[1].z).normalized())>0.0
	var local_waypoint:=Runner.discovery_escape_waypoint(escape_origin,escape_target,0,48.0,contact_normals)
	checks.discovery_contact_waypoint_is_bounded=local_waypoint.is_finite() \
		and is_equal_approx(Vector2(local_waypoint.x-escape_origin.x,local_waypoint.z-escape_origin.z).length(),48.0)
	var wall_normals: Array=[Vector3(1.0,0.0,0.0)]
	var first_wall:=Runner.discovery_wall_follow_decision(Vector2(0.1,1.0),wall_normals,0,7.0,2.0)
	var persistent_wall:=Runner.discovery_wall_follow_decision(Vector2(0.1,1.0),wall_normals,
		int(first_wall.get("side",0)),0.5,7.0,first_wall.get("outward",Vector2.ZERO))
	var corner_wall:=Runner.discovery_wall_follow_decision(Vector2(0.1,1.0),
		[Vector3(0.707,0.0,0.707)],int(first_wall.get("side",0)),0.5,7.0,
		first_wall.get("outward",Vector2.ZERO))
	checks.discovery_wall_follow_chooses_progressing_clear_tangent=first_wall.get("side",0)==1 \
		and float(first_wall.get("targetProgress",-1.0))>0.5
	checks.discovery_wall_follow_side_persists_when_probe_rank_flips=first_wall.get("side",0)==persistent_wall.get("side",0) \
		and persistent_wall.get("side",0)==corner_wall.get("side",0)
	checks.discovery_wall_follow_never_steers_into_live_contact=(first_wall.get("direction",Vector2.ZERO) as Vector2).dot(Vector2.RIGHT)>=-0.0001 \
		and (corner_wall.get("direction",Vector2.ZERO) as Vector2).dot(Vector2(0.707,0.707).normalized())>=-0.0001
	var classified_contacts:=Runner.discovery_contact_normals([
		{"normal":Vector3.UP},{"normal":Vector3(0.393134,0.417879,0.819038)},
		{"normal":Vector3(0.4,0.8,0.45).normalized()}],PI*0.25)
	checks.discovery_wall_contacts_use_character_floor_angle=classified_contacts.size()==1 \
		and absf(float((classified_contacts[0] as Vector3).y)-0.417879)<0.0001
	var stalled_progress: Dictionary={"samples":[]}
	for sample_index in range(5):
		stalled_progress=Runner.next_discovery_progress_state(stalled_progress.samples,sample_index*1000,
			100.0-float(sample_index)*0.2,4000,1.5)
	var advancing_progress: Dictionary={"samples":[]}
	for advancing_index in range(5):
		advancing_progress=Runner.next_discovery_progress_state(advancing_progress.samples,advancing_index*1000,
			100.0-float(advancing_index)*1.0,4000,1.5)
	checks.discovery_progress_uses_rolling_candidate_distance=stalled_progress.get("mature",false) \
		and stalled_progress.get("stalled",false) and float(stalled_progress.get("progressMeters",0.0))<1.5 \
		and advancing_progress.get("mature",false) and not advancing_progress.get("stalled",true) \
		and float(advancing_progress.get("progressMeters",0.0))>=4.0
	var jittered_progress: Dictionary={"samples":[]}
	for jittered_sample in [0,1016,2016,3017,4017]:
		jittered_progress=Runner.next_discovery_progress_state(jittered_progress.samples,jittered_sample,
			100.0,4000,1.5)
	checks.discovery_progress_window_matures_across_real_sampling_jitter=jittered_progress.get("mature",false) \
		and jittered_progress.get("stalled",false) and int(jittered_progress.samples[0].msec)==0
	checks.discovery_stationary_wall_follow_releases_after_bounded_samples=Runner.should_release_stalled_wall_follow(
		true,jittered_progress,2,2) and not Runner.should_release_stalled_wall_follow(true,jittered_progress,1,2)
	checks.discovery_moving_wall_follow_is_not_released=not Runner.should_release_stalled_wall_follow(
		true,{"mature":true,"stalled":false},8,2)
	checks.discovery_moving_but_nonprogressing_wall_follow_has_time_bound=not Runner.should_release_stalled_wall_follow(
		true,jittered_progress,0,2,19999,20000) and Runner.should_release_stalled_wall_follow(
		true,jittered_progress,0,2,20000,20000)
	checks.ordinary_ground_leg_can_ignore_natural_vertical_variation=Runner.movement_target_reached(0.4,12.0,0.5)
	checks.authored_stair_leg_requires_vertical_convergence=not Runner.movement_target_reached(0.4,2.0,0.5,0.58) \
		and Runner.movement_target_reached(0.4,0.5,0.5,0.58)
	checks.authored_stair_leg_cannot_pass_while_airborne=not Runner.movement_target_reached(
		0.4,0.5,0.5,0.58,false,true) and Runner.movement_target_reached(0.4,0.5,0.5,0.58,true,true)
	var retry_one:=Runner.discovery_contact_miss_retry_direction(Vector2(-1.0,0.2),Vector2(0.4,0.9),1,1,Vector2.ZERO)
	var retry_four:=Runner.discovery_contact_miss_retry_direction(Vector2(-1.0,0.2),Vector2(0.4,0.9),1,4,retry_one)
	var retained_tangent:=Vector2(-0.9,0.4).normalized()
	checks.discovery_contact_miss_retry_is_short_same_hand_backoff=retry_one.length()>0.99 \
		and retry_four.length()>0.99 and retry_one.dot(retained_tangent)>0.0 \
		and retry_four.dot(retained_tangent)>0.0 and retry_four.dot(Vector2(0.4,0.9).normalized())>0.0
	var aim_state: Dictionary={}
	for ready: bool in [true,true,false]: aim_state=Runner.next_discovery_aim_state(aim_state,ready)
	checks.discovery_aim_retains_ever_and_sustained=aim_state.get("ever",false) \
		and int(aim_state.get("maxConsecutive",0))==2 and not aim_state.get("finalReady",true)
	checks.discovery_transient_final_aim_miss_keeps_no_source_timeout=Runner.classify_discovery_completion(
		true,false,aim_state,0,true)=="ordinary_source_not_accepted"
	checks.discovery_transient_final_aim_miss_allows_accepted_source=Runner.classify_discovery_completion(
		true,true,aim_state,0,true).is_empty()
	checks.discovery_never_aimed_is_not_no_source_timeout=Runner.classify_discovery_completion(
		true,false,Runner.next_discovery_aim_state({},false),0,true)=="source_discovery_aim_never_acquired"
	var camera_retry: Dictionary={}
	camera_retry=Runner.next_camera_convergence_retry_state(camera_retry,
		{"passed":false,"inputEvents":40,"finalYawErrorRadians":0.054783},3)
	checks.camera_convergence_miss_retains_retry_budget=not camera_retry.get("passed",true) \
		and camera_retry.get("retryAvailable",false) and not camera_retry.get("exhausted",true) \
		and int(camera_retry.get("windowCount",0))==1
	camera_retry=Runner.next_camera_convergence_retry_state(camera_retry,
		{"passed":true,"inputEvents":12,"finalYawErrorRadians":0.019},3)
	checks.camera_convergence_requires_actual_angular_success=camera_retry.get("passed",false) \
		and not camera_retry.get("retryAvailable",true) and not camera_retry.get("exhausted",true) \
		and int(camera_retry.get("windowCount",0))==2 and int(camera_retry.get("inputEvents",0))==52
	var camera_exhausted: Dictionary={}
	for retry_index in range(2):
		camera_exhausted=Runner.next_camera_convergence_retry_state(camera_exhausted,
			{"passed":false,"inputEvents":40,"finalYawErrorRadians":0.05-float(retry_index)*0.01},2)
	checks.camera_convergence_still_fails_when_retry_budget_exhausts=not camera_exhausted.get("passed",true) \
		and not camera_exhausted.get("retryAvailable",true) and camera_exhausted.get("exhausted",false) \
		and int(camera_exhausted.get("windowCount",0))==2
	checks.menu_journey_requires_player_scale_inspection=Runner.requires_player_scale_inspection(true,0,false)
	checks.plain_diagnostic_does_not_require_player_scale_inspection=not Runner.requires_player_scale_inspection(false,0,false)
	var runner_source:=FileAccess.get_file_as_string("res://scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd")
	var camera_proof_index:=runner_source.find("checks.camera_facing_candidate = await _look_toward_candidate_with_retries(")
	var ready_capture_index:=runner_source.find("if not await _capture(\"ready\")")
	var itinerary_index:=runner_source.find("evidence.playerScaleInspection=await _run_player_scale_inspection()")
	checks.menu_itinerary_follows_bounded_camera_proof=camera_proof_index>=0 \
		and ready_capture_index>camera_proof_index and itinerary_index>ready_capture_index
	checks.discovery_records_unchanged=discovery_before==var_to_bytes(discovery_rows)
	for value: String in ["0",",","0,0,0"," 0,0","0,0 ","+1,0","01,0","-0,0","x,0","0.5,0","1048576,0","-1048577,0","999999999999999,0"]:
		checks["invalid:"+value]=not Runner.valid_region_request(value) and Runner.select_candidate(found,value).is_empty()
	for value: String in ["","0,0","-1,0","1048575,-1048576"]:
		checks["valid:"+value]=Runner.valid_region_request(value)
	var path := OS.get_environment("CITADEL_TELEPORT_SELECTION_OUTPUT")
	if not path.is_absolute_path() or FileAccess.file_exists(path): quit(2); return
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null: quit(2); return
	var passed := not checks.values().has(false)
	file.store_string(JSON.stringify({"passed":passed,"checks":checks,"checkCount":checks.size(),
		"evidenceLevel":"pure fixture selection contract, no Main instance or site eligibility",
		"runnerSha256":FileAccess.get_sha256("res://scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd")},"\t"))
	file.close()
	print("Citadel teleport selection checks=",checks.size()," passed=",passed)
	quit(0 if passed else 1)
