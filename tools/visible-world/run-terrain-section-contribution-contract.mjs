import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'terrain-section-contribution-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/MainSetupScene.gd',
    'resources/visual/water_material.tres',
    'shaders/stylized_water.gdshader',
    'scripts/TerrainVolumeService.gd',
    'scripts/terrain/TerrainSectionShadowPublisher.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/testing/world/TerrainSectionContributionContract.gd',
    'tools/visible-world/run-terrain-section-contribution-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'terrain-section-contribution-contract-launch/v1',
    evidenceLevel: 'synthetic_terrain_provider_and_shared_assembler_contract',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/TerrainSectionContributionContract.gd'],
    env: { VOXEL_TERRAIN_SECTION_CONTRIBUTION_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'terrain_section_contribution_contract/v1' && report.passed === true,
    'Terrain section contribution contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});
