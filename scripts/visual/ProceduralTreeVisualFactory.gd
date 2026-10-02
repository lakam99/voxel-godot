extends RefCounted
class_name ProceduralTreeVisualFactory

const BRANCH_SHADER := preload("res://resources/visual/procedural_tree_branch.gdshader")
const FOLIAGE_SHADER := preload("res://resources/visual/procedural_tree_foliage.gdshader")
const VISIBILITY_RANGE := 440.0
const RUNTIME_DENSE_FOLIAGE_VARIANT := 4
# PoC/review mesh quality. Runtime trees keep the same single connected bole,
# but use a slightly leaner tessellation below so publication is not held up by
# bark detail the material already supplies at gameplay distance.
const CONTINUOUS_WOOD_RADIAL_SEGMENTS := 10
const JUNCTION_HULL_RADIAL_SEGMENTS := 8
const JUNCTION_HULL_LATITUDES := 3
const RUNTIME_CONTINUOUS_WOOD_RADIAL_SEGMENTS := 4
const RUNTIME_JUNCTION_HULL_RADIAL_SEGMENTS := 3
const RUNTIME_JUNCTION_HULL_LATITUDES := 1

var branch_mesh: CylinderMesh
var foliage_cluster_meshes: Array[ArrayMesh] = []
var impostor_crown_mesh: QuadMesh
var horizon_crown_meshes := {}
var branch_materials := {}
var foliage_materials := {}

func instantiate_recipe(recipe: Dictionary, biome: String, prop_id: String) -> Node3D:
	var root := create_recipe_root(recipe, biome, prop_id)
	if root == null:
		return null
	var branch_visual := instantiate_branches(recipe, biome, prop_id)
	if branch_visual != null:
		root.add_child(branch_visual)
	var foliage_visual := instantiate_foliage(recipe, biome, prop_id)
	if foliage_visual != null:
		root.add_child(foliage_visual)
	return root

func create_recipe_root(recipe: Dictionary, biome: String, prop_id: String) -> Node3D:
	if recipe.is_empty():
		return null
	# Godot's dummy headless renderer cannot allocate MultiMesh RIDs.  The
	# runtime queue still needs to exercise deterministic recipe generation,
	# publication order, LOD transitions, and gameplay tree metadata in that
	# mode, but it must not try to publish a GPU resource that the renderer does
	# not implement. Headed/visible runs take the unchanged shared-geometry path.
	if not is_headless_renderer():
		ensure_shared_geometry()
	var root := Node3D.new()
	root.name = "ProceduralTreeVisual"
	root.set_meta("visual_source", "procedural_tree_recipe")
	root.set_meta("tree_recipe_signature", String(recipe.get("signature", "")))
	root.set_meta("tree_branch_count", int(recipe.get("branchCount", 0)))
	root.set_meta("tree_foliage_cluster_count", int(recipe.get("foliageClusterCount", 0)))
	root.set_meta("tree_architecture", String(recipe.get("architecture", "broadleaf")))
	root.set_meta("tree_species_grammar", String(recipe.get("speciesGrammar", "")))
	root.set_meta("tree_crown_habit", String(recipe.get("crownHabit", "natural")))
	root.set_meta("tree_visual_height", float(recipe.get("height", 0.0)))
	root.set_meta("tree_canopy_radius", float(recipe.get("canopyRadius", 0.0)))
	root.set_meta("tree_id", prop_id)
	var render_policy: Dictionary = recipe.get("renderPolicy", {})
	root.set_meta("tree_visibility_range", float(render_policy.get("visibilityRange", VISIBILITY_RANGE)))
	root.set_meta("tree_shadow_range", float(render_policy.get("shadowRange", VISIBILITY_RANGE * 0.5)))
	root.set_meta("tree_wind_response", float(render_policy.get("windResponse", 1.0)))
	# The GPU receives deterministic per-segment/per-cluster phases through
	# MultiMesh custom data.  Keep the root phase as diagnostic metadata too so
	# visual runners can prove independent trees do not share an authored sway.
	root.set_meta("tree_wind_phase", stable_unit("tree-wind-phase:%s:%s" % [biome, prop_id]) * TAU)
	return root

func ensure_shared_geometry() -> void:
	if branch_mesh == null:
		branch_mesh = CylinderMesh.new()
		branch_mesh.resource_name = "procedural_tree_shared_branch_segment"
		branch_mesh.height = 1.0
		branch_mesh.top_radius = 1.0
		branch_mesh.bottom_radius = 1.0
		branch_mesh.radial_segments = 8
		branch_mesh.rings = 5
	if foliage_cluster_meshes.is_empty():
		# Variants 0-3 are the detailed PoC shapes. Variant 4 is a denser shared
		# runtime crown unit: more leaf cards in the same one MultiMesh instance
		# increase canopy coverage without adding transforms, nodes, or draw calls.
		for variant in range(5):
			foliage_cluster_meshes.append(build_foliage_cluster_mesh(variant))
	# Far-tree impostors use two crossed copies of this unit quad.  It must be a
	# shared prewarmed resource just like the branch and foliage meshes: allocating
	# a QuadMesh while publishing a distant streamed tree made the otherwise
	# bounded root stage brush against the 1 ms gameplay-frame budget.
	if impostor_crown_mesh == null:
		impostor_crown_mesh = QuadMesh.new()
		impostor_crown_mesh.resource_name = "procedural_tree_shared_impostor_crown"
		impostor_crown_mesh.size = Vector2.ONE
	if horizon_crown_meshes.is_empty():
		# Temporary chunk-batched silhouettes use the same material and two
		# crossed cards as the existing impostor, but a small shared outline keeps
		# their crowns legible while mathematical recipes are still queued.
		horizon_crown_meshes["broadleaf"] = build_horizon_crown_mesh([
			Vector2(-0.47, -0.34), Vector2(-0.50, 0.06),
			Vector2(-0.37, 0.34), Vector2(-0.15, 0.49),
			Vector2(0.13, 0.48), Vector2(0.39, 0.29),
			Vector2(0.50, -0.04), Vector2(0.43, -0.34),
			Vector2(0.19, -0.49), Vector2(-0.20, -0.47)
		], "broadleaf")
		horizon_crown_meshes["conifer"] = build_horizon_crown_mesh([
			Vector2(0.0, 0.50), Vector2(0.20, 0.17),
			Vector2(0.32, -0.08), Vector2(0.50, -0.48),
			Vector2(-0.50, -0.48), Vector2(-0.32, -0.08),
			Vector2(-0.20, 0.17)
		], "conifer")
		horizon_crown_meshes["savanna"] = build_horizon_crown_mesh([
			Vector2(-0.46, -0.21), Vector2(-0.50, 0.08),
			Vector2(-0.30, 0.33), Vector2(0.04, 0.43),
			Vector2(0.36, 0.29), Vector2(0.50, 0.06),
			Vector2(0.46, -0.20), Vector2(0.21, -0.35),
			Vector2(-0.24, -0.34)
		], "savanna")

func prewarm_runtime_resources() -> void:
	# Geometry and material variants are immutable shared resources. Build them
	# while the loading screen is still active so a first visit to a biome cannot
	# create shader materials in the same frame as tree publication.
	ensure_shared_geometry()
	for architecture in ["broadleaf", "conifer", "savanna"]:
		for biome in ["forest", "taiga", "savanna", "swamp", "snow", "tundra", "plains"]:
			branch_material(architecture, biome)
			foliage_material(architecture, biome)

## Candidate-A renderer accessors.  The chunk-batched prototype uses exactly
## the same immutable primitives and materials as the production per-tree
## renderer; it must not fork tree geometry simply to make a benchmark look
## favorable.
func runtime_shared_branch_mesh() -> Mesh:
	ensure_shared_geometry()
	return branch_mesh

func runtime_shared_impostor_crown_mesh() -> Mesh:
	ensure_shared_geometry()
	return impostor_crown_mesh


func runtime_shared_horizon_crown_mesh(architecture: String) -> Mesh:
	ensure_shared_geometry()
	return horizon_crown_meshes.get(architecture, horizon_crown_meshes["broadleaf"]) as Mesh


func build_horizon_crown_mesh(outline: Array[Vector2], architecture: String) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(outline.size()):
		for point in [Vector2.ZERO, outline[(index + 1) % outline.size()], outline[index]]:
			surface.set_normal(Vector3.BACK)
			surface.set_uv(point + Vector2(0.5, 0.5))
			surface.set_color(Color(0.85, 0.53, 0.84 + point.y * 0.10, 1.0))
			surface.add_vertex(Vector3(point.x, point.y, 0.0))
	var mesh := surface.commit()
	mesh.resource_name = "procedural_tree_shared_horizon_crown_%s" % architecture
	return mesh

func runtime_shared_foliage_cluster_mesh(cluster_variant := 1) -> Mesh:
	ensure_shared_geometry()
	if foliage_cluster_meshes.is_empty():
		return null
	return foliage_cluster_meshes[clampi(cluster_variant, 0, foliage_cluster_meshes.size() - 1)]

func instantiate_branches(recipe: Dictionary, biome: String, prop_id: String) -> Node3D:
	var branches: Array = recipe.get("branches", [])
	if branches.is_empty():
		return null
	var typed_branches: Array[Dictionary] = []
	for branch_value in branches:
		if not (branch_value is Dictionary):
			continue
		typed_branches.append(branch_value as Dictionary)
	# Existing runtime users keep their direct MultiMesh renderer. The generated
	# connected surface is an explicit isolated-PoC opt-in only.
	if bool(recipe.get("pocContinuousWood", false)):
		return instantiate_continuous_wood(recipe, typed_branches, biome)
	if bool(recipe.get("runtimeContinuousBole", false)):
		return instantiate_runtime_bole_and_branches(recipe, typed_branches, biome, prop_id)
	return instantiate_branch_instances(recipe, typed_branches, biome, prop_id)

func instantiate_runtime_bole_and_branches(
	recipe: Dictionary,
	branches: Array[Dictionary],
	biome: String,
	prop_id: String
) -> Node3D:
	var root := Node3D.new()
	root.name = "ProceduralTreeWood"
	var bole_visual := instantiate_runtime_bole(recipe, branches, biome)
	if bole_visual != null:
		bole_visual.name = "ProceduralTreeContinuousStructuralWood"
		bole_visual.set_meta("tree_wood_role", "continuous_bole_and_scaffolds")
		root.add_child(bole_visual)
	var distal_visual := instantiate_runtime_distal_branches(recipe, branches, biome, prop_id)
	if distal_visual != null:
		distal_visual.name = "ProceduralTreeDistalBranches"
		distal_visual.set_meta("tree_wood_role", "instanced_distal_branches")
		root.add_child(distal_visual)
	root.set_meta("tree_wood_topology", "continuous_structural_wood_with_instanced_supported_twigs")
	return root

func instantiate_runtime_bole(recipe: Dictionary, branches: Array[Dictionary], biome: String) -> MeshInstance3D:
	var build_state := begin_runtime_bole_build(branches)
	if build_state.is_empty():
		return null
	while not advance_continuous_wood_build(build_state, 32):
		pass
	return finish_runtime_bole(recipe, build_state, biome)

func begin_runtime_bole_build(branches: Array[Dictionary]) -> Dictionary:
	var bole: Array[Dictionary] = []
	for branch in branches:
		# The order-zero bole is the trunk chain players inspect at close range.
		# Render it as one joined surface; the graph-preserving runtime reducer
		# guarantees every instanced branch retains a supporting parent segment.
		if int(branch.get("order", 1)) == 0:
			bole.append(branch)
	if bole.is_empty():
		return {}
	if is_headless_renderer():
		return {
			"headlessVisualProxy": true,
			"nextIndex": 0,
			"workCount": bole.size(),
			"segmentCount": bole.size()
		}
	return begin_continuous_wood_build(
		bole,
		RUNTIME_CONTINUOUS_WOOD_RADIAL_SEGMENTS,
		RUNTIME_JUNCTION_HULL_RADIAL_SEGMENTS,
		RUNTIME_JUNCTION_HULL_LATITUDES
	)

func advance_runtime_bole_build(build_state: Dictionary, work_budget := 1) -> bool:
	if bool(build_state.get("headlessVisualProxy", false)):
		var next_index := int(build_state.get("nextIndex", 0)) + maxi(1, int(work_budget))
		build_state["nextIndex"] = next_index
		return next_index >= int(build_state.get("workCount", 0))
	return advance_continuous_wood_build(build_state, work_budget)

func finish_runtime_bole(recipe: Dictionary, build_state: Dictionary, biome: String) -> MeshInstance3D:
	if bool(build_state.get("headlessVisualProxy", false)):
		# Even an empty GeometryInstance allocates a renderer RID. The dummy
		# headless renderer has no mesh RID owner, so return no geometry while the
		# queue still completes the same bounded logical stage and records the
		# recipe-derived render statistics on the authoritative tree body.
		return null
	var mesh_result := finish_continuous_wood_build(build_state)
	var bole_visual := instantiate_continuous_wood_mesh_result(
		recipe,
		mesh_result,
		biome,
		RUNTIME_CONTINUOUS_WOOD_RADIAL_SEGMENTS
	)
	if bole_visual != null:
		bole_visual.name = "ProceduralTreeContinuousStructuralWood"
		bole_visual.set_meta("tree_wood_role", "continuous_bole_and_scaffolds")
	return bole_visual

func instantiate_runtime_distal_branches(
	recipe: Dictionary,
	branches: Array[Dictionary],
	biome: String,
	prop_id: String
) -> MultiMeshInstance3D:
	var build_state := begin_runtime_distal_build(recipe, branches, biome, prop_id)
	if build_state.is_empty():
		return null
	while not advance_runtime_distal_build(build_state, 512):
		pass
	return finish_runtime_distal_build(build_state, recipe, biome)

func begin_runtime_distal_build(
	recipe: Dictionary,
	branches: Array[Dictionary],
	biome: String,
	prop_id: String
) -> Dictionary:
	var distal: Array[Dictionary] = []
	for branch in branches:
		if int(branch.get("order", 1)) != 0:
			distal.append(branch)
	if distal.is_empty():
		return {}
	if is_headless_renderer():
		return {
			"headlessVisualProxy": true,
			"branches": distal,
			"nextIndex": 0
		}
	ensure_shared_geometry()
	var multi_mesh := MultiMesh.new()
	multi_mesh.resource_name = "procedural_tree_branches_%s" % String(recipe.get("signature", ""))
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_custom_data = true
	multi_mesh.mesh = branch_mesh
	multi_mesh.instance_count = distal.size()
	return {
		"multiMesh": multi_mesh,
		"branches": distal,
		"nextIndex": 0,
		"propId": prop_id,
		"phaseBase": stable_unit("branch-phase:%s:%s" % [biome, prop_id])
	}

func advance_runtime_distal_build(build_state: Dictionary, instance_budget := 48) -> bool:
	if bool(build_state.get("headlessVisualProxy", false)):
		var headless_branches: Array = build_state.get("branches", [])
		var headless_end := mini(headless_branches.size(), int(build_state.get("nextIndex", 0)) + maxi(1, instance_budget))
		build_state["nextIndex"] = headless_end
		return headless_end >= headless_branches.size()
	var multi_mesh := build_state.get("multiMesh", null) as MultiMesh
	if multi_mesh == null:
		return true
	var branches: Array = build_state.get("branches", [])
	var index := int(build_state.get("nextIndex", 0))
	var end_index := mini(branches.size(), index + maxi(1, instance_budget))
	var phase_base := float(build_state.get("phaseBase", 0.0))
	for branch_index in range(index, end_index):
		var branch: Dictionary = branches[branch_index] as Dictionary
		var radius_start := maxf(0.025, float(branch.get("radiusStart", 0.1)))
		var radius_end := maxf(0.012, float(branch.get("radiusEnd", radius_start * 0.5)))
		multi_mesh.set_instance_transform(branch_index, branch_transform(branch.get("start", Vector3.ZERO), branch.get("end", Vector3.UP), radius_start))
		multi_mesh.set_instance_custom_data(branch_index, Color(
			clampf(radius_end / radius_start, 0.03, 1.0),
			clampf(float(branch.get("windWeight", 0.0)), 0.0, 1.0),
			fmod(phase_base + float(branch_index) * 0.0618034, 1.0),
			stable_unit("bark:%s:%d" % [String(build_state.get("propId", "procedural-tree")), branch_index])
		))
	build_state["nextIndex"] = end_index
	return end_index >= branches.size()

func finish_runtime_distal_build(build_state: Dictionary, recipe: Dictionary, biome: String) -> MultiMeshInstance3D:
	if bool(build_state.get("headlessVisualProxy", false)):
		return null
	var multi_mesh := build_state.get("multiMesh", null) as MultiMesh
	if multi_mesh == null:
		return null
	multi_mesh.custom_aabb = recipe_aabb(recipe, 1.5)
	var instance := MultiMeshInstance3D.new()
	instance.name = "ProceduralTreeDistalBranches"
	instance.multimesh = multi_mesh
	instance.material_override = branch_material(String(recipe.get("architecture", "broadleaf")), biome)
	apply_recipe_render_policy(instance, recipe, 28.0, 2.0)
	instance.set_meta("tree_render_role", "branches")
	instance.set_meta("tree_wood_role", "instanced_distal_branches")
	return instance

func instantiate_branch_instances(
	recipe: Dictionary,
	branches: Array[Dictionary],
	biome: String,
	prop_id: String
) -> MultiMeshInstance3D:
	var multi_mesh := MultiMesh.new()
	multi_mesh.resource_name = "procedural_tree_branches_%s" % String(recipe.get("signature", ""))
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_custom_data = true
	multi_mesh.mesh = branch_mesh
	multi_mesh.instance_count = branches.size()
	var phase_base := stable_unit("branch-phase:%s:%s" % [biome, prop_id])
	for index in range(branches.size()):
		var branch: Dictionary = branches[index]
		var radius_start := maxf(0.025, float(branch.get("radiusStart", 0.1)))
		var radius_end := maxf(0.012, float(branch.get("radiusEnd", radius_start * 0.5)))
		multi_mesh.set_instance_transform(index, branch_transform(branch.get("start", Vector3.ZERO), branch.get("end", Vector3.UP), radius_start))
		multi_mesh.set_instance_custom_data(index, Color(
			clampf(radius_end / radius_start, 0.03, 1.0),
			clampf(float(branch.get("windWeight", 0.0)), 0.0, 1.0),
			fmod(phase_base + float(index) * 0.0618034, 1.0),
			stable_unit("bark:%s:%d" % [prop_id, index])
		))
	multi_mesh.custom_aabb = recipe_aabb(recipe, 1.5)
	var instance := MultiMeshInstance3D.new()
	instance.name = "ProceduralTreeBranches"
	instance.multimesh = multi_mesh
	instance.material_override = branch_material(String(recipe.get("architecture", "broadleaf")), biome)
	apply_recipe_render_policy(instance, recipe, 28.0, 2.0)
	instance.set_meta("tree_render_role", "branches")
	return instance

func instantiate_continuous_wood(
	recipe: Dictionary,
	branches: Array[Dictionary],
	biome: String,
	radial_segments := CONTINUOUS_WOOD_RADIAL_SEGMENTS,
	junction_radial_segments := JUNCTION_HULL_RADIAL_SEGMENTS,
	junction_latitudes := JUNCTION_HULL_LATITUDES
) -> MeshInstance3D:
	var mesh_result := build_continuous_wood_mesh(branches, radial_segments, junction_radial_segments, junction_latitudes)
	return instantiate_continuous_wood_mesh_result(recipe, mesh_result, biome, radial_segments)

func instantiate_continuous_wood_mesh_result(
	recipe: Dictionary,
	mesh_result: Dictionary,
	biome: String,
	radial_segments: int
) -> MeshInstance3D:
	var mesh := mesh_result.get("mesh", null) as ArrayMesh
	if mesh == null:
		return null
	var instance := MeshInstance3D.new()
	instance.name = "ProceduralTreeContinuousWood"
	instance.mesh = mesh
	instance.material_override = continuous_wood_material(
		String(recipe.get("architecture", "broadleaf")),
		biome,
		maxf(1.0, float(recipe.get("height", 12.0)))
	)
	apply_recipe_render_policy(instance, recipe, 28.0, 2.0)
	instance.set_meta("tree_render_role", "continuous_wood")
	instance.set_meta("tree_wood_topology", "single_generated_wood_graph_without_segment_caps")
	instance.set_meta("tree_wood_uses_cylinder_instances", false)
	instance.set_meta("tree_wood_segment_count", int(mesh_result.get("segmentCount", 0)))
	instance.set_meta("tree_wood_tube_count", int(mesh_result.get("tubeCount", 0)))
	instance.set_meta("tree_wood_junction_count", int(mesh_result.get("junctionCount", 0)))
	instance.set_meta("tree_wood_radial_segments", radial_segments)
	return instance

func build_continuous_wood_mesh(
	branches: Array[Dictionary],
	radial_segments := CONTINUOUS_WOOD_RADIAL_SEGMENTS,
	junction_radial_segments := JUNCTION_HULL_RADIAL_SEGMENTS,
	junction_latitudes := JUNCTION_HULL_LATITUDES
) -> Dictionary:
	var build_state := begin_continuous_wood_build(branches, radial_segments, junction_radial_segments, junction_latitudes)
	if build_state.is_empty():
		return {}
	while not advance_continuous_wood_build(build_state, 32):
		pass
	return finish_continuous_wood_build(build_state)

func begin_continuous_wood_build(
	branches: Array[Dictionary],
	radial_segments := CONTINUOUS_WOOD_RADIAL_SEGMENTS,
	junction_radial_segments := JUNCTION_HULL_RADIAL_SEGMENTS,
	junction_latitudes := JUNCTION_HULL_LATITUDES
) -> Dictionary:
	if branches.is_empty():
		return {}
	var graph_segments: Array[Dictionary] = []
	var buttresses: Array[Dictionary] = []
	var outgoing := {}
	var incoming := {}
	for branch in branches:
		var parent := int(branch.get("parentNode", -1))
		var child := int(branch.get("childNode", -1))
		if parent < 0 or child < 0:
			buttresses.append(branch)
			continue
		graph_segments.append(branch)
		if not outgoing.has(parent):
			outgoing[parent] = []
		(outgoing[parent] as Array).append(branch)
		incoming[child] = branch
	var chains := collect_wood_chains(graph_segments, outgoing, incoming)
	var continuing_fork_radii := continuing_fork_radius_map(outgoing, incoming)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tubes: Array[Dictionary] = []
	for chain_value in chains:
		var chain: Array[Dictionary] = chain_value
		if chain.is_empty():
			continue
		var first: Dictionary = chain[0]
		var last: Dictionary = chain.back()
		tubes.append({
			"chain": chain,
			"capStart": not incoming.has(int(first.get("parentNode", -1))),
			"capEnd": not outgoing.has(int(last.get("childNode", -1)))
		})
	for buttress in buttresses:
		tubes.append({"chain": [buttress], "capStart": false, "capEnd": true, "buttress": true})
	var junctions: Array[Dictionary] = []
	for node_value in outgoing.keys():
		var node := int(node_value)
		var children: Array = outgoing[node]
		if children.size() == 1:
			# A change in biological growth order is a real wood-growth node even
			# when it has only one child. Seal it with a small collar so generation
			# labels can never become a visible break in the bark.
			if incoming.has(node) and int((incoming[node] as Dictionary).get("order", -1)) != int((children[0] as Dictionary).get("order", -1)):
				var transition_position: Vector3 = (children[0] as Dictionary).get("start", Vector3.ZERO)
				var transition_radius := maxf(
					float((incoming[node] as Dictionary).get("radiusEnd", 0.0)),
					float((children[0] as Dictionary).get("radiusStart", 0.0))
				)
				junctions.append({"position": transition_position, "radius": maxf(0.065, transition_radius * 1.14)})
			continue
		if children.size() < 2:
			continue
		var junction_position: Vector3 = (children[0] as Dictionary).get("start", Vector3.ZERO)
		var junction_radius := 0.0
		if incoming.has(node):
			junction_radius = maxf(junction_radius, float((incoming[node] as Dictionary).get("radiusEnd", 0.0)))
		for child_segment in children:
			junction_radius = maxf(junction_radius, float((child_segment as Dictionary).get("radiusStart", 0.0)))
		# Tube skins are hollow. Every fork therefore needs a tight procedurally
		# generated bark collar to seal the child limb into its parent surface.
		junctions.append({"position": junction_position, "radius": maxf(0.065, junction_radius * 1.05)})
	return {
		"surface": surface,
		"tubes": tubes,
		"junctions": junctions,
		"nextTube": 0,
		"nextJunction": 0,
		"vertexOffset": 0,
		"longestPath": 0.0,
		"tubeCount": tubes.size(),
		"segmentCount": branches.size(),
		"junctionCount": 0,
		"continuingForkRadii": continuing_fork_radii,
		"radialSegments": radial_segments,
		"junctionRadialSegments": junction_radial_segments,
		"junctionLatitudes": junction_latitudes
	}

func advance_continuous_wood_build(build_state: Dictionary, work_budget := 1) -> bool:
	var surface := build_state.get("surface", null) as SurfaceTool
	if surface == null:
		return true
	var budget := maxi(1, work_budget)
	var completed := 0
	while completed < budget:
		var next_tube := int(build_state.get("nextTube", 0))
		var tubes: Array = build_state.get("tubes", [])
		if next_tube < tubes.size():
			var tube: Dictionary = tubes[next_tube] as Dictionary
			var chain: Array[Dictionary] = []
			for branch_value in tube.get("chain", []):
				if branch_value is Dictionary:
					chain.append(branch_value as Dictionary)
			var fork_radii: Dictionary = {} if bool(tube.get("buttress", false)) else build_state.get("continuingForkRadii", {})
			var tube_result := append_wood_tube(
				surface,
				chain,
				bool(tube.get("capStart", false)),
				bool(tube.get("capEnd", false)),
				int(build_state.get("vertexOffset", 0)),
				fork_radii,
				int(build_state.get("radialSegments", RUNTIME_CONTINUOUS_WOOD_RADIAL_SEGMENTS))
			)
			build_state["vertexOffset"] = int(tube_result.get("vertexOffset", build_state.get("vertexOffset", 0)))
			build_state["longestPath"] = maxf(float(build_state.get("longestPath", 0.0)), float(tube_result.get("pathLength", 0.0)))
			build_state["nextTube"] = next_tube + 1
			completed += 1
			continue
		var next_junction := int(build_state.get("nextJunction", 0))
		var junctions: Array = build_state.get("junctions", [])
		if next_junction < junctions.size():
			var junction: Dictionary = junctions[next_junction] as Dictionary
			build_state["vertexOffset"] = append_junction_hull(
				surface,
				junction.get("position", Vector3.ZERO),
				float(junction.get("radius", 0.065)),
				int(build_state.get("vertexOffset", 0)),
				int(build_state.get("junctionRadialSegments", RUNTIME_JUNCTION_HULL_RADIAL_SEGMENTS)),
				int(build_state.get("junctionLatitudes", RUNTIME_JUNCTION_HULL_LATITUDES))
			)
			build_state["nextJunction"] = next_junction + 1
			build_state["junctionCount"] = int(build_state.get("junctionCount", 0)) + 1
			completed += 1
			continue
		return true
	return false

func finish_continuous_wood_build(build_state: Dictionary) -> Dictionary:
	var surface := build_state.get("surface", null) as SurfaceTool
	if surface == null:
		return {}
	return {
		"mesh": surface.commit(),
		"tubeCount": int(build_state.get("tubeCount", 0)),
		"segmentCount": int(build_state.get("segmentCount", 0)),
		"junctionCount": int(build_state.get("junctionCount", 0)),
		"longestPathLength": float(build_state.get("longestPath", 0.0))
	}

func collect_wood_chains(graph_segments: Array[Dictionary], outgoing: Dictionary, incoming: Dictionary) -> Array:
	var chains: Array = []
	var visited := {}
	for seed_segment in graph_segments:
		var parent := int(seed_segment.get("parentNode", -1))
		var parent_children: Array = outgoing.get(parent, [])
		if incoming.has(parent):
			var parent_continuation := wood_continuation(incoming[parent] as Dictionary, parent_children)
			if not parent_continuation.is_empty() and same_wood_segment(parent_continuation, seed_segment):
				continue
		var chain: Array[Dictionary] = []
		var current := seed_segment
		while true:
			var child := int(current.get("childNode", -1))
			var edge_key := "%d:%d" % [int(current.get("parentNode", -1)), child]
			if visited.has(edge_key):
				break
			visited[edge_key] = true
			chain.append(current)
			var next_children: Array = outgoing.get(child, [])
			var continuation := wood_continuation(current, next_children)
			if continuation.is_empty():
				break
			current = continuation
		if not chain.is_empty():
			chains.append(chain)
	for segment in graph_segments:
		var edge_key := "%d:%d" % [int(segment.get("parentNode", -1)), int(segment.get("childNode", -1))]
		if not visited.has(edge_key):
			chains.append([segment])
	return chains

func wood_continuation(current: Dictionary, children: Array) -> Dictionary:
	# A one-child order transition is still a physical continuation. Branch order
	# describes growth generation, never a seam in the generated wood surface.
	if children.size() == 1 and children[0] is Dictionary:
		return children[0] as Dictionary
	var matches: Array[Dictionary] = []
	var order := int(current.get("order", -1))
	for child_value in children:
		if child_value is Dictionary and int((child_value as Dictionary).get("order", -2)) == order:
			matches.append(child_value as Dictionary)
	return matches[0] if matches.size() == 1 else {}

func same_wood_segment(first: Dictionary, second: Dictionary) -> bool:
	return int(first.get("parentNode", -1)) == int(second.get("parentNode", -2)) \
		and int(first.get("childNode", -1)) == int(second.get("childNode", -2))

func continuing_fork_radius_map(outgoing: Dictionary, incoming: Dictionary) -> Dictionary:
	var radii := {}
	for node_value in outgoing.keys():
		var node := int(node_value)
		var children: Array = outgoing[node]
		if children.size() < 2 or not incoming.has(node):
			continue
		var continuation := wood_continuation(incoming[node] as Dictionary, children)
		if continuation.is_empty():
			continue
		var radius := float((incoming[node] as Dictionary).get("radiusEnd", 0.0))
		for child_value in children:
			radius = maxf(radius, float((child_value as Dictionary).get("radiusStart", 0.0)))
		radii[node] = maxf(0.025, radius * 1.10)
	return radii

func append_wood_tube(
	surface: SurfaceTool,
	chain: Array[Dictionary],
	cap_start: bool,
	cap_end: bool,
	vertex_offset: int,
	continuing_fork_radii: Dictionary,
	radial_segments: int
) -> Dictionary:
	var ring_positions: Array[Vector3] = []
	var ring_radii: Array[float] = []
	var first: Dictionary = chain[0]
	ring_positions.append(first.get("start", Vector3.ZERO))
	ring_radii.append(maxf(0.025, float(first.get("radiusStart", 0.1))))
	for segment_index in range(chain.size()):
		var segment: Dictionary = chain[segment_index]
		var radius := maxf(0.018, float(segment.get("radiusEnd", 0.1)))
		if segment_index + 1 < chain.size():
			radius = maxf(radius, float((chain[segment_index + 1] as Dictionary).get("radiusStart", radius)))
			var fork_node := int(segment.get("childNode", -1))
			if continuing_fork_radii.has(fork_node):
				radius = maxf(radius, float(continuing_fork_radii[fork_node]))
		ring_positions.append(segment.get("end", Vector3.UP))
		ring_radii.append(radius)
	var cumulative_lengths: Array[float] = [0.0]
	for ring_index in range(1, ring_positions.size()):
		cumulative_lengths.append(cumulative_lengths[ring_index - 1] + ring_positions[ring_index].distance_to(ring_positions[ring_index - 1]))
	var path_length := maxf(0.01, float(cumulative_lengths.back()))
	var tangents: Array[Vector3] = []
	var sides: Array[Vector3] = []
	var forwards: Array[Vector3] = []
	for ring_index in range(ring_positions.size()):
		var tangent := wood_tangent(ring_positions, ring_index)
		tangents.append(tangent)
		var side := Vector3.ZERO
		if ring_index > 0:
			side = sides[ring_index - 1] - tangent * sides[ring_index - 1].dot(tangent)
		if side.length_squared() < 0.0001:
			var reference := Vector3.UP if absf(tangent.dot(Vector3.UP)) < 0.92 else Vector3.RIGHT
			side = reference.cross(tangent)
		side = side.normalized()
		sides.append(side)
		forwards.append(tangent.cross(side).normalized())
	for ring_index in range(ring_positions.size()):
		for radial_index in range(radial_segments):
			var unit := float(radial_index) / float(radial_segments)
			var angle := unit * TAU
			var radial := (sides[ring_index] * cos(angle) + forwards[ring_index] * sin(angle)).normalized()
			surface.set_normal(radial)
			surface.set_uv(Vector2(unit, cumulative_lengths[ring_index] / path_length))
			surface.add_vertex(ring_positions[ring_index] + radial * ring_radii[ring_index])
	for ring_index in range(ring_positions.size() - 1):
		for radial_index in range(radial_segments):
			var next_radial := posmod(radial_index + 1, radial_segments)
			var lower_left := vertex_offset + ring_index * radial_segments + radial_index
			var lower_right := vertex_offset + ring_index * radial_segments + next_radial
			var upper_left := vertex_offset + (ring_index + 1) * radial_segments + radial_index
			var upper_right := vertex_offset + (ring_index + 1) * radial_segments + next_radial
			surface.add_index(lower_left)
			surface.add_index(upper_left)
			surface.add_index(upper_right)
			surface.add_index(lower_left)
			surface.add_index(upper_right)
			surface.add_index(lower_right)
	var next_vertex_offset := vertex_offset + ring_positions.size() * radial_segments
	if cap_start:
		next_vertex_offset = append_wood_end_cap(surface, ring_positions[0], tangents[0], vertex_offset, next_vertex_offset, false, radial_segments)
	if cap_end:
		var final_ring_start := vertex_offset + (ring_positions.size() - 1) * radial_segments
		next_vertex_offset = append_wood_end_cap(surface, ring_positions.back(), tangents.back(), final_ring_start, next_vertex_offset, true, radial_segments)
	return {"vertexOffset": next_vertex_offset, "pathLength": path_length}

func wood_tangent(ring_positions: Array[Vector3], ring_index: int) -> Vector3:
	var delta: Vector3
	if ring_index == 0:
		delta = ring_positions[1] - ring_positions[0]
	elif ring_index == ring_positions.size() - 1:
		delta = ring_positions[ring_index] - ring_positions[ring_index - 1]
	else:
		delta = ring_positions[ring_index + 1] - ring_positions[ring_index - 1]
	return delta.normalized() if delta.length_squared() > 0.0001 else Vector3.UP

func append_wood_end_cap(
	surface: SurfaceTool,
	position: Vector3,
	tangent: Vector3,
	ring_start: int,
	center_index: int,
	is_top: bool,
	radial_segments: int
) -> int:
	var normal := tangent if is_top else -tangent
	surface.set_normal(normal)
	surface.set_uv(Vector2(0.5, 1.0 if is_top else 0.0))
	surface.add_vertex(position)
	for radial_index in range(radial_segments):
		var next_radial := posmod(radial_index + 1, radial_segments)
		if is_top:
			surface.add_index(center_index)
			surface.add_index(ring_start + radial_index)
			surface.add_index(ring_start + next_radial)
		else:
			surface.add_index(center_index)
			surface.add_index(ring_start + next_radial)
			surface.add_index(ring_start + radial_index)
	return center_index + 1

func append_junction_hull(
	surface: SurfaceTool,
	center: Vector3,
	radius: float,
	vertex_offset: int,
	radial_segments: int,
	latitudes: int
) -> int:
	for latitude in range(latitudes + 1):
		var latitude_unit := float(latitude) / float(latitudes)
		var polar := latitude_unit * PI
		var y := cos(polar)
		var horizontal := sin(polar)
		for radial_index in range(radial_segments):
			var unit := float(radial_index) / float(radial_segments)
			var angle := unit * TAU
			var normal := Vector3(cos(angle) * horizontal, y, sin(angle) * horizontal).normalized()
			surface.set_normal(normal)
			surface.set_uv(Vector2(unit, latitude_unit))
			surface.add_vertex(center + normal * radius)
	for latitude in range(latitudes):
		for radial_index in range(radial_segments):
			var next_radial := posmod(radial_index + 1, radial_segments)
			var lower_left := vertex_offset + latitude * radial_segments + radial_index
			var lower_right := vertex_offset + latitude * radial_segments + next_radial
			var upper_left := vertex_offset + (latitude + 1) * radial_segments + radial_index
			var upper_right := vertex_offset + (latitude + 1) * radial_segments + next_radial
			surface.add_index(lower_left)
			surface.add_index(upper_left)
			surface.add_index(upper_right)
			surface.add_index(lower_left)
			surface.add_index(upper_right)
			surface.add_index(lower_right)
	return vertex_offset + (latitudes + 1) * radial_segments

func continuous_wood_material(architecture: String, biome: String, path_length: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.resource_name = "procedural_tree_continuous_wood_%s_%s" % [architecture, biome]
	material.shader = BRANCH_SHADER
	var bark := bark_color_for_architecture(architecture)
	material.set_shader_parameter("bark_color", bark)
	material.set_shader_parameter("bark_dark", bark.darkened(0.58))
	material.set_shader_parameter("roughness", 0.92)
	material.set_shader_parameter("wind_bend_meters", 0.0)
	material.set_shader_parameter("geometry_baked_taper", true)
	material.set_shader_parameter("baked_axial_length", maxf(0.1, path_length))
	material.set_shader_parameter("baked_bark_variation", 0.53)
	return material

func instantiate_foliage(recipe: Dictionary, biome: String, prop_id: String) -> Node3D:
	var foliage: Array = recipe.get("foliage", [])
	if foliage.is_empty():
		return null
	if bool(recipe.get("runtimeContinuousBole", false)):
		return instantiate_runtime_foliage_batch(recipe, foliage, biome, prop_id)
	var groups: Array[Array] = [[], [], [], []]
	for anchor_value in foliage:
		if anchor_value is Dictionary:
			var variant := clampi(int((anchor_value as Dictionary).get("clusterVariant", 0)), 0, 3)
			groups[variant].append(anchor_value)
	var root := Node3D.new()
	root.name = "ProceduralTreeFoliage"
	var phase_base := stable_unit("foliage-phase:%s:%s" % [biome, prop_id])
	for variant in range(groups.size()):
		var anchors: Array = groups[variant]
		if anchors.is_empty():
			continue
		var multi_mesh := MultiMesh.new()
		multi_mesh.resource_name = "procedural_tree_foliage_%s_v%d" % [String(recipe.get("signature", "")), variant]
		multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
		multi_mesh.use_custom_data = true
		multi_mesh.mesh = foliage_cluster_meshes[variant]
		multi_mesh.instance_count = anchors.size()
		for index in range(anchors.size()):
			var anchor: Dictionary = anchors[index]
			var rotation: Vector3 = anchor.get("rotation", Vector3.ZERO)
			var scale: Vector3 = anchor.get("scale", Vector3.ONE)
			var basis := Basis.from_euler(rotation).scaled(scale)
			multi_mesh.set_instance_transform(index, Transform3D(basis, anchor.get("position", Vector3.ZERO)))
			multi_mesh.set_instance_custom_data(index, Color(
				fmod(phase_base + float(index) * 0.037 + float(variant) * 0.173, 1.0),
				clampf(float(anchor.get("windWeight", 0.5)), 0.0, 1.0),
				clampf(float(anchor.get("variation", 0.5)), 0.0, 1.0),
				float(variant) / 3.0
			))
		multi_mesh.custom_aabb = recipe_aabb(recipe, 3.0)
		var instance := MultiMeshInstance3D.new()
		instance.name = "FoliageVariant%d" % variant
		instance.multimesh = multi_mesh
		instance.material_override = foliage_material(String(recipe.get("architecture", "broadleaf")), biome)
		apply_recipe_render_policy(instance, recipe, 30.0, 3.0)
		instance.set_meta("tree_render_role", "foliage")
		instance.set_meta("tree_foliage_variant", variant)
		root.add_child(instance)
	return root

func instantiate_runtime_foliage_batch(recipe: Dictionary, foliage: Array, biome: String, prop_id: String) -> Node3D:
	var build_state := begin_runtime_foliage_build(recipe, foliage, biome, prop_id)
	if build_state.is_empty():
		return null
	while not advance_runtime_foliage_build(build_state, 512):
		pass
	return finish_runtime_foliage_build(build_state, recipe, biome)

func begin_runtime_foliage_build(recipe: Dictionary, foliage: Array, biome: String, prop_id: String) -> Dictionary:
	# Foliage geometry/material are shared.  A runtime tree varies cluster pose,
	# scale, phase, shade and wind response per instance, so publishing four
	# separate MultiMeshes solely for near-identical cluster silhouettes adds
	# main-thread work without adding a new ecological rule.  PoC/review still
	# renders each detailed variant independently.
	if is_headless_renderer():
		return {
			"headlessVisualProxy": true,
			"foliage": foliage,
			"nextIndex": 0
		}
	ensure_shared_geometry()
	var multi_mesh := MultiMesh.new()
	multi_mesh.resource_name = "procedural_tree_runtime_foliage_%s" % String(recipe.get("signature", ""))
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_custom_data = true
	multi_mesh.mesh = foliage_cluster_meshes[RUNTIME_DENSE_FOLIAGE_VARIANT]
	multi_mesh.instance_count = foliage.size()
	return {
		"multiMesh": multi_mesh,
		"foliage": foliage,
		"nextIndex": 0,
		"phaseBase": stable_unit("foliage-phase:%s:%s" % [biome, prop_id])
	}

func advance_runtime_foliage_build(build_state: Dictionary, instance_budget := 48) -> bool:
	if bool(build_state.get("headlessVisualProxy", false)):
		var headless_foliage: Array = build_state.get("foliage", [])
		var headless_end := mini(headless_foliage.size(), int(build_state.get("nextIndex", 0)) + maxi(1, instance_budget))
		build_state["nextIndex"] = headless_end
		return headless_end >= headless_foliage.size()
	var multi_mesh := build_state.get("multiMesh", null) as MultiMesh
	if multi_mesh == null:
		return true
	var foliage: Array = build_state.get("foliage", [])
	var index := int(build_state.get("nextIndex", 0))
	var end_index := mini(foliage.size(), index + maxi(1, instance_budget))
	var phase_base := float(build_state.get("phaseBase", 0.0))
	for foliage_index in range(index, end_index):
		var anchor_value = foliage[foliage_index]
		if not (anchor_value is Dictionary):
			continue
		var anchor: Dictionary = anchor_value as Dictionary
		var rotation: Vector3 = anchor.get("rotation", Vector3.ZERO)
		var scale: Vector3 = anchor.get("scale", Vector3.ONE)
		var basis := Basis.from_euler(rotation).scaled(scale)
		var cluster_variant := clampi(int(anchor.get("clusterVariant", 0)), 0, 3)
		multi_mesh.set_instance_transform(foliage_index, Transform3D(basis, anchor.get("position", Vector3.ZERO)))
		multi_mesh.set_instance_custom_data(foliage_index, Color(
			fmod(phase_base + float(foliage_index) * 0.037 + float(cluster_variant) * 0.173, 1.0),
			clampf(float(anchor.get("windWeight", 0.5)), 0.0, 1.0),
			clampf(float(anchor.get("variation", 0.5)), 0.0, 1.0),
			float(cluster_variant) / 3.0
		))
	build_state["nextIndex"] = end_index
	return end_index >= foliage.size()

func finish_runtime_foliage_build(build_state: Dictionary, recipe: Dictionary, biome: String) -> Node3D:
	if bool(build_state.get("headlessVisualProxy", false)):
		var proxy := Node3D.new()
		proxy.name = "ProceduralTreeFoliage"
		proxy.set_meta("tree_render_role", "foliage")
		proxy.set_meta("tree_foliage_batching", "headless_visual_proxy")
		proxy.set_meta("tree_headless_visual_proxy", true)
		return proxy
	var multi_mesh := build_state.get("multiMesh", null) as MultiMesh
	if multi_mesh == null:
		return null
	multi_mesh.custom_aabb = recipe_aabb(recipe, 3.0)
	var instance := MultiMeshInstance3D.new()
	instance.name = "RuntimeFoliage"
	instance.multimesh = multi_mesh
	instance.material_override = foliage_material(String(recipe.get("architecture", "broadleaf")), biome)
	apply_recipe_render_policy(instance, recipe, 30.0, 3.0)
	instance.set_meta("tree_render_role", "foliage")
	instance.set_meta("tree_foliage_batching", "single_shared_cluster_mesh")
	var root := Node3D.new()
	root.name = "ProceduralTreeFoliage"
	root.set_meta("tree_foliage_batching", "single_shared_cluster_mesh")
	root.add_child(instance)
	return root

func instantiate_runtime_impostor(recipe: Dictionary, biome: String) -> Node3D:
	# The impostor is only selected beyond the far LOD boundary.  It retains a
	# readable trunk/crown silhouette while avoiding all branch graph and
	# MultiMesh instance publication for trees a player cannot inspect.
	var root := Node3D.new()
	root.name = "ProceduralTreeImpostor"
	root.set_meta("tree_render_role", "impostor")
	root.set_meta("tree_impostor", true)
	if is_headless_renderer():
		root.set_meta("tree_headless_visual_proxy", true)
		return root
	ensure_shared_geometry()
	var height := maxf(2.0, float(recipe.get("height", 8.0)))
	var radius := maxf(1.0, float(recipe.get("canopyRadius", 3.0)))
	var architecture := String(recipe.get("architecture", "broadleaf"))
	var trunk := MeshInstance3D.new()
	trunk.name = "ImpostorTrunk"
	trunk.mesh = branch_mesh
	trunk.material_override = branch_material(architecture, biome)
	trunk.position.y = height * 0.27
	trunk.scale = Vector3(maxf(0.10, float(recipe.get("trunkRadius", 0.25))), height * 0.54, maxf(0.10, float(recipe.get("trunkRadius", 0.25))))
	apply_recipe_render_policy(trunk, recipe, 20.0, 1.0)
	root.add_child(trunk)
	for rotation in [0.0, PI * 0.5]:
		var crown := MeshInstance3D.new()
		crown.name = "ImpostorCrown"
		crown.mesh = impostor_crown_mesh
		crown.material_override = foliage_material(architecture, biome)
		crown.position.y = height * 0.68
		crown.rotation.y = rotation
		crown.scale = Vector3(radius * 2.0, maxf(radius * 1.25, height * 0.46), 1.0)
		apply_recipe_render_policy(crown, recipe, 20.0, 1.0)
		root.add_child(crown)
	return root

## A temporary collision-visibility representation for a streamed runtime
## tree. It deliberately consumes only already-shared primitive meshes and
## cached materials; no recipe graph, branch/leaf nodes, unique material,
## collision shape, or shadow work is created here. TreePublicationQueue
## removes it atomically once the normal mathematical recipe visual commits.
func instantiate_collision_visibility_proxy(request: Dictionary, biome: String) -> Node3D:
	var root := Node3D.new()
	root.name = "TreeVisibilityProxy"
	root.set_meta("tree_visibility_proxy", true)
	root.set_meta("tree_render_role", "collision_visibility_proxy")
	root.set_meta("tree_id", String(request.get("treeId", "procedural-tree")))
	if is_headless_renderer():
		root.set_meta("tree_headless_visual_proxy", true)
		return root
	ensure_shared_geometry()
	var height := maxf(2.0, float(request.get("visualHeight", request.get("height", 8.0))))
	var radius := maxf(1.0, float(request.get("canopyRadius", 3.0)))
	var trunk_radius := maxf(0.10, float(request.get("trunkRadius", 0.25)))
	var architecture := String(request.get("architecture", "broadleaf"))
	var visibility_range := maxf(64.0, float((request.get("biomeParameters", {}) as Dictionary).get("visibilityRange", VISIBILITY_RANGE)))
	var trunk := MeshInstance3D.new()
	trunk.name = "VisibilityProxyTrunk"
	trunk.mesh = branch_mesh
	trunk.material_override = branch_material(architecture, biome)
	trunk.position.y = height * 0.34
	trunk.scale = Vector3(trunk_radius, height * 0.68, trunk_radius)
	trunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	trunk.visibility_range_end = visibility_range
	trunk.visibility_range_end_margin = minf(12.0, visibility_range * 0.12)
	trunk.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	trunk.extra_cull_margin = 1.0
	root.add_child(trunk)
	for rotation in [0.0, PI * 0.5]:
		var crown := MeshInstance3D.new()
		crown.name = "VisibilityProxyCrown"
		crown.mesh = impostor_crown_mesh
		crown.material_override = foliage_material(architecture, biome)
		crown.position.y = height * 0.68
		crown.rotation.y = rotation
		crown.scale = Vector3(radius * 2.0, maxf(radius * 1.2, height * 0.42), 1.0)
		crown.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		crown.visibility_range_end = visibility_range
		crown.visibility_range_end_margin = minf(12.0, visibility_range * 0.12)
		crown.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		crown.extra_cull_margin = 1.0
		root.add_child(crown)
	return root

func branch_transform(start: Vector3, end: Vector3, radius: float) -> Transform3D:
	var delta := end - start
	var length := maxf(0.01, delta.length())
	var up := delta / length
	var side := Vector3.UP.cross(up)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	else:
		side = side.normalized()
	var forward := side.cross(up).normalized()
	var basis := Basis(side * radius, up * length, forward * radius)
	return Transform3D(basis, start.lerp(end, 0.5))

func recipe_aabb(recipe: Dictionary, padding: float) -> AABB:
	var radius := maxf(1.0, float(recipe.get("canopyRadius", 4.0))) + padding
	var height := maxf(1.0, float(recipe.get("height", 8.0))) + padding * 2.0
	return AABB(Vector3(-radius, -padding, -radius), Vector3(radius * 2.0, height, radius * 2.0))

func is_headless_renderer() -> bool:
	return DisplayServer.get_name().to_lower() == "headless"

static func recipe_casts_shadows(recipe: Dictionary) -> bool:
	# `renderPolicy` is part of the immutable recipe. Keep this decision here so
	# every renderer applies the same LOD/shadow contract instead of quietly
	# promoting a mid-distance tree to a shadow caster. A malformed or legacy
	# policy keeps close-range shade without filling the shadow map at range.
	var policy: Dictionary = recipe.get("renderPolicy", {})
	var lod: Dictionary = recipe.get("renderLod", {})
	var tier := String(lod.get("tier", policy.get("lodTier", "near"))).strip_edges().to_lower()
	match String(policy.get("shadowPolicy", "near_only")).strip_edges().to_lower():
		"none":
			return false
		"near_and_mid":
			return tier in ["near", "mid"]
		"all_non_impostor":
			return tier != "impostor"
		_:
			return tier == "near"

func apply_recipe_render_policy(instance: GeometryInstance3D, recipe: Dictionary, fade_margin: float, cull_margin: float) -> void:
	var policy: Dictionary = recipe.get("renderPolicy", {})
	var visibility_range := maxf(32.0, float(policy.get("visibilityRange", VISIBILITY_RANGE)))
	var shadow_range := clampf(float(policy.get("shadowRange", visibility_range * 0.5)), 16.0, visibility_range)
	var lod: Dictionary = recipe.get("renderLod", {})
	var tier := String(lod.get("tier", policy.get("lodTier", "near")))
	# Distant foliage contributes disproportionate shadow-map fill but no
	# nearby gameplay readability. Shadow participation is an actual recipe
	# policy decision, not merely diagnostic metadata.
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if recipe_casts_shadows(recipe) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_end = visibility_range
	instance.visibility_range_end_margin = minf(fade_margin, visibility_range * 0.12)
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	instance.extra_cull_margin = cull_margin
	# Godot's GeometryInstance3D does not expose per-instance shadow-distance
	# culling. Keep the policy attached for the chunk/LOD owner, rather than
	# pretending this per-tree renderer already has a distinct shadow mesh.
	instance.set_meta("tree_shadow_range", shadow_range)
	instance.set_meta("tree_shadow_policy", String(policy.get("shadowPolicy", "near_only")))
	instance.set_meta("tree_visibility_range", visibility_range)
	instance.set_meta("tree_lod_tier", tier)

func build_foliage_cluster_mesh(variant: int) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	# The fifth mesh is used only by runtime batching. Its doubled card density
	# turns one mathematically placed foliage cluster into a cohesive leafy volume
	# while retaining one immutable mesh and one MultiMesh draw call per tree.
	var leaf_counts := [24, 28, 31, 26, 56]
	var leaf_count: int = leaf_counts[clampi(variant, 0, leaf_counts.size() - 1)]
	var golden_angle := 2.39996323 + float(variant) * 0.071
	for index in range(leaf_count):
		var unit := (float(index) + 0.5) / float(leaf_count)
		var shaped_unit := pow(unit, lerpf(0.82, 1.22, float(variant) / 3.0))
		var y := lerpf(-0.68, 0.68, shaped_unit)
		var radial := sqrt(maxf(0.0, 1.0 - y * y))
		var angle := float(index) * golden_angle + float(variant) * 0.83
		var radial_scale := 0.52 + 0.10 * sin(float(index + variant * 7) * 1.31)
		var center := Vector3(cos(angle) * radial, y, sin(angle) * radial) * radial_scale
		center += Vector3(
			sin(float(index + variant * 3) * 1.73) * 0.16,
			cos(float(index + variant * 5) * 2.11) * 0.12,
			sin(float(index + variant * 11) * 2.47) * 0.16
		)
		var outward := center.normalized()
		if outward.length_squared() < 0.001:
			outward = Vector3.FORWARD
		var right := Vector3.UP.cross(outward)
		if right.length_squared() < 0.001:
			right = Vector3.RIGHT
		else:
			right = right.normalized()
		var up := outward.cross(right).normalized()
		var width := 0.18 + 0.07 * sin(float(index + variant * 2) * 2.17)
		var half_height := 0.24 + 0.09 * cos(float(index + variant * 4) * 1.37)
		var leaf_color := Color(0.72 + 0.28 * unit, fmod(float(index) * 0.173 + float(variant) * 0.11, 1.0), fmod(float(index) * 0.347 + float(variant) * 0.19, 1.0), 1.0)
		add_leaf_card(surface, center, right * width, up * half_height, outward, leaf_color)
	return surface.commit()

func add_leaf_card(
	surface: SurfaceTool,
	center: Vector3,
	right: Vector3,
	up: Vector3,
	normal: Vector3,
	color: Color
) -> void:
	var top := center + up
	var east := center + right
	var bottom := center - up
	var west := center - right
	add_leaf_vertex(surface, top, normal, Vector2(0.5, 0.0), color)
	add_leaf_vertex(surface, east, normal, Vector2(1.0, 0.5), color)
	add_leaf_vertex(surface, bottom, normal, Vector2(0.5, 1.0), color)
	add_leaf_vertex(surface, top, normal, Vector2(0.5, 0.0), color)
	add_leaf_vertex(surface, bottom, normal, Vector2(0.5, 1.0), color)
	add_leaf_vertex(surface, west, normal, Vector2(0.0, 0.5), color)

func add_leaf_vertex(surface: SurfaceTool, vertex: Vector3, normal: Vector3, uv: Vector2, color: Color) -> void:
	surface.set_normal(normal)
	surface.set_uv(uv)
	surface.set_color(color)
	surface.add_vertex(vertex)

func branch_material(architecture: String, biome: String) -> ShaderMaterial:
	var key := "%s:%s" % [architecture, biome]
	if branch_materials.has(key):
		return branch_materials[key] as ShaderMaterial
	var material := ShaderMaterial.new()
	material.resource_name = "procedural_tree_bark_%s" % key.replace(":", "_")
	material.shader = BRANCH_SHADER
	var bark := bark_color_for_architecture(architecture)
	material.set_shader_parameter("bark_color", bark)
	material.set_shader_parameter("bark_dark", bark.darkened(0.58))
	material.set_shader_parameter("roughness", 0.92)
	material.set_shader_parameter("wind_bend_meters", 0.24 if architecture == "conifer" else 0.32)
	branch_materials[key] = material
	return material

func bark_color_for_architecture(architecture: String) -> Color:
	match architecture:
		"conifer":
			return Color("3b281d")
		"savanna":
			return Color("68401f")
	return Color("4a2b17")

func foliage_material(architecture: String, biome: String) -> ShaderMaterial:
	var key := "%s:%s" % [architecture, biome]
	if foliage_materials.has(key):
		return foliage_materials[key] as ShaderMaterial
	var material := ShaderMaterial.new()
	material.resource_name = "procedural_tree_foliage_%s" % key.replace(":", "_")
	material.shader = FOLIAGE_SHADER
	var leaf := Color("3d672c")
	match architecture:
		"conifer":
			leaf = Color("28553b")
		"savanna":
			leaf = Color("6f7d2e")
	if biome == "snow" or biome == "tundra":
		leaf = leaf.lerp(Color("8fa99a"), 0.24)
	elif biome == "swamp":
		leaf = leaf.lerp(Color("315e3a"), 0.32)
	material.set_shader_parameter("leaf_color", leaf)
	material.set_shader_parameter("leaf_shadow_color", leaf.darkened(0.63))
	material.set_shader_parameter("main_bend_meters", 0.40 if architecture == "conifer" else 0.50)
	material.set_shader_parameter("flutter_meters", 0.065 if architecture == "conifer" else 0.090)
	foliage_materials[key] = material
	return material

func stable_unit(text: String) -> float:
	return float(stable_hash(text) & 0x7fffffff) / float(0x7fffffff)

func stable_hash(text: String) -> int:
	var hash_value := 2166136261
	for index in range(text.length()):
		hash_value = int((hash_value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return hash_value
