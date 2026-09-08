#!/usr/bin/env node
import { mkdir, writeFile, appendFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { projectRoot, parseOptions, freshDirectory, expectedError, startCandidateWatcher, exists, sha256, helperSource, writeJson, cli } from './lib/citadel-candidate-runner.mjs';

// Exercises the very same watcher imported by the production Node wrapper.
export async function runWatcherCases(run) {
  const rows = [];
  for (const kind of ['duplicate_same_log', 'duplicate_other_log', 'unexpected_error', 'warning', 'no_allowed_error']) {
    const dir = join(run, kind);
    await mkdir(dir);
    const out = join(dir, 'stdout.log'), err = join(dir, 'stderr.log'), stop = join(dir, 'stop.txt');
    await writeFile(out, expectedError + '\n'); await writeFile(err, '');
    const watcher = startCandidateWatcher({ stdoutPath: out, stderrPath: err, stopRequestPath: stop, allowedLine: kind === 'no_allowed_error' ? '' : expectedError });
    try {
      if (kind !== 'no_allowed_error') {
        for (let poll = 0; poll < 4; poll++) {
          await delay(200);
          if (await exists(stop)) throw new Error('One header incorrectly stopped across polls.');
          await appendFile(out, 'benign trace\n');
        }
        await appendFile(kind === 'duplicate_same_log' ? out : err,
          (kind.startsWith('duplicate_') ? expectedError : kind === 'warning' ? 'WARNING: unexpected' : 'SCRIPT ERROR: unexpected') + '\n');
      }
      const deadline = performance.now() + 3000;
      while (!(await exists(stop)) && performance.now() < deadline) await delay(20);
      if (!(await exists(stop))) throw new Error('Error did not stop promptly.');
      await watcher.stop();
      if (watcher.failed) throw new Error('Error watcher failed.');
      const reason = await readFile(stop, 'utf8');
      if (kind.startsWith('duplicate_') && !reason.startsWith('Repeated inventoried engine error:')) throw new Error('Wrong duplicate stop reason.');
      rows.push({ case: kind, passed: true, reason });
    } finally { await watcher.stop(); }
  }
  return rows;
}
export async function testRecipeErrorWatcher(input, project = projectRoot) {
  const run = await freshDirectory(project, input.outputDirectory);
  const rows = await runWatcherCases(run);
  await writeJson(join(run, 'report.json'), { passed: true, checks: rows, sourceSha256: await sha256(join(project, 'tools/run-citadel-candidate-recipe-diagnostic.mjs')),
    watcherSourceSha256: await sha256(join(project, helperSource)), evidenceLevel: 'synthetic log watcher; no Godot process or recipe execution' });
  return rows;
}
await cli(import.meta.url, argv => testRecipeErrorWatcher(parseOptions(argv, 'watcher')));
