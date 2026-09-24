extends RefCounted
class_name NativeCollisionRetirementReceipt

## Retirement is authorized only by a drain receipt for this exact retained
## window installation. Tokens and leases alone can be reused across owner
## replacement, so bind the full source, membership and block identity too.
static func matches_record(window_token: String, receipt: Dictionary,
		record: Dictionary, lease: Dictionary) -> bool:
	var identity: Variant = record.get("identity")
	var source_identity: Variant = record.get("sourceIdentity")
	var membership: Variant = record.get("membershipProvenance")
	var blocks: Variant = record.get("blocks")
	var physical_owner_epoch: Variant = record.get("physicalOwnerEpoch")
	var receipt_blocks: Variant = receipt.get("residentBlocks")
	var receipt_required: Variant = receipt.get("requiredResidentBlocks")
	if not identity is Dictionary or not source_identity is Dictionary \
			or not membership is Dictionary or not blocks is Array \
			or not receipt_blocks is Array or not receipt_required is Array \
			or blocks.is_empty() \
			or not receipt.get("identity") is Dictionary \
			or not receipt.get("sourceIdentity") is Dictionary \
			or not receipt.get("membershipProvenance") is Dictionary \
			or not physical_owner_epoch is String or String(physical_owner_epoch).is_empty() \
			or not lease_matches_record(window_token, record, lease):
		return false
	if String(receipt.get("retirementLeaseId", "")) \
			!= String(lease.get("leaseId", "")) \
			or String(lease.get("leaseId", "")).is_empty() \
			or receipt.get("status") != "ready" \
			or not bool(receipt.get("drained", false)) \
			or int(receipt.get("remainingBodies", -1)) != 0 \
			or int(receipt.get("remainingPendingEntries", -1)) != 0 \
			or int(receipt.get("remainingLiveEntries", -1)) != 0 \
			or not bool(receipt.get("sourceReleased", false)) \
			or not bool(receipt.get("barrierOwnershipReleased", false)) \
			or receipt.get("windowToken") != window_token \
			or receipt.get("physicalOwnerEpoch") != physical_owner_epoch \
			or int(receipt.get("residentBlockCount", -1)) != blocks.size() \
			or receipt.get("identity") != identity \
			or receipt.get("sourceIdentity") != source_identity \
			or receipt.get("membershipProvenance") != membership:
		return false
	var expected_blocks: Array[String] = _canonical_block_ids(blocks)
	var received_blocks: Array[String] = _canonical_block_ids(receipt_blocks)
	var received_required: Array[String] = _canonical_block_ids(receipt_required)
	return expected_blocks.size() == blocks.size() \
		and received_blocks.size() == blocks.size() \
		and received_required.size() == blocks.size() \
		and expected_blocks == received_blocks \
		and expected_blocks == received_required


static func lease_matches_record(window_token: String, record: Dictionary,
		lease: Dictionary) -> bool:
	var identity: Variant = record.get("identity")
	var source_identity: Variant = record.get("sourceIdentity")
	var membership: Variant = record.get("membershipProvenance")
	var blocks: Variant = record.get("blocks")
	var physical_owner_epoch: Variant = record.get("physicalOwnerEpoch")
	var leased_blocks: Variant = lease.get("residentBlocks")
	if not identity is Dictionary or not source_identity is Dictionary \
			or not membership is Dictionary or not blocks is Array \
			or not physical_owner_epoch is String or String(physical_owner_epoch).is_empty() \
			or not leased_blocks is Array or blocks.is_empty() \
			or lease.get("windowToken") != window_token \
			or String(lease.get("leaseId", "")).is_empty() \
			or String(lease.get("expectedLayoutToken", "")).is_empty() \
			or lease.get("recordIdentity") != identity \
			or lease.get("physicalOwnerEpoch") != physical_owner_epoch \
			or lease.get("sourceIdentity") != source_identity \
			or lease.get("membershipProvenance") != membership:
		return false
	var expected_blocks: Array[String] = _canonical_block_ids(blocks)
	var leased_block_ids: Array[String] = _canonical_block_ids(leased_blocks)
	return expected_blocks.size() == blocks.size() \
		and leased_block_ids.size() == blocks.size() \
		and expected_blocks == leased_block_ids


static func _canonical_block_ids(blocks: Array) -> Array[String]:
	var result: Array[String] = []
	var seen := {}
	for block in blocks:
		if not block is Vector3i or seen.has(block):
			return []
		seen[block] = true
		result.append("%d,%d,%d" % [block.x, block.y, block.z])
	result.sort()
	return result
