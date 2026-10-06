extends RefCounted
class_name EcologyProducerDomain

## Versioned producer support policy and inverse source-domain census.
## This contract describes which source chunks can affect a render section. It
## does not claim that a source value or renderer installation is present.

const StaticRenderSectionGridScript := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const SCHEMA := "ecology-support-policy/v1"
const CENSUS_SCHEMA := "ecology-source-domain-census/v1"
const REQUIRED_CATEGORIES := ["trees", "surface_rocks", "ore", "forage", "details", "underground_props"]
const TREE_SUPPORT_ENVELOPE_REVISION := "procedural-tree-support-envelope-v2"
const TREE_GRAMMAR_REVISION := "tree-spawn-service-v10:bushy-oak-v21:norway-spruce-v2:umbrella-thorn-v2"
const TREE_VISUAL_REVISION := "procedural-tree-visual-factory+procedural-tree-branch-shader+procedural-tree-foliage-shader+environment-wind-system"
const STATIC_BASE_SUPPORT_REVISION := "ecology-support-base-v1"
const TREE_SPATIAL_REVIEWED_SOURCE_DIGESTS := {
	"res://scripts/environment/TreeRuntimeRequestBuilder.gd":"d64504cd04aed50dcb27927d9c28cf8b86ef7db10fce6e40550951ba99df02b6",
	"res://scripts/environment/TreeRequestAdmission.gd":"d05224dc126c64d9182bf471930295407e4e7810c730be4553f6ac33244525ac",
	# Reviewed 2026-10-06: the request admission check binds existing profile
	# dimensions, and the copy-count optimization preserves recipe transforms,
	# reduction rules, and the certified geometry envelope.
	"res://scripts/environment/TreeSpawnService.gd":"647cae9e895b1fee21b6845533f771a10219b05fbda82b0da5dc574df2401ddd",
	"res://scripts/environment/tree_grammars/MathematicalTreePocRecipeBuilder.gd":"7bd74c202c809f6746ebd930c9a38b0507a1ee1b3205e488279064ad42db3f27",
	"res://scripts/environment/tree_grammars/MathematicalTreePocBushyOakRecipeBuilder.gd":"7732f35e113c8b60baa29e49e4f9142bc9104ed1fcdbf1c3cbd2730a812639d0",
	"res://scripts/environment/tree_grammars/MathematicalTreePocConiferRecipeBuilder.gd":"2558e11b39f10a64a68cdaa8f33753883ae5bbb82c0a71ee9968651c9f44dbf8",
	"res://scripts/environment/tree_grammars/MathematicalTreePocSavannaRecipeBuilder.gd":"a1c373d87694b93a262bf5cbf5e2ea24b053d8b9d369dc858e29449260b33f33",
	"res://scripts/visual/ProceduralTreeVisualFactory.gd":"2d05e04ce2001966ae739d603ee926521943e1ce501936606cd443eb4c4b74a5",
	"res://scripts/world/TreeRecipeSectionCompiler.gd":"8722d3f4a593e3f55fb5ea53428760132e69ec849a3bbec37e8b5e1eb773c227",
	"res://scripts/environment/EnvironmentWindSystem.gd":"4b40c0de4b474c96b9b8526ec413446ce60886a1938e43edbb6ed42c41a42b84",
	"res://resources/visual/procedural_tree_branch.gdshader":"d50c72fd94a4f8958b807e74b530f93daba4e5f4fc9f88b6825b3ea0768aca6e",
	"res://resources/visual/procedural_tree_foliage.gdshader":"2e55f5a392dc5849fcf84caece2deee957a3294dd8d09a023715579ab7b32f2d",
}

# The bounds are intended maxima of producer recipes, including their maximum
# generated member extents and declared visual displacement. They remain
# pending until the producer/factory path proves and enforces each maximum.
# Keep this table versioned: changing a family limit changes the inverse census.
const FAMILY_POLICY := {
	# Runtime bounds replace these pending family rows after the complete profile
	# catalog and, for rocks, every eligible static scene descriptor are captured.
	"trees": {"status": "pending_catalog_bound", "maxHorizontalSupportMeters": 0.0,
		"maxVerticalSupportMeters": 0.0},
	"surface_rocks": {"status": "pending_catalog_bound", "maxHorizontalSupportMeters": 0.0,
		"maxVerticalSupportMeters": 0.0},
	# Surface ore has r<1.4m; the widest body ellipsoid has horizontal radius
	# <= r*sqrt(1.65^2+1.42^2) < 3.05m and vertical extent < 1.51m.
	"ore": {"status": "bounded", "maxHorizontalSupportMeters": 5.0,
		"maxVerticalSupportMeters": 4.0},
	# Canonical aloe/mushroom/frost/berry recipes stay within 0.9m horizontally
	# and 0.7m vertically including their maximum primitive scales and offsets.
	"forage": {"status": "bounded", "maxHorizontalSupportMeters": 1.5,
		"maxVerticalSupportMeters": 2.0},
	# Detail mesh recipes fit within 0.3m horizontally and 0.87m vertically after
	# the maximum 1.4 profile scale and the detail material's bounded wind offset.
	"details": {"status": "bounded", "maxHorizontalSupportMeters": 1.5,
		"maxVerticalSupportMeters": 2.0},
	"underground_props": {"status": "pending_catalog_bound", "maxHorizontalSupportMeters": 0.0,
		"maxVerticalSupportMeters": 0.0},
}

const MAX_COMPLETED_SNAPSHOTS := 2048

var _completed_snapshot_cache: Dictionary = {}
var _completed_snapshot_order: Array[String] = []
var _pending_capture_progress: Dictionary = {}


func completed_snapshot_for(world_id: String, source_chunk_key: Vector2i,
		source_inputs: Dictionary, removed_projection_digest: String) -> Dictionary:
	var identity := snapshot_cache_identity(world_id, source_chunk_key, source_inputs,
		removed_projection_digest)
	var value: Variant = _completed_snapshot_cache.get(identity, null)
	if not value is Dictionary:
		return {"status": "pending", "reason": "ecology_source_snapshot_not_cached",
			"cacheIdentity": identity}
	var snapshot: Dictionary = value
	if not validate_source_domain_snapshot(snapshot, world_id, source_chunk_key):
		_completed_snapshot_cache.erase(identity)
		_completed_snapshot_order.erase(identity)
		return {"status": "pending", "reason": "ecology_cached_snapshot_stale",
			"cacheIdentity": identity}
	return {"status": "ready", "cacheIdentity": identity, "snapshot": snapshot}


func retain_completed_snapshot(snapshot: Dictionary) -> bool:
	if String(snapshot.get("status", "")) != "ready" \
			or not validate_source_domain_snapshot(snapshot):
		return false
	var source_inputs: Variant = snapshot.get("sourceInputs", {})
	if not source_inputs is Dictionary:
		return false
	var identity := snapshot_cache_identity(String(snapshot.worldId),
		snapshot.sourceChunkKey, source_inputs,
		String(snapshot.get("removedSourceProjectionDigest", "")))
	if not _completed_snapshot_cache.has(identity):
		_completed_snapshot_order.append(identity)
	_completed_snapshot_cache[identity] = snapshot
	while _completed_snapshot_order.size() > MAX_COMPLETED_SNAPSHOTS:
		var retired: String = String(_completed_snapshot_order.pop_front())
		_completed_snapshot_cache.erase(retired)
	return true


func set_pending_capture_progress(identity: String, progress: Dictionary) -> void:
	if identity.is_empty():
		return
	var frozen: Variant = _freeze_value(progress.duplicate(true))
	_pending_capture_progress[identity] = frozen


func pending_capture_progress(identity: String) -> Dictionary:
	var value: Variant = _pending_capture_progress.get(identity, null)
	return {"status": "pending", "reason": "ecology_source_capture_pending",
		"cacheIdentity": identity, "progress": value} if value is Dictionary else {
		"status": "pending", "reason": "ecology_source_capture_not_started",
		"cacheIdentity": identity}


func clear_pending_capture_progress(identity: String) -> void:
	_pending_capture_progress.erase(identity)


func invalidate_source_chunk(world_id: String, source_chunk_key: Vector2i) -> void:
	var prefix := "%s|%d,%d|" % [world_id, source_chunk_key.x, source_chunk_key.y]
	for identity_value: Variant in _completed_snapshot_cache.keys():
		var identity := String(identity_value)
		if identity.begins_with(prefix):
			_completed_snapshot_cache.erase(identity)
			_completed_snapshot_order.erase(identity)
			_pending_capture_progress.erase(identity)


static func support_policy(source_inputs: Dictionary = {}) -> Dictionary:
	var families: Dictionary = _canonical_value(FAMILY_POLICY)
	var runtime_policy := derive_runtime_support_policy(source_inputs) \
		if not source_inputs.is_empty() else {"status":"pending", "reason":"runtime_ecology_catalog_inputs_required"}
	if String(runtime_policy.get("status", "")) == "ready":
		families.merge(runtime_policy.get("families", {}), true)
	var policy := {
		"schema": SCHEMA,
		"revision": "ecology-support-v3",
		"sourceChunkSizeMeters": StaticRenderSectionGridScript.STREAM_CHUNK_SIZE_METERS,
		"families": families,
		# Keep the exact catalog-bound proof inputs available to the section
		# index. Compiled tree members validate their wind-expanded envelope
		# against this same derived tree envelope.
		"treeEnvelope":runtime_policy.get("treeEnvelope", {}),
		"rockEnvelope":runtime_policy.get("rockEnvelope", {}),
		"runtimePolicyStatus":String(runtime_policy.get("status", "pending")),
		"runtimePolicyReason":String(runtime_policy.get("reason", "")),
		"runtimePolicyDigest":String(runtime_policy.get("digest", "")),
	}
	policy["status"] = "ready" if _all_families_bounded(families) \
		and String(runtime_policy.get("status", "")) == "ready" else "pending"
	policy["digest"] = _digest(policy)
	return policy


static func derive_runtime_support_policy(source_inputs: Dictionary) -> Dictionary:
	var profiles: Variant = source_inputs.get("biomeProfileSnapshot", null)
	if not profiles is Dictionary:
		return {"status":"pending", "reason":"ecology_profile_catalog_missing"}
	var tree := derive_tree_grammar_support_envelope(profiles)
	if String(tree.get("status", "")) != "ready":
		return {"status":String(tree.get("status", "pending")),
			"reason":String(tree.get("reason", "tree_support_envelope_unavailable"))}
	if String(source_inputs.get("treeGrammarEnvelopeDigest", "")) != String(tree.get("digest", "")):
		return {"status":"pending", "reason":"tree_support_envelope_input_digest_mismatch"}
	var rock: Variant = source_inputs.get("rockSupportEnvelope", null)
	if not rock is Dictionary or String(rock.get("status", "")) != "ready":
		return {"status":"pending", "reason":String(rock.get("reason",
			"rock_catalog_descriptor_envelope_unavailable")) if rock is Dictionary \
			else "rock_catalog_descriptor_envelope_missing"}
	if String(rock.get("profileCatalogRevision", "")) != String(profiles.get("contentIdentity", "")) \
			or String(rock.get("eligibleAssetSetDigest", "")).length() != 64 \
			or String(rock.get("digest", "")).length() != 64 \
			or String(rock.get("assetSetDigest", "")).length() != 64 \
			or String(rock.get("registryRevision", "")).is_empty() \
			or not rock.get("assetRows", null) is Array \
			or (rock.get("assetRows", []) as Array).is_empty():
		return {"status":"pending", "reason":"rock_support_envelope_provenance_incomplete"}
	var tree_horizontal := float(tree.maxHorizontalSupportMeters)
	var tree_vertical := float(tree.maxVerticalSupportMeters)
	var rock_horizontal := float(rock.maxHorizontalSupportMeters)
	var rock_vertical := float(rock.maxVerticalSupportMeters)
	if not is_finite(rock_horizontal) or not is_finite(rock_vertical) \
			or rock_horizontal <= 0.0 or rock_vertical <= 0.0:
		return {"status":"failed", "reason":"rock_support_envelope_extents_invalid"}
	var families: Dictionary = _canonical_value(FAMILY_POLICY)
	families["trees"] = {"status":"bounded", "maxHorizontalSupportMeters":tree_horizontal,
		"maxVerticalSupportMeters":tree_vertical, "envelopeDigest":String(tree.digest),
		"envelopeRevision":TREE_SUPPORT_ENVELOPE_REVISION}
	families["surface_rocks"] = {"status":"bounded",
		"maxHorizontalSupportMeters":rock_horizontal,
		"maxVerticalSupportMeters":rock_vertical,
		"envelopeDigest":String(rock.digest), "envelopeRevision":"rock-static-descriptor-envelope-v1"}
	# The underground pass emits rock, ore, and forage descriptors. Its support is
	# the component-wise union of those source families, measured from each
	# emitted source origin; it does not inherit the source scan radius.
	families["underground_props"] = {"status":"bounded",
		"maxHorizontalSupportMeters":maxf(rock_horizontal, 5.0),
		"maxVerticalSupportMeters":maxf(rock_vertical, 4.0),
		"envelopeDigest":_digest([String(rock.digest), "ore-source-recipe/v1",
			"forage-source-recipe/v1"]), "envelopeRevision":"underground-source-union-v1"}
	var payload := {"schema":"ecology-runtime-support-policy/v1",
		"baseRevision":STATIC_BASE_SUPPORT_REVISION,
		"treeEnvelope":tree, "rockEnvelope":rock,
		"profileCatalogRevision":String(profiles.get("contentIdentity", "")),
		"families":families}
	payload["status"] = "ready" if _all_families_bounded(families) else "pending"
	payload["digest"] = _digest(payload)
	return payload


static func derive_tree_grammar_support_envelope(profile_snapshot: Dictionary) -> Dictionary:
	var request := derive_tree_request_envelope(profile_snapshot)
	if String(request.get("status", "")) != "ready":
		return request
	var visual_wind := active_tree_visual_wind_envelope()
	var grammar_receipt := active_tree_grammar_receipt()
	if String(visual_wind.get("status", "")) != "ready":
		return {"status":"pending", "reason":String(visual_wind.get("reason",
			"active_tree_visual_wind_envelope_unavailable"))}
	if String(grammar_receipt.get("status", "")) != "ready":
		return {"status":"pending", "reason":String(grammar_receipt.get("reason",
			"active_tree_grammar_receipt_unavailable"))}
	var source_contract := active_tree_spatial_source_contract()
	if String(source_contract.get("status", "")) != "ready":
		return {"status":"pending", "reason":String(source_contract.get("reason",
			"active_tree_spatial_source_contract_unrecognized"))}
	var per_profile: Dictionary = {}
	var max_horizontal := 0.0
	var max_vertical := 0.0
	var request_profiles: Dictionary = request.get("profileBounds", {})
	for profile_id_value: Variant in request_profiles.keys():
		var profile_id := String(profile_id_value)
		var profile_row: Dictionary = request_profiles[profile_id]
		var architecture_rows: Dictionary = profile_row.get("architectures", {})
		var resolved_architectures: Dictionary = {}
		for architecture_value: Variant in architecture_rows.keys():
			var architecture := String(architecture_value)
			var request_dimensions: Dictionary = architecture_rows[architecture]
			var bound := derive_tree_architecture_support_bound(architecture,
				request_dimensions, visual_wind)
			if String(bound.get("status", "")) != "ready":
				return {"status":String(bound.get("status", "pending")),
					"reason":String(bound.get("reason", "tree_geometry_bound_unavailable")),
					"profileId":profile_id, "architecture":architecture}
			resolved_architectures[architecture] = bound
			max_horizontal = maxf(max_horizontal,
				float(bound.get("maxHorizontalSupportMeters", 0.0)))
			max_vertical = maxf(max_vertical,
				float(bound.get("maxVerticalSupportMeters", 0.0)))
		per_profile[profile_id] = {"architectures":resolved_architectures,
			"maxWindResponse":float(profile_row.get("maxWindResponse", 0.0))}
	if max_horizontal <= 0.0 or max_vertical <= 0.0:
		return {"status":"failed", "reason":"tree_geometry_support_bound_empty"}
	var envelope := {"schema":"ecology-tree-grammar-support-envelope/v2",
		"status":"ready", "revision":TREE_SUPPORT_ENVELOPE_REVISION,
		"grammarRevision":TREE_GRAMMAR_REVISION,
		"visualRevision":TREE_VISUAL_REVISION,
		"profileCatalogRevision":String(profile_snapshot.get("contentIdentity", "")),
		"requestEnvelopeDigest":String(request.get("digest", "")),
		"visualWindEnvelope":visual_wind,
		"activeGrammarReceipt":grammar_receipt,
		"spatialSourceContract":source_contract,
		"profileBounds":per_profile,
		"maxHorizontalSupportMeters":max_horizontal + 0.001,
		"maxVerticalSupportMeters":max_vertical + 0.001,
		"boundMethod":"component-wise request-to-grammar adaptation plus conservative recipe/factory vertex envelopes",
		"compiledGeometryAdmission":"Every compiled member AABB is independently checked by validate_source_bounds against this envelope before source-row admission."}
	envelope["digest"] = _digest(envelope)
	return envelope


static func derive_tree_architecture_support_bound(architecture: String,
		request_dimensions: Dictionary, visual_wind: Dictionary) -> Dictionary:
	var request_height := float(request_dimensions.get("maxVisualHeightMeters", NAN))
	var request_trunk := float(request_dimensions.get("maxTrunkRadiusMeters", NAN))
	var request_canopy := float(request_dimensions.get("maxCanopyRadiusMeters", NAN))
	if not is_finite(request_height) or not is_finite(request_trunk) \
			or not is_finite(request_canopy) or request_height <= 0.0 \
			or request_trunk <= 0.0 or request_canopy <= 0.0:
		return {"status":"failed", "reason":"tree_request_support_dimensions_invalid"}
	var grammar := tree_grammar_dimension_envelope(architecture)
	if String(grammar.get("status", "")) != "ready":
		return grammar
	var raw_height_min := float(grammar.minHeightMeters)
	var raw_canopy_min := float(grammar.minCanopyRadiusMeters)
	var raw_canopy_max := float(grammar.maxCanopyRadiusMeters)
	var canopy_scale := request_canopy / raw_canopy_min
	var height_scale := request_height / raw_height_min
	var wood_radius := 1.414 * request_trunk
	var wind_horizontal := maxf(float(visual_wind.get("branchComponentDisplacementMaxMeters", 0.0)),
		float(visual_wind.get("foliageComponentDisplacementMaxMeters", 0.0)))
	var wind_vertical := float(visual_wind.get("foliageVerticalDisplacementMaxMeters", 0.0))
	var horizontal := 0.0
	var vertical := 0.0
	var formula: Dictionary = {}
	match architecture:
		"broadleaf":
			# Active oak SCA endpoints are admitted by the ellipsoid/lobe test:
			# x <= 1.06*sqrt(1.06)*R. The lower-primary and trunk-bud seeds
			# are inside this envelope for every canonical oak profile. Buttresses
			# independently reach 2.35R + 0.28R tangentially; their widest
			# start flare is 0.70R and the wood renderer's largest joining hull
			# multiplier is 1.14.
			var crown_factor := 1.06 * sqrt(1.06)
			var buttress_factor := 2.35 + 0.28 + 1.14 * 0.70
			var leaf_anchor_horizontal := 0.58 + 0.48 + 0.48
			var leaf_anchor_vertical := 0.58 + 0.48
			var leaf_mesh_scale_horizontal := 1.86 * 1.12
			var leaf_mesh_scale_vertical := 1.86 * 1.12 * 0.74
			var leaf_mesh_radius := 1.26
			var crown_support := crown_factor * request_canopy
			var foliage_horizontal := crown_support + leaf_anchor_horizontal * canopy_scale \
				+ leaf_mesh_radius * maxf(leaf_mesh_scale_horizontal * canopy_scale,
					leaf_mesh_scale_vertical * height_scale)
			horizontal = maxf(maxf(foliage_horizontal, buttress_factor * request_trunk),
				wood_radius) + wind_horizontal
			var crown_top_request := float(grammar.get("maxRawCrownTopToHeightRatio", NAN)) * request_height
			var leaf_mesh_vertical_extent := leaf_mesh_radius * maxf(
				leaf_mesh_scale_horizontal * canopy_scale,
				leaf_mesh_scale_vertical * height_scale)
			var leaf_vertical := leaf_anchor_vertical * height_scale + leaf_mesh_vertical_extent
			vertical = maxf(maxf(crown_top_request + leaf_vertical + wind_vertical,
				0.70 * request_trunk), wood_radius + crown_top_request)
			formula = {"branchCrownFactor":crown_factor,
				"rootButtressFactor":buttress_factor,
				"foliageAnchorOffsetHorizontalMeters":leaf_anchor_horizontal,
				"foliageAnchorOffsetVerticalMeters":leaf_anchor_vertical,
				"foliageUnitMeshRadiusMeters":leaf_mesh_radius,
				"foliageAnchorScaleMax":leaf_mesh_scale_horizontal,
				"foliageAnchorVerticalScaleMax":leaf_mesh_scale_vertical,
				"maxRawCrownTopToHeightRatio":float(grammar.maxRawCrownTopToHeightRatio)}
		"conifer":
			# Primary boughs sum to <= 1.188R. For curtain tips, the source
			# requests at most six primary steps; when fewer than six are admitted,
			# ceil(bough/2.24) proves bough/step <= 2.24. Curtain and tip lengths
			# add <= (1.18 + .76*1.18) times the largest step.
			var max_bough := 1.10 * raw_canopy_max
			var max_primary_step := 1.08 * maxf(2.24, max_bough / 6.0)
			var curtain_tip := (1.18 + 0.76 * 1.18) * max_primary_step
			var bough_path := 1.188 * request_canopy + curtain_tip * canopy_scale
			var leaf_anchor_horizontal := 0.34 + 0.28
			var leaf_anchor_vertical := 0.34 + 0.28
			var leaf_scale_horizontal := 2.05 * 1.10 * 0.86
			var leaf_scale_vertical := 2.05 * 1.10 * 0.72
			var leaf_mesh_radius := 1.26
			var leaf_mesh_extent := leaf_mesh_radius * maxf(leaf_scale_horizontal * canopy_scale,
				leaf_scale_vertical * height_scale)
			horizontal = maxf(wood_radius, 0.46 * canopy_scale + bough_path \
				+ leaf_anchor_horizontal * canopy_scale + leaf_mesh_extent) + wind_horizontal
			var foliage_vertical := leaf_anchor_vertical * height_scale \
				+ leaf_mesh_radius * maxf(leaf_scale_horizontal * canopy_scale,
					leaf_scale_vertical * height_scale)
			vertical = maxf(maxf(request_height,
				float(grammar.maxRawCrownTopToHeightRatio) * request_height \
				+ foliage_vertical + wind_vertical), wood_radius)
			formula = {"principalBoughPathFactor":1.188,
				"maxRawPrimaryStepMeters":max_primary_step,
				"curtainAndTipPathFactor":1.18 + 0.76 * 1.18,
				"trunkDriftMeters":0.46,
				"foliageAnchorOffsetMeters":leaf_anchor_horizontal,
				"foliageUnitMeshRadiusMeters":leaf_mesh_radius,
				"foliageAnchorScaleHorizontalMax":leaf_scale_horizontal,
				"foliageAnchorScaleVerticalMax":leaf_scale_vertical}
		"savanna":
			# The production scaffold has at most 1.12R total raised-fork steps.
			# Remaining lateral reach is <= .54R, multiplied by the two explicit
			# 1.12 arm factors. The final arm node can add a .31 arm-length twig
			# and a .72 twig-length tip.
			var fork_path := 1.12 * request_canopy
			var max_arm := 0.54 * 1.12 * 1.12 * raw_canopy_max
			var arm_and_tip_factor := 1.0 + 0.31 + 0.31 * 0.72
			var scaffold_path := fork_path + max_arm * arm_and_tip_factor * canopy_scale
			var leaf_anchor_horizontal := 0.58 + 0.42
			var leaf_anchor_vertical := 0.58 + 0.42
			var leaf_scale_horizontal := 2.54 * 1.10 * 1.08 * 1.40
			var leaf_scale_vertical := 2.54 * 1.10 * 1.08 * 1.04
			var leaf_mesh_radius := 1.26
			var leaf_mesh_extent := leaf_mesh_radius * maxf(leaf_scale_horizontal * canopy_scale,
				leaf_scale_vertical * height_scale)
			horizontal = maxf(wood_radius, scaffold_path + 0.99 * canopy_scale \
				+ leaf_anchor_horizontal * canopy_scale + leaf_mesh_extent) + wind_horizontal
			var foliage_vertical := leaf_anchor_vertical * height_scale \
				+ leaf_mesh_radius * maxf(leaf_scale_horizontal * canopy_scale,
					leaf_scale_vertical * height_scale)
			vertical = maxf(maxf(request_height,
				float(grammar.maxRawCrownTopToHeightRatio) * request_height \
				+ foliage_vertical + wind_vertical), wood_radius)
			formula = {"raisedForkPathFactor":1.12,
				"maxArmReachFactor":0.54 * 1.12 * 1.12,
				"armTwigTipPathFactor":arm_and_tip_factor,
				"trunkDriftMeters":0.99,
				"foliageAnchorOffsetMeters":leaf_anchor_horizontal,
				"foliageUnitMeshRadiusMeters":leaf_mesh_radius,
				"foliageAnchorScaleHorizontalMax":leaf_scale_horizontal,
				"foliageAnchorScaleVerticalMax":leaf_scale_vertical,
				"maxRawCrownTopToHeightRatio":float(grammar.maxRawCrownTopToHeightRatio)}
		_:
			return {"status":"pending", "reason":"tree_architecture_spatial_formula_missing"}
	if not is_finite(horizontal) or not is_finite(vertical) \
			or horizontal <= 0.0 or vertical <= 0.0:
		return {"status":"failed", "reason":"tree_spatial_support_bound_invalid"}
	return {"status":"ready", "architecture":architecture,
		"maxHorizontalSupportMeters":horizontal,
		"maxVerticalSupportMeters":vertical,
		"requestDimensions":request_dimensions.duplicate(true),
		"rawGrammarDimensions":grammar,
		"adaptationRatios":{"horizontal":canopy_scale, "vertical":height_scale,
			"woodRadius":request_trunk / float(grammar.minTrunkRadiusMeters)},
		"geometryFactors":formula,
		"windEnvelopeDigest":String(visual_wind.get("digest", ""))}


static func tree_grammar_dimension_envelope(architecture: String) -> Dictionary:
	var growth_rate := 0.0
	var height_minimum := 0.0
	var height_maximum := 0.0
	var trunk_base := 0.0
	var trunk_delta := 0.0
	var trunk_exponent := 0.0
	var canopy_base := 0.0
	var canopy_delta := 0.0
	var canopy_exponent := 0.0
	match architecture:
		"broadleaf":
			growth_rate = 3.40
			height_minimum = 16.0
			height_maximum = 43.0
			trunk_base = 0.78
			trunk_delta = 2.32
			trunk_exponent = 0.70
			canopy_base = 9.0
			canopy_delta = 20.0
			canopy_exponent = 0.84
		"conifer":
			growth_rate = 3.15
			height_minimum = 15.5
			height_maximum = 53.0
			trunk_base = 0.56
			trunk_delta = 1.52
			trunk_exponent = 0.78
			canopy_base = 3.65
			canopy_delta = 10.65
			canopy_exponent = 0.88
		"savanna":
			growth_rate = 3.25
			height_minimum = 10.5
			height_maximum = 29.5
			trunk_base = 0.58
			trunk_delta = 1.90
			trunk_exponent = 0.71
			canopy_base = 7.0
			canopy_delta = 16.5
			canopy_exponent = 0.86
		_:
			return {"status":"pending", "reason":"tree_architecture_dimensions_unknown"}
	var growth_min := (1.0 - exp(-growth_rate * 0.12)) / (1.0 - exp(-growth_rate))
	var min_height := height_minimum + (height_maximum - height_minimum) * growth_min
	var min_trunk := trunk_base + trunk_delta * pow(growth_min, trunk_exponent)
	var min_canopy := canopy_base + canopy_delta * pow(growth_min, canopy_exponent)
	var crown_top_ratio := NAN
	match architecture:
		"broadleaf":
			# Exact upper expression from crownBase + (0.45 + 1.06*0.54)*crownHeight.
			# Power terms are bounded by their value at m=.12 times linear growth;
			# the resulting ratio bound is the larger ratio of the two positive affine sums.
			var growth_078 := pow(growth_min, 0.78 - 1.0)
			var growth_082 := pow(growth_min, 0.82 - 1.0)
			var numerator_constant := 5.8 + (0.45 + 1.06 * 0.54) * 13.0
			var numerator_growth := 5.8 * growth_078 \
				+ (0.45 + 1.06 * 0.54) * 19.5 * growth_082
			crown_top_ratio = maxf(numerator_constant / 16.0, numerator_growth / 27.0)
		"savanna":
			# Raised-fork plus maximum arm/twig reach, divided by source height.
			# Bounding each sublinear maturity power by its m=.12 ratio to linear growth
			# gives an affine numerator and an exact component-wise ratio upper bound.
			var growth_083 := pow(growth_min, 0.83 - 1.0)
			var growth_086 := pow(growth_min, 0.86 - 1.0)
			var raised_fork_and_arm_path_factor := 1.12 \
				+ 0.54 * 1.12 * 1.12 * (1.0 + 0.31 + 0.31 * 0.72)
			var numerator_constant := 3.4 + raised_fork_and_arm_path_factor * 7.0
			var numerator_growth := 5.4 * growth_083 \
				+ raised_fork_and_arm_path_factor * 16.5 * growth_086
			crown_top_ratio = maxf(1.0, maxf(numerator_constant / 10.5,
				numerator_growth / 19.0))
		"conifer":
			# Source trunk reaches height; boughs and their curtains/tips use the
			# explicit worst path computed by the active step and length constraints.
			var max_raw_bough := 1.10 * (canopy_base + canopy_delta)
			var max_step := 1.08 * maxf(2.24, max_raw_bough / 6.0)
			var max_branch_path := 1.188 * (canopy_base + canopy_delta) \
				+ (1.18 + 0.76 * 1.18) * max_step
			crown_top_ratio = 1.0 + max_branch_path / min_height
	return {"status":"ready", "architecture":architecture,
		"growthAtMinimumMaturity":growth_min,
		"minHeightMeters":min_height,"maxHeightMeters":height_maximum,
		"minTrunkRadiusMeters":min_trunk,"maxTrunkRadiusMeters":trunk_base + trunk_delta,
		"minCanopyRadiusMeters":min_canopy,"maxCanopyRadiusMeters":canopy_base + canopy_delta,
		"maxRawCrownTopToHeightRatio":crown_top_ratio,
		"recipeMaturityDomain":[0.12,1.0]}


static func active_tree_spatial_source_contract() -> Dictionary:
	var oak := load("res://scripts/environment/tree_grammars/MathematicalTreePocBushyOakRecipeBuilder.gd") as GDScript
	var conifer := load("res://scripts/environment/tree_grammars/MathematicalTreePocConiferRecipeBuilder.gd") as GDScript
	var savanna := load("res://scripts/environment/tree_grammars/MathematicalTreePocSavannaRecipeBuilder.gd") as GDScript
	var factory := load("res://scripts/visual/ProceduralTreeVisualFactory.gd") as GDScript
	if oak == null or conifer == null or savanna == null or factory == null:
		return {"status":"pending", "reason":"tree_spatial_source_dependency_missing"}
	var requirements := [
		{"source":oak.source_code,"needles":[
			"func build_oak_space_colony_recipe(",
			"var crown_radii := Vector3(crown_radius, crown_height * 0.54, crown_radius * 0.92)",
			"return horizontal * horizontal + vertical_unit * vertical_unit <= 1.06",
			"var branches: Array[Dictionary] = pipe_result.get(\"branches\", [])",
			"branches.append_array(build_root_buttresses(trunk_radius, resolved_seed))",
			"var foliage: Array[Dictionary] = build_oak_full_axis_foliage"]},
		{"source":conifer.source_code,"needles":[
			"const MAX_CONIFER_BRANCH_SEGMENTS := 1120",
			"var bough_length := crown_radius * pow(1.0 - crown_unit, 0.64) * length_irregularity",
			"var primary_steps := clampi(ceili(bough_length / lerpf(2.24, 1.72, crown_unit)), 2, 6)",
			"var curtain_length := step_length * lerpf(1.18, 0.68, crown_unit)",
			"curtain_length * 0.76"]},
		{"source":savanna.source_code,"needles":[
			"const MAX_RAISED_FORKS := 6",
			"var step_length := canopy_radius / float(main_steps) * lerpf(0.94, 1.12,",
			"var remaining_reach := canopy_radius * lerpf(0.34, 0.54, primary_unit)",
			"lerpf(0.80, 1.12, stable_unit(\"savanna-arm-length:",
			"length * 0.72"]},
		{"source":factory.source_code,"needles":[
			"const RUNTIME_DENSE_FOLIAGE_VARIANT := 4",
			"var radial_scale := 0.52 + 0.10 * sin(float(index + variant * 7) * 1.31)",
			"var width := 0.18 + 0.07 * sin(float(index + variant * 2) * 2.17)",
			"var half_height := 0.24 + 0.09 * cos(float(index + variant * 4) * 1.37)",
			"func append_wood_tube(", "func append_junction_hull("]},
	]
	var source_rows: Array[Dictionary] = []
	for row_value: Variant in requirements:
		var row: Dictionary = row_value
		var source_text := String(row.get("source", ""))
		if source_text.is_empty():
			return {"status":"pending", "reason":"tree_spatial_source_text_unavailable"}
		for needle_value: Variant in row.get("needles", []):
			var needle := String(needle_value)
			if not source_text.contains(needle):
				return {"status":"pending", "reason":"tree_spatial_bound_input_unrecognized:%s" % needle}
		source_rows.append({"sourceDigest":_digest(source_text),
			"recognizedInputs":(row.get("needles", []) as Array).duplicate()})
	var reviewed_paths: Array[String] = []
	for path_value: Variant in TREE_SPATIAL_REVIEWED_SOURCE_DIGESTS.keys():
		reviewed_paths.append(String(path_value))
	reviewed_paths.sort()
	var reviewed_source_rows: Array[Dictionary] = []
	for path: String in reviewed_paths:
		var expected_digest := String(TREE_SPATIAL_REVIEWED_SOURCE_DIGESTS[path])
		var source_text := FileAccess.get_file_as_string(path)
		var actual_digest := _spatial_source_digest(source_text)
		if source_text.is_empty() or expected_digest.begins_with("PENDING_") \
				or actual_digest != expected_digest:
			return {"status":"pending", "reason":"tree_spatial_source_requires_review:%s" % path,
				"expectedDigest":expected_digest, "actualDigest":actual_digest}
		reviewed_source_rows.append({"path":path, "sourceDigest":actual_digest})
	var proof := {"schema":"active-tree-spatial-source-contract/v1",
		"status":"ready", "sourceRows":source_rows,
		"reviewedSpatialSources":reviewed_source_rows,
		"oakRootAndCanopy":"crown ellipsoid plus explicit root buttress recipe",
		"coniferReach":"capped bough path plus six-step curtain and tip maxima",
		"savannaReach":"capped raised forks plus remaining-reach arm/twig limits",
		"renderer":"runtime dense leaf vertices, joined tubes, junction hulls, and bound wind shaders"}
	proof["digest"] = _digest(proof)
	return proof


static func active_tree_grammar_receipt() -> Dictionary:
	var paths: Array[String] = [
		"res://scripts/environment/TreeRuntimeRequestBuilder.gd",
		"res://scripts/environment/TreeSpawnService.gd",
		"res://scripts/environment/tree_grammars/MathematicalTreePocRecipeBuilder.gd",
		"res://scripts/environment/tree_grammars/MathematicalTreePocBushyOakRecipeBuilder.gd",
		"res://scripts/environment/tree_grammars/MathematicalTreePocConiferRecipeBuilder.gd",
		"res://scripts/environment/tree_grammars/MathematicalTreePocSavannaRecipeBuilder.gd",
	]
	var rows: Array[Dictionary] = []
	for path: String in paths:
		var script := load(path) as GDScript
		if script == null or script.source_code.is_empty():
			return {"status":"pending", "reason":"active_tree_grammar_source_unavailable:%s" % path}
		rows.append({"path":path, "sourceDigest":_digest(script.source_code)})
	var receipt := {"schema":"active-mathematical-tree-grammar-receipt/v1",
		"status":"ready", "grammarRevision":TREE_GRAMMAR_REVISION, "rows":rows}
	receipt["digest"] = _digest(receipt)
	return receipt


static func active_tree_visual_wind_envelope() -> Dictionary:
	const VISUAL_FACTORY_PATH := "res://scripts/visual/ProceduralTreeVisualFactory.gd"
	const BRANCH_SHADER_PATH := "res://resources/visual/procedural_tree_branch.gdshader"
	const FOLIAGE_SHADER_PATH := "res://resources/visual/procedural_tree_foliage.gdshader"
	const WIND_SYSTEM_PATH := "res://scripts/environment/EnvironmentWindSystem.gd"
	var factory := load(VISUAL_FACTORY_PATH) as GDScript
	var wind_system := load(WIND_SYSTEM_PATH) as GDScript
	var branch_shader := load(BRANCH_SHADER_PATH) as Shader
	var foliage_shader := load(FOLIAGE_SHADER_PATH) as Shader
	if factory == null or wind_system == null or branch_shader == null or foliage_shader == null:
		return {"status":"pending", "reason":"active_tree_visual_wind_dependency_missing"}
	var factory_source := factory.source_code
	var wind_source := wind_system.source_code
	if not factory_source.contains(BRANCH_SHADER_PATH) \
			or not factory_source.contains(FOLIAGE_SHADER_PATH) \
			or not factory_source.contains("0.24 if architecture == \"conifer\" else 0.32") \
			or not factory_source.contains("0.40 if architecture == \"conifer\" else 0.50") \
			or not factory_source.contains("0.065 if architecture == \"conifer\" else 0.090") \
			or not wind_source.contains("target_strength = clampf((0.16 + clouds * 0.14 + weather_boost) * biome_response, 0.0, 1.0)") \
			or not wind_source.contains("target_gust_strength = clampf((0.06 + clouds * 0.08 + precipitation * 0.48) * biome_response, 0.0, 0.90)") \
			or not wind_source.contains("direction = Vector3(cos(direction_angle), 0.0, sin(direction_angle)).normalized()"):
		return {"status":"pending", "reason":"active_tree_visual_wind_policy_unrecognized"}
	var branch_shader_source := branch_shader.code
	var foliage_shader_source := foliage_shader.code
	if not branch_shader_source.contains("wind_bend_meters") \
			or not foliage_shader_source.contains("main_bend_meters") \
			or not foliage_shader_source.contains("flutter_meters"):
		return {"status":"pending", "reason":"active_tree_wind_shader_policy_unrecognized"}
	var branch_component := 0.32 * (0.68 + 0.90)
	var foliage_main := 0.50 * (0.68 + 0.90)
	var foliage_flutter := 0.090 * (1.0 * 0.42 + 0.90)
	var envelope := {"schema":"active-procedural-tree-wind-envelope/v1",
		"status":"ready", "visualFactoryPath":VISUAL_FACTORY_PATH,
		"branchShaderPath":BRANCH_SHADER_PATH, "foliageShaderPath":FOLIAGE_SHADER_PATH,
		"windSystemPath":WIND_SYSTEM_PATH,
		"windSystemSourceDigest":_digest(wind_source),
		"visualFactorySourceDigest":_digest(factory_source),
		"branchShaderDigest":_digest(branch_shader_source),
		"foliageShaderDigest":_digest(foliage_shader_source),
		"windStrengthMax":1.0, "windGustMax":0.90,
		"windDirectionYAxis":0.0,
		"branchComponentDisplacementMaxMeters":branch_component,
		"foliageComponentDisplacementMaxMeters":sqrt(foliage_main * foliage_main \
			+ foliage_flutter * foliage_flutter),
		"foliageVerticalDisplacementMaxMeters":foliage_flutter * 0.14}
	envelope["digest"] = _digest(envelope)
	return envelope


static func derive_tree_request_envelope(profile_snapshot: Dictionary) -> Dictionary:
	if int(profile_snapshot.get("schemaVersion", -1)) != 1 \
			or String(profile_snapshot.get("fallbackId", "")) != "default" \
			or String(profile_snapshot.get("contentIdentity", "")).length() != 64:
		return {"status":"failed", "reason":"tree_profile_catalog_snapshot_invalid"}
	var profiles: Variant = profile_snapshot.get("profiles", null)
	if not profiles is Array or (profiles as Array).is_empty():
		return {"status":"failed", "reason":"tree_profile_catalog_empty"}
	var max_height := 0.0
	var max_canopy := 0.0
	var max_trunk := 0.0
	var max_wind_response := 0.0
	var profile_ids: Array[String] = []
	var profile_bounds := {}
	for profile_value: Variant in profiles:
		if not profile_value is Dictionary:
			return {"status":"failed", "reason":"tree_profile_catalog_row_invalid"}
		var profile: Dictionary = profile_value
		var profile_id := String(profile.get("biomeId", ""))
		var tree_scale := _snapshot_number(profile, "tree_scale")
		var height_min := _snapshot_number(profile, "tree_height_min")
		var height_max := _snapshot_number(profile, "tree_height_max")
		var crown_min := _snapshot_number(profile, "crown_radius_min")
		var crown_max := _snapshot_number(profile, "crown_radius_max")
		var trunk_min := _snapshot_number(profile, "trunk_radius_min")
		var trunk_max := _snapshot_number(profile, "trunk_radius_max")
		var wind_response := _snapshot_number(profile, "wind_response")
		if not is_finite(tree_scale) or not is_finite(height_min) or not is_finite(height_max) \
				or not is_finite(crown_min) or not is_finite(crown_max) \
				or not is_finite(trunk_min) or not is_finite(trunk_max) \
				or not is_finite(wind_response) or profile_id.is_empty() \
				or not profile.get("tree_families", null) is Array \
				or tree_scale <= 0.0 or height_min < 0.0 or height_max < height_min \
				or crown_min < 0.0 or crown_max < crown_min \
				or trunk_min < 0.0 or trunk_max < trunk_min or wind_response < 0.0:
			return {"status":"failed", "reason":"tree_profile_spatial_parameters_invalid:%s" % profile_id}
		var request_height := height_max * 1.06 * tree_scale \
			if height_min > 0.0 else 6.8 * tree_scale
		# ProceduralTreeRecipeBuilder has a six metre canonical minimum even when
		# callers ask for less; include that effective request in the envelope.
		request_height = maxf(6.0, request_height)
		var architectures: Dictionary = {}
		for family_value: Variant in profile.tree_families:
			var family := String(family_value)
			var architecture := "conifer" if family.contains("conifer") else \
				("savanna" if family.contains("savanna") else \
				("broadleaf" if family.contains("broadleaf") else ""))
			if architecture.is_empty():
				return {"status":"pending", "reason":"tree_family_architecture_unproven:%s:%s" \
					% [profile_id, family]}
			architectures[architecture] = true
		if architectures.is_empty():
			return {"status":"pending", "reason":"tree_profile_has_no_supported_family:%s" % profile_id}
		var profile_trunk_max := 0.0
		var profile_canopy_max := 0.0
		var architecture_bounds := {}
		for architecture_value: Variant in architectures.keys():
			var architecture := String(architecture_value)
			var raw_trunk_ratio := 0.070
			var raw_canopy_ratio := 0.70
			match architecture:
				"conifer":
					raw_trunk_ratio = 0.034
					raw_canopy_ratio = 0.34
				"savanna":
					raw_trunk_ratio = 0.055
					raw_canopy_ratio = 0.70
				"broadleaf":
					pass
			var request_trunk := maxf(0.18, request_height * raw_trunk_ratio * 1.08)
			if trunk_max > 0.0:
				request_trunk = maxf(maxf(0.18, trunk_min), trunk_max)
			var request_canopy := maxf(request_trunk * 2.2,
				request_height * raw_canopy_ratio * 1.10)
			if crown_max > 0.0:
				request_canopy = maxf(maxf(request_trunk * 2.2, crown_min), crown_max)
			# The grammar builder itself raises trunk/crown minima after request
			# generation; preserve those exact effective values in this envelope.
			request_trunk = maxf(0.28, request_trunk)
			request_canopy = maxf(request_trunk * 2.4, request_canopy)
			profile_trunk_max = maxf(profile_trunk_max, request_trunk)
			profile_canopy_max = maxf(profile_canopy_max, request_canopy)
			architecture_bounds[architecture] = {
				"maxVisualHeightMeters": request_height,
				"maxTrunkRadiusMeters": request_trunk,
				"maxCanopyRadiusMeters": request_canopy
			}
		max_height = maxf(max_height, request_height)
		max_trunk = maxf(max_trunk, profile_trunk_max)
		max_canopy = maxf(max_canopy, profile_canopy_max)
		max_wind_response = maxf(max_wind_response, minf(2.0, wind_response))
		profile_bounds[profile_id] = {
			"architectures": architecture_bounds,
			"maxWindResponse": minf(2.0, wind_response)
		}
		profile_ids.append(profile_id)
	profile_ids.sort()
	var envelope := {
		"schema":"ecology-tree-request-envelope/v1", "status":"ready",
		"profileCatalogRevision":String(profile_snapshot.contentIdentity),
		"profileIds":profile_ids, "maxVisualHeightMeters":max_height,
		"maxTrunkRadiusMeters":max_trunk, "maxCanopyRadiusMeters":max_canopy,
		"maxWindResponse":max_wind_response,
		"profileBounds":profile_bounds,
		"fallbackLegacyHeightUpperMeters":6.8,
		"geneticHeightMultiplierUpper":1.06,
		"geneticRadiusMultiplierUpper":1.10,
		"grammarEnvelopeStatus":"pending_compiled_geometry_proof"
	}
	envelope["digest"] = _digest(envelope)
	return envelope


static func _snapshot_number(profile: Dictionary, field: String) -> float:
	var encoded: Variant = profile.get(field, null)
	if not encoded is Dictionary:
		return NAN
	var value: Variant = encoded.get("value", null)
	return float(value) if value is float or value is int else NAN


static func derive_static_recipe_profile_envelope(profile_snapshot: Dictionary) -> Dictionary:
	var tree_envelope := derive_tree_request_envelope(profile_snapshot)
	if String(tree_envelope.get("status", "")) != "ready":
		return tree_envelope
	var profiles: Array = profile_snapshot.get("profiles", [])
	var max_rock_scale := 0.0
	var max_detail_scale := 0.0
	for profile_value: Variant in profiles:
		if not profile_value is Dictionary:
			return {"status":"failed", "reason":"ecology_profile_row_invalid"}
		var profile: Dictionary = profile_value
		var rock_scale := _snapshot_number(profile, "rock_scale")
		if not is_finite(rock_scale) or rock_scale <= 0.0:
			return {"status":"failed", "reason":"ecology_rock_profile_scale_invalid"}
		max_rock_scale = maxf(max_rock_scale, rock_scale)
		var detail_scales: Variant = profile.get("detail_scale_maxs", null)
		if not detail_scales is Array:
			return {"status":"failed", "reason":"ecology_detail_profile_scales_invalid"}
		for encoded_scale: Variant in detail_scales:
			if not encoded_scale is Dictionary:
				return {"status":"failed", "reason":"ecology_detail_profile_scale_invalid"}
			var scale_value: Variant = encoded_scale.get("value", null)
			if not scale_value is float and not scale_value is int:
				return {"status":"failed", "reason":"ecology_detail_profile_scale_invalid"}
			var scale := float(scale_value)
			if not is_finite(scale) or scale < 0.0:
				return {"status":"failed", "reason":"ecology_detail_profile_scale_nonfinite"}
			max_detail_scale = maxf(max_detail_scale, scale)
	if max_rock_scale > 1.12 + 0.0001 or max_detail_scale > 1.40 + 0.0001:
		return {"status":"failed", "reason":"ecology_profile_exceeds_certified_static_recipe_input"}
	var envelope := {
		"schema":"ecology-static-recipe-profile-envelope/v1",
		"status":"ready", "profileCatalogRevision":String(profile_snapshot.contentIdentity),
		"maxRockProfileScale":max_rock_scale,
		"maxDetailInstanceScale":max_detail_scale,
		"oreRecipeRevision":"ore-source-recipe/v1",
		"forageRecipeRevision":"forage-source-recipe/v1",
		"detailMeshRecipeRevision":"procedural-detail-meshes/v1",
		"detailWindDisplacementMaxMeters":0.07,
	}
	envelope["digest"] = _digest(envelope)
	return envelope


static func maximum_horizontal_support_meters(source_inputs: Dictionary = {}) -> float:
	var result := 0.0
	var policy := support_policy(source_inputs)
	for family_value: Variant in (policy.get("families", {}) as Dictionary).values():
		if family_value is Dictionary:
			result = maxf(result, float(family_value.get("maxHorizontalSupportMeters", 0.0)))
	return result


static func snapshot_cache_identity(world_id: String, source_chunk_key: Vector2i,
		source_inputs: Dictionary, removed_projection_digest: String) -> String:
	var policy := support_policy(source_inputs)
	var inputs_digest := _digest({
		"sourceInputs": source_inputs,
		"removedSourceProjectionDigest": removed_projection_digest,
		"influencePolicyRevision": policy.revision,
		"influencePolicyDigest": policy.digest,
	})
	return "%s|%d,%d|%s" % [world_id, source_chunk_key.x, source_chunk_key.y, inputs_digest]


static func source_domain_revision(world_id: String, world_seed: String,
		source_chunk_key: Vector2i, source_inputs: Dictionary,
		removed_projection_digest: String) -> String:
	var policy := support_policy(source_inputs)
	return _digest({
		"schema": "ecology-source-domain-snapshot/v1",
		"worldId": world_id,
		"worldSeed": world_seed,
		"sourceChunkKey": source_chunk_key,
		"sourceInputs": source_inputs,
		"removedSourceProjectionDigest": removed_projection_digest,
		"influencePolicyRevision": policy.revision,
		"influencePolicyDigest": policy.digest,
	})


static func digest_value(value: Variant) -> String:
	return _digest(value)


static func inverse_source_chunk_keys_for_section(section_key: Vector3i,
		source_inputs: Dictionary = {}) -> Array[Vector2i]:
	var bounds := section_bounds(section_key)
	var support := maximum_horizontal_support_meters(source_inputs)
	var chunk_size := StaticRenderSectionGridScript.STREAM_CHUNK_SIZE_METERS
	# Source origins range over half-open source chunk cells. The lower inclusive
	# key is ceil(lower_origin / chunk_size) - 1, which includes the cell touching
	# an exact boundary and every cell that overlaps the admissible origin range.
	var low_x := ceili((bounds.position.x - support) / chunk_size) - 1
	var low_z := ceili((bounds.position.z - support) / chunk_size) - 1
	var high_x := ceili((bounds.end.x + support) / chunk_size) - 1
	var high_z := ceili((bounds.end.z + support) / chunk_size) - 1
	var result: Array[Vector2i] = []
	for z in range(low_z, high_z + 1):
		for x in range(low_x, high_x + 1):
			result.append(Vector2i(x, z))
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x if a.x != b.x else a.y < b.y)
	return result


static func source_domain_census_certificate(section_key: Vector3i,
		source_inputs: Dictionary = {}) -> Dictionary:
	var bounds := section_bounds(section_key)
	var keys := inverse_source_chunk_keys_for_section(section_key, source_inputs)
	var policy := support_policy(source_inputs)
	var key_rows: Array = []
	for key: Vector2i in keys:
		key_rows.append([key.x, key.y])
	var certificate := {
		"status": "ready" if String(policy.get("status", "pending")) == "ready" else "pending",
		"schema": CENSUS_SCHEMA,
		"sectionKey": section_key,
		"sectionBounds": bounds,
		"influencePolicyRevision": String(policy.revision),
		"influencePolicyDigest": String(policy.digest),
		"sourceChunkSizeMeters": float(policy.sourceChunkSizeMeters),
		"sourceOriginDomainFootprintMeters":float(policy.sourceChunkSizeMeters),
		"maxHorizontalSupportMeters": maximum_horizontal_support_meters(source_inputs),
		"sourceInputs":_freeze_value(source_inputs.duplicate(true)),
		"sourceInputsDigest":_digest(source_inputs),
		"supportPolicy":_freeze_value(policy.duplicate(true)),
		"sourceChunkKeys": keys,
		"sourceChunkKeysDigest": _digest(key_rows),
	}
	if certificate.status == "pending":
		certificate["reason"] = "ecology_support_policy_unbounded"
	return certificate


static func validate_source_domain_census_certificate(certificate: Dictionary,
		expected_section_key := Vector3i(2147483647, 2147483647, 2147483647),
			source_inputs: Dictionary = {}) -> bool:
	if String(certificate.get("schema", "")) != CENSUS_SCHEMA:
		return false
	var section_key: Variant = certificate.get("sectionKey", null)
	if not section_key is Vector3i or section_key == Vector3i(2147483647, 2147483647, 2147483647):
		return false
	if expected_section_key != Vector3i(2147483647, 2147483647, 2147483647) \
			and section_key != expected_section_key:
		return false
	var certificate_inputs: Variant = certificate.get("sourceInputs", null)
	if not certificate_inputs is Dictionary:
		return false
	if not source_inputs.is_empty() and _digest(source_inputs) != _digest(certificate_inputs):
		return false
	var effective_inputs: Dictionary = source_inputs if not source_inputs.is_empty() \
		else certificate_inputs
	var expected := source_domain_census_certificate(section_key, effective_inputs)
	if String(expected.get("status", "")) != String(certificate.get("status", "")):
		return false
	for field: String in ["sectionBounds", "influencePolicyRevision", "influencePolicyDigest",
			"sourceChunkSizeMeters", "sourceOriginDomainFootprintMeters",
			"maxHorizontalSupportMeters", "sourceChunkKeysDigest", "sourceInputsDigest"]:
		if certificate.get(field) != expected.get(field):
			return false
	if _digest(certificate.get("supportPolicy", {})) != _digest(expected.get("supportPolicy", {})):
		return false
	if String(expected.get("status", "")) != "ready" \
			and String(certificate.get("reason", "")) != String(expected.get("reason", "")):
		return false
	var supplied_keys: Variant = certificate.get("sourceChunkKeys", null)
	if not supplied_keys is Array or supplied_keys != expected.sourceChunkKeys:
		return false
	return true


static func seal_source_domain_snapshot(fields: Dictionary) -> Dictionary:
	var snapshot: Dictionary = fields.duplicate(true)
	snapshot["schema"] = "ecology-source-domain-snapshot/v1"
	var world_id := String(snapshot.get("worldId", ""))
	var world_seed := String(snapshot.get("worldSeed", ""))
	var source_chunk_key: Variant = snapshot.get("sourceChunkKey", null)
	var source_inputs: Dictionary = snapshot.get("sourceInputs", {}) \
		if snapshot.get("sourceInputs", {}) is Dictionary else {}
	var source_rows: Array = snapshot.get("sourceRows", []) \
		if snapshot.get("sourceRows", []) is Array else []
	var actor_intents: Array = snapshot.get("actorIntents", []) \
		if snapshot.get("actorIntents", []) is Array else []
	var categories_complete: Array = snapshot.get("categoriesComplete", []) \
		if snapshot.get("categoriesComplete", []) is Array else []
	var removed_projection_digest := String(snapshot.get("removedSourceProjectionDigest", ""))
	var terrain_revision := String(source_inputs.get("terrainVolumeChunkRevision", ""))
	var structure_revision := String(source_inputs.get("structureAdmissionRevision", ""))
	var structure_status := String(source_inputs.get("structureAdmissionStatus", "pending"))
	var policy := support_policy(source_inputs)
	source_rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		if not a is Dictionary: return true
		if not b is Dictionary: return false
		return String(a.get("sourceId", "")) < String(b.get("sourceId", "")))
	actor_intents.sort_custom(func(a: Variant, b: Variant) -> bool:
		if not a is Dictionary: return true
		if not b is Dictionary: return false
		return String(a.get("propId", "")) < String(b.get("propId", "")))
	categories_complete.sort()
	snapshot["categoriesComplete"] = categories_complete
	snapshot["sourceRows"] = source_rows
	snapshot["actorIntents"] = actor_intents
	snapshot["removedSourceProjectionDigest"] = removed_projection_digest
	snapshot["removedPropsRevision"] = removed_projection_digest
	snapshot["terrainVolumeChunkRevision"] = terrain_revision
	snapshot["structureAdmissionRevision"] = structure_revision
	snapshot["structureAdmissionStatus"] = structure_status
	snapshot["influencePolicyRevision"] = String(policy.revision)
	snapshot["influencePolicyDigest"] = String(policy.digest)
	snapshot["sourceRevision"] = source_domain_revision(world_id, world_seed,
		source_chunk_key, source_inputs, removed_projection_digest)
	snapshot["sourceDomainRevision"] = snapshot.sourceRevision
	snapshot["producerCatalogRevision"] = String(source_inputs.get(
		"producerCatalogRevision", ""))
	snapshot["sourceManifestDigest"] = _digest({
		"categoriesComplete": categories_complete, "sourceRows": source_rows,
	})
	snapshot["actorIntentDigest"] = _digest(actor_intents)
	snapshot["producerSnapshotRevision"] = _digest({
		"sourceRevision": snapshot.sourceRevision,
		"sourceManifestDigest": snapshot.sourceManifestDigest,
		"actorIntentDigest": snapshot.actorIntentDigest,
	})
	snapshot["enumeratedSourceCount"] = source_rows.size()
	snapshot["producerComplete"] = bool(snapshot.get("producerComplete", false))
	var producer_status := String(snapshot.get("producerStatus",
		"ready" if snapshot.producerComplete else "pending"))
	var source_inputs_complete := not terrain_revision.is_empty() \
		and not structure_revision.is_empty() and structure_status == "ready" \
		and removed_projection_digest.length() == 64 \
		and not world_id.is_empty() and not world_seed.is_empty() \
		and source_chunk_key is Vector2i
	var complete_categories := true
	for required_category: String in REQUIRED_CATEGORIES:
		if not categories_complete.has(required_category):
			complete_categories = false
	snapshot["status"] = "failed" if producer_status == "failed" else ("ready" if snapshot.producerComplete and source_inputs_complete \
			and complete_categories \
			and String(policy.get("status", "pending")) == "ready" else "pending")
	if snapshot.status != "ready":
		snapshot["reason"] = String(snapshot.get("failureReason",
			"ecology_producer_domain_incomplete_or_unbounded")) if snapshot.status == "failed" \
			else "ecology_producer_domain_incomplete_or_unbounded"
	return _freeze_value(snapshot)


static func validate_source_domain_snapshot(snapshot: Dictionary, expected_world_id := "",
		expected_source_chunk_key := Vector2i(2147483647, 2147483647)) -> bool:
	if String(snapshot.get("schema", "")) != "ecology-source-domain-snapshot/v1":
		return false
	if not expected_world_id.is_empty() and String(snapshot.get("worldId", "")) != expected_world_id:
		return false
	if expected_source_chunk_key != Vector2i(2147483647, 2147483647) \
			and snapshot.get("sourceChunkKey", null) != expected_source_chunk_key:
		return false
	var mutable: Dictionary = snapshot.duplicate(true)
	var expected := seal_source_domain_snapshot(mutable)
	for field: String in ["sourceRevision", "sourceDomainRevision", "producerCatalogRevision", "sourceManifestDigest", "actorIntentDigest", "producerSnapshotRevision",
			"enumeratedSourceCount", "producerComplete", "producerStatus", "status", "reason",
			"influencePolicyRevision", "influencePolicyDigest", "removedPropsRevision",
			"terrainVolumeChunkRevision", "structureAdmissionRevision", "structureAdmissionStatus"]:
		if snapshot.get(field, null) != expected.get(field, null):
			return false
	return true


static func _all_families_bounded(families: Dictionary) -> bool:
	for family_value: Variant in families.values():
		if not family_value is Dictionary \
				or String(family_value.get("status", "")) != "bounded":
			return false
	return true


static func validate_source_bounds(family: String, source_origin: Vector3, bounds: AABB,
		runtime_policy: Dictionary = {}) -> Dictionary:
	var families: Dictionary = runtime_policy.get("families", {}) \
		if String(runtime_policy.get("status", "")) == "ready" else FAMILY_POLICY
	if not families.has(family):
		return {"status": "pending", "reason": "unknown_ecology_support_family", "family": family}
	if not source_origin.is_finite() or not bounds.position.is_finite() or not bounds.size.is_finite() \
			or bounds.size.x < 0.0 or bounds.size.y < 0.0 or bounds.size.z < 0.0:
		return {"status": "pending", "reason": "invalid_ecology_source_bounds", "family": family}
	var policy: Dictionary = families[family]
	if String(policy.get("status", "")) != "bounded":
		return {"status": "pending", "reason": "ecology_support_policy_unbounded",
			"family": family, "policy": policy.duplicate(true)}
	var relative := bounds.position - source_origin
	var horizontal := maxf(maxf(absf(relative.x), absf(bounds.end.x - source_origin.x)),
		maxf(absf(relative.z), absf(bounds.end.z - source_origin.z)))
	var vertical := maxf(absf(relative.y), absf(bounds.end.y - source_origin.y))
	if horizontal > float(policy.maxHorizontalSupportMeters) + 0.0001 \
			or vertical > float(policy.maxVerticalSupportMeters) + 0.0001:
		return {"status": "pending", "reason": "ecology_source_exceeds_support_policy",
			"family": family, "horizontalSupportMeters": horizontal,
			"verticalSupportMeters": vertical, "policy": policy.duplicate(true)}
	return {"status": "ready", "family": family,
		"horizontalSupportMeters": horizontal, "verticalSupportMeters": vertical,
		"influencePolicyRevision": String(runtime_policy.get("revision", "ecology-support-v3")),
		"influencePolicyDigest": String(runtime_policy.get("digest", ""))}


static func section_bounds(section_key: Vector3i) -> AABB:
	var size := StaticRenderSectionGridScript.SECTION_SIZE_METERS
	return AABB(StaticRenderSectionGridScript.origin_for_key(section_key), Vector3.ONE * size)


static func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSON.stringify(_canonical_value(value)).to_utf8_buffer())
	return context.finish().hex_encode()


static func _spatial_source_digest(source: String) -> String:
	var normalized := source.replace("\r\n", "\n").replace("\r", "\n")
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(normalized.to_utf8_buffer()) != OK:
		return ""
	return context.finish().hex_encode()


static func _canonical_value(value: Variant) -> Variant:
	if value is Vector2i:
		return {"$type": "Vector2i", "x": value.x, "y": value.y}
	if value is Vector3i:
		return {"$type": "Vector3i", "x": value.x, "y": value.y, "z": value.z}
	if value is Vector2:
		return {"$type": "Vector2", "x": value.x, "y": value.y}
	if value is Vector3:
		return {"$type": "Vector3", "x": value.x, "y": value.y, "z": value.z}
	if value is Color:
		return {"$type": "Color", "r": value.r, "g": value.g, "b": value.b, "a": value.a}
	if value is Basis:
		return {"$type": "Basis", "x": _canonical_value(value.x),
			"y": _canonical_value(value.y), "z": _canonical_value(value.z)}
	if value is Transform3D:
		return {"$type": "Transform3D", "basis": _canonical_value(value.basis),
			"origin": _canonical_value(value.origin)}
	if value is AABB:
		return {"$type": "AABB", "position": _canonical_value(value.position),
			"size": _canonical_value(value.size)}
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool: return String(a) < String(b))
		var result := {}
		for key: Variant in keys:
			result[String(key)] = _canonical_value(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_canonical_value(item))
		return result
	return value


static func _freeze_value(value: Variant) -> Variant:
	if value is Dictionary:
		var frozen: Dictionary = {}
		for key: Variant in value.keys():
			frozen[key] = _freeze_value(value[key])
		frozen.make_read_only()
		return frozen
	if value is Array:
		var frozen: Array = []
		for item: Variant in value:
			frozen.append(_freeze_value(item))
		frozen.make_read_only()
		return frozen
	return value
