import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'whole-section-candidate-assembler-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/testing/world/WorldStaticSectionCandidateAssemblerContract.gd',
    'tools/visible-world/run-world-static-section-candidate-assembler-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'whole-section-candidate-assembler-contract-launch/v1',
    evidenceLevel: 'synthetic_whole_section_candidate_contract',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/WorldStaticSectionCandidateAssemblerContract.gd'],
    env: { VOXEL_WHOLE_SECTION_ASSEMBLER_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'world-static-section-candidate-assembler-contract/v1' && report.passed === true,
    'Whole-section candidate assembler contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});
