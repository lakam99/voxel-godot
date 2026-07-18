extends Node3D
class_name TreeChunkBatchRenderer

## VOX-134 candidate A: a chunk/material/LOD-owned renderer experiment.
##
## This class deliberately has no collision, save, prop, terrain, or gameplay
## authority.  It consumes the same immutable mathematical recipes and shared
## branch/foliage primitives as ProceduralTreeVisualFactory, then owns only GPU
## instance slots.  Keeping it isolated lets us measure the batching boundary
## before replacing the proven per-tree hybrid renderer in live gameplay.

const VisualFactoryScript := preload("res://scripts/visual/ProceduralTreeVisualFactory.gd")

const MAX_BRANCH_SLOTS_PER_BATCH := 4096
const FOLIAGE_VARIANT_COUNT := 4
# Fixed capacity is split by the same four deterministic cluster meshes that
# the production hybrid renderer uses.  Combining all four shapes into one
# per-instance mesh would change a tree's crown density, so that is not an
# acceptable batching shortcut.
const MAX_FOLIAGE_SLOTS_PER_VARIANT := 2048
const BATCH_CULL_EXTENT := 96.0
# MultiMesh stores one 3D transform and one custom-data colour per instance.
# This is deliberately an estimate rather than a renderer readback, but makes
# the fixed-capacity trade-off explicit in the candidate comparison report.
const ESTIMATED_INSTANCE_BYTES := 64

var visual_factory = VisualFactoryScript.new()
var batches := {}
var tree_records := {}
var published_tree_count := 0
var removal_swap_count := 0
var rejected_tree_count := 0
var batch_create_count := 0

func _ready() -> void:
	visual_factory.prewarm_runtime_resources()

func add_tree(
	tree_id: String,
	recipe: Dictionary,
	biome: String,
	chunk_key: String,
	world_origin: Vector3
) -> bool:
	if tree_id.strip_edges() == "" or recipe.is_empty():
		return false
	if tree_records.has(tree_id):
		remove_tree(tree_id)
	var lod_tier := String((recipe.get("renderLod", {}) as Dictionary).get("tier", "near"))
	if lod_tier == "impostor":
		# Candidate A deliberately measures shared branch/foliage primitives. The
		# established billboard impostor remains separate in this prototype.
		return false
	var architecture := String(recipe.get("architecture", "broadleaf"))
	var all_branches := typed_dictionary_array(recipe.get("branches", []))
	# Candidate A must retain the production renderer's single continuous
	# order-zero bole. Only non-zero-order wood is suitable for the shared
	# primitive batch; otherwise this experiment would reintroduce the visible
	# stack-of-cylinders trunk defect that the hybrid renderer fixed.
	var branches := runtime_distal_branches(all_branches)
	var foliage := typed_dictionary_array(recipe.get("foliage", []))
	if all_branches.is_empty() and foliage.is_empty():
		return false
	var key := batch_key(chunk_key, architecture, biome, lod_tier)
	var batch: Dictionary = batches.get(key, {})
	if batch.is_empty():
		batch = create_batch(key, architecture, biome, lod_tier, VisualFactoryScript.recipe_casts_shadows(recipe))
		batches[key] = batch
	var foliage_requested := foliage_variant_counts(foliage)
	var foliage_live: PackedInt32Array = batch.get("foliageLive", PackedInt32Array())
	if int(batch.get("branchLive", 0)) + branches.size() > MAX_BRANCH_SLOTS_PER_BATCH \
		or foliage_exceeds_capacity(foliage_live, foliage_requested):
		rejected_tree_count += 1
		return false
	var bole_visual := visual_factory.instantiate_runtime_bole(recipe, all_branches, biome)
	if bole_visual != null:
		bole_visual.name = "ContinuousBole_%s" % tree_id
		bole_visual.position = world_origin
		(batch.get("root", null) as Node3D).add_child(bole_visual)
	var branch_slots: Array[int] = []
	var branch_start := int(batch.get("branchLive", 0))
	var branch_multi_mesh := batch.get("branchMultiMesh", null) as MultiMesh
	for local_index in range(branches.size()):
		var branch: Dictionary = branches[local_index]
		var slot := branch_start + local_index
		var start: Vector3 = world_origin + (branch.get("start", Vector3.ZERO) as Vector3)
		var end: Vector3 = world_origin + (branch.get("end", Vector3.UP) as Vector3)
		var radius_start := maxf(0.025, float(branch.get("radiusStart", 0.1)))
		var radius_end := maxf(0.012, float(branch.get("radiusEnd", radius_start * 0.5)))
		branch_multi_mesh.set_instance_transform(slot, visual_factory.branch_transform(start, end, radius_start))
		branch_multi_mesh.set_instance_custom_data(slot, Color(
			clampf(radius_end / radius_start, 0.03, 1.0),
			clampf(float(branch.get("windWeight", 0.0)), 0.0, 1.0),
			fmod(stable_unit("chunk-branch-phase:%s:%d" % [tree_id, local_index]), 1.0),
			stable_unit("chunk-bark:%s:%d" % [tree_id, local_index])
		))
		set_slot_owner(batch, "branch", slot, tree_id, local_index)
		branch_slots.append(slot)
	batch["branchLive"] = branch_start + branches.size()
	branch_multi_mesh.visible_instance_count = int(batch.get("branchLive", 0))
	var foliage_slots: Array[Dictionary] = []
	var foliage_multi_meshes: Array = batch.get("foliageMultiMeshes", [])
	for local_index in range(foliage.size()):
		var anchor: Dictionary = foliage[local_index]
		var rotation: Vector3 = anchor.get("rotation", Vector3.ZERO)
		var scale: Vector3 = anchor.get("scale", Vector3.ONE)
		var cluster_variant := clampi(int(anchor.get("clusterVariant", 0)), 0, 3)
		var slot := foliage_live[cluster_variant]
		var foliage_multi_mesh := foliage_multi_meshes[cluster_variant] as MultiMesh
		foliage_multi_mesh.set_instance_transform(
			slot,
			Transform3D(Basis.from_euler(rotation).scaled(scale), world_origin + (anchor.get("position", Vector3.ZERO) as Vector3))
		)
		foliage_multi_mesh.set_instance_custom_data(slot, Color(
			fmod(stable_unit("chunk-foliage-phase:%s:%d" % [tree_id, local_index]) + float(cluster_variant) * 0.173, 1.0),
			clampf(float(anchor.get("windWeight", 0.5)), 0.0, 1.0),
			clampf(float(anchor.get("variation", 0.5)), 0.0, 1.0),
			float(cluster_variant) / 3.0
		))
		set_slot_owner(batch, "foliage", slot, tree_id, local_index, cluster_variant)
		foliage_slots.append({"variant": cluster_variant, "slot": slot})
		foliage_live[cluster_variant] = slot + 1
	for cluster_variant in range(FOLIAGE_VARIANT_COUNT):
		(foliage_multi_meshes[cluster_variant] as MultiMesh).visible_instance_count = foliage_live[cluster_variant]
	batch["foliageLive"] = foliage_live
	batches[key] = batch
	tree_records[tree_id] = {
		"batchKey": key,
		"branchSlots": branch_slots,
		"foliageSlots": foliage_slots,
		"signature": String(recipe.get("signature", "")),
		"lodTier": lod_tier,
		"castsShadows": bool(batch.get("castsShadows", false)),
		"boleVisual": bole_visual
	}
	published_tree_count += 1
	return true

func remove_tree(tree_id: String) -> bool:
	var record: Dictionary = tree_records.get(tree_id, {})
	if record.is_empty():
		return false
	var key := String(record.get("batchKey", ""))
	var batch: Dictionary = batches.get(key, {})
	if batch.is_empty():
		tree_records.erase(tree_id)
		return false
	var bole_visual := record.get("boleVisual", null) as MeshInstance3D
	if bole_visual != null and is_instance_valid(bole_visual):
		bole_visual.queue_free()
	var branch_slots: Array = (record.get("branchSlots", []) as Array).duplicate()
	branch_slots.sort()
	branch_slots.reverse()
	for slot_value in branch_slots:
		release_slot(batch, "branch", int(slot_value))
	var foliage_slots_by_variant := {}
	for slot_value in record.get("foliageSlots", []) as Array:
		if not (slot_value is Dictionary):
			continue
		var foliage_slot: Dictionary = slot_value as Dictionary
		var variant := clampi(int(foliage_slot.get("variant", 0)), 0, FOLIAGE_VARIANT_COUNT - 1)
		if not foliage_slots_by_variant.has(variant):
			foliage_slots_by_variant[variant] = []
		(foliage_slots_by_variant[variant] as Array).append(int(foliage_slot.get("slot", -1)))
	for variant_value in foliage_slots_by_variant.keys():
		var variant := int(variant_value)
		var foliage_slots: Array = (foliage_slots_by_variant[variant] as Array).duplicate()
		foliage_slots.sort()
		foliage_slots.reverse()
		for slot_value in foliage_slots:
			release_slot(batch, "foliage", int(slot_value), variant)
	batches[key] = batch
	tree_records.erase(tree_id)
	published_tree_count = maxi(0, published_tree_count - 1)
	return true

func metrics() -> Dictionary:
	var branch_live := 0
	var foliage_total := 0
	var draw_calls := 0
	var shadow_draw_calls := 0
	var continuous_boles := 0
	for batch_value in batches.values():
		var batch: Dictionary = batch_value as Dictionary
		var batch_branches := int(batch.get("branchLive", 0))
		var batch_casts_shadows := bool(batch.get("castsShadows", false))
		var batch_foliage_live: PackedInt32Array = batch.get("foliageLive", PackedInt32Array())
		var batch_foliage := 0
		for cluster_variant in range(FOLIAGE_VARIANT_COUNT):
			batch_foliage += batch_foliage_live[cluster_variant]
		branch_live += batch_branches
		foliage_total += batch_foliage
		if batch_branches > 0:
			draw_calls += 1
			if batch_casts_shadows:
				shadow_draw_calls += 1
		for cluster_variant in range(FOLIAGE_VARIANT_COUNT):
			if batch_foliage_live[cluster_variant] > 0:
				draw_calls += 1
			if batch_casts_shadows:
				shadow_draw_calls += 1
	for record_value in tree_records.values():
		var record: Dictionary = record_value as Dictionary
		var bole_visual := record.get("boleVisual", null) as MeshInstance3D
		if bole_visual != null and is_instance_valid(bole_visual):
			continuous_boles += 1
			if bool(record.get("castsShadows", false)):
				shadow_draw_calls += 1
	draw_calls += continuous_boles
	return {
		"renderer": "candidate_a_chunk_batched_shared_primitives",
		"batchCount": batches.size(),
		"treeCount": tree_records.size(),
		"branchInstances": branch_live,
		"foliageInstances": foliage_total,
		"estimatedDrawCalls": draw_calls,
		"estimatedShadowDrawCalls": shadow_draw_calls,
		"continuousBoleMeshInstances": continuous_boles,
		"branchSlotCapacity": batches.size() * MAX_BRANCH_SLOTS_PER_BATCH,
		"foliageSlotCapacity": batches.size() * FOLIAGE_VARIANT_COUNT * MAX_FOLIAGE_SLOTS_PER_VARIANT,
		"estimatedInstanceBytes": batches.size() * (MAX_BRANCH_SLOTS_PER_BATCH + FOLIAGE_VARIANT_COUNT * MAX_FOLIAGE_SLOTS_PER_VARIANT) * ESTIMATED_INSTANCE_BYTES,
		"removalSwapCount": removal_swap_count,
		"rejectedTreeCount": rejected_tree_count,
		"batchCreateCount": batch_create_count
	}

func create_batch(key: String, architecture: String, biome: String, lod_tier: String, casts_shadows: bool) -> Dictionary:
	var root := Node3D.new()
	root.name = "TreeChunkBatch_%s" % key.replace(":", "_").replace(",", "_")
	add_child(root)
	var branch_multi_mesh := MultiMesh.new()
	branch_multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	branch_multi_mesh.use_custom_data = true
	branch_multi_mesh.mesh = visual_factory.runtime_shared_branch_mesh()
	branch_multi_mesh.instance_count = MAX_BRANCH_SLOTS_PER_BATCH
	branch_multi_mesh.visible_instance_count = 0
	branch_multi_mesh.custom_aabb = AABB(Vector3.ONE * -BATCH_CULL_EXTENT, Vector3.ONE * BATCH_CULL_EXTENT * 2.0)
	var branch_instance := MultiMeshInstance3D.new()
	branch_instance.name = "SharedBranchSegments"
	branch_instance.multimesh = branch_multi_mesh
	branch_instance.material_override = visual_factory.branch_material(architecture, biome)
	branch_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	branch_instance.extra_cull_margin = BATCH_CULL_EXTENT
	root.add_child(branch_instance)
	var foliage_multi_meshes: Array[MultiMesh] = []
	for cluster_variant in range(FOLIAGE_VARIANT_COUNT):
		var foliage_multi_mesh := MultiMesh.new()
		foliage_multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
		foliage_multi_mesh.use_custom_data = true
		foliage_multi_mesh.mesh = visual_factory.runtime_shared_foliage_cluster_mesh(cluster_variant)
		foliage_multi_mesh.instance_count = MAX_FOLIAGE_SLOTS_PER_VARIANT
		foliage_multi_mesh.visible_instance_count = 0
		foliage_multi_mesh.custom_aabb = AABB(Vector3.ONE * -BATCH_CULL_EXTENT, Vector3.ONE * BATCH_CULL_EXTENT * 2.0)
		var foliage_instance := MultiMeshInstance3D.new()
		foliage_instance.name = "SharedFoliageClusters%d" % cluster_variant
		foliage_instance.multimesh = foliage_multi_mesh
		foliage_instance.material_override = visual_factory.foliage_material(architecture, biome)
		foliage_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		foliage_instance.extra_cull_margin = BATCH_CULL_EXTENT
		root.add_child(foliage_instance)
		foliage_multi_meshes.append(foliage_multi_mesh)
	var branch_owner_ids: Array[String] = []
	branch_owner_ids.resize(MAX_BRANCH_SLOTS_PER_BATCH)
	var foliage_owner_ids: Array[Array] = []
	var foliage_owner_local: Array[PackedInt32Array] = []
	for _cluster_variant in range(FOLIAGE_VARIANT_COUNT):
		var variant_owner_ids: Array[String] = []
		variant_owner_ids.resize(MAX_FOLIAGE_SLOTS_PER_VARIANT)
		foliage_owner_ids.append(variant_owner_ids)
		var variant_owner_local := PackedInt32Array()
		variant_owner_local.resize(MAX_FOLIAGE_SLOTS_PER_VARIANT)
		foliage_owner_local.append(variant_owner_local)
	var branch_owner_local := PackedInt32Array()
	branch_owner_local.resize(MAX_BRANCH_SLOTS_PER_BATCH)
	batch_create_count += 1
	return {
		"root": root,
		"architecture": architecture,
		"biome": biome,
		"lodTier": lod_tier,
		"castsShadows": casts_shadows,
		"branchMultiMesh": branch_multi_mesh,
		"foliageMultiMeshes": foliage_multi_meshes,
		"branchLive": 0,
		"foliageLive": PackedInt32Array([0, 0, 0, 0]),
		"branchOwnerIds": branch_owner_ids,
		"foliageOwnerIds": foliage_owner_ids,
		"branchOwnerLocal": branch_owner_local,
		"foliageOwnerLocal": foliage_owner_local
	}

func release_slot(batch: Dictionary, kind: String, slot: int, cluster_variant := -1) -> void:
	var is_branch := kind == "branch"
	var live_key := "branchLive" if is_branch else "foliageLive"
	var mesh_key := "branchMultiMesh" if is_branch else "foliageMultiMeshes"
	var owner_ids_key := "branchOwnerIds" if is_branch else "foliageOwnerIds"
	var owner_local_key := "branchOwnerLocal" if is_branch else "foliageOwnerLocal"
	var live_count := int(batch.get(live_key, 0)) if is_branch else (batch.get(live_key, PackedInt32Array()) as PackedInt32Array)[cluster_variant]
	var last_slot := live_count - 1
	if slot < 0 or slot > last_slot:
		return
	var multi_mesh := batch.get(mesh_key, null) as MultiMesh if is_branch else (batch.get(mesh_key, []) as Array)[cluster_variant] as MultiMesh
	var owner_ids: Array = batch.get(owner_ids_key, []) if is_branch else ((batch.get(owner_ids_key, []) as Array)[cluster_variant] as Array)
	var owner_local: PackedInt32Array = batch.get(owner_local_key, PackedInt32Array()) if is_branch else ((batch.get(owner_local_key, []) as Array)[cluster_variant] as PackedInt32Array)
	if slot != last_slot:
		multi_mesh.set_instance_transform(slot, multi_mesh.get_instance_transform(last_slot))
		multi_mesh.set_instance_custom_data(slot, multi_mesh.get_instance_custom_data(last_slot))
		var moved_tree_id := String(owner_ids[last_slot])
		var moved_local_index := int(owner_local[last_slot])
		owner_ids[slot] = moved_tree_id
		owner_local[slot] = moved_local_index
		update_owner_slot(moved_tree_id, kind, moved_local_index, slot, cluster_variant)
		removal_swap_count += 1
	owner_ids[last_slot] = ""
	owner_local[last_slot] = -1
	if is_branch:
		batch[owner_ids_key] = owner_ids
		batch[owner_local_key] = owner_local
		batch[live_key] = last_slot
	else:
		var all_owner_ids: Array = batch.get(owner_ids_key, [])
		var all_owner_local: Array = batch.get(owner_local_key, [])
		var all_live: PackedInt32Array = batch.get(live_key, PackedInt32Array())
		all_owner_ids[cluster_variant] = owner_ids
		all_owner_local[cluster_variant] = owner_local
		all_live[cluster_variant] = last_slot
		batch[owner_ids_key] = all_owner_ids
		batch[owner_local_key] = all_owner_local
		batch[live_key] = all_live
	multi_mesh.visible_instance_count = last_slot

func set_slot_owner(batch: Dictionary, kind: String, slot: int, tree_id: String, local_index: int, cluster_variant := -1) -> void:
	var is_branch := kind == "branch"
	var owner_ids_key := "branchOwnerIds" if is_branch else "foliageOwnerIds"
	var owner_local_key := "branchOwnerLocal" if is_branch else "foliageOwnerLocal"
	var owner_ids: Array = batch.get(owner_ids_key, []) if is_branch else ((batch.get(owner_ids_key, []) as Array)[cluster_variant] as Array)
	var owner_local: PackedInt32Array = batch.get(owner_local_key, PackedInt32Array()) if is_branch else ((batch.get(owner_local_key, []) as Array)[cluster_variant] as PackedInt32Array)
	owner_ids[slot] = tree_id
	owner_local[slot] = local_index
	if is_branch:
		batch[owner_ids_key] = owner_ids
		batch[owner_local_key] = owner_local
	else:
		var all_owner_ids: Array = batch.get(owner_ids_key, [])
		var all_owner_local: Array = batch.get(owner_local_key, [])
		all_owner_ids[cluster_variant] = owner_ids
		all_owner_local[cluster_variant] = owner_local
		batch[owner_ids_key] = all_owner_ids
		batch[owner_local_key] = all_owner_local

func update_owner_slot(tree_id: String, kind: String, local_index: int, slot: int, cluster_variant := -1) -> void:
	if tree_id == "" or not tree_records.has(tree_id):
		return
	var record: Dictionary = tree_records.get(tree_id, {})
	var slots_key := "branchSlots" if kind == "branch" else "foliageSlots"
	var slots: Array = record.get(slots_key, [])
	if local_index < 0 or local_index >= slots.size():
		return
	if kind == "branch":
		slots[local_index] = slot
	else:
		var foliage_slot: Dictionary = slots[local_index] as Dictionary
		foliage_slot["variant"] = cluster_variant
		foliage_slot["slot"] = slot
		slots[local_index] = foliage_slot
	record[slots_key] = slots
	tree_records[tree_id] = record

func typed_dictionary_array(source: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not (source is Array):
		return result
	for value in source:
		if value is Dictionary:
			result.append(value as Dictionary)
	return result

func runtime_distal_branches(all_branches: Array[Dictionary]) -> Array[Dictionary]:
	var distal: Array[Dictionary] = []
	for branch in all_branches:
		if int(branch.get("order", 1)) != 0:
			distal.append(branch)
	return distal

func foliage_variant_counts(foliage: Array[Dictionary]) -> PackedInt32Array:
	var counts := PackedInt32Array([0, 0, 0, 0])
	for anchor in foliage:
		var cluster_variant := clampi(int(anchor.get("clusterVariant", 0)), 0, FOLIAGE_VARIANT_COUNT - 1)
		counts[cluster_variant] += 1
	return counts

func foliage_exceeds_capacity(live: PackedInt32Array, requested: PackedInt32Array) -> bool:
	for cluster_variant in range(FOLIAGE_VARIANT_COUNT):
		if live[cluster_variant] + requested[cluster_variant] > MAX_FOLIAGE_SLOTS_PER_VARIANT:
			return true
	return false

func batch_key(chunk_key: String, architecture: String, biome: String, lod_tier: String) -> String:
	return "%s:%s:%s:%s" % [chunk_key, architecture, biome, lod_tier]

func stable_unit(text: String) -> float:
	return float(stable_hash(text) & 0x7fffffff) / float(0x7fffffff)

func stable_hash(text: String) -> int:
	var hash_value := 2166136261
	for index in range(text.length()):
		hash_value = int((hash_value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return hash_value
