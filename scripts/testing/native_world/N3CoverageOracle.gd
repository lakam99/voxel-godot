extends SceneTree

const ContextScript := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const WorldScript := preload("res://scripts/WorldGenerationSystem.gd")

func _initialize() -> void:
	var context = ContextScript.new()
	context.seed_text = "atlas-1492"
	context.seed_hash = context.hash_string(context.seed_text)
	context.setup_noise()
	var world = WorldScript.new()
	world.setup(context)
	context.set_generator(world)
	var found := {}
	var wanted := ["plains", "forest", "swamp", "desert", "savanna", "snow", "taiga", "tundra", "ocean", "beach"]
	for z in range(-65536, 65537, 256):
		for x in range(-65536, 65537, 256):
			var biome := String(world.surface_biome_for_cell3(Vector3i(x, 0, z)))
			if biome in wanted and not found.has(biome):
				var surface := float(world.natural_surface_y_for_cell(Vector3i(x, 0, z)))
				var top_y := floori((surface - 0.675) / 1.35)
				var subsoil_y := floori((surface - 2.7) / 1.35)
				var top := world.generate_cell_state(Vector3i(x, top_y, z))
				var subsoil := world.generate_cell_state(Vector3i(x, subsoil_y, z))
				found[biome] = {"x":x,"z":z,"surface":surface,"top":top,"subsoil":subsoil}
			if found.size() == wanted.size(): break
		if found.size() == wanted.size(): break
	var fluids := {}
	var ores := {}
	var lights := {}
	var shallow_air := {}
	var shallow_water_eligible_air := {}
	var lava_hash_false_air := {}
	var above_aquifer_air := {}
	for z in range(-128, 129):
		for x in range(-128, 129):
			for y in range(-63, 24):
				var state: Dictionary = world.generate_cell_state(Vector3i(x,y,z))
				var material := String(state.material)
				var fluid := String(state.fluid)
				var light: Dictionary = state.light
				if fluid != "" and not fluids.has(fluid): fluids[fluid] = {"x":x,"y":y,"z":z,"state":state}
				if material in ["copperOre", "ironOre", "deepStone"] and not ores.has(material): ores[material] = {"x":x,"y":y,"z":z,"state":state}
				var light_key := "%s:%d" % [String(state.biome), int(light.sky)]
				if not lights.has(light_key): lights[light_key] = {"x":x,"y":y,"z":z,"state":state}
				var depth_cells := float(state.sample.get("depthCells", 0.0))
				if String(state.material) == "air" and depth_cells > 0.35 and depth_cells < 6.0 and shallow_air.is_empty(): shallow_air = {"x":x,"y":y,"z":z,"state":state}
				if String(state.material) == "air" and depth_cells > 0.35 and depth_cells <= 2.0 and shallow_water_eligible_air.is_empty(): shallow_water_eligible_air = {"x":x,"y":y,"z":z,"state":state}
				if String(state.biome) == "underground_air" and y <= -55 and String(state.fluid) != "lava" and lava_hash_false_air.is_empty(): lava_hash_false_air = {"x":x,"y":y,"z":z,"state":state}
				if String(state.biome) == "underground_air" and depth_cells >= 6.0 and (float(y) + 0.5) * 1.35 > 9.075 and above_aquifer_air.is_empty(): above_aquifer_air = {"x":x,"y":y,"z":z,"state":state}
				if fluids.size() >= 2 and ores.size() >= 3 and lights.size() >= 8 and not shallow_air.is_empty(): break
			if fluids.size() >= 2 and ores.size() >= 3 and lights.size() >= 8 and not shallow_air.is_empty(): break
		if fluids.size() >= 2 and ores.size() >= 3 and lights.size() >= 8 and not shallow_air.is_empty(): break
	var desert_air := {}
	for z in range(-57728, -57472):
		for x in range(-53632, -53376):
			for y in range(-63, 8):
				var desert_state: Dictionary = world.generate_cell_state(Vector3i(x,y,z))
				if String(desert_state.biome) == "underground_air" and float(desert_state.sample.get("depthCells", 0.0)) >= 6.0 and String(world.surface_biome_for_cell3(Vector3i(x,0,z))) == "desert":
					desert_air = {"x":x,"y":y,"z":z,"state":desert_state,"surfaceBiome":world.surface_biome_for_cell3(Vector3i(x,0,z))}
					break
			if not desert_air.is_empty(): break
		if not desert_air.is_empty(): break
	print(JSON.stringify({"shallowAir":shallow_air,"lavaHashFalseAir":lava_hash_false_air,"aboveAquiferAir":above_aquifer_air,"desertAir":desert_air}))
	quit()
