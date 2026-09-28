extends RefCounted
## One worker's bounded diagnostic call stack. Never consulted by production.
static var rows: Dictionary = {}
static var counters: Dictionary = {}
static var stack: Array[Dictionary] = []
static var errors: Array[String] = []
static var worker_id: int = 0
static var max_depth: int = 0
static var serial: int = 0

static func reset() -> void:
	rows = {}; counters = {}; stack = []; errors = []
	worker_id = OS.get_thread_caller_id(); max_depth = 0; serial = 0

static func begin_span(label: String, context: String = "") -> Dictionary:
	if OS.get_thread_caller_id() != worker_id: _error("timing_thread_changed")
	if not rows.has(label):
		if rows.size() >= 96: _error("timing_row_limit")
		rows[label] = {"calls":0,"inclusiveUsec":0,"exclusiveUsec":0,
			"maxInclusiveUsec":0,"maxExclusiveUsec":0,"slowestContext":""}
	serial += 1
	var token: Dictionary = {"serial":serial,"label":label,"context":context,
		"startedUsec":Time.get_ticks_usec(),"childUsec":0}
	stack.append(token)
	max_depth = maxi(max_depth,stack.size())
	if stack.size() > 32: _error("timing_depth_limit")
	return token

static func end_span(token: Dictionary) -> void:
	var now: int = Time.get_ticks_usec()
	if OS.get_thread_caller_id() != worker_id: _error("timing_thread_changed")
	if stack.is_empty() or not is_same(stack.back(),token): _error("timing_stack_mismatch"); return
	stack.pop_back()
	var elapsed: int = now-int(token.startedUsec)
	var exclusive: int = elapsed-int(token.childUsec)
	if exclusive < 0: _error("timing_negative_exclusive")
	var row: Dictionary = rows[token.label]
	row.calls += 1; row.inclusiveUsec += elapsed; row.exclusiveUsec += exclusive
	if elapsed > int(row.maxInclusiveUsec):
		row.maxInclusiveUsec = elapsed; row.slowestContext = token.context
	row.maxExclusiveUsec = maxi(int(row.maxExclusiveUsec),exclusive)
	if not stack.is_empty(): stack.back().childUsec += elapsed

static func add_count(label: String, amount: int) -> void:
	counters[label] = int(counters.get(label,0))+amount

static func finish() -> Dictionary:
	if not stack.is_empty(): _error("timing_unclosed_spans")
	var exclusive_total: int = 0
	for row: Dictionary in rows.values(): exclusive_total += int(row.exclusiveUsec)
	var root_elapsed: int = int(rows.get("lower_total",{}).get("inclusiveUsec",-1))
	if exclusive_total != root_elapsed: _error("timing_exclusive_partition_mismatch")
	return {"schema":"citadel-lower-phase-timing/v1","valid":errors.is_empty(),
		"rows":rows.duplicate(true),"counters":counters.duplicate(),"errors":errors.duplicate(),
		"workerThreadId":worker_id,"spans":serial,"maximumDepth":max_depth,
		"exclusivePartitionUsec":exclusive_total,"instrumentedCallUsec":root_elapsed,
		"timingSemantics":"Nested wall-clock call spans, not CPU samples. Inclusive rows overlap; exclusive rows partition the instrumented lower call. Parent exclusive time includes timer bookkeeping and all uninstrumented descendants. No subtraction against an uninstrumented second run.",
		"indexCoverage":"assembly_support_index times the existing AssemblyProof override's super call exactly. The three original base-Blueprint validations retain native eligibility; their index cost remains inside physical_validation_base. validation_grid_admission is the bounds/work-limit audit, not index construction."}

static func _error(message: String) -> void:
	if errors.size()<8 and not errors.has(message): errors.append(message)
