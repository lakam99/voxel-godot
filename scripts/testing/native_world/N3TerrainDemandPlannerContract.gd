extends SceneTree

const PLANNER = preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
var failures: Array[String] = []
var observations: Array[Dictionary] = []

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var planner = PLANNER.new()
	check(planner.setup(71).get("status") == "ready", "single owner setup")
	var startup: Dictionary = planner.replace_sources(
		{"position":Vector3.ZERO, "distance":80}, [], [], [], Vector2i(-16, 48))
	check(startup.get("status") == "ready", "startup desired")
	check(int(startup.get("desiredDataBlocks", 0)) == 1183, "startup 13x13x7 halo")
	var first: Dictionary = planner.next_delta()
	check(first.get("status") == "ready" and first.get("consumerId") == 71,
		"stable publisher consumer")
	check((first.get("addBlocks", []) as Array).size() == 128,
		"bounded first add")
	check(planner.next_delta() == first, "unacknowledged delta replay")
	check(planner.acknowledge_delta(int(first.ticket), false).get("status") == "pending",
		"capacity pending retained")
	check(planner.next_delta() == first, "capacity retry preserves exact delta")
	check(planner.acknowledge_delta(int(first.ticket), true).get("status") == "ready",
		"accepted delta advances")
	var next: Dictionary = planner.next_delta()
	check(next.get("ticket") != first.get("ticket"), "new ticket after ack")
	check(planner.replace_sources({"position":Vector3.ZERO, "distance":80}, [], [], [],
		Vector2i(-16, 48)).get("reason") == "delta_ack_pending", "no lost in-flight delta")
	check(planner.acknowledge_delta(int(next.ticket), true).get("status") == "ready",
		"second batch ack")
	var batches := 2
	while true:
		var delta: Dictionary = planner.next_delta()
		if delta.status == "idle": break
		check((delta.addBlocks as Array).size() + (delta.removeBlocks as Array).size() <= 128,
			"each delta bounded")
		planner.acknowledge_delta(int(delta.ticket), true)
		batches += 1
		if batches > 20:
			check(false, "startup drain bounded")
			break
	check(int(planner.diagnostics().appliedDataBlocks) == 1183, "startup all applied")
	observations.append({"phase":"startup", "desiredDataBlocks":1183, "batches":batches})

	var full: Dictionary = planner.replace_sources(
		{"position":Vector3.ZERO, "distance":96}, [], [], [], Vector2i(-68, 97))
	check(full.get("status") == "ready" and full.get("desiredDataBlocks") == 3150,
		"full primary 15x15x14 halo")
	var aux: Dictionary = planner.replace_sources(
		{"position":Vector3.ZERO, "distance":96},
		[{"kind":"startup", "id":"town-east", "position":Vector3(2000, 0, 0), "distance":128}],
		[], [], Vector2i(-68, 97))
	check(aux.get("status") == "ready" and aux.get("desiredDataBlocks") == 8204,
		"disjoint startup auxiliary exact union")
	var refs: Dictionary = planner.replace_sources(
		{"position":Vector3.ZERO, "distance":96},
		[{"kind":"startup", "id":"town-east", "position":Vector3(2000, 0, 0), "distance":128}],
		[Vector2i.ZERO], [Vector2i.ZERO], Vector2i(-68, 97))
	check(refs.get("status") == "ready" and refs.get("desiredDataBlocks") == 8204,
		"retained and foreground overlap reference-counted union")
	check(planner.source_ids() == ["chunk:foreground:0:0", "chunk:retained:0:0",
		"viewer:primary:primary", "viewer:startup:town-east"],
		"stable source identities")
	var duplicate: Dictionary = planner.replace_sources({},
		[{"kind":"startup", "id":"dup", "position":Vector3.ZERO, "distance":80},
		 {"kind":"startup", "id":"dup", "position":Vector3.ZERO, "distance":80}],
		[], [], Vector2i(-16, 48))
	check(duplicate.get("reason") == "duplicate_source_id", "duplicate source rejected")
	check(int(planner.diagnostics().desiredDataBlocks) == 8204,
		"failed replacement preserves previous desired union")
	var over: Array[Dictionary] = []
	for index in range(7):
		over.append({"kind":"secondary", "id":"far-%d" % index,
			"position":Vector3(float(index * 2000), 0, 4000), "distance":128})
	var overflow: Dictionary = planner.replace_sources({}, over, [], [], Vector2i(-68, 97))
	check(overflow.get("status") == "pending" and overflow.get("reason") == "desired_union_capacity",
		"oversized union retryable and not installed")
	check(int(planner.diagnostics().desiredDataBlocks) == 8204,
		"overflow preserves previous demand")
	var moved: Dictionary = planner.replace_sources(
		{"position":Vector3(1000, 0, 0), "distance":96}, [], [], [], Vector2i(-68, 97))
	check(moved.get("status") == "ready" and moved.get("desiredDataBlocks") == 3150,
		"moved viewer changes desired frontier")
	var moving_delta: Dictionary = planner.next_delta()
	check((moving_delta.get("addBlocks", []) as Array).size() == 64
		and (moving_delta.get("removeBlocks", []) as Array).size() == 64,
		"handoff advances add and retirement together")
	check(planner.acknowledge_delta(int(moving_delta.ticket), false).get("status") == "pending"
		and planner.next_delta() == moving_delta, "handoff retry unchanged")
	check(planner.acknowledge_delta(int(moving_delta.ticket), true).get("status") == "ready",
		"handoff acknowledgement advances both frontiers")
	var priority_planner = PLANNER.new()
	priority_planner.setup(71)
	priority_planner.replace_sources({"position":Vector3(2000, 0, 0), "distance":96},
		[], [], [Vector2i.ZERO], Vector2i(-68, 97))
	var priority_delta: Dictionary = priority_planner.next_delta()
	var priority_first: Vector3i = priority_delta.addBlocks[0]
	check(priority_first.x >= -1 and priority_first.x <= 2,
		"foreground safety demand precedes distant appearance")
	observations.append({"phase":"full", "primaryBlocks":3150,
		"primaryPlusAux":8204, "overflow":overflow,
		"handoffAddBlocks":(moving_delta.addBlocks as Array).size(),
		"handoffRemoveBlocks":(moving_delta.removeBlocks as Array).size()})
	var partitioned = PLANNER.new()
	partitioned.setup(72)
	var large: Dictionary = partitioned.replace_sources(
		{"position":Vector3.ZERO, "distance":128}, [], [], [], Vector2i(0,256))
	var layout: Dictionary = partitioned.collision_mesh_window_layout()
	var union := {}
	var max_window := 0
	for window: Dictionary in layout.get("windows", []):
		max_window = maxi(max_window, (window.blocks as Array).size())
		for block: Vector3i in window.blocks:
			check(not union.has(block), "spatial window duplicate rejected")
			union[block] = true
	check(large.get("status") == "ready"
		and int(layout.get("requiredBlockCount", 0)) == 4913
		and union.size() == 4913
		and int(layout.get("windowCount", 0)) > 1
		and max_window <= 4096
		and union.keys().size() == (layout.get("requiredBlocks", []) as Array).size(),
		"17 cubed closure partitions without gaps or over-capacity windows")
	var same_layout: Dictionary = partitioned.collision_mesh_window_layout()
	check(same_layout == layout, "identical 4913-block demand retains window tokens")
	observations.append({"phase":"partitioned_17_cubed",
		"requiredBlocks":layout.get("requiredBlockCount", 0),
		"windows":layout.get("windowCount", 0), "maxWindowBlocks":max_window,
		"logicalClosureToken":layout.get("logicalClosureToken", "")})

	var output := {"schema":"n3-terrain-demand-planner-contract/v1",
		"passed":failures.is_empty(), "evidenceLevel":"pure-headless-planner-contract",
		"productionCutover":false, "failures":failures, "observations":observations}
	var path := OS.get_environment("VWB_TERRAIN_DEMAND_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(output, "\t"))
	quit(0 if output.passed else 1)
