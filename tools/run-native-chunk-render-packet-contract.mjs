import path from 'node:path';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'native-chunk-packet-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/NativeChunkRenderPacketContract.gd',
    'scripts/Main.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/VoxelTerrainSiteGate.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/PreparedStaticContributorLedger.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/buildings/BuildingInstanceBuffer.gd',
    'scripts/buildings/BuildingPartPublisher.gd',
    'scripts/buildings/BuildingStaticBatchFlush.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/build/world_backend/debug/build-manifest.json',
    'tools/run-native-chunk-render-packet-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  const nativeSourcePath = path.join(c.project, 'native/terrain_meshing/src/chunk_render_packet_backend.cpp');
  const sourceBytes = fs.readFileSync(nativeSourcePath);
  const sourceSha = createHash('sha256').update(sourceBytes).digest('hex');
  const buildManifest = read(path.join(c.project, 'native/terrain_meshing/build/world_backend/debug/build-manifest.json'));
  const buildRecord = buildManifest.extensionSources?.find(row => row.path === 'native/terrain_meshing/src/chunk_render_packet_backend.cpp');
  demand(buildManifest.schema === 'native-world-backend-build-manifest/v1' && buildRecord?.sha256 === sourceSha
    && buildRecord.bytes === sourceBytes.length,
  'Native GDExtension DLL build manifest does not match chunk packet backend source; rebuild the extension first.');
  launchRecord(c, files, { schema: 'native-chunk-render-packet-launch/v1',
    evidenceLevel: 'native_chunk_packet_and_building_flush_contract', headed: false, timeoutSeconds: 60 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/NativeChunkRenderPacketContract.gd'],
    env: { NATIVE_CHUNK_PACKET_REPORT: path.join(c.run, 'report.json') },
    timeout: 60,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  const checks = report.checks || {};
  demand(report.schema === 'native_chunk_render_packet_contract/v1'
    && report.evidence === 'native_building_packet_flush_and_replay; world-owned coordinator installs a census-checked candidate through the native backend and rejects incomplete replacement census; section cancellation retains the old root; ArrayMesh triangle resource is installed in native section slot; no generated-world/live-gameplay acceptance' && report.passed === true
    && checks.native_backend_attached_to_actual_chunk === true
    && checks.native_backend_rejects_wrong_owner_cell === true
    && checks.native_packet_generation_one_installs === true
    && checks.native_packet_receipt_matches_generation_one === true
    && checks.native_packet_generation_two_replaces_generation_one === true
    && checks.native_packet_stale_release_preserves_current_generation === true
    && checks.production_static_flush_installs_through_native_backend === true
    && checks['32_cell_source_owner_differs_from_28_cell_stream_chunk'] === true
    && checks.production_packet_attaches_to_actual_28_cell_stream_chunk === true
    && checks.nonzero_packet_retires_from_actual_chunk_owner === true
    && checks.native_backend_recreated_for_replacement_chunk === true
    && checks.production_static_packet_replays_after_chunk_recreation === true
    && checks.production_static_packet_release_acknowledged === true
    && checks.native_packet_republishes_after_chunk_replacement === true
    && checks.native_packet_release_acknowledged === true
    && checks.native_packet_capacity_fixture_fills_installed_limit === true
    && checks.production_flush_fails_closed_at_installed_packet_capacity === true
    && checks.main_runtime_creates_chunk_owned_native_backend === true
    && checks.main_runtime_admits_and_requests_production_chunk === true
    && checks.main_runtime_releases_backend_before_unregistering_chunk === true
    && checks.main_runtime_chunk_retirement_frees_native_owner === true
    && checks.main_runtime_preserves_retained_terrain_owner === true
    && checks.main_runtime_preserves_startup_auxiliary_terrain_owner === true
    && checks.main_runtime_retires_owner_after_dependencies_release === true
    && checks.bound_section_candidate_installs_through_native_chunk_renderer === true
    && checks.cancelled_section_replacement_keeps_previous_native_root_visible === true
    && checks.native_section_slot_rejects_reused_generation === true
    && checks.section_install_revalidates_registry_owner_before_upload === true
    && checks.section_owner_accepts_cross_chunk_manifest_and_retains_old_slot_on_cancel === true
    && checks.main_runtime_creates_independent_static_section_owner === true
    && checks.main_runtime_retires_static_section_owner_after_render_demand === true
    && checks.world_coordinator_candidate_installs_and_promotes_through_native_renderer === true
    && checks.native_section_slot_installs_transvoxel_shaped_array_mesh === true
    && checks.world_coordinator_rejects_incomplete_source_census_without_replacing_slot === true,
  'Native chunk packet lifecycle contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checks,
    nativeSourceSha256: sourceSha,
    evidence: 'Production building flush/replay plus world-coordinator census-checked section installation and rejection through the native backend, including an ArrayMesh triangle surface installed into a native section MultiMesh; Main.gd chunk creation/retirement uses actual VoxelTerrainRuntime demand bookkeeping and a stubbed site gate; no generated-world or gameplay acceptance.' };
});
