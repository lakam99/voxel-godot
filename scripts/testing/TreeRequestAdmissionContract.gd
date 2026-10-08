extends SceneTree

const Admission := preload("res://scripts/environment/TreeRequestAdmission.gd")
const Fixture := preload("res://scripts/testing/CertifiedTreeRequestFixture.gd")
const CitadelComposer := preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var prepared: Dictionary = Fixture.prepare_request({
		"treeId":"tree-admission-tamper-contract",
		"biome":"forest", "worldSeed":"tree-admission-contract-seed"})
	var checks := {"canonical_request_accepted":false,
		"tampered_certificate_rejected":false, "stale_catalog_rejected":false}
	var reason := ""
	if String(prepared.get("status", "")) == "ready":
		var request: Dictionary = prepared.get("request", {})
		var certificate: Dictionary = request.get("treeAdmissionCertificate", {})
		var snapshot: Dictionary = certificate.get("profileCatalogSnapshot", {})
		checks.canonical_request_accepted = String(Admission.validate_request(
			request, snapshot).get("status", "")) == "ready"
		var tampered_request := request.duplicate(true)
		var tampered_certificate: Dictionary = certificate.duplicate(true)
		tampered_certificate["maxVisualHeightMeters"] = float(
			tampered_certificate.get("maxVisualHeightMeters", 0.0)) + 1.0
		tampered_request["treeAdmissionCertificate"] = tampered_certificate
		checks.tampered_certificate_rejected = String(Admission.validate_request(
			tampered_request, snapshot).get("status", "")) == "failed"
		var stale_snapshot := snapshot.duplicate(true)
		stale_snapshot["contentIdentity"] = "0".repeat(64)
		checks.stale_catalog_rejected = String(Admission.validate_request(
			request, stale_snapshot).get("status", "")) == "failed"
	else:
		reason = String(prepared.get("reason", "fixture_request_unavailable"))
	# Exercise the actual production caller, including all three authored fallback
	# heights. A valid catalog certificate must bound requests its producers emit.
	var town_records := CitadelComposer.build_tree_placement_records(
		[Vector3.ZERO, Vector3(20, 0, 0), Vector3(40, 0, 0)], 1492)
	var town_results: Array[Dictionary] = []
	checks["citadel_producer_complete_three_height_cycle"] = town_records.size() == 3
	for index: int in town_records.size():
		var town_request: Dictionary = town_records[index].get("treeRequest", {})
		var town_admission := Admission.validate_request(town_request)
		checks["citadel_producer_request_%d_accepted" % index] = town_admission.get("status") == "ready"
		town_results.append({"index":index, "visualHeight":town_request.get("visualHeight"),
			"trunkRadius":town_request.get("trunkRadius"), "canopyRadius":town_request.get("canopyRadius"),
			"admission":town_admission.get("status"), "reason":town_admission.get("reason", "")})
		var oversized := town_request.duplicate(true)
		oversized["visualHeight"] = 1000.0
		checks["citadel_oversized_request_%d_rejected" % index] = Admission.validate_request(
			oversized).get("status") == "failed"
		var beyond_profile := town_request.duplicate(true)
		beyond_profile["visualHeight"] = 8.001
		checks["citadel_request_%d_above_producer_bound_rejected" % index] = Admission.validate_request(
			beyond_profile).get("reason") == "tree_request_outside_profile_envelope"
	var passed := checks.values().all(func(value: Variant) -> bool: return bool(value))
	var report := {"schema":"tree-request-admission-contract/v1",
		"passed":passed, "checks":checks, "fixtureReason":reason, "citadelProducerRequests":town_results,
		"evidence":"Production builder request; cached canonical-certificate structural equality rejects altered certificate fields and stale catalog identity."}
	var report_path := OS.get_environment("TREE_REQUEST_ADMISSION_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	quit(0 if passed else 1)
