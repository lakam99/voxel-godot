extends SceneTree

const SERVICE = preload("res://scripts/terrain/NativeVoxelTerrainPublicationService.gd")

class FakeRuntime extends RefCounted:
	var receipts: Array[Dictionary] = []
	var reject_receipts := false
	var expected_seed := "contract-seed"
	var expected_terrain_instance := 7
	var expected_collision_owner_generation := 9
	var expected_accepted_revision := -1
	var expected_native_revision := 0
	var expected_closure_token := ""
	var expected_required_block_count := 0
	var expected_consumer_id := 71
	var expected_owner_generation := 55
	var expected_demand_accepted := false
	var expected_source_revision := 6
	var expected_backend_instance := 101
	var expected_source_identity := {"algorithm":"sha256",
		"hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
	func validate_native_publication_receipt(receipt: Dictionary) -> Dictionary:
		receipts.append(receipt.duplicate(true))
		if reject_receipts:
			return {"status":"failed", "reason":"contract_runtime_rejected_receipt"}
		if receipt.get("schema") != SERVICE.RECEIPT_SCHEMA \
				or receipt.get("configuredSeed") != expected_seed \
				or int(receipt.get("terrainInstanceId", 0)) != expected_terrain_instance \
				or int(receipt.get("collisionOwnerGeneration", 0)) != expected_collision_owner_generation \
				or int(receipt.get("demandRevision", -99)) != expected_accepted_revision \
				or int(receipt.get("nativeDemandRevision", -99)) != expected_native_revision \
				or String(receipt.get("closureToken", "")) != expected_closure_token \
				or int(receipt.get("requiredBlockCount", -99)) != expected_required_block_count \
				or int(receipt.get("consumerId", 0)) != expected_consumer_id \
				or int(receipt.get("ownerGeneration", 0)) != expected_owner_generation \
				or receipt.get("demandAccepted") != expected_demand_accepted \
				or int(receipt.get("sourceRevision", -99)) != expected_source_revision \
				or int(receipt.get("backendInstanceId", 0)) != expected_backend_instance \
				or receipt.get("sourceIdentity") != expected_source_identity \
				or receipt.get("ownerSourceCurrent") != true \
				or not receipt.get("sourceIdentity", {}) is Dictionary:
			return {"status":"failed", "reason":"receipt_identity_invalid"}
		if receipt.get("meshReady") == true or receipt.get("physicsReady") == true:
			return {"status":"failed", "reason":"data_receipt_promoted_to_readiness"}
		if int(receipt.get("demandRevision", -1)) < 0 and (receipt.get("demandAccepted") == true \
				or receipt.get("dataInserted") == true or receipt.get("meshReady") == true \
				or receipt.get("physicsReady") == true):
			return {"status":"failed", "reason":"unbound_initial_receipt_claimed_readiness"}
		return {"status":"ready", "accepted":true}
	func validate_native_publication_owner_binding(binding: Dictionary) -> Dictionary:
		if int(binding.get("backendInstanceId", 0)) != expected_backend_instance \
				or int(binding.get("ownerGeneration", 0)) != expected_owner_generation \
			or int(binding.get("consumerId", 0)) != expected_consumer_id \
				or binding.get("sourceIdentity") != expected_source_identity \
				or int(binding.get("sourceRevision", -1)) != expected_source_revision \
			or String(binding.get("sourceSeedText", "")) != expected_seed:
			return {"status":"failed", "reason":"owner_binding_mismatch"}
		return {"status":"ready", "frozen":true}
	func validate_native_publication_retirement_receipt(evidence: Dictionary,
			owner_step: Dictionary, owner_state: Dictionary, binding: Dictionary) -> Dictionary:
		if int(evidence.get("backendInstanceId", 0)) != expected_backend_instance \
				or int(evidence.get("ownerGeneration", 0)) != expected_owner_generation \
				or evidence.get("sourceIdentity") != expected_source_identity \
				or int(evidence.get("sourceRevision", -1)) != expected_source_revision:
			return {"status":"failed", "reason":"retirement_identity_mismatch"}
		if evidence.get("viewerDetached") != true \
				or evidence.get("physicalBlocksUnloaded") != true \
				or evidence.get("leasesReleased") != true:
			return {"status":"pending", "reason":"outer_retirement_ack_pending"}
		if owner_step.is_empty(): return {"status":"ready", "outerRetirementValidated":true}
		if owner_step.get("drained") != true or owner_step.get("physicalBlocksUnloaded") != true \
				or owner_step.get("nativeWorkersDrained") != true \
				or owner_step.get("demandReleased") != true or owner_step.get("leasesReleased") != true \
				or owner_state.get("state") != "drained" \
				or int(owner_state.get("backendInstanceId", -1)) != 0:
			return {"status":"pending", "reason":"native_owner_retirement_pending"}
		var proof: Dictionary = owner_state.get("asyncStopReceipt", {})
		if proof.get("drained") != true or proof.get("physicalBlocksUnloaded") != true \
				or proof.get("nativeWorkersDrained") != true \
				or proof.get("demandReleased") != true or proof.get("leasesReleased") != true:
			return {"status":"failed", "reason":"owner_retirement_proof_incomplete"}
		return {"status":"ready", "outerRetirementValidated":true,
			"nativeRetirementValidated":true, "retirementProof":proof.duplicate(true)}

class FakeOwner extends RefCounted:
	var replacements: Array[Dictionary] = []
	var advance_count := 0
	var pending_replacements := 1
	var inserted := false
	var active_demand_revision := -1
	var active_payload: Dictionary = {}
	var lie_on_replace := false
	var fail_advance := false
	var native_demand_revision := 0
	var closure_token := ""
	var required_mesh_blocks := 0
	var drain_steps_remaining := 2
	var drain_count := 0
	var stop_count := 0
	var owner_snapshot := {"state":"active", "backendInstanceId":101,
		"ownerGeneration":55,
		"sourceIdentity":{"algorithm":"sha256",
		"hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
		"backend":{"status":"ready", "sourceIdentity":{"algorithm":"sha256",
		"hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
		"sourceSeedText":"contract-seed", "terrainDeltaRevision":6},
		"planner":{"consumerId":71,"sources":0,"desiredDataBlocks":0,
		"appliedDataBlocks":0,"deltaAckPending":false,"demandRevision":0,
		"closureToken":"","requiredMeshBlocks":0},
		"publisher":{"active":true,"demanded":0,"registered":0,"waitingSource":0,
		"inserted":0,"retiring":0,"orphaned":0},
		"artifactRequests":{"producerActive":false,"windowRecords":0,"activeWindows":0,
		"retirementLeases":0}}
	func replace_demand(primary: Dictionary, viewers: Array, retained: Array,
			foreground: Array, bounds: Vector2i) -> Dictionary:
		replacements.append({"primary":primary, "viewers":viewers,
			"retained":retained, "foreground":foreground, "bounds":bounds})
		if pending_replacements > 0:
			pending_replacements -= 1
			return {"status":"pending", "reason":"desired_union_capacity"}
		if lie_on_replace:
			return {"status":"ready", "demandRevision":99,
				"closureToken":"unbacked-closure", "requiredMeshBlocks":8,
				"consumerId":71}
		active_demand_revision = int(primary.get("contractRevision", -1))
		active_payload = primary.duplicate(true)
		native_demand_revision += 1
		closure_token = "closure-%d" % native_demand_revision
		required_mesh_blocks = 8
		owner_snapshot.planner.sources = 1
		owner_snapshot.planner.desiredDataBlocks = 27
		owner_snapshot.planner.demandRevision = native_demand_revision
		owner_snapshot.planner.closureToken = closure_token
		owner_snapshot.planner.requiredMeshBlocks = required_mesh_blocks
		return {"status":"ready", "demandRevision":native_demand_revision,
			"closureToken":closure_token, "requiredMeshBlocks":required_mesh_blocks,
			"consumerId":71}
	func advance() -> Dictionary:
		advance_count += 1
		if fail_advance: return {"status":"failed", "reason":"contract_advance_failed"}
		var publication := {"status":"pending"}
		if inserted:
			publication = {"status":"ready", "state":"inserted_waiting_mesh",
				"insertionReceipt":"ready", "block":Vector3i(1, 0, -2), "generation":4}
			inserted = false
		return {"status":"pending" if publication.status == "pending" else "ready",
			"activeDemandRevision":active_demand_revision, "publication":publication}
	func snapshot() -> Dictionary:
		return owner_snapshot.duplicate(true)
	func request_stop() -> Dictionary:
		stop_count += 1
		owner_snapshot.state = "stopping_async"
		return {"status":"pending", "reason":"contract_retirement_started"}
	func drain_step() -> Dictionary:
		drain_count += 1
		if drain_steps_remaining > 0:
			drain_steps_remaining -= 1
			return {"status":"pending", "reason":"contract_worker_or_block_pending"}
		owner_snapshot.state = "drained"
		owner_snapshot.backendInstanceId = 0
		owner_snapshot.backend = {}
		owner_snapshot.planner = {}
		owner_snapshot.publisher = {}
		owner_snapshot.artifactRequests = {}
		owner_snapshot.asyncStopReceipt = {"drained":true,
			"physicalBlocksUnloaded":true,"nativeWorkersDrained":true,
			"demandReleased":true,"leasesReleased":true}
		return {"status":"ready", "drained":true,"physicalBlocksUnloaded":true,
			"nativeWorkersDrained":true,"demandReleased":true,"leasesReleased":true}

var failures: Array[String] = []

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func demand(revision: int) -> Dictionary:
	return {"schema":SERVICE.SCHEMA, "demandRevision":revision,
		"configuredSeed":"contract-seed", "terrainInstanceId":7,
		"collisionOwnerGeneration":9, "primaryViewer":{"position":Vector3.ZERO,
		"distance":8, "contractRevision":revision}, "otherViewers":[], "retainedChunks":[],
		"foregroundChunks":[], "verticalBounds":Vector2i(-16, 32)}

func expect_receipt(runtime: FakeRuntime, external_revision: int,
		native_revision: int, closure: String, block_count: int,
		accepted: bool) -> void:
	runtime.expected_accepted_revision = external_revision
	runtime.expected_native_revision = native_revision
	runtime.expected_closure_token = closure
	runtime.expected_required_block_count = block_count
	runtime.expected_demand_accepted = accepted

func retirement_evidence(detached: bool) -> Dictionary:
	return {"backendInstanceId":101, "ownerGeneration":55,
		"sourceIdentity":{"algorithm":"sha256",
		"hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
		"sourceRevision":6, "viewerDetached":detached,
		"physicalBlocksUnloaded":detached, "leasesReleased":detached}

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var sentinel_runtime := FakeRuntime.new()
	var sentinel_owner := FakeOwner.new()
	var sentinel_service := SERVICE.new()
	sentinel_owner.pending_replacements = 1
	check(sentinel_service.setup(sentinel_runtime, sentinel_owner).get("status") == "ready",
		"virgin empty owner is accepted")
	var first_pending: Dictionary = sentinel_service.advance(demand(0))
	check(first_pending.get("status") == "advanced" \
			and int(first_pending.get("receipt", {}).get("demandRevision", 0)) == -1 \
			and first_pending.get("receipt", {}).get("pendingProposalRevision") == 0,
		"first pending proposal uses the no-accepted-revision sentinel")
	check(first_pending.get("readinessClaim") == {"data":false, "mesh":false, "physics":false},
		"unbound initial pending receipt claims no readiness")
	check(first_pending.get("receipt", {}).get("dataInserted") == false,
		"unbound initial receipt explicitly reports no data insertion")
	check(sentinel_owner.advance_count == 1, "initial pending still pumps owner once")

	var runtime := FakeRuntime.new()
	var owner := FakeOwner.new()
	var service := SERVICE.new()
	check(service.setup(runtime, owner).get("status") == "ready", "service installs explicit collaborators")
	owner.pending_replacements = 0
	expect_receipt(runtime, 0, 1, "closure-1", 8, true)
	var baseline: Dictionary = service.advance(demand(0))
	check(baseline.get("demandStatus") == "ready" and int(baseline.get("demandRevision", -1)) == 0,
		"accepted baseline demand is established")
	owner.pending_replacements = 1
	expect_receipt(runtime, 0, 1, "closure-1", 8, false)
	var pending: Dictionary = service.advance(demand(1))
	check(pending.get("status") == "advanced" and pending.get("demandStatus") == "pending",
		"over-cap demand remains pending while old owner advances")
	check(int(service.snapshot().pendingDemandRevision) == 1 and int(pending.get("demandRevision", -1)) == 0,
		"pending revision retained separately from accepted revision")
	check(int(pending.get("nativeStep", {}).get("activeDemandRevision", -1)) == 0,
		"previously accepted demand remains active during capacity pending")
	check(int(owner.active_payload.get("contractRevision", -1)) == 0,
		"owner retains accepted payload while newer replacement is capacity-pending")
	check(owner.advance_count == 2 and owner.replacements.size() == 2,
		"one owner advance per call and one proposal per new revision")
	check(pending.get("readinessClaim") == {"data":false, "mesh":false, "physics":false},
		"pending demand cannot claim publication readiness")
	expect_receipt(runtime, 1, 2, "closure-2", 8, true)
	var retry: Dictionary = service.advance(demand(1))
	check(retry.get("demandStatus") == "ready" and int(service.snapshot().acceptedDemandRevision) == 1,
		"identical revision is retried and accepted")
	check(owner.replacements.size() == 3 and owner.advance_count == 3,
		"retry reuses revision exactly once")
	expect_receipt(runtime, 1, 2, "closure-2", 8, true)
	var repeated: Dictionary = service.advance(demand(1))
	check(repeated.get("demandStatus") == "ready" \
			and int(repeated.get("demandRevision", -1)) == 1 \
			and owner.replacements.size() == 3,
		"accepted revision is not redundantly replanned")
	owner.inserted = true
	expect_receipt(runtime, 1, 2, "closure-2", 8, true)
	var inserted: Dictionary = service.advance(demand(1))
	check(inserted.get("receipt", {}).get("dataInserted") == true,
		"native data insertion has a receipt")
	check(inserted.get("receipt", {}).get("meshReady") == false \
			and inserted.get("receipt", {}).get("physicsReady") == false,
		"data insertion is never mesh or physics readiness")
	check(int(inserted.get("receipt", {}).get("demandRevision", -1)) == 1,
		"publication receipt binds accepted demand revision")
	owner.pending_replacements = 1
	expect_receipt(runtime, 1, 2, "closure-2", 8, false)
	var second := demand(2)
	var pending_two: Dictionary = service.advance(second)
	check(pending_two.get("demandStatus") == "pending" \
			and int(pending_two.get("receipt", {}).get("demandRevision", -1)) == 1 \
			and int(pending_two.get("receipt", {}).get("pendingProposalRevision", -1)) == 2,
		"receipt separates accepted demand from pending proposal")
	expect_receipt(runtime, 3, 3, "closure-3", 8, true)
	var newer: Dictionary = service.advance(demand(3))
	check(newer.get("demandStatus") == "ready" \
			and int(service.snapshot().acceptedDemandRevision) == 3,
		"newer full snapshot supersedes pending proposal")
	check(int(service.snapshot().supersededPendingRevisions) == 1,
		"superseded proposal is observable")
	check(runtime.receipts.size() == 7, "runtime validates every emitted receipt")
	var valid_receipt: Dictionary = runtime.receipts[-1].duplicate(true)
	for field in ["configuredSeed", "terrainInstanceId", "collisionOwnerGeneration",
			"demandRevision", "nativeDemandRevision", "closureToken",
			"requiredBlockCount", "consumerId", "ownerGeneration", "sourceRevision"]:
		var forged: Dictionary = valid_receipt.duplicate(true)
		match field:
			"configuredSeed": forged.configuredSeed = "wrong-seed"
			"terrainInstanceId": forged.terrainInstanceId = 700
			"collisionOwnerGeneration": forged.collisionOwnerGeneration = 900
			"demandRevision": forged.demandRevision = 33
			"sourceRevision": forged.sourceRevision = 66
			"nativeDemandRevision": forged.nativeDemandRevision = 44
			"closureToken": forged.closureToken = "forged-closure"
			"requiredBlockCount": forged.requiredBlockCount = 999
			"consumerId": forged.consumerId = 999
			"ownerGeneration": forged.ownerGeneration = 999
		check(runtime.validate_native_publication_receipt(forged).get("status") == "failed",
			"runtime rejects forged receipt mismatch: %s" % field)
	var regressed: Dictionary = service.advance(demand(2))
	check(regressed.get("status") == "failed" \
			and regressed.get("reason") == "native_demand_revision_regressed",
		"revision regression fails closed")
	check(owner.advance_count == 7, "each valid advance pumps owner once")
	var rejected_runtime := FakeRuntime.new()
	rejected_runtime.reject_receipts = true
	var rejected_owner := FakeOwner.new()
	rejected_owner.pending_replacements = 0
	var rejected_service := SERVICE.new()
	expect_receipt(rejected_runtime, 0, 1, "closure-1", 8, true)
	check(rejected_service.setup(rejected_runtime, rejected_owner).get("status") == "ready",
		"rejection fixture starts from a virgin owner")
	var rejected: Dictionary = rejected_service.advance(demand(0))
	var rejected_advance_count := rejected_owner.advance_count
	var after_reject: Dictionary = rejected_service.advance(demand(0))
	check(rejected.get("status") == "failed_draining" \
			and rejected_service.snapshot().get("state") == "failed_draining" \
			and rejected_owner.stop_count == 1,
		"receipt rejection requests terminal owner retirement")
	check(after_reject.get("status") == "failed_draining" \
			and rejected_owner.advance_count == rejected_advance_count,
		"terminal service does not continue advancing owner")
	var not_detached: Dictionary = rejected_service.drain_step(retirement_evidence(false))
	check(not_detached.get("status") == "failed_draining" \
			and rejected_owner.drain_count == 0,
		"drain requires external viewer/physical/lease retirement before owner work")
	var drained: Dictionary = {}
	for step in range(5):
		drained = rejected_service.drain_step(retirement_evidence(true))
		if drained.get("cleanupComplete") == true: break
	check(drained.get("status") == "failed" and drained.get("cleanupComplete") == true \
			and rejected_owner.drain_count == 3 \
			and rejected_service.snapshot().get("cleanupComplete") == true,
		"validator failure stays draining through bounded owner drain and exact final proof")

	var reused_runtime := FakeRuntime.new()
	var reused_owner := FakeOwner.new()
	reused_owner.owner_snapshot.planner.sources = 1
	var reused_service := SERVICE.new()
	check(reused_service.setup(reused_runtime, reused_owner).get("reason") \
			== "native_owner_planner_not_virgin",
		"setup rejects reused owner with prior demand")
	var lying_runtime := FakeRuntime.new()
	var lying_owner := FakeOwner.new()
	lying_owner.pending_replacements = 0
	lying_owner.lie_on_replace = true
	var lying_service := SERVICE.new()
	check(lying_service.setup(lying_runtime, lying_owner).get("status") == "ready",
		"no-op owner fixture begins virgin")
	var lied: Dictionary = lying_service.advance(demand(0))
	check(lied.get("status") == "failed_draining"
			and lied.get("context", {}).get("plannerReceipt", {}).get("reason") \
				== "native_replace_receipt_not_current_planner"
			and lying_owner.advance_count == 0,
		"external revision is rejected when owner reports ready without changing planner tuple")

	var step_runtime := FakeRuntime.new()
	var step_owner := FakeOwner.new()
	step_owner.pending_replacements = 0
	var step_service := SERVICE.new()
	expect_receipt(step_runtime, 0, 1, "closure-1", 8, true)
	step_service.setup(step_runtime, step_owner)
	step_service.advance(demand(0))
	step_owner.fail_advance = true
	var native_failed: Dictionary = step_service.advance(demand(0))
	check(native_failed.get("status") == "failed_draining" \
			and step_owner.stop_count == 1,
		"native-step failure also enters required retirement")
	var native_drained: Dictionary = {}
	for step in range(5):
		native_drained = step_service.drain_step(retirement_evidence(true))
		if native_drained.get("cleanupComplete") == true: break
	check(native_drained.get("status") == "failed"
			and native_drained.get("cleanupComplete") == true
			and native_drained.get("retirementReceipt", {}).get("nativeRetirementValidated") == true
			and step_service.snapshot().get("state") == "failed"
			and step_owner.drain_count == 3,
		"native-step failure reaches terminal failure only after bounded native retirement proof")
	var report := {"schema":"n3-native-voxel-publication-service/v1",
		"passed":failures.is_empty(), "productionCutover":false,
		"evidenceLevel":"synthetic focused orchestration contract",
		"failures":failures, "metrics":{"ownerAdvances":owner.advance_count + sentinel_owner.advance_count \
			+ rejected_owner.advance_count,
			"demandReplacements":owner.replacements.size(),
			"runtimeValidatedReceipts":runtime.receipts.size()},
		"doesNotProve":"No live VoxelTerrainRuntime demand mapping, bounded incremental planning, mesh/collision publication, or gameplay readiness. Service remains unreachable from default production."}
	var path := OS.get_environment("VWB_NATIVE_PUBLICATION_SERVICE_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)
