extends SceneTree

const SERVICE = preload("res://scripts/terrain/NativeVoxelTerrainPublicationService.gd")

class FakeRuntime extends RefCounted:
	var receipts: Array[Dictionary] = []
	func validate_native_publication_receipt(receipt: Dictionary) -> Dictionary:
		receipts.append(receipt.duplicate(true))
		if receipt.get("schema") != SERVICE.RECEIPT_SCHEMA \
				or int(receipt.get("backendInstanceId", 0)) <= 0 \
				or receipt.get("ownerSourceCurrent") != true \
				or not receipt.get("sourceIdentity", {}) is Dictionary:
			return {"status":"failed", "reason":"receipt_identity_invalid"}
		if receipt.get("meshReady") == true or receipt.get("physicsReady") == true:
			return {"status":"failed", "reason":"data_receipt_promoted_to_readiness"}
		return {"status":"ready", "accepted":true}

class FakeOwner extends RefCounted:
	var replacements: Array[Dictionary] = []
	var advance_count := 0
	var pending_replacements := 1
	var inserted := false
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
		return {"status":"ready", "demandRevision":int(replacements[-1].get("revision", -1))}
	func advance() -> Dictionary:
		advance_count += 1
		var publication := {"status":"pending"}
		if inserted:
			publication = {"status":"ready", "state":"inserted_waiting_mesh",
				"insertionReceipt":"ready", "block":Vector3i(1, 0, -2), "generation":4}
			inserted = false
		return {"status":"pending" if publication.status == "pending" else "ready",
			"publication":publication}
	func snapshot() -> Dictionary:
		return owner_snapshot.duplicate(true)

var failures: Array[String] = []

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func demand(revision: int) -> Dictionary:
	return {"schema":SERVICE.SCHEMA, "demandRevision":revision,
		"configuredSeed":"contract-seed", "terrainInstanceId":7,
		"collisionOwnerGeneration":9, "primaryViewer":{"position":Vector3.ZERO,
		"distance":8}, "otherViewers":[], "retainedChunks":[],
		"foregroundChunks":[], "verticalBounds":Vector2i(-16, 32)}

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var runtime := FakeRuntime.new()
	var owner := FakeOwner.new()
	var service := SERVICE.new()
	check(service.setup(runtime, owner).get("status") == "ready", "service installs explicit collaborators")
	var first := demand(1)
	var pending: Dictionary = service.advance(first)
	check(pending.get("status") == "advanced" and pending.get("demandStatus") == "pending",
		"over-cap demand remains pending while old owner advances")
	check(int(service.snapshot().pendingDemandRevision) == 1, "pending revision retained")
	check(owner.advance_count == 1 and owner.replacements.size() == 1,
		"one owner advance and one initial proposal")
	check(pending.get("readinessClaim") == {"data":false, "mesh":false, "physics":false},
		"pending demand cannot claim publication readiness")
	var retry: Dictionary = service.advance(demand(1))
	check(retry.get("demandStatus") == "ready" and int(service.snapshot().acceptedDemandRevision) == 1,
		"identical revision is retried and accepted")
	check(owner.replacements.size() == 2 and owner.advance_count == 2,
		"retry reuses revision exactly once")
	var repeated: Dictionary = service.advance(demand(1))
	check(repeated.get("demandStatus") == "ready" and owner.replacements.size() == 2,
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
	var second := demand(2)
	var pending_two: Dictionary = service.advance(second)
	check(pending_two.get("demandStatus") == "pending" \
			and int(pending_two.get("receipt", {}).get("demandRevision", -1)) == 1 \
			and int(pending_two.get("receipt", {}).get("pendingProposalRevision", -1)) == 2,
		"receipt separates accepted demand from pending proposal")
	var newer: Dictionary = service.advance(demand(3))
	check(newer.get("demandStatus") == "ready" \
			and int(service.snapshot().acceptedDemandRevision) == 3,
		"newer full snapshot supersedes pending proposal")
	check(int(service.snapshot().supersededPendingRevisions) == 1,
		"superseded proposal is observable")
	var regressed: Dictionary = service.advance(demand(2))
	check(regressed.get("status") == "failed" \
			and regressed.get("reason") == "native_demand_revision_regressed",
		"revision regression fails closed")
	check(owner.advance_count == 6, "each valid advance pumps owner once")
	check(runtime.receipts.size() == 6, "runtime validates every emitted receipt")
	var report := {"schema":"n3-native-voxel-publication-service/v1",
		"passed":failures.is_empty(), "productionCutover":false,
		"evidenceLevel":"synthetic focused orchestration contract",
		"failures":failures, "metrics":{"ownerAdvances":owner.advance_count,
			"demandReplacements":owner.replacements.size(),
			"runtimeValidatedReceipts":runtime.receipts.size()},
		"doesNotProve":"No live VoxelTerrainRuntime demand mapping, bounded incremental planning, mesh/collision publication, or gameplay readiness. Service remains unreachable from default production."}
	var path := OS.get_environment("VWB_NATIVE_PUBLICATION_SERVICE_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)
