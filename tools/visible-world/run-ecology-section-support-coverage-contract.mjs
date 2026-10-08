import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-section-support-coverage-');
  prepare(c, 'userdata', false);
  const sourceSha256 = launchRecord(c, [
    'scripts/world/EcologyProducerCatalogContext.gd',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/EcologyWorldSupportIndex.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/testing/world/EcologySectionSupportCoverageContract.gd',
    'tools/visible-world/run-ecology-section-support-coverage-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'ecology-section-support-coverage-contract-launch/v1',
    evidenceLevel: 'synthetic_ecology_support_manifest_v2_identity_contract',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/EcologySectionSupportCoverageContract.gd'],
    env: { VOXEL_ECOLOGY_SECTION_SUPPORT_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'ecology_section_support_coverage_contract/v1' && report.passed === true,
    'Ecology section support coverage contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});
