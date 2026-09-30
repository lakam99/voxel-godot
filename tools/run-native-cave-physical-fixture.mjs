#!/usr/bin/env node

import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArguments, findGodot, projectRoot, timestamp } from './lib/voxel-tool-runtime.mjs';
import { runOwnedProcess } from './lib/owned-process.mjs';

const parsed = parseArguments(process.argv.slice(2));
const options = parsed.options;
if (options.help) {
  process.stdout.write(`Usage: node tools/run-native-cave-physical-fixture.mjs [options]

Publishes fixed native-cave SDF blocks through a real VoxelTerrain mesher and
physics world, captures entrance/interior views, then proves owned cleanup.
This is a shadow-candidate fixture, not production cutover or live gameplay.

  --godot-exe PATH      Godot console executable (or GODOT_EXE)
  --output-dir PATH     New output directory (must not already exist)
  --timeout-seconds N   Owned Godot process deadline (default 600)
`);
  process.exit(0);
}

const timeoutSeconds = Number(options.timeoutSeconds ?? 600);
if (!Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 1800) {
  throw new Error('--timeout-seconds must be an integer from 1 through 1800');
}
const runId = randomUUID().replaceAll('-', '').slice(0, 10);
const outputDirectory = path.resolve(options.outputDir ?? path.join(projectRoot, 'artifacts',
  'native-world-backend', `native-cave-physical-${timestamp().replace(/[:.]/g, '-')}-${runId}`));
await mkdir(path.dirname(outputDirectory), { recursive: true });
await mkdir(outputDirectory, { recursive: false });

const godot = await findGodot(options.godotExe);
const reportPath = path.join(outputDirectory, 'report.json');
const nativeLibraryPath = path.join(projectRoot,
  'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll');
const nativeBuildManifestPath = path.join(projectRoot,
  'native/terrain_meshing/build/world_backend/debug/build-manifest.json');
const nativeBuildIdentity = {
  extensionPath: nativeLibraryPath,
  extensionSha256: createHash('sha256').update(await readFile(nativeLibraryPath)).digest('hex'),
  buildManifestPath: nativeBuildManifestPath,
  buildManifestSha256: createHash('sha256').update(await readFile(nativeBuildManifestPath)).digest('hex'),
};
const processSummary = await runOwnedProcess({
  projectPath: projectRoot,
  executable: godot,
  args: ['--path', projectRoot, '--script', 'res://scripts/testing/native_world/NativeCavePhysicalFixture.gd'],
  env: { ...process.env,
    NATIVE_CAVE_PHYSICAL_OUTPUT: outputDirectory.replaceAll('\\', '/'),
    NATIVE_CAVE_PHYSICAL_REPORT: reportPath.replaceAll('\\', '/') },
  timeoutSeconds,
  stdoutPath: path.join(outputDirectory, 'godot.stdout.log'),
  stderrPath: path.join(outputDirectory, 'godot.stderr.log'),
  summaryPath: path.join(outputDirectory, 'godot.watchdog.json'),
});

let report;
try {
  report = JSON.parse(await readFile(reportPath, 'utf8'));
} catch (error) {
  throw new Error(`Native cave physical fixture did not publish ${reportPath}: ${error.message}`);
}
report.watchdog = {
  overallExitCode: processSummary.overallExitCode,
  functionalExitCode: processSummary.functionalExitCode,
  cleanupPassed: processSummary.cleanupPassed,
  authoritativeZeroProven: processSummary.authoritativeZeroProven,
  finalJobMemberPids: processSummary.finalJobMemberPids,
};
report.nativeBuildIdentity = nativeBuildIdentity;
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
const passed = processSummary.overallExitCode === 0
  && processSummary.cleanupPassed === true
  && processSummary.authoritativeZeroProven === true
  && report.passed === true;
process.stdout.write(`${JSON.stringify({
  passed,
  evidenceLevel: report.evidenceLevel,
  productionCutover: report.productionCutover,
  failures: report.failures,
  captures: report.evidence?.views?.map(view => view.screenshot).filter(Boolean) ?? [],
  report: reportPath,
  nativeBuildIdentity,
  watchdog: report.watchdog,
}, null, 2)}\n`);
if (!passed) process.exitCode = 1;
