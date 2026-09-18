#!/usr/bin/env node
import { runN3NativeEffectiveTerrainDifferential } from './lib/n3-native-effective-terrain-differential.mjs';

try {
  const result = await runN3NativeEffectiveTerrainDifferential();
  process.stdout.write(`${JSON.stringify({
    status: result.receipt.status,
    evidenceLevel: result.receipt.evidenceLevel,
    receiptPath: result.receiptPath,
    failedChecks: result.receipt.checks.filter(check => !check.passed).map(check => check.name),
  }, null, 2)}\n`);
  process.exitCode = result.receipt.status === 'passed' ? 0 : 1;
} catch (error) {
  process.stderr.write(`${error.stack ?? error.message}\n`);
  process.exitCode = 1;
}
