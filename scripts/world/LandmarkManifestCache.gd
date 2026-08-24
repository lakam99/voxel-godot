extends RefCounted
class_name LandmarkManifestCache

class RegionClaim:
	extends RefCounted
	var region := Vector2i.ZERO
	var heartbeat_usec := 0

var records_by_region: Dictionary = {}
var in_flight_by_region: Dictionary = {}
var mutex := Mutex.new()

const OWNER_LEASE_TIMEOUT_USEC := 2000000
const OWNER_WAIT_SLICE_USEC := 250000
const OWNER_WAIT_POLL_USEC := 100


func acquire_region(region: Vector2i) -> Dictionary:
	mutex.lock()
	if records_by_region.has(region):
		var ready_sites: Array = records_by_region[region] if records_by_region[region] is Array else []
		var ready_snapshot := ready_sites.duplicate(true)
		mutex.unlock()
		return {"state": "ready", "sites": ready_snapshot}
	if in_flight_by_region.has(region):
		var pending: Dictionary = in_flight_by_region[region] if in_flight_by_region[region] is Dictionary else {}
		pending["waiters"] = int(pending.get("waiters", 0)) + 1
		in_flight_by_region[region] = pending
		mutex.unlock()
		return {"state": "wait", "semaphore": pending.get("semaphore", null)}
	var claim := RegionClaim.new()
	claim.region = region
	claim.heartbeat_usec = Time.get_ticks_usec()
	var semaphore := Semaphore.new()
	in_flight_by_region[region] = {"semaphore": semaphore, "waiters": 0, "claim": claim}
	mutex.unlock()
	return {"state": "owner", "claim": claim}


func heartbeat_region(region: Vector2i, claim) -> bool:
	mutex.lock()
	var pending: Dictionary = in_flight_by_region.get(region, {}) if in_flight_by_region.get(region, {}) is Dictionary else {}
	if pending.is_empty() or pending.get("claim", null) != claim:
		mutex.unlock()
		return false
	(claim as RegionClaim).heartbeat_usec = Time.get_ticks_usec()
	mutex.unlock()
	return true


func wait_for_region(region: Vector2i, semaphore) -> Dictionary:
	var deadline := Time.get_ticks_usec() + OWNER_WAIT_SLICE_USEC
	while semaphore is Semaphore and Time.get_ticks_usec() < deadline:
		if (semaphore as Semaphore).try_wait():
			return acquire_region(region)
		OS.delay_usec(OWNER_WAIT_POLL_USEC)
	return _take_over_expired_claim(region, semaphore)


func publish_region(region: Vector2i, claim, sites: Array) -> bool:
	mutex.lock()
	var pending: Dictionary = in_flight_by_region.get(region, {}) if in_flight_by_region.get(region, {}) is Dictionary else {}
	if records_by_region.has(region) or pending.is_empty() or pending.get("claim", null) != claim:
		mutex.unlock()
		return false
	records_by_region[region] = sites.duplicate(true)
	in_flight_by_region.erase(region)
	mutex.unlock()
	_wake_waiters(pending)
	return true


func abort_region(region: Vector2i, claim, _reason: String) -> bool:
	mutex.lock()
	var pending: Dictionary = in_flight_by_region.get(region, {}) if in_flight_by_region.get(region, {}) is Dictionary else {}
	if pending.is_empty() or pending.get("claim", null) != claim:
		mutex.unlock()
		return false
	in_flight_by_region.erase(region)
	mutex.unlock()
	_wake_waiters(pending)
	return true


func _take_over_expired_claim(region: Vector2i, waited_semaphore) -> Dictionary:
	mutex.lock()
	if records_by_region.has(region):
		var ready_sites: Array = records_by_region[region] if records_by_region[region] is Array else []
		var ready_snapshot := ready_sites.duplicate(true)
		mutex.unlock()
		return {"state": "ready", "sites": ready_snapshot}
	var pending: Dictionary = in_flight_by_region.get(region, {}) if in_flight_by_region.get(region, {}) is Dictionary else {}
	if not pending.is_empty() and pending.get("semaphore", null) != waited_semaphore:
		pending["waiters"] = int(pending.get("waiters", 0)) + 1
		in_flight_by_region[region] = pending
		mutex.unlock()
		return {"state": "wait", "semaphore": pending.get("semaphore", null)}
	var active_claim = pending.get("claim", null)
	if active_claim is RegionClaim and Time.get_ticks_usec() - int((active_claim as RegionClaim).heartbeat_usec) <= OWNER_LEASE_TIMEOUT_USEC:
		mutex.unlock()
		return {"state": "wait", "semaphore": waited_semaphore}
	var replacement_claim := RegionClaim.new()
	replacement_claim.region = region
	replacement_claim.heartbeat_usec = Time.get_ticks_usec()
	var replacement_semaphore := Semaphore.new()
	in_flight_by_region[region] = {"semaphore": replacement_semaphore, "waiters": 0, "claim": replacement_claim}
	mutex.unlock()
	return {"state": "owner", "claim": replacement_claim, "replacedExpiredOwner": true}


func _wake_waiters(pending: Dictionary) -> void:
	var semaphore = pending.get("semaphore", null)
	if semaphore is Semaphore:
		for _waiter in range(int(pending.get("waiters", 0))):
			(semaphore as Semaphore).post()
