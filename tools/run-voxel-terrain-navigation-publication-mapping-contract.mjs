#!/usr/bin/env node
import { access, mkdir, readFile, rm } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { dirname, isAbsolute, resolve } from 'node:path';
import { findGodot, parseArguments, projectRoot } from './lib/voxel-tool-runtime.mjs';
import { runGodotProcess } from './lib/godot-process.mjs';

const parsed = parseArguments(process.argv.slice(2));
const configured = String(parsed.options.reportPath ?? 'artifacts/test-runners/voxel-terrain-navigation-publication-mapping.json');
const reportPath = isAbsolute(configured) ? configured : resolve(projectRoot, configured);
await mkdir(dirname(reportPath), { recursive: true });
await rm(reportPath, { force: true });
const godot = await findGodot(parsed.options.godotExe);
const execution = await runGodotProcess(godot, [
  '--headless', '--path', projectRoot,
  '--script', 'res://scripts/testing/terrain/VoxelTerrainNavigationPublicationMappingContract.gd'
], {
  env: { ...process.env, VOXEL_TERRAIN_NAV_MAPPING_REPORT: reportPath },
  timeoutSeconds: Number(parsed.options.timeoutSeconds ?? 120)
});
try {
  await access(reportPath, fsConstants.F_OK);
} catch {
  throw new Error(`Missing terrain-navigation mapping report: ${reportPath}`);
}
const report = JSON.parse(await readFile(reportPath, 'utf8'));
process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
if (execution.code !== 0 || !report.passed) process.exitCode = 1;
