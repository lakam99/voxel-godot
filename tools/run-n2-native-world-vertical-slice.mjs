#!/usr/bin/env node
import { runN2NativeWorldVerticalSlice } from './lib/n2-native-world-vertical-slice.mjs';

try {
  const result = await runN2NativeWorldVerticalSlice();
  process.stdout.write(`${JSON.stringify({ status: result.receipt.status, receiptPath: result.receiptPath,
    reason: result.receipt.fixture?.value?.reason ?? null }, null, 2)}\n`);
  process.exitCode = result.receipt.status === 'passed' ? 0 : 1;
} catch (error) {
  process.stderr.write(`${error.stack ?? error.message}\n`);
  process.exitCode = 1;
}
