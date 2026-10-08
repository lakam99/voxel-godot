import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ordinary-section-geometry-adapter-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/OrdinaryStructureSectionGeometryAdapterContract.gd',
    'scripts/MainChunkTerrain.gd',
    'scripts/world/OrdinaryStructureSectionGeometryAdapter.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/StructureSystem.gd',
    'scripts/world/CitadelSiteField.gd',
    'scripts/world/CitadelTerrainAdmission.gd',
    'scripts/world/StandaloneStructureCandidate.gd',
    'scripts/world/OrdinaryStructureBlockVisualRecipe.gd',
    'scripts/visual/StaticItemAssetRegistry.gd',
    'assets/generated/static/static-item-manifest.json',
    'assets/generated/static/workbench.glb',
    'assets/generated/static/bed.glb',
    'assets/generated/static/traderStall.glb',
    'assets/generated/static/spikeTrap.glb',
    'tools/visible-world/run-ordinary-section-geometry-adapter-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'ordinary-section-geometry-adapter-launch/v1',
    evidenceLevel: 'synthetic_producer_value_partition_and_local_structure_dependency_contract',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/OrdinaryStructureSectionGeometryAdapterContract.gd'],
    env: { VOXEL_ORDINARY_SECTION_GEOMETRY_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, {
    schema: 'ordinary-structure-section-geometry-adapter-contract/v1',
    complete: true,
    passed: true
  });
  demand(report.checkCount >= 8, 'ordinary section geometry adapter coverage unexpectedly shrank');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel
  };
});
