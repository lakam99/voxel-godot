#!/usr/bin/env node
import { randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArguments, findGodot, findExecutable, projectRoot, timestamp } from './lib/voxel-tool-runtime.mjs';
import { runOwnedProcess } from './lib/owned-process.mjs';
import { runProcess } from './lib/voxel-tool-runtime.mjs';

const parsed = parseArguments(process.argv.slice(2));
const options = parsed.options;

if (options.help) {
  process.stdout.write(`Usage: node tools/run-cave-walkthrough.mjs [options]

Runs the cave SceneTree fixture in a visible Godot window, captures named
screenshots, and records a gameplay video by default.

  --godot-exe PATH       Godot console executable (or GODOT_EXE)
  --ffmpeg-exe PATH      FFmpeg executable (or FFMPEG_EXE)
  --output-dir PATH      New, empty run output directory
  --timeout-seconds N    Owned Godot process deadline (default 900)
  --seed VALUE           Requested seed (normal New Game may choose its own)
  --region-x N --region-z N  Cave recipe region to walk
  --capture-only         Capture interior viewpoints; not a traversal test
  --diagnostic           Use diagnostic boot instead of normal menu/New Game
  --record false         Skip video frames and MP4 encoding
`);
  process.exit(0);
}

const runId = randomUUID().replaceAll('-', '').slice(0, 10);
const safeTime = timestamp().replace(/[:.]/g, '-');
const outputDirectory = path.resolve(options.outputDir ?? path.join(projectRoot, 'artifacts', 'caves', `walkthrough-${safeTime}-${runId}`));
const timeoutSeconds = Number(options.timeoutSeconds ?? 900);
if (!Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 86400) throw new Error('--timeout-seconds must be an integer from 1 to 86400');
await mkdir(path.dirname(outputDirectory), { recursive: true });
await mkdir(outputDirectory, { recursive: false });

const godot = await findGodot(options.godotExe);
const record = String(options.record ?? 'true').toLowerCase() !== 'false' && String(options.record) !== '0';
const env = {
  ...process.env,
  CAVE_OUTPUT: `${outputDirectory.replaceAll('\\', '/')}/`,
  CAVE_RECORD: record ? '1' : '0',
  CAVE_CAPTURE_ONLY: options.captureOnly ? '1' : '0',
  CAVE_DIAGNOSTIC: options.diagnostic ? '1' : '0',
  VOXEL_PLAYTEST: options.seed !== undefined ? '1' : (process.env.VOXEL_PLAYTEST ?? '')
};
if (options.seed !== undefined) env.CAVE_SEED = String(options.seed);
if (options.regionX !== undefined) env.CAVE_REGION_X = String(options.regionX);
if (options.regionZ !== undefined) env.CAVE_REGION_Z = String(options.regionZ);

const processSummary = await runOwnedProcess({
  projectPath: projectRoot,
  executable: godot,
  args: ['--path', projectRoot, '--script', 'res://scripts/testing/terrain/CaveWalkthroughRunner.gd'],
  env,
  timeoutSeconds,
  stdoutPath: path.join(outputDirectory, 'godot.stdout.log'),
  stderrPath: path.join(outputDirectory, 'godot.stderr.log'),
  summaryPath: path.join(outputDirectory, 'watchdog-summary.json')
});

const reportPath = path.join(outputDirectory, 'report.json');
let report;
try {
  report = JSON.parse(await readFile(reportPath, 'utf8'));
} catch (error) {
  throw new Error(`Cave runner did not publish a readable report at ${reportPath}: ${error.message}`);
}

let videoPath = '';
if (record && Array.isArray(report.recordedFrames) && report.recordedFrames.length > 1) {
  const concatPath = path.join(outputDirectory, 'frames.ffconcat');
  videoPath = path.join(outputDirectory, 'cave-walkthrough.mp4');
  const ffmpeg = await findExecutable(options.ffmpegExe, ['FFMPEG_EXE', 'FFMPEG_BIN'], ['ffmpeg'], [], 'FFmpeg');
  const encoded = await runProcess(ffmpeg, [
    '-hide_banner', '-loglevel', 'warning', '-y', '-safe', '0', '-f', 'concat', '-i', concatPath,
    '-fps_mode', 'vfr', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', videoPath
  ], { cwd: projectRoot, timeoutSeconds: 300 });
  if (encoded.code !== 0) throw new Error(`FFmpeg failed with exit ${encoded.code}; frames remain in ${path.join(outputDirectory, 'frames')}`);
}

report.videoPath = videoPath;
report.watchdog = {
  overallExitCode: processSummary.overallExitCode,
  functionalExitCode: processSummary.functionalExitCode,
  cleanupPassed: processSummary.cleanupPassed,
  authoritativeZeroProven: processSummary.authoritativeZeroProven,
  finalJobMemberPids: processSummary.finalJobMemberPids
};
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');

const liveWalkRequired = !options.captureOnly;
const passed = processSummary.overallExitCode === 0
  && processSummary.cleanupPassed === true
  && processSummary.authoritativeZeroProven === true
  && report.passed === true
  && (!liveWalkRequired || report.liveWalkCompleted === true);
process.stdout.write(`${JSON.stringify({
  passed,
  evidenceLevel: report.evidenceLevel,
  liveWalkCompleted: report.liveWalkCompleted,
  captureOnly: report.captureOnly,
  actualSeed: report.seed,
  region: report.region,
  captures: report.captures?.map(capture => {
    const capturePath = String(capture.path).replace(/^res:\/\//, '');
    return path.isAbsolute(capturePath) ? capturePath : path.resolve(projectRoot, capturePath);
  }),
  video: videoPath,
  report: reportPath,
  watchdog: report.watchdog
}, null, 2)}\n`);
if (!passed) process.exitCode = 1;
