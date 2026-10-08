import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'section-mesh-resource-identity-');
  prepare(c, 'userdata', false);
  const sourceSha256 = launchRecord(c, [
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/testing/world/WorldStaticSectionMeshResourceIdentityContract.gd',
    'scripts/testing/world/WorldStaticSectionMeshResourceIdentityContract.gd.uid',
    'tools/visible-world/run-world-static-section-mesh-resource-identity-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'world-static-section-mesh-resource-identity-contract-launch/v1',
    evidenceLevel: 'synthetic_resource_identity_contract',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/WorldStaticSectionMeshResourceIdentityContract.gd'],
    env: { VOXEL_SECTION_MESH_RESOURCE_IDENTITY_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'world-static-section-mesh-resource-identity-contract/v1' && report.passed === true,
    'Section mesh resource identity contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});
