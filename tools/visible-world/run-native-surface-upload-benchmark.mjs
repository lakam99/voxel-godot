import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const c = context(options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' }), 'native-surface-upload-');
  prepare(c, 'userdata', false);
  const sourceHashes = launchRecord(c, [
    'project.godot',
    'scripts/testing/world/NativeSurfaceUploadBenchmark.gd',
    'scripts/testing/world/NativeSurfaceUploadBenchmark.gd.uid',
    'scripts/buildings/BuildingPartPublisher.gd',
    'scripts/buildings/BuildingPart.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingStaticBatchFlush.gd',
    'scripts/buildings/BuildingWindowVisualRecipe.gd',
    'scripts/world/StaticTranslucentMeshPreparation.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'native/terrain_meshing/build/world_backend/debug/build-manifest.json',
    'tools/visible-world/run-native-surface-upload-benchmark.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], { schema: 'native-surface-upload-launch/v1', headed: true, timeoutSeconds: 120 });
  await phaseRun(c, {
    args: ['--script', 'res://scripts/testing/world/NativeSurfaceUploadBenchmark.gd'],
    env: { VOXEL_SURFACE_UPLOAD_REPORT: path.join(c.run, 'report.json') },
    timeout: 120,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceHashes);
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'native-surface-upload-benchmark/v1', complete: true, passed: true });
  demand(report.sampleCountPerMode === 12, 'Benchmark sample count changed');
  const required = ['real_window_source_admitted', 'actual_translucent_surface_found',
    'actual_glass_sorted_payload_prepared', 'native_packet_backend_ready',
    'cancelled_render_work_creates_no_resource', 'destroyed_owner_result_not_adopted', 'destroyed_owner_resource_released'];
  for (let i = 0; i < 12; i++) for (const prefix of ['native_sample_', 'server_cold_sample_', 'index_readback_', 'server_update_sample_', 'server_release_']) required.push(prefix + i);
  for (const name of required) demand(report.checks?.some(row => row.name === name && row.passed === true), `Missing proof: ${name}`);
  demand(report.measurements?.length === 36, 'Missing upload measurements');
  for (const mode of ['baseline', 'arraymesh_native', 'server_cold', 'server_slot_index_update']) demand(report.frameTiming?.[mode]?.count > 0, `Missing frame evidence: ${mode}`);
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount, frameTiming: report.frameTiming };
});
