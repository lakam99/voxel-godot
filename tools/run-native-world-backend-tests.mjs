#!/usr/bin/env node

import { runNativeWorldBackend } from './lib/native-world-backend-runner.mjs';

try {
  const result = await runNativeWorldBackend(process.argv.slice(2));
  process.stdout.write(`${JSON.stringify({ status: result.status, reportPath: result.reportPath }, null, 2)}\n`);
  process.exitCode = result.status === 'passed' ? 0 : 1;
} catch (error) {
  process.stderr.write(`${error.stack ?? error.message}\n`);
  process.exitCode = 1;
}
