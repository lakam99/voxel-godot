#!/usr/bin/env node

import { fileURLToPath } from 'node:url';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const execution = await runGodotProcess(await findGodot(), [
  '--headless', '--audio-driver', 'Dummy', '--path', project, '--script',
  'res://scripts/testing/native_world/StartupWorkProgressTrackerContract.gd',
], { cwd: project, timeoutSeconds: 30, env: { ...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1' } });
process.stdout.write(`${execution.stdout ?? ''}${execution.stderr ?? ''}`);
process.exitCode = execution.code === 0 ? 0 : 1;
