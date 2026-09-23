extends RefCounted
class_name NativeShapingPageAdmission

## Shadow-only bridge from the production site admission to native shaping pins.
## The caller owns the initialized backend and advances CitadelTerrainAdmission.
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const MAX_RESOLUTIONS := 16

var _backend
var _admission
var _seed := ""
var _store

func setup(backend, admission) -> Dictionary:
	if backend == null or admission == null or admission.profile_store == null:
		return {"status":"failed", "reason":"shaping_bridge_owner_missing"}
	if String(admission.world_seed).is_empty() or admission.profile_store.world_seed() != admission.world_seed:
		return {"status":"failed", "reason":"shaping_bridge_seed_mismatch"}
	_backend = backend
	_admission = admission
	_store = admission.profile_store
	_seed = String(admission.world_seed)
	return {"status":"ready"}

func request_page(page: Vector2i) -> Dictionary:
	if _backend == null or _admission == null or _store == null:
		return {"status":"failed", "reason":"shaping_bridge_not_configured"}
	if _admission.world_seed != _seed or _admission.profile_store != _store:
		return {"status":"failed", "reason":"shaping_bridge_source_changed"}
	var readiness: Dictionary = _backend.shaping_requests(page)
	if readiness.get("status") != "pending":
		return readiness
	var requests: Array = readiness.get("requests", [])
	var resolutions: Array = []
	var waiting: Array = []
	var profiles: Array = _store.snapshot()
	for request_value in requests:
		if resolutions.size() >= MAX_RESOLUTIONS:
			break
		if not request_value is Dictionary:
			return {"status":"failed", "reason":"invalid_native_shaping_request"}
		var request: Dictionary = request_value
		var region: Vector2i = request.get("region", Vector2i.ZERO)
		var candidate: Dictionary = Field.candidate_for_region(_seed, region)
		if candidate.is_empty() or candidate.get("siteId") != request.get("siteId") \
				or candidate.get("centerCell") != request.get("centerCell") \
				or candidate.get("recipeSeed") != request.get("recipeSeed"):
			return {"status":"failed", "reason":"shaping_candidate_identity_mismatch", "region":region}
		var source: Dictionary = _admission.request_source(region)
		var source_status := String(source.get("status", ""))
		if source_status == "pending":
			waiting.append(region)
			continue
		if source_status == "ready" or source_status == "prepared":
			var profile: Dictionary = {}
			for value in profiles:
				if value is Dictionary and value.get("siteId") == candidate.get("siteId"):
					profile = value
					break
			if profile.is_empty() or profile.get("worldSeed") != _seed \
					or profile.get("sourceSignature") != source.get("sourceSignature"):
				return {"status":"failed", "reason":"prepared_source_profile_mismatch", "region":region}
			resolutions.append({"region":region, "requestIdentity":request.get("requestIdentity"),
				"workerSourceKey":request.get("workerSourceKey"), "kind":"prepared", "reasonCode":"",
				"candidate":candidate, "manifest":{"ready":true, "sourceSignature":profile.sourceSignature},
				"reservationCells":source.get("reservationCells"), "profile":profile})
		elif source_status == "absent" and source.get("reason") != "source_not_requested":
			var absence_reason := String(source.get("reason", ""))
			if absence_reason.is_empty():
				absence_reason = "authoritative_absent"
			resolutions.append({"region":region, "requestIdentity":request.get("requestIdentity"),
				"workerSourceKey":request.get("workerSourceKey"), "kind":"absent",
				"reasonCode":absence_reason})
		elif source_status == "failed":
			return {"status":"failed", "reason":String(source.get("reason", "site_source_failed")), "region":region}
		else:
			waiting.append(region)
	if not resolutions.is_empty():
		var receipt: Dictionary = _backend.apply_shaping_resolutions(resolutions)
		if receipt.get("status") != "ready":
			return receipt
	var current: Dictionary = _backend.shaping_requests(page)
	if current.get("status") == "failed":
		return current
	if current.get("status") == "ready":
		return current
	return {"status":"pending", "reason":"site_source_pending", "page":page,
		"waitingRegions":waiting, "remainingRequests":(current.get("requests", []) as Array).size(),
		"resolvedThisCall":resolutions.size()}
