import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { buildOwnedWindowHelper, parseOwnedWindowArguments } from '../invoke-owned-game-window.mjs';

// Pure parser and fake-desktop controller tests. No action against a real window.
const base = ['-LiveOwnershipPath', 'unused.json', '-RunId', 'test-run', '-ProjectPath', '.'];
assert.equal(parseOwnedWindowArguments([...base, '--window-handle', '9007199254740993']).WindowHandle, '9007199254740993');
assert.equal(parseOwnedWindowArguments([...base, '--dx=-1000']).Dx, '-1000');
assert.throws(() => parseOwnedWindowArguments([...base, '-Key']), /Missing value/);
assert.throws(() => parseOwnedWindowArguments([...base, '-RunId', 'duplicate']), /Duplicate/);
assert.throws(() => parseOwnedWindowArguments([...base, '--unsafe']), /Unknown/);
assert.throws(() => parseOwnedWindowArguments([...base, '-WindowHandle', '1.5']), /integer/);
assert.throws(() => parseOwnedWindowArguments([]), /required/);
buildOwnedWindowHelper(); // Compile the actual production entry point too; do not run it.
const result = spawnSync(buildOwnedWindowHelper({ tests: true }), [], {
  encoding: 'utf8', windowsHide: true, shell: false, timeout: 30000,
});
if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);
assert.ifError(result.error);
assert.equal(result.status, 0, 'Synthetic owned-window controller tests failed');
const report = JSON.parse(result.stdout);
assert.equal(report.passed, true);
process.stdout.write(`Node argument validation: 7 passed; native synthetic checks: ${report.testCount} passed.\n`);
