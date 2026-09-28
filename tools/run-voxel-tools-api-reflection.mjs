#!/usr/bin/env node
import { runVoxelToolsApiReflection } from './lib/voxel-tools-api-reflection.mjs';

const result = await runVoxelToolsApiReflection();
if (result.help) {
  process.stdout.write(`${result.help}\n`);
} else {
  process.stdout.write(`${JSON.stringify({
    passed: result.receipt.passed,
    reportPath: result.reportPath,
    probePath: result.probePath,
    validationErrors: result.receipt.validationErrors,
    ownedProcessSummaryPath: result.receipt.ownedProcess.summaryPath
  }, null, 2)}\n`);
  if (!result.receipt.passed) process.exitCode = 1;
}
