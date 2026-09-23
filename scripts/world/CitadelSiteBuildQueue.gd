extends RefCounted
class_name CitadelSiteBuildQueue

## One main-thread owner; source preparation runs on one owned worker.
## Unwired until deep cancellation and terrain admission are proven. Polling
## never joins a running thread or exposes mutable, partially prepared source.
const Site = preload("res://scripts/world/CitadelSitePreparation.gd")
const Survey = preload("res://scripts/world/CitadelSiteSurvey.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const SOURCE_POLICY_REVISION := 1
const MAX_PENDING := 8
const MAX_PRIORITY_BURST := 3
const MAX_RESULT_VALUES := 2000000
const MAX_RESULT_DEPTH := 64
const MAX_RESULT_BYTES := 32 * 1024 * 1024
const SOURCE_TIMING_HISTORY_LIMIT := 64

class RetirementState extends RefCounted:
	var payload: Dictionary
	var tokens: Array[int] = []
	var transferred := Semaphore.new()
	var released_on_thread := -1
	func release_payload() -> int:
		transferred.wait()
		var started := Time.get_ticks_usec()
		# The callable may survive until owner-side join. Clear the holder here,
		# rather than binding the payload into that callable's lifetime.
		payload = {}
		released_on_thread = OS.get_thread_caller_id()
		return Time.get_ticks_usec()-started

class RunState extends RefCounted:
	const RAW_PREPARE_STAGE_NAMES := ["centerSurvey", "recipe", "compound", "urbanComposition", "structuralCompletion", "structuralPrerequisites", "facadeOpeningHeads", "facadeLowerBearings", "structuralLaterSetup", "chimneyCompletion", "bracketFirstCompletion", "signCompletion", "partyWallCompletion", "bracketRetryCompletion", "buntingCompletion", "thresholdCompletion", "finalSignVerification", "finalBuntingVerification", "structuralFinalize", "geometryManifest", "terrainPreparation", "terrainProfile", "ordinaryConflict", "envelopeSurvey", "visualReservationSurvey", "finalProfile"]
	var mutex := Mutex.new()
	var cancelled := false
	var stage := "dispatch"
	var stage_count := 0
	var started_usec := Time.get_ticks_usec()
	var previous_usec := started_usec
	var max_stage_gap_usec := 0
	var phase_timing := {"rawPrepare":{},"snapshot":{},"freeze":{},"serialization":{}}
	var raw_prepare_stages := {"centerSurvey":{},"recipe":{},"compound":{},"urbanComposition":{},"structuralCompletion":{},"structuralPrerequisites":{},"facadeOpeningHeads":{},"facadeLowerBearings":{},"structuralLaterSetup":{},"chimneyCompletion":{},"bracketFirstCompletion":{},"signCompletion":{},"partyWallCompletion":{},"bracketRetryCompletion":{},"buntingCompletion":{},"thresholdCompletion":{},"finalSignVerification":{},"finalBuntingVerification":{},"structuralFinalize":{},"geometryManifest":{},"terrainPreparation":{},"terrainProfile":{},"ordinaryConflict":{},"envelopeSurvey":{},"visualReservationSurvey":{},"finalProfile":{}}
	func cancel() -> void:
		mutex.lock()
		cancelled = true
		mutex.unlock()
	func is_cancelled() -> bool:
		mutex.lock()
		var value := cancelled
		mutex.unlock()
		return value
	func advance(next_stage: String) -> bool:
		mutex.lock()
		var now := Time.get_ticks_usec()
		max_stage_gap_usec = maxi(max_stage_gap_usec,now-previous_usec)
		previous_usec = now
		stage = next_stage.left(160)
		stage_count += 1
		var permitted := not cancelled
		mutex.unlock()
		return permitted
	func snapshot() -> Dictionary:
		mutex.lock()
		var result := {"stage":stage,"stageCount":stage_count,"cancelRequested":cancelled,
			"elapsedUsec":Time.get_ticks_usec()-started_usec,"maxStageGapUsec":max_stage_gap_usec,
			"phaseTiming":{"schema":"citadel-site-phase-timing/v1","activePhase":_active_phase(),
				"rawPrepare":phase_timing.rawPrepare.duplicate(),"snapshot":phase_timing.snapshot.duplicate(),
				"freeze":phase_timing.freeze.duplicate(),"serialization":phase_timing.serialization.duplicate(),
				"rawPrepareStages":{"schema":"citadel-site-raw-prepare-stages/v1","stages":raw_prepare_stages.duplicate(true)}}}
		mutex.unlock()
		return result
	func begin_phase(name: String) -> void:
		if not phase_timing.has(name): return
		mutex.lock()
		phase_timing[name] = {"startedUsec":Time.get_ticks_usec(),"finishedUsec":0,"elapsedUsec":0,"complete":false}
		mutex.unlock()
	func finish_phase(name: String) -> void:
		if not phase_timing.has(name): return
		mutex.lock()
		var row: Dictionary = phase_timing[name]
		if not row.is_empty() and not row.complete:
			row.finishedUsec = Time.get_ticks_usec()
			row.elapsedUsec = maxi(0,int(row.finishedUsec)-int(row.startedUsec))
			row.complete = true
		mutex.unlock()
	func observe_raw_prepare_stage(name: String, beginning: bool) -> void:
		if name not in RAW_PREPARE_STAGE_NAMES: return
		mutex.lock()
		var now := Time.get_ticks_usec()
		var row: Dictionary = raw_prepare_stages[name]
		if beginning:
			if row.is_empty(): row = {"startedUsec":now,"finishedUsec":0,"activeStartedUsec":0,"elapsedUsec":0,"maxUsec":0,"complete":false,"count":0}
			row.activeStartedUsec = now
			row.count = int(row.count)+1
			row.complete = false
		elif not row.is_empty() and not bool(row.get("complete",false)):
			row.finishedUsec = now
			var elapsed := maxi(0,now-int(row.activeStartedUsec))
			row.elapsedUsec = int(row.elapsedUsec)+elapsed
			row.maxUsec = maxi(int(row.maxUsec),elapsed)
			row.complete = true
		raw_prepare_stages[name] = row
		mutex.unlock()
	func _active_phase() -> String:
		for name: String in ["rawPrepare","snapshot","freeze","serialization"]:
			var row: Dictionary = phase_timing[name]
			if not row.is_empty() and not row.complete: return name
		return ""

var _epoch := 1
var _next_token := 1
var _pending: Array = []
var _active: Dictionary = {}
var _completed: Dictionary = {}
var _thread: Thread
var _state: RunState
var _closing := false
var _priority_burst := 0
var _max_poll_usec := 0
var _max_join_usec := 0
var _max_submit_usec := 0
var _discarded_stale := 0
var _retired: Dictionary = {}
var _retirement: RetirementState
var _retiring_tokens: Dictionary = {}
var _retirement_start_error := OK
var _max_retirement_usec := 0
var _last_retirement_thread := -1
var _source_timing_history: Array[Dictionary] = []
var _source_timing_dropped := 0
var _worker_callable_for_test: Callable

func submit(world_seed: String, region: Vector2i, towns: Dictionary, ordinary_policy: Dictionary, priority: bool = false) -> Dictionary:
	var started := Time.get_ticks_usec()
	if _closing: return {"status":"failed","reason":"shutting_down"}
	var input := _canonical_request(world_seed,region,towns,ordinary_policy)
	if input.is_empty(): return {"status":"failed","reason":"invalid_request"}
	var key: String = input.sourceKey
	for entry: Dictionary in _pending + [_active,_completed]:
		if not entry.is_empty() and entry.epoch == _epoch and entry.sourceKey == key and not entry.get("cancelled",false):
			if _pending.has(entry): entry.priority = entry.priority or priority
			return _receipt(entry,"duplicate")
	if _pending.size() >= MAX_PENDING: return {"status":"failed","reason":"queue_full"}
	var request := {"token":_next_token,"epoch":_epoch,"sourceKey":key,"input":input,"priority":priority,"cancelled":false}
	_next_token += 1
	_pending.append(request)
	_max_submit_usec = maxi(_max_submit_usec,Time.get_ticks_usec()-started)
	return _receipt(request,"queued")

static func _receipt(entry: Dictionary, status: String) -> Dictionary:
	return {"status":status,"token":entry.token,"epoch":entry.epoch,"sourceKey":entry.sourceKey}

func poll() -> Dictionary:
	var started := Time.get_ticks_usec()
	var joined := false
	if _thread != null and not _thread.is_alive():
		var join_start := Time.get_ticks_usec()
		var result: Variant = _thread.wait_to_finish()
		_max_join_usec = maxi(_max_join_usec,Time.get_ticks_usec()-join_start)
		_thread = null
		joined = true
		var terminal_status := ""
		if _active.get("kind","") == "retirement":
			_max_retirement_usec = maxi(_max_retirement_usec,int(result))
			_last_retirement_thread = _retirement.released_on_thread
			for token: int in _retirement.tokens: _retiring_tokens.erase(token)
			_retirement = null
		elif _active.epoch != _epoch or _closing:
			if result is Dictionary: _queue_retirement(result, int(_active.get("token", 0)))
			_discarded_stale += 1
			terminal_status = "discarded_stale"
		elif _active.cancelled or _state.is_cancelled():
			if result is Dictionary: _queue_retirement(result, int(_active.get("token", 0)))
			_store_completed(_terminal("cancelled","cancelled"),false)
			terminal_status = "cancelled"
		elif result is Dictionary:
			_store_completed(result)
			terminal_status = String(result.get("status","prepared"))
		else:
			_store_completed(_terminal("failed","invalid_worker_return"),false)
			terminal_status = "invalid_worker_return"
		_record_source_timing(_active,_state,terminal_status)
		# Include disposal of rejected payloads in the measured owner call.
		result = null
		_active = {}
		_state = null
	if _thread == null and not _retired.is_empty():
		_start_retirement()
	elif _thread == null and _completed.is_empty() and not _closing and not _pending.is_empty():
		_active = _pending.pop_at(_next_index())
		_state = RunState.new()
		_thread = Thread.new()
		var worker := _worker_callable_for_test if _worker_callable_for_test.is_valid() else Callable(self, "_run")
		var error := _start_thread(worker.bind(_active.input,_state))
		if error != OK:
			_thread = null
			_store_completed(_terminal("failed","worker_start_failed"),false)
			_active = {}
			_state = null
	_max_poll_usec = maxi(_max_poll_usec,Time.get_ticks_usec()-started)
	return {"epoch":_epoch,"workerRunning":_thread != null,"workerJoined":joined,
		"activeToken":_active.get("token",0),"pendingCount":_pending.size(),
		"completedToken":_completed.get("token",0),"completedStatus":_completed.get("result",{}).get("status",""),
		"shutdownComplete":_closing and _thread == null and _retired.is_empty(),"progress":_state.snapshot() if _state != null else {},
		"workerKind":_active.get("kind","source") if _thread != null else "",
		"retirementPending":not _retired.is_empty() or _retirement != null,"retirementStartError":_retirement_start_error,
		"maxRetirementWorkUsec":_max_retirement_usec,"lastRetirementThreadId":_last_retirement_thread,
		"maxPollUsec":_max_poll_usec,"maxJoinUsec":_max_join_usec,"maxSubmitUsec":_max_submit_usec,"discardedStale":_discarded_stale}

func source_timing() -> Dictionary:
	var history: Array[Dictionary] = []
	for row: Dictionary in _source_timing_history: history.append(row.duplicate(true))
	return {"schema":"citadel-site-source-timing/v1","observedUsec":Time.get_ticks_usec(),"historyLimit":SOURCE_TIMING_HISTORY_LIMIT,
		"droppedCount":_source_timing_dropped,"history":history,"active":_state.snapshot().get("phaseTiming",{}) if _state != null else {}}

func _record_source_timing(entry: Dictionary, state: RunState, terminal_status: String) -> void:
	if entry.get("kind","")=="retirement": return
	var timing: Dictionary = state.snapshot().get("phaseTiming",{}).duplicate(true)
	var row := {"epoch":int(entry.get("epoch",0)),"token":int(entry.get("token",0)),"sourceKey":String(entry.get("sourceKey","")).left(128),
		"terminalStatus":terminal_status,"cancelled":bool(entry.get("cancelled",false)) or state.is_cancelled(),"phaseTiming":timing}
	_source_timing_history.append(row)
	if _source_timing_history.size()>SOURCE_TIMING_HISTORY_LIMIT:
		_source_timing_history.pop_front()
		_source_timing_dropped += 1

func take_result(token: int) -> Dictionary:
	if not _completed.is_empty() and _completed.token == token and _completed.epoch == _epoch:
		var result := _completed
		_completed = {}
		return {"status":"consumed","token":token,"epoch":result.epoch,"sourceKey":result.sourceKey,"result":result.result}
	if _active.get("token",0) == token and _active.get("epoch",0) == _epoch or _pending.any(func(entry):return entry.token==token):
		return {"status":"pending","token":token}
	return {"status":"stale_token","token":token}

## A started source build has already claimed the queue's sole worker slot. A
## camera/view-priority reversal may alter which *new* source is desirable, but
## must not repeatedly discard this immutable build only to submit the same
## source again on the next view refresh.
func is_active_token(token: int) -> bool:
	return token > 0 and int(_active.get("token", 0)) == token and int(_active.get("epoch", 0)) == _epoch

func cancel(token: int) -> bool:
	return cancel_with_status(token).get("accepted", false)

## Structured cancellation result for owners that must retain a lease until
## the worker-owned payload has been retired. This never waits or joins.
func cancel_with_status(token: int) -> Dictionary:
	for index in range(_pending.size()):
		if _pending[index].token == token:
			_pending.remove_at(index)
			return {"accepted":true,"state":"cancelled_before_dispatch","token":token}
	if _active.get("token",0) == token and _active.get("epoch",0) == _epoch:
		_active.cancelled = true
		_state.cancel()
		return {"accepted":true,"state":"cancel_requested","token":token}
	if _completed.get("token",0) == token and _completed.get("epoch",0) == _epoch:
		if _completed.ownsWorkerPayload: _queue_retirement(_completed.result, token)
		_completed.ownsWorkerPayload = false
		_completed.cancelled = true
		_completed.result = _terminal("cancelled","cancelled")
		return {"accepted":true,"state":"retirement_pending" if _retiring_tokens.has(token) else "cancelled", "token":token}
	return {"accepted":false,"state":"not_found","token":token}

func source_request_state(token: int) -> String:
	if token <= 0: return "absent"
	# Include an active old-epoch worker: reset() cooperatively cancels it, but
	# it is not drained until its returned payload passes through retirement.
	if _active.get("token", 0) == token: return "active"
	if _pending.any(func(entry): return int(entry.get("token", 0)) == token): return "pending"
	if _completed.get("token", 0) == token and _completed.get("epoch", 0) == _epoch:
		return "retirement_pending" if _retiring_tokens.has(token) else "completed"
	if _retiring_tokens.has(token): return "retirement_pending"
	return "absent"

func reset() -> int:
	_epoch += 1
	_pending.clear()
	if _completed.get("ownsWorkerPayload",false): _queue_retirement(_completed.result, int(_completed.get("token", 0)))
	_completed = {}
	_priority_burst = 0
	if _state != null: _state.cancel()
	return _epoch

func request_shutdown() -> void:
	_closing = true
	reset()

func retire_external_payload(payload: Dictionary, tokens: Array[int] = []) -> bool:
	# A lifecycle consumer may relinquish previously consumed immutable sources.
	# The same owned retirement worker handles final disposal, never a frame call.
	if _thread != null or not _completed.is_empty() or not _retired.is_empty(): return false
	_queue_retirement(payload, 0, tokens)
	return true

func _next_index() -> int:
	var indices: Array = range(_pending.size())
	var regular: Array = indices.filter(func(index):return not _pending[index].priority)
	var urgent: Array = indices.filter(func(index):return _pending[index].priority)
	var selected: Array = urgent if not urgent.is_empty() and (_priority_burst<MAX_PRIORITY_BURST or regular.is_empty()) else regular
	selected.sort_custom(func(a,b):return _pending[a].sourceKey < _pending[b].sourceKey)
	var index: int = selected[0]
	_priority_burst = _priority_burst+1 if _pending[index].priority else 0
	return index

func _start_thread(work: Callable) -> int:
	return _thread.start(work)

## Deterministic worker gate for focused queue ownership contracts only.
## Production admission never configures this callback.
func _set_worker_callable_for_test(callback: Callable) -> bool:
	if _thread != null or not _pending.is_empty() or not _active.is_empty(): return false
	if not callback.is_valid(): return false
	_worker_callable_for_test = callback
	return true

func _prepare_site(request: Dictionary, continuation: Callable, raw_stage_observer: Callable = Callable()) -> Dictionary:
	return Site.prepare(request.worldSeed,request.region,request.towns,request.ordinaryPolicy,continuation,raw_stage_observer)

func _run(request: Dictionary, state: RunState) -> Dictionary:
	if not state.advance("preparation_started"): return _terminal("cancelled","cancelled")
	state.begin_phase("rawPrepare")
	var raw := _prepare_site(request,state.advance,Callable(state,"observe_raw_prepare_stage"))
	state.finish_phase("rawPrepare")
	if state.is_cancelled(): return _terminal("cancelled","cancelled")
	if raw.get("status","") not in ["prepared","absent","failed","cancelled"]:
		return _terminal("failed","invalid_preparation_status")
	# Snapshot objects ONCE on the worker, then detach/freeze every container.
	# Small status polling and one-shot consumption never copy this payload.
	if not state.advance("snapshot_started"): return _terminal("cancelled","cancelled")
	state.begin_phase("snapshot")
	var result: Dictionary = raw.duplicate(true)
	if raw.status == "prepared":
		var blueprint: Variant = raw.get("blueprint")
		var furnishings: Variant = raw.get("furnishingPlan")
		if not blueprint is Object or not blueprint.has_method("snapshot") or not furnishings is Object or not furnishings.has_method("snapshot") or not furnishings.has_method("access_reservations_snapshot"):
			return _terminal("failed","incomplete_prepared_source")
		var blueprint_snapshot: Variant = blueprint.snapshot()
		var furnishing_snapshot: Variant = furnishings.snapshot()
		var reservations: Variant = furnishings.access_reservations_snapshot()
		if not blueprint_snapshot is Dictionary or not furnishing_snapshot is Dictionary or not reservations is Array:
			return _terminal("failed","invalid_source_snapshot")
		result.blueprint = blueprint_snapshot.duplicate(true)
		result.furnishingPlan = furnishing_snapshot.duplicate(true)
		result.furnishingPlan["accessReservations"] = reservations.duplicate(true)
	state.finish_phase("snapshot")
	var count := [0]
	state.begin_phase("freeze")
	if not _freeze(result,state,count,0):
		state.finish_phase("freeze")
		return _terminal("cancelled","cancelled") if state.is_cancelled() else _terminal("failed","invalid_or_unbounded_worker_payload")
	state.finish_phase("freeze")
	state.begin_phase("serialization")
	var result_bytes := var_to_bytes(result).size()
	state.finish_phase("serialization")
	if result_bytes > MAX_RESULT_BYTES: return _terminal("failed","worker_payload_byte_limit")
	if not state.advance("result_ready"): return _terminal("cancelled","cancelled")
	return result

func _store_completed(result: Dictionary, owns_worker_payload: bool = true) -> void:
	_completed = {"token":_active.token,"epoch":_active.epoch,"sourceKey":_active.sourceKey,"cancelled":_active.cancelled,"result":result,"ownsWorkerPayload":owns_worker_payload}

func _queue_retirement(result: Dictionary, token := 0, tokens: Array[int] = []) -> void:
	# Single ownership invariant: no source dispatch while this slot is held,
	# and repeated terminal cancellation never re-enqueues its small receipt.
	assert(_retired.is_empty())
	_retired = result
	if token > 0: _retiring_tokens[token] = true
	for retired_token: int in tokens:
		if retired_token > 0: _retiring_tokens[retired_token] = true

func _start_retirement() -> void:
	_retirement = RetirementState.new()
	_retirement.payload = _retired
	for token: Variant in _retiring_tokens: _retirement.tokens.append(int(token))
	_active = {"kind":"retirement","epoch":_epoch,"token":0,"sourceKey":"","cancelled":false}
	_state = RunState.new()
	_state.advance("retiring_source")
	_thread = Thread.new()
	_retirement_start_error = _start_thread(_retirement.release_payload)
	if _retirement_start_error != OK:
		# The queue retains the sole payload slot for retry; never free it on the
		# owner thread or claim shutdown complete because a worker failed to start.
		_thread = null
		_active = {}
		_state = null
		_retirement = null
		return
	_retired = {}
	# No main-thread payload alias remains. The worker owns final destruction.
	_retirement.transferred.post()

static func _terminal(status: String, reason: String) -> Dictionary:
	var result := {"status":status,"reason":reason,"terrainReady":false,"publicationReady":false}
	result.make_read_only()
	return result

static func _freeze(value: Variant, state: RunState, count: Array, depth: int) -> bool:
	count[0] += 1
	if count[0] > MAX_RESULT_VALUES or depth > MAX_RESULT_DEPTH: return false
	if count[0] % 512 == 0 and state.is_cancelled(): return false
	if value is Dictionary:
		for key in value:
			if not _freeze(key,state,count,depth+1) or not _freeze(value[key],state,count,depth+1): return false
		value.make_read_only()
	elif value is Array:
		for item in value:
			if not _freeze(item,state,count,depth+1): return false
		value.make_read_only()
	elif typeof(value) in [TYPE_OBJECT,TYPE_RID,TYPE_CALLABLE,TYPE_SIGNAL] or typeof(value) >= TYPE_PACKED_BYTE_ARRAY:
		# Packed buffers cannot be frozen. Current site manifests already export
		# ordinary Arrays; reject an unexpected mutable publication authority.
		return false
	return true

static func _canonical_request(seed: String, region: Vector2i, towns: Dictionary, policy: Dictionary) -> Dictionary:
	if seed.is_empty() or seed.length()>1024 or not Field._valid_region(region): return {}
	if not Survey.new()._valid_town_overrides(towns): return {}
	if not policy.get("regionCells") is int or policy.regionCells<34: return {}
	if not (policy.get("spawnChance") is int or policy.get("spawnChance") is float) or not is_finite(float(policy.spawnChance)) or policy.spawnChance<0 or policy.spawnChance>1: return {}
	var keys: Array = towns.keys()
	keys.sort_custom(func(a,b):return a.x<b.x or a.x==b.x and a.y<b.y)
	var canonical_towns := {}
	var identity_towns: Array = []
	for key: Vector2i in keys:
		var original: Dictionary = towns[key]
		var record := {} if original.is_empty() else {"regionX":key.x,"regionZ":key.y,"centerX":original.centerX,"centerZ":original.centerZ,"radius":original.radius,"level":float(original.level)}
		record.make_read_only()
		canonical_towns[key] = record
		identity_towns.append([key,record])
	canonical_towns.make_read_only()
	var canonical_policy := {"regionCells":policy.regionCells,"spawnChance":float(policy.spawnChance)}
	canonical_policy.make_read_only()
	var identity := [SOURCE_POLICY_REVISION,Survey.GENERATION_POLICY_VERSION,Engine.get_version_info().string,seed,region,identity_towns,canonical_policy]
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(var_to_bytes(identity))
	var result := {"worldSeed":seed,"region":region,"towns":canonical_towns,"ordinaryPolicy":canonical_policy,"sourceKey":digest.finish().hex_encode()}
	result.make_read_only()
	return result
