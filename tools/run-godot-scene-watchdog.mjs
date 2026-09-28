#!/usr/bin/env node
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { runOwnedProcess } from './lib/owned-process.mjs';
export { runOwnedProcess } from './lib/owned-process.mjs';

const fields = ['projectPath', 'executable', 'godotExe', 'scene', 'timeoutSeconds',
  'cleanupGraceMilliseconds', 'finalCleanupTimeoutMilliseconds', 'stdoutPath',
  'stderrPath', 'summaryPath', 'stopRequestPath', 'liveOwnershipPath', 'headless',
  'sceneArguments', 'args', 'env'];
const normalize = name => name.replace(/^-+/, '').replaceAll('-', '').toLowerCase();
const names = new Map(fields.map(name => [normalize(name), name]));

export function parseWatchdogArguments(argv) {
  const options = {}, rest = [];
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (token === '--') { rest.push(...argv.slice(i + 1)); break; }
    if (/^--?help$/i.test(token)) return { help: true };
    const match = /^(-{1,2}[^=:]+)(?:[=:](.*))?$/.exec(token);
    const name = match && names.get(normalize(match[1]));
    if (!name) {
      if (options.scene) { rest.push(token); continue; }
      throw new Error('Unknown watchdog argument: ' + token);
    }
    if (name === 'headless') {
      const v = match[2];
      if (v !== undefined && !/^(true|false|\$true|\$false)$/i.test(v)) throw new Error('Invalid headless boolean');
      options.headless = v === undefined || /^(true|\$true)$/i.test(v);
    } else if (name === 'sceneArguments' || name === 'args') {
      if (match[2] !== undefined) rest.push(...JSON.parse(match[2]));
      else { rest.push(...argv.slice(i + 1)); break; }
    } else {
      const value = match[2] ?? argv[++i];
      if (value === undefined) throw new Error('Missing value for ' + token);
      options[name] = name === 'env' ? JSON.parse(value) : value;
    }
  }
  options.executable ??= options.godotExe;
  if (options.scene) {
    options.sceneArguments = rest;
    options.args = [...(options.headless ? ['--headless'] : []),
      '--path', path.resolve(options.projectPath || process.cwd()), options.scene, ...rest];
  } else options.args = rest;
  return options;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const options = parseWatchdogArguments(process.argv.slice(2));
    if (options.help) {
      console.log(`Usage: node tools/run-godot-scene-watchdog.mjs [options] -- [child arguments]

Generic process: --executable PATH [--project-path DIR] -- ARGS...
Godot scene: -GodotExe PATH -ProjectPath DIR -Scene res://scene.tscn [-Headless]

--timeout-seconds N                  Integer 0..86400; default 300; 0 disables deadline
--cleanup-grace-milliseconds N       Default 2000
--final-cleanup-timeout-milliseconds N  Default 30000
--stdout-path PATH --stderr-path PATH --summary-path PATH
--stop-request-path PATH --live-ownership-path PATH
--env JSON                          Complete child environment map
--help, -Help                        Show help without launching or compiling

Camelcase, kebab-case and PowerShell-style option names are accepted.
Output paths must be unique and nonexistent. Results separate functional exit
from owned-process cleanup; forced cleanup is nonzero even after root success.`);
    } else {
      const result = await runOwnedProcess(options);
      console.log(JSON.stringify(result));
      process.exitCode = result.overallExitCode;
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 127;
  }
}
