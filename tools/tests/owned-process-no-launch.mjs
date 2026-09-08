// Test-only preload: help must never attempt to compile or launch any process.
import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
for (const name of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) {
  childProcess[name] = () => { throw new Error('Launch-free help attempted ' + name); };
}
syncBuiltinESMExports();
