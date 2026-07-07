param(
    [string]$ReportPath = "artifacts/underground-volume-audit.json"
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedReportPath = [System.IO.Path]::GetFullPath((Join-Path $projectPath $ReportPath))
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($resolvedReportPath)) | Out-Null

$legacy = "ca" + "ve"
$checks = @(
    [pscustomobject]@{
        Id = "world-generation-legacy-feature-api"
        Files = @("scripts/WorldGenerationSystem.gd")
        ForbiddenPattern = "func $($legacy)_feature_|find_$($legacy)_biome_sample|$($legacy)Value|$($legacy)_features_near_world"
        Requirement = "WorldGenerationSystem must expose underground volume through sample_world and find_underground_air_sample, not legacy feature records."
    },
    [pscustomobject]@{
        Id = "production-legacy-feature-authority"
        Files = @("scripts/MainCore.gd", "scripts/MainPlaytestTools.gd", "scripts/MainSaveState.gd", "scripts/StructureSystem.gd", "scripts/SubsurfaceSystem.gd")
        ForbiddenPattern = "find_$($legacy)_biome_sample|$($legacy)_feature|$($legacy)Id|VOXEL_$($legacy.ToUpper())"
        Requirement = "Production systems must not depend on legacy underground feature IDs, regions, launch variables, or geometry."
    },
    [pscustomobject]@{
        Id = "underground-sampler-entrypoints"
        Files = @("scripts/WorldGenerationSystem.gd")
        RequiredPattern = "func sample_world|func find_underground_air_sample|func world_bottom_cell_y|WORLD_BOTTOM_CELL_Y|UNDERGROUND_AIR_BIOME := `"underground_air`""
        Requirement = "Unified underground generation must expose sample_world, find_underground_air_sample, world-bottom-backed volume depth, and the underground_air state."
    },
    [pscustomobject]@{
        Id = "terrain-volume-service-entrypoints"
        Files = @("scripts/TerrainVolumeService.gd")
        RequiredPattern = "class_name TerrainVolumeService|func get_cell_state|func set_cell_state|func request_section|func request_sections_for_bounds|func save_all_section_deltas|func set_cell_light|func terrain_occupancy_at_cell|func surface_projection_for_cell|func find_underground_air_sample|func exposed_surface_cells|func exposed_underground_floor_cells|func begin_exposed_underground_floor_scan|func advance_exposed_underground_floor_scan"
        Requirement = "Minecraft-equivalent terrain migration requires a block-state terrain volume service with cell, section, delta, light, occupancy, underground-air search, and exposed-cell entry points."
    },
    [pscustomobject]@{
        Id = "terrain-volume-section-channels"
        Files = @("scripts/TerrainVolumeService.gd")
        RequiredPattern = "SECTION_CELL_COUNT|channelSchema|func empty_section_channels|func write_state_to_section_channels|func section_cell_state|func write_loaded_section_cell_state|func write_loaded_section_cell_light|func section_payload_for_bounds|blockIds|materialIds|biomeIds|fluidIds|skyLight|blockLight|metadataByIndex"
        Requirement = "TerrainVolumeService sections must store Minecraft-like block-state channels for materials, biomes, fluids, light, density, solid state, and metadata instead of relying only on per-cell sampler dictionaries."
    },
    [pscustomobject]@{
        Id = "terrain-surface-prop-volume-spawn"
        Files = @("scripts/MainPlaytestTools.gd")
        RequiredPattern = "surface_volume_spawn_sample_at_cell|surface_projection_for_cell|solidState|airState|surface_prop_volume_projection_queries"
        Requirement = "Surface prop/detail spawning must place against exposed terrain-volume solid/air boundaries and biome channels, not only direct heightfield columns."
    },
    [pscustomobject]@{
        Id = "terrain-underground-prop-volume-spawn"
        Files = @("scripts/MainPlaytestTools.gd")
        RequiredPattern = "scan_underground_prop_candidates|scan_underground_prop_candidates_from_volume_service|advance_exposed_underground_floor_scan|underground_prop_cells_scanned|underground_prop_volume_service_scans"
        Requirement = "Underground gameplay prop/resource spawning must discover exposed underground floors from volume cell state with bounded runtime counters, not from cave metadata or mesh-gated exposure scans."
    },
    [pscustomobject]@{
        Id = "terrain-underground-prop-runtime-report"
        Files = @("scripts/testing/RuntimePerformanceObservationRunner.gd")
        RequiredPattern = "underground_prop_cells_scanned|undergroundPropCellsScanned|undergroundPropCandidatesFound"
        Requirement = "Runtime performance reports must expose underground prop scanner work so terrain/resource spawning spikes can be diagnosed."
    },
    [pscustomobject]@{
        Id = "terrain-main-volume-query-wrappers"
        Files = @("scripts/MainPropFactory.gd", "scripts/MainInterface.gd")
        RequiredPattern = "terrain_occupancy_at_cell|surface_projection_for_cell|walkable_surface_cell_near"
        Requirement = "The main scene must expose terrain-volume occupancy and projection wrappers for gameplay systems that only receive Main as their terrain provider."
    },
    [pscustomobject]@{
        Id = "terrain-structure-volume-writes"
        Files = @("scripts/StructureSystem.gd")
        RequiredPattern = "apply_box_edit|structure_foundation|structure_reserved_air"
        Requirement = "Generated structures and placed scene blocks must write terrain-volume cell state instead of existing only as heightfield-adjacent nodes."
    },
    [pscustomobject]@{
        Id = "terrain-scene-block-volume-writes"
        Files = @("scripts/MainChunkTerrain.gd")
        RequiredPattern = "sync_block_state_to_terrain|clear_block_state_from_terrain|scene_block"
        Requirement = "Scene block placement/removal must sync terrain-volume cell state and restore replaced terrain state when possible."
    },
    [pscustomobject]@{
        Id = "terrain-fluid-runtime-mesh-node"
        Files = @("scripts/MainRuntimeTools.gd")
        RequiredPattern = "TerrainFluidMesh|chunk_fluid_mesh_asset|apply_chunk_fluid_mesh|volume_fluid_state|collision_source"
        Requirement = "Static water/lava terrain fluid states must produce a separate render mesh without becoming terrain collision."
    },
    [pscustomobject]@{
        Id = "terrain-fluid-volume-extraction"
        Files = @("scripts/MainPlaytestTools.gd")
        RequiredPattern = "func build_chunk_fluid_mesh|func append_fluid_cell_faces|chunk_fluid_faces|chunk_water_faces|chunk_lava_faces"
        Requirement = "Chunk fluid rendering must be extracted from the same volume sample state that drives solid terrain."
    },
    [pscustomobject]@{
        Id = "terrain-fluid-materials"
        Files = @("scripts/MainSetupScene.gd")
        RequiredPattern = "materials\[`"water`"\]|materials\[`"lava`"\]"
        Requirement = "Generated terrain fluids must have explicit water and lava materials."
    },
    [pscustomobject]@{
        Id = "terrain-meshing-service-entrypoints"
        Files = @("scripts/TerrainMeshingService.gd")
        RequiredPattern = "class_name TerrainMeshingService|func request_chunk_assets|func process_jobs|func take_completed_chunk_assets|func build_chunk_asset_bundle|func build_chunk_mesh|func section_payload_for_chunk|stepCells|build_chunk_mesh_from_sections|build_chunk_fluid_mesh_from_sections|func build_chunk_fluid_mesh|func collision_shape_for_mesh|terrainMeshingBackend"
        Requirement = "Chunk terrain meshing must have a replaceable meshing service boundary so native/GDExtension work can replace the current GDScript fallback."
    },
    [pscustomobject]@{
        Id = "terrain-native-section-payload-api"
        Files = @("native/terrain_meshing/src/terrain_meshing_backend.h")
        RequiredPattern = "build_chunk_mesh_from_sections|build_chunk_fluid_mesh_from_sections"
        Requirement = "The native terrain meshing backend must expose section-channel payload entry points for TerrainMeshingService solid and fluid extraction."
    },
    [pscustomobject]@{
        Id = "terrain-native-section-payload-meshing"
        Files = @("native/terrain_meshing/src/terrain_meshing_backend.cpp")
        RequiredPattern = "build_chunk_mesh_from_sections|sample_section_payload|sample_section_payload_numeric|section_lookup_from_payload|PackedFloat32Array|PackedByteArray|PackedStringArray|materialIds|material_color|nativeVolumeMaterialIds|terrainMeshingSectionPayload"
        Requirement = "The native terrain meshing backend must consume section channel payloads directly, including material IDs, instead of sampling every grid cell through GDScript callbacks."
    },
    [pscustomobject]@{
        Id = "terrain-meshing-applies-material"
        Files = @("scripts/TerrainMeshingService.gd")
        RequiredPattern = "func apply_terrain_material|surface_set_material|terrain_material|terrainMeshingSectionPayload"
        Requirement = "TerrainMeshingService must apply the shared terrain material to native section-payload meshes so volume-derived vertex colors render consistently."
    },
    [pscustomobject]@{
        Id = "terrain-native-section-payload-fluid-meshing"
        Files = @("native/terrain_meshing/src/terrain_meshing_backend.cpp")
        RequiredPattern = "build_chunk_fluid_mesh_from_sections|fluidIds|terrainFluidSectionPayload|terrainFluidSurfaceOrder|chunk_water_faces|chunk_lava_faces|native_section_payload_fluid_faces_v1"
        Requirement = "The native terrain meshing backend must extract water/lava render faces from TerrainVolumeService section fluid channels."
    },
    [pscustomobject]@{
        Id = "terrain-meshing-fluid-native-fallback"
        Files = @("scripts/TerrainMeshingService.gd")
        RequiredPattern = "build_chunk_fluid_mesh_from_sections|terrainFluidNativeDeferred|apply_fluid_materials|terrainFluidSurfaceOrder|surface_set_material"
        Requirement = "TerrainMeshingService must prefer native section-payload fluid extraction and fall back to the GDScript extractor when an older native backend reports fluid work as deferred."
    },
    [pscustomobject]@{
        Id = "terrain-meshing-runtime-boundary"
        Files = @("scripts/MainRuntimeTools.gd")
        RequiredPattern = "terrain_meshing_service.build_chunk_mesh|terrain_meshing_service.build_chunk_fluid_mesh|terrain_meshing_service.collision_shape_for_mesh|terrain_meshing_gdscript_fallback_chunks|terrain_meshing_service.request_chunk_assets|process_pending_terrain_meshing_jobs|apply_completed_terrain_meshing_jobs|provisional_chunk_assets"
        Requirement = "Chunk terrain meshing must route through a replaceable meshing service boundary so native/GDExtension work can replace the current GDScript fallback."
    },
    [pscustomobject]@{
        Id = "terrain-exterior-projection-volume-derived"
        Files = @("scripts/MainPlaytestTools.gd")
        RequiredPattern = "func natural_exterior_surface_y_cell|surface_y_for_cell"
        ForbiddenPattern = "natural_exterior_surface_y_cell[\s\S]*natural_surface_y_for_cell"
        Requirement = "The cheap exterior terrain projection must ask world generation for the terrain-volume surface projection, not direct natural heightfield authority."
    },
    [pscustomobject]@{
        Id = "terrain-volume-surface-projection-fast-path"
        Files = @("scripts/WorldGenerationSystem.gd")
        RequiredPattern = "func volume_surface_y_for_cell|terrain_volume_column_has_mesh_affecting_edits|terrain_deformed_surface_y_for_cell|surface_projection_cache"
        Requirement = "Terrain-volume surface projection must keep a cheap generated-column fast path and reserve full density scans for mesh-affecting edits."
    },
    [pscustomobject]@{
        Id = "terrain-meshing-streaming-budget"
        Files = @("scripts/MainRuntimeTools.gd")
        RequiredPattern = "STREAMING_TERRAIN_MESH_JOBS_PER_FRAME|STREAMING_TERRAIN_MESH_FRAME_BUDGET_MS|terrain_meshing_job_queue|terrain_meshing_jobs_processed|terrain_volume_sections_prepared_for_mesh|terrain_meshing_provisional_chunks"
        Requirement = "Full-volume chunk terrain meshing must be scheduled as bounded streaming work instead of forced through synchronous chunk creation."
    },
    [pscustomobject]@{
        Id = "terrain-meshing-no-normal-blocking-gdscript"
        Files = @("scripts/TerrainMeshingService.gd")
        RequiredPattern = "VOXEL_ALLOW_BLOCKING_GDSCRIPT_TERRAIN_MESHING|deferredWithoutNative|normalQueuedWorkDeferredWithoutNative"
        Requirement = "Normal queued gameplay terrain meshing must not silently perform full-volume GDScript fallback work when the native backend is unavailable."
    },
    [pscustomobject]@{
        Id = "terrain-meshing-deferred-work-runtime-counter"
        Files = @("scripts/MainRuntimeTools.gd")
        RequiredPattern = "terrain_meshing_jobs_deferred_without_native|deferredWithoutNative"
        Requirement = "Runtime performance counters must expose terrain mesh jobs deferred because the native backend is unavailable."
    },
    [pscustomobject]@{
        Id = "terrain-meshing-deferred-work-report"
        Files = @("scripts/testing/RuntimePerformanceObservationRunner.gd")
        RequiredPattern = "terrain_meshing_jobs_deferred_without_native|TerrainMeshingJobsDeferredWithoutNative"
        Requirement = "Runtime performance reports must include terrain mesh jobs deferred because the native backend is unavailable."
    },
    [pscustomobject]@{
        Id = "terrain-meshing-section-prewarm"
        Files = @("scripts/TerrainMeshingService.gd")
        RequiredPattern = "func prepare_chunk_sections|request_sections_for_bounds|terrainPreparedSections|chunk_volume_y_bounds"
        Requirement = "Chunk meshing jobs must prewarm overlapping 16x16x16 terrain volume sections before extracting mesh/collision assets."
    },
    [pscustomobject]@{
        Id = "terrain-native-meshing-sconstruct"
        Files = @("native/terrain_meshing/SConstruct")
        RequiredPattern = "godot-cpp|SharedLibrary|terrain_meshing_backend"
        Requirement = "The native terrain meshing backend must have a godot-cpp SCons build target."
    },
    [pscustomobject]@{
        Id = "terrain-native-meshing-gdextension-template"
        Files = @("native/terrain_meshing/terrain_meshing_backend.gdextension.in")
        RequiredPattern = "entry_symbol|terrain_meshing_library_init|\[libraries\]|terrain_meshing_backend"
        Requirement = "The native terrain meshing backend must include GDExtension loader metadata."
    },
    [pscustomobject]@{
        Id = "terrain-native-meshing-registration"
        Files = @("native/terrain_meshing/src/register_types.cpp")
        RequiredPattern = "ClassDB::register_class<TerrainMeshingBackend>|terrain_meshing_library_init|MODULE_INITIALIZATION_LEVEL_SCENE"
        Requirement = "The native terrain meshing backend must register TerrainMeshingBackend with Godot."
    },
    [pscustomobject]@{
        Id = "terrain-native-meshing-backend-class"
        Files = @("native/terrain_meshing/src/terrain_meshing_backend.cpp", "native/terrain_meshing/src/terrain_meshing_backend.h")
        RequiredPattern = "TerrainMeshingBackend|build_chunk_mesh|build_chunk_fluid_mesh|collision_shape_for_mesh|backend_summary"
        Requirement = "The native terrain meshing backend class must expose the methods TerrainMeshingService can discover."
    },
    [pscustomobject]@{
        Id = "terrain-native-density-extractor"
        Files = @("native/terrain_meshing/src/terrain_meshing_backend.cpp")
        RequiredPattern = "native_density_marching_tetrahedra_v1|append_tetrahedron_surface|native_terrain_numeric_sample_at_grid_cell|result\[`"ready`"\] = true"
        Requirement = "The native terrain meshing backend must contain a real density-field extractor instead of a registered-but-not-ready placeholder."
    },
    [pscustomobject]@{
        Id = "terrain-native-sampler-wrapper"
        Files = @("scripts/MainPlaytestTools.gd")
        RequiredPattern = "func native_terrain_numeric_sample_at_grid_cell|volume_numeric_sample_at_grid_cell|volume_grid_sample_numeric"
        Requirement = "The main gameplay scene must expose a thin numeric sampler wrapper for the native terrain backend."
    },
    [pscustomobject]@{
        Id = "terrain-native-meshing-build-wrapper"
        Files = @("tools/build-native-terrain-meshing.ps1")
        RequiredPattern = "FetchGodotCpp|scons|No C\+\+ compiler|terrain_meshing_backend.gdextension"
        Requirement = "The native terrain meshing backend must have a build/install wrapper that checks dependency and compiler availability."
    },
    [pscustomobject]@{
        Id = "terrain-digging-cell-edit-authority"
        Files = @("scripts/SubsurfaceSystem.gd")
        RequiredPattern = "terrain_volume_authority_available\(\) and sampler\(\)\.has_method\(`"apply_sphere_edit`"\)|terrain_air_edit_state|primaryMaterial|removedMaterials|solid_target_cell_for_hit"
        Requirement = "Player digging must write terrain-volume cell edits directly and report material drops from removed cells; brush records are legacy compatibility only."
    },
    [pscustomobject]@{
        Id = "terrain-volume-sphere-edit-wrapper"
        Files = @("scripts/WorldGenerationSystem.gd")
        RequiredPattern = "func apply_sphere_edit|terrain_volume_service\.apply_sphere_edit|surface_projection_cache\.clear"
        Requirement = "WorldGenerationSystem must expose sphere cell edits as a public terrain-volume edit API for digging and migration callers."
    }
)

$findings = @()
foreach ($check in $checks) {
    foreach ($relativePath in $check.Files) {
        $path = Join-Path $projectPath $relativePath
        if (-not (Test-Path -LiteralPath $path)) {
            $findings += [pscustomobject]@{
                id = $check.Id
                file = $relativePath
                type = "missing_file"
                requirement = $check.Requirement
            }
            continue
        }
        $source = Get-Content -LiteralPath $path -Raw
        if ($check.PSObject.Properties["ForbiddenPattern"] -and $check.ForbiddenPattern -ne "") {
            if ($source -match $check.ForbiddenPattern) {
                $findings += [pscustomobject]@{
                    id = $check.Id
                    file = $relativePath
                    type = "forbidden_pattern"
                    pattern = $check.ForbiddenPattern
                    requirement = $check.Requirement
                }
            }
        }
        if ($check.PSObject.Properties["RequiredPattern"] -and $check.RequiredPattern -ne "") {
            foreach ($pattern in ($check.RequiredPattern -split "\|")) {
                if ($source -notmatch $pattern) {
                    $findings += [pscustomobject]@{
                        id = $check.Id
                        file = $relativePath
                        type = "missing_required_pattern"
                        pattern = $pattern
                        requirement = $check.Requirement
                    }
                }
            }
        }
    }
}

$report = [pscustomobject]@{
    schemaVersion = 1
    runnerId = "underground_volume_static_audit"
    evidenceLevel = "static_audit"
    status = if ($findings.Count -eq 0) { "passed" } else { "failed" }
    findingCount = $findings.Count
    findings = $findings
}
$report | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $resolvedReportPath

if ($findings.Count -gt 0) {
    Get-Content -LiteralPath $resolvedReportPath
    exit 1
}

Get-Content -LiteralPath $resolvedReportPath
exit 0
