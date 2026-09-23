import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { findGodot, projectRoot } from './lib/voxel-tool-runtime.mjs';
import { runGodotProcess } from './lib/godot-process.mjs';

const output = join(projectRoot, 'artifacts', 'native-world-backend', 'n4-direct-source-order-differential');
await mkdir(output, { recursive: true });
const token = randomUUID();
const probePath = join(output, `probe-${token}.json`);
const reportPath = join(output, `report-${token}.json`);
const executable = await findGodot();
const command = ['--headless', '--path', projectRoot, '--script', 'res://scripts/testing/native_world/N4DirectSourceOrderProbe.gd'];
const processResult = await runGodotProcess(executable, command, {
  cwd: projectRoot, timeoutSeconds: 90, workTimeoutSeconds: 60,
  env: { ...process.env, N4_DIRECT_SOURCE_ORDER_PROBE_REPORT: probePath },
});
const failures = [];
let probe;
try { probe = JSON.parse(await readFile(probePath, 'utf8')); }
catch (error) { failures.push(`Probe report unavailable: ${error.message}`); }
if (processResult.code !== 0) failures.push(`Godot process failed: ${processResult.code}`);
if (probe?.cases?.length !== 3) failures.push(`Expected three cases, got ${probe?.cases?.length}`);
for (const [caseIndex, sample] of (probe?.cases ?? []).entries()) {
  const label = `case ${caseIndex} chunk ${JSON.stringify(sample.chunk)} removed ${sample.removed?.length ?? 0}`;
  for (const key of ['nativeInitialization', 'structureAdmission', 'orderedStatus'])
    if (sample[key] !== 'ready') failures.push(`${label} ${key}: ${sample[key]}`);
  if (!sample.bundleReady) failures.push(`${label} owner bundle not ready`);
  for (const [key, value] of Object.entries(sample.admissions ?? {}))
    if (value !== 'ready') failures.push(`${label} ${key} admission: ${value}`);
  if (sample.direct?.length !== 28 || sample.native?.length !== 28)
    failures.push(`${label} attempt counts: direct=${sample.direct?.length}, native=${sample.native?.length}`);
  const uint64 = value => BigInt.asUintN(64, BigInt(value)).toString();
  for (let index = 0; index < Math.min(sample.direct?.length ?? 0, sample.native?.length ?? 0); index++) {
    const direct = sample.direct[index], native = sample.native[index];
    for (const field of ['ordinal', 'durableId'])
      if (direct[field] !== native[field]) failures.push(`${label} attempt ${index} ${field}: ${direct[field]} != ${native[field]}`);
    if (JSON.stringify(direct.cell) !== JSON.stringify(native.cell)) failures.push(`${label} attempt ${index} cell mismatch`);
    if (direct.sourceSampleApplicable) {
      if (direct.sourceBiome !== native.sourceBiome) failures.push(`${label} attempt ${index} source biome mismatch`);
      if (Math.abs(direct.sourceHeightMeters - native.sourceHeightMeters) > 1e-5)
        failures.push(`${label} attempt ${index} source height mismatch`);
    } else if (native.sourceBiome !== '' || native.sourceHeightMeters !== 0) {
      failures.push(`${label} attempt ${index} sampled after tombstone`);
    }
    for (const field of ['stateBeforeCoordinates', 'stateAfterRecipe'])
      if (uint64(direct[field]) !== uint64(native[field])) failures.push(`${label} attempt ${index} ${field} mismatch`);
  }
  if (uint64(sample.directFinalRngState) !== uint64(sample.nativeFinalRngState)) failures.push(`${label} final RNG state mismatch`);
}
const report = {
  schema: 'n4-direct-source-order-differential/v1',
  status: failures.length ? 'failed' : 'passed',
  evidenceLevel: 'direct production-method/service differential; not headed gameplay acceptance',
  seed: probe?.seed ?? null, cases: probe?.cases?.map(({chunk, removed, direct, native}) => ({
    chunk, removed, attemptsCompared: Math.min(direct?.length ?? 0, native?.length ?? 0),
  })) ?? [],
  failures: failures.slice(0, 40), probePath, processSummaryPath: processResult.summaryPath,
  executable, command,
};
await writeFile(reportPath, JSON.stringify(report, null, 2));
console.log(`${report.status}: ${reportPath}`);
if (failures.length) { console.error(failures.slice(0, 10).join('\n')); process.exitCode = 1; }
