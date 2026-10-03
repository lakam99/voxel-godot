import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'chunk-prop-bounded-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/ChunkPropBoundedCaptureContract.gd',
    'scripts/world/ChunkPropVisualManifest.gd',
    'scripts/world/PhysicalChunkPropManifestCache.gd',
    'scripts/world/DetailBatchVisualReceiptPublisher.gd',
    'tools/visible-world/run-chunk-prop-bounded-contract.mjs',
    'tools/lib/building-runner.mjs'
  ], { schema: 'chunk-prop-bounded-launch/v1',
    evidenceLevel: 'synthetic_producer_cache_contract', headed: false, timeoutSeconds: 90 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/ChunkPropBoundedCaptureContract.gd'],
    env: { VOXEL_CHUNK_PROP_BOUNDED_REPORT: path.join(c.run, 'report.json') },
    timeout: 90, membership: true, logPolicy: { emptyStderr: false }
  });
  const reportPath = path.join(c.run, 'report.json');
  const report = read(reportPath);
  assertReport(report, { schema: 'chunk-prop-bounded-capture-contract/v1', passed: true });
  demand(report.checkCount >= 14, 'Chunk prop bounded capture coverage unexpectedly shrank');
  return { reportPath, checkCount: report.checkCount,
    evidenceLevel: 'synthetic_producer_cache_contract' };
});
