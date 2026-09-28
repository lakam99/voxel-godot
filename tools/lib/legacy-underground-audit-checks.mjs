// All 37 rules from e09cc95:tools/run-underground-volume-audit.ps1.
// Only the retired build-wrapper path is mapped to its Node entry point plus
// implementation module. Its dependency/compiler requirements remain intact.
export const undergroundAuditChecks = [
  {
    "id": "world-generation-legacy-feature-api",
    "files": [
      "scripts/WorldGenerationSystem.gd"
    ],
    "forbiddenPattern": "func cave_feature_|find_cave_biome_sample|caveValue|cave_features_near_world",
    "requirement": "WorldGenerationSystem must expose underground volume through sample_world and find_underground_air_sample, not legacy feature records."
  },
  {
    "id": "production-legacy-feature-authority",
    "files": [
      "scripts/MainCore.gd",
      "scripts/MainPlaytestTools.gd",
      "scripts/MainSaveState.gd",
      "scripts/StructureSystem.gd",
      "scripts/SubsurfaceSystem.gd"
    ],
    "forbiddenPattern": "find_cave_biome_sample|cave_feature|caveId|VOXEL_CAVE",
    "requirement": "Production systems must not depend on legacy underground feature IDs, regions, launch variables, or geometry."
  },
  {
    "id": "underground-sampler-entrypoints",
    "files": [
      "scripts/WorldGenerationSystem.gd"
    ],
    "requiredPattern": "func sample_world|func find_underground_air_sample|func world_bottom_cell_y|WORLD_BOTTOM_CELL_Y|UNDERGROUND_AIR_BIOME := \"underground_air\"",
    "requirement": "Unified underground generation must expose sample_world, find_underground_air_sample, world-bottom-backed volume depth, and the underground_air state."
  },
  {
    "id": "terrain-volume-service-entrypoints",
    "files": [
      "scripts/TerrainVolumeService.gd"
    ],
    "requiredPattern": "class_name TerrainVolumeService|func get_cell_state|func set_cell_state|func request_section|func request_sections_for_bounds|func save_all_section_deltas|func set_cell_light|func terrain_occupancy_at_cell|func surface_projection_for_cell|func find_underground_air_sample|func exposed_surface_cells|func exposed_underground_floor_cells|func begin_exposed_underground_floor_scan|func advance_exposed_underground_floor_scan",
    "requirement": "Minecraft-equivalent terrain migration requires a block-state terrain volume service with cell, section, delta, light, occupancy, underground-air search, and exposed-cell entry points."
  },
  {
    "id": "terrain-volume-section-channels",
    "files": [
      "scripts/TerrainVolumeService.gd"
    ],
    "requiredPattern": "SECTION_CELL_COUNT|channelSchema|func empty_section_channels|func write_state_to_section_channels|func section_cell_state|func write_loaded_section_cell_state|func write_loaded_section_cell_light|func section_payload_for_bounds|blockIds|materialIds|biomeIds|fluidIds|skyLight|blockLight|metadataByIndex",
    "requirement": "TerrainVolumeService sections must store Minecraft-like block-state channels for materials, biomes, fluids, light, density, solid state, and metadata instead of relying only on per-cell sampler dictionaries."
  },
  {
    "id": "terrain-surface-prop-volume-spawn",
    "files": [
      "scripts/MainPlaytestTools.gd"
    ],
    "requiredPattern": "surface_volume_spawn_sample_at_cell|surface_projection_for_cell|solidState|airState|surface_prop_volume_projection_queries",
    "requirement": "Surface prop/detail spawning must place against exposed terrain-volume solid/air boundaries and biome channels, not only direct heightfield columns."
  },
  {
    "id": "terrain-underground-prop-volume-spawn",
    "files": [
      "scripts/MainPlaytestTools.gd"
    ],
    "requiredPattern": "scan_underground_prop_candidates|scan_underground_prop_candidates_from_volume_service|advance_exposed_underground_floor_scan|underground_prop_cells_scanned|underground_prop_volume_service_scans",
    "requirement": "Underground gameplay prop/resource spawning must discover exposed underground floors from volume cell state with bounded runtime counters, not from cave metadata or mesh-gated exposure scans."
  },
  {
    "id": "terrain-underground-prop-runtime-report",
    "files": [
      "scripts/testing/RuntimePerformanceObservationRunner.gd"
    ],
    "requiredPattern": "underground_prop_cells_scanned|undergroundPropCellsScanned|undergroundPropCandidatesFound",
    "requirement": "Runtime performance reports must expose underground prop scanner work so terrain/resource spawning spikes can be diagnosed."
  },
  {
    "id": "terrain-main-volume-query-wrappers",
    "files": [
      "scripts/MainPropFactory.gd",
      "scripts/MainInterface.gd"
    ],
    "requiredPattern": "terrain_occupancy_at_cell|surface_projection_for_cell|walkable_surface_cell_near",
    "requirement": "The main scene must expose terrain-volume occupancy and projection wrappers for gameplay systems that only receive Main as their terrain provider."
  },
  {
    "id": "terrain-structure-volume-writes",
    "files": [
      "scripts/StructureSystem.gd"
    ],
    "requiredPattern": "apply_box_edit|structure_foundation|structure_reserved_air",
    "requirement": "Generated structures and placed scene blocks must write terrain-volume cell state instead of existing only as heightfield-adjacent nodes."
  },
  {
    "id": "terrain-scene-block-volume-writes",
    "files": [
      "scripts/MainChunkTerrain.gd"
    ],
    "requiredPattern": "sync_block_state_to_terrain|clear_block_state_from_terrain|scene_block",
    "requirement": "Scene block placement/removal must sync terrain-volume cell state and restore replaced terrain state when possible."
  },
  {
    "id": "terrain-fluid-runtime-mesh-node",
    "files": [
      "scripts/MainRuntimeTools.gd"
    ],
    "requiredPattern": "TerrainFluidMesh|chunk_fluid_mesh_asset|apply_chunk_fluid_mesh|volume_fluid_state|collision_source",
    "requirement": "Static water/lava terrain fluid states must produce a separate render mesh without becoming terrain collision."
  },
  {
    "id": "terrain-fluid-volume-extraction",
    "files": [
      "scripts/MainPlaytestTools.gd"
    ],
    "requiredPattern": "func build_chunk_fluid_mesh|func append_fluid_cell_faces|chunk_fluid_faces|chunk_water_faces|chunk_lava_faces",
    "requirement": "Chunk fluid rendering must be extracted from the same volume sample state that drives solid terrain."
  },
  {
    "id": "terrain-fluid-materials",
    "files": [
      "scripts/MainSetupScene.gd"
    ],
    "requiredPattern": "materials\\[\"water\"\\]|materials\\[\"lava\"\\]",
    "requirement": "Generated terrain fluids must have explicit water and lava materials."
  },
  {
    "id": "terrain-meshing-service-entrypoints",
    "files": [
      "scripts/TerrainMeshingService.gd"
    ],
    "requiredPattern": "class_name TerrainMeshingService|func request_chunk_assets|func process_jobs|func take_completed_chunk_assets|func build_chunk_asset_bundle|func build_chunk_mesh|func section_payload_for_chunk|stepCells|build_chunk_mesh_from_sections|build_chunk_fluid_mesh_from_sections|func build_chunk_fluid_mesh|func collision_shape_for_mesh|terrainMeshingBackend",
    "requirement": "Chunk terrain meshing must have a replaceable meshing service boundary so native/GDExtension work can replace the current GDScript fallback."
  },
  {
    "id": "terrain-native-section-payload-api",
    "files": [
      "native/terrain_meshing/src/terrain_meshing_backend.h"
    ],
    "requiredPattern": "build_chunk_mesh_from_sections|build_chunk_fluid_mesh_from_sections",
    "requirement": "The native terrain meshing backend must expose section-channel payload entry points for TerrainMeshingService solid and fluid extraction."
  },
  {
    "id": "terrain-native-section-payload-meshing",
    "files": [
      "native/terrain_meshing/src/terrain_meshing_backend.cpp"
    ],
    "requiredPattern": "build_chunk_mesh_from_sections|sample_section_payload|sample_section_payload_numeric|section_lookup_from_payload|PackedFloat32Array|PackedByteArray|PackedStringArray|materialIds|material_color|nativeVolumeMaterialIds|terrainMeshingSectionPayload",
    "requirement": "The native terrain meshing backend must consume section channel payloads directly, including material IDs, instead of sampling every grid cell through GDScript callbacks."
  },
  {
    "id": "terrain-meshing-applies-material",
    "files": [
      "scripts/TerrainMeshingService.gd"
    ],
    "requiredPattern": "func apply_terrain_material|surface_set_material|terrain_material|terrainMeshingSectionPayload",
    "requirement": "TerrainMeshingService must apply the shared terrain material to native section-payload meshes so volume-derived vertex colors render consistently."
  },
  {
    "id": "terrain-native-section-payload-fluid-meshing",
    "files": [
      "native/terrain_meshing/src/terrain_meshing_backend.cpp"
    ],
    "requiredPattern": "build_chunk_fluid_mesh_from_sections|fluidIds|terrainFluidSectionPayload|terrainFluidSurfaceOrder|chunk_water_faces|chunk_lava_faces|native_section_payload_fluid_faces_v1",
    "requirement": "The native terrain meshing backend must extract water/lava render faces from TerrainVolumeService section fluid channels."
  },
  {
    "id": "terrain-meshing-fluid-native-fallback",
    "files": [
      "scripts/TerrainMeshingService.gd"
    ],
    "requiredPattern": "build_chunk_fluid_mesh_from_sections|terrainFluidNativeDeferred|apply_fluid_materials|terrainFluidSurfaceOrder|surface_set_material",
    "requirement": "TerrainMeshingService must prefer native section-payload fluid extraction and fall back to the GDScript extractor when an older native backend reports fluid work as deferred."
  },
  {
    "id": "terrain-meshing-runtime-boundary",
    "files": [
      "scripts/MainRuntimeTools.gd"
    ],
    "requiredPattern": "terrain_meshing_service.build_chunk_mesh|terrain_meshing_service.build_chunk_fluid_mesh|terrain_meshing_service.collision_shape_for_mesh|terrain_meshing_gdscript_fallback_chunks|terrain_meshing_service.request_chunk_assets|process_pending_terrain_meshing_jobs|apply_completed_terrain_meshing_jobs|provisional_chunk_assets",
    "requirement": "Chunk terrain meshing must route through a replaceable meshing service boundary so native/GDExtension work can replace the current GDScript fallback."
  },
  {
    "id": "terrain-exterior-projection-volume-derived",
    "files": [
      "scripts/MainPlaytestTools.gd"
    ],
    "requiredPattern": "func natural_exterior_surface_y_cell|surface_y_for_cell",
    "forbiddenPattern": "natural_exterior_surface_y_cell[\\s\\S]*natural_surface_y_for_cell",
    "requirement": "The cheap exterior terrain projection must ask world generation for the terrain-volume surface projection, not direct natural heightfield authority."
  },
  {
    "id": "terrain-volume-surface-projection-fast-path",
    "files": [
      "scripts/WorldGenerationSystem.gd"
    ],
    "requiredPattern": "func volume_surface_y_for_cell|terrain_volume_column_has_mesh_affecting_edits|terrain_deformed_surface_y_for_cell|surface_projection_cache",
    "requirement": "Terrain-volume surface projection must keep a cheap generated-column fast path and reserve full density scans for mesh-affecting edits."
  },
  {
    "id": "terrain-meshing-streaming-budget",
    "files": [
      "scripts/MainRuntimeTools.gd"
    ],
    "requiredPattern": "STREAMING_TERRAIN_MESH_JOBS_PER_FRAME|STREAMING_TERRAIN_MESH_FRAME_BUDGET_MS|terrain_meshing_job_queue|terrain_meshing_jobs_processed|terrain_volume_sections_prepared_for_mesh|terrain_meshing_provisional_chunks",
    "requirement": "Full-volume chunk terrain meshing must be scheduled as bounded streaming work instead of forced through synchronous chunk creation."
  },
  {
    "id": "terrain-meshing-no-normal-blocking-gdscript",
    "files": [
      "scripts/TerrainMeshingService.gd"
    ],
    "requiredPattern": "VOXEL_ALLOW_BLOCKING_GDSCRIPT_TERRAIN_MESHING|deferredWithoutNative|normalQueuedWorkDeferredWithoutNative",
    "requirement": "Normal queued gameplay terrain meshing must not silently perform full-volume GDScript fallback work when the native backend is unavailable."
  },
  {
    "id": "terrain-meshing-deferred-work-runtime-counter",
    "files": [
      "scripts/MainRuntimeTools.gd"
    ],
    "requiredPattern": "terrain_meshing_jobs_deferred_without_native|deferredWithoutNative",
    "requirement": "Runtime performance counters must expose terrain mesh jobs deferred because the native backend is unavailable."
  },
  {
    "id": "terrain-meshing-deferred-work-report",
    "files": [
      "scripts/testing/RuntimePerformanceObservationRunner.gd"
    ],
    "requiredPattern": "terrain_meshing_jobs_deferred_without_native|TerrainMeshingJobsDeferredWithoutNative",
    "requirement": "Runtime performance reports must include terrain mesh jobs deferred because the native backend is unavailable."
  },
  {
    "id": "terrain-meshing-section-prewarm",
    "files": [
      "scripts/TerrainMeshingService.gd"
    ],
    "requiredPattern": "func prepare_chunk_sections|request_sections_for_bounds|terrainPreparedSections|chunk_volume_y_bounds",
    "requirement": "Chunk meshing jobs must prewarm overlapping 16x16x16 terrain volume sections before extracting mesh/collision assets."
  },
  {
    "id": "terrain-native-meshing-sconstruct",
    "files": [
      "native/terrain_meshing/SConstruct"
    ],
    "requiredPattern": "godot-cpp|SharedLibrary|terrain_meshing_backend",
    "requirement": "The native terrain meshing backend must have a godot-cpp SCons build target."
  },
  {
    "id": "terrain-native-meshing-gdextension-template",
    "files": [
      "native/terrain_meshing/terrain_meshing_backend.gdextension.in"
    ],
    "requiredPattern": "entry_symbol|terrain_meshing_library_init|\\[libraries\\]|terrain_meshing_backend",
    "requirement": "The native terrain meshing backend must include GDExtension loader metadata."
  },
  {
    "id": "terrain-native-meshing-registration",
    "files": [
      "native/terrain_meshing/src/register_types.cpp"
    ],
    "requiredPattern": "ClassDB::register_class<TerrainMeshingBackend>|terrain_meshing_library_init|MODULE_INITIALIZATION_LEVEL_SCENE",
    "requirement": "The native terrain meshing backend must register TerrainMeshingBackend with Godot."
  },
  {
    "id": "terrain-native-meshing-backend-class",
    "files": [
      "native/terrain_meshing/src/terrain_meshing_backend.cpp",
      "native/terrain_meshing/src/terrain_meshing_backend.h"
    ],
    "requiredPattern": "TerrainMeshingBackend|build_chunk_mesh|build_chunk_fluid_mesh|collision_shape_for_mesh|backend_summary",
    "requirement": "The native terrain meshing backend class must expose the methods TerrainMeshingService can discover."
  },
  {
    "id": "terrain-native-density-extractor",
    "files": [
      "native/terrain_meshing/src/terrain_meshing_backend.cpp"
    ],
    "requiredPattern": "native_density_marching_tetrahedra_v1|append_tetrahedron_surface|native_terrain_numeric_sample_at_grid_cell|result\\[\"ready\"\\] = true",
    "requirement": "The native terrain meshing backend must contain a real density-field extractor instead of a registered-but-not-ready placeholder."
  },
  {
    "id": "terrain-native-sampler-wrapper",
    "files": [
      "scripts/MainPlaytestTools.gd"
    ],
    "requiredPattern": "func native_terrain_numeric_sample_at_grid_cell|volume_numeric_sample_at_grid_cell|volume_grid_sample_numeric",
    "requirement": "The main gameplay scene must expose a thin numeric sampler wrapper for the native terrain backend."
  },
  {
    "id": "terrain-native-meshing-build-wrapper",
    "files": [
      "tools/build-native-terrain-meshing.mjs"
    ],
    "requiredPattern": "FetchGodotCpp|scons|No C\\+\\+ compiler|terrain_meshing_backend.gdextension",
    "requirement": "The native terrain meshing backend must have a build/install wrapper that checks dependency and compiler availability.",
    "composedSources": [
      "tools/lib/voxel-tool-runtime.mjs"
    ],
    "entrypointPattern": "runToolMain\\('build-native-terrain-meshing'\\)"
  },
  {
    "id": "terrain-digging-cell-edit-authority",
    "files": [
      "scripts/SubsurfaceSystem.gd"
    ],
    "requiredPattern": "terrain_volume_authority_available\\(\\) and sampler\\(\\)\\.has_method\\(\"apply_sphere_edit\"\\)|terrain_air_edit_state|primaryMaterial|removedMaterials|solid_target_cell_for_hit",
    "requirement": "Player digging must write terrain-volume cell edits directly and report material drops from removed cells; brush records are legacy compatibility only."
  },
  {
    "id": "terrain-volume-sphere-edit-wrapper",
    "files": [
      "scripts/WorldGenerationSystem.gd"
    ],
    "requiredPattern": "func apply_sphere_edit|terrain_volume_service\\.apply_sphere_edit|surface_projection_cache\\.clear",
    "requirement": "WorldGenerationSystem must expose sphere cell edits as a public terrain-volume edit API for digging and migration callers."
  }
];
