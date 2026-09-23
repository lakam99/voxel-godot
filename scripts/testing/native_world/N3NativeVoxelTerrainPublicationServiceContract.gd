extends SceneTree

const SERVICE = preload("res://scripts/terrain/NativeVoxelTerrainPublicationService.gd")

class FakeRuntime extends RefCounted:
	var receipts: Array[Dictionary] = []
	var reject_receipts := false
	var expected_seed := "contract-seed"
	var expected_terrain_instance := 7
	var expected_collision_owner_generation := 9
	var expected_accepted_revision := -1
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

class FakeOwner extends RefCounted:
	var replacements: Array[Dictionary] = []
	var advance_count := 0
	var pending_replacements := 1
	var inserted := false
	var active_demand_revision := -1
	var active_payload: Dictionary = {}
	var owner_snapshot := {"backendInstanceId":101,
		"backend":{"status":"ready", "sourceIdentity":{"algorithm":"sha256",
		"hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
		"terrainDeltaRevision":6}}
	func replace_demand(primary: Dictionary, viewers: Array, retained: Array,
			foreground: Array, bounds: Vector2i) -> Dictionary:
		replacements.append({"primary":primary, "viewers":viewers,
			"retained":retained, "foreground":foreground, "bounds":bounds})
		if pending_replacements > 0:
			pending_replacements -= 1
			return {"status":"pending", "reason":"desired_union_capacity"}
		active_demand_revision = int(primary.get("contractRevision", -1))
		active_payload = primary.duplicate(true)
		return {"status":"ready", "demandRevision":active_demand_revision}
	func advance() -> Dictionary:
		advance_count += 1
		var publication := {"status":"pending"}
		if inserted:
			publication = {"status":"ready", "state":"inserted_waiting_mesh",
				"insertionReceipt":"ready", "block":Vector3i(1, 0, -2), "generation":4}
			inserted = false
		return {"status":"pending" if publication.status == "pending" else "ready",
			"activeDemandRevision":active_demand_revision, "publication":publication}
	func snapshot() -> Dictionary:
		return owner_snapshot.duplicate(true)

var failures: Array[String] = []

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func demand(revision: int) -> Dictionary:
	return {"schema":SERVICE.SCHEMA, "demandRevision":revision,
		"configuredSeed":"contract-seed", "terrainInstanceId":7,
		"collisionOwnerGeneration":9, "primaryViewer":{"position":Vector3.ZERO,
		"distance":8, "contractRevision":revision}, "otherViewers":[], "retainedChunks":[],
		"foregroundChunks":[], "verticalBounds":Vector2i(-16, 32)}

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var sentinel_runtime := FakeRuntime.new()
	var sentinel_owner := FakeOwner.new()
	var sentinel_service := SERVICE.new()
	sentinel_owner.pending_replacements = 1
	sentinel_service.setup(sentinel_runtime, sentinel_owner)
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
	runtime.expected_accepted_revision = 0
	var baseline: Dictionary = service.advance(demand(0))
	check(baseline.get("demandStatus") == "ready" and int(baseline.get("demandRevision", -1)) == 0,
		"accepted baseline demand is established")
	owner.pending_replacements = 1
	runtime.expected_accepted_revision = 0
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
	runtime.expected_accepted_revision = 1
	var retry: Dictionary = service.advance(demand(1))
	check(retry.get("demandStatus") == "ready" and int(service.snapshot().acceptedDemandRevision) == 1,
		"identical revision is retried and accepted")
	check(owner.replacements.size() == 3 and owner.advance_count == 3,
		"retry reuses revision exactly once")
	var repeated: Dictionary = service.advance(demand(1))
	check(repeated.get("demandStatus") == "ready" \
			and int(repeated.get("demandRevision", -1)) == 1 \
			and owner.replacements.size() == 3,
		"accepted revision is not redundantly replanned")
	owner.inserted = true
	var inserted: Dictionary = service.advance(demand(1))
	check(inserted.get("receipt", {}).get("dataInserted") == true,
		"native data insertion has a receipt")
	check(inserted.get("receipt", {}).get("meshReady") == false \
			and inserted.get("receipt", {}).get("physicsReady") == false,
		"data insertion is never mesh or physics readiness")
	check(int(inserted.get("receipt", {}).get("demandRevision", -1)) == 1,
		"publication receipt binds accepted demand revision")
	owner.pending_replacements = 1
	runtime.expected_accepted_revision = 1
	var second := demand(2)
	var pending_two: Dictionary = service.advance(second)
	check(pending_two.get("demandStatus") == "pending" \
			and int(pending_two.get("receipt", {}).get("demandRevision", -1)) == 1 \
			and int(pending_two.get("receipt", {}).get("pendingProposalRevision", -1)) == 2,
		"receipt separates accepted demand from pending proposal")
	runtime.expected_accepted_revision = 3
	var newer: Dictionary = service.advance(demand(3))
	check(newer.get("demandStatus") == "ready" \
			and int(service.snapshot().acceptedDemandRevision) == 3,
		"newer full snapshot supersedes pending proposal")
	check(int(service.snapshot().supersededPendingRevisions) == 1,
		"superseded proposal is observable")
	check(runtime.receipts.size() == 7, "runtime validates every emitted receipt")
	var valid_receipt: Dictionary = runtime.receipts[-1].duplicate(true)
	for field in ["configuredSeed", "terrainInstanceId", "collisionOwnerGeneration",
			"demandRevision", "sourceRevision"]:
		var forged: Dictionary = valid_receipt.duplicate(true)
		match field:
			"configuredSeed": forged.configuredSeed = "wrong-seed"
			"terrainInstanceId": forged.terrainInstanceId = 700
			"collisionOwnerGeneration": forged.collisionOwnerGeneration = 900
			"demandRevision": forged.demandRevision = 33
			"sourceRevision": forged.sourceRevision = 66
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
	rejected_service.setup(rejected_runtime, rejected_owner)
	var rejected: Dictionary = rejected_service.advance(demand(0))
	var rejected_advance_count := rejected_owner.advance_count
	var after_reject: Dictionary = rejected_service.advance(demand(0))
	check(rejected.get("status") == "failed" \
			and rejected_service.snapshot().get("state") == "failed",
		"receipt validator rejection terminally fails service")
	check(after_reject.get("status") == "failed" \
			and rejected_owner.advance_count == rejected_advance_count,
		"terminal service does not continue advancing owner")
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
