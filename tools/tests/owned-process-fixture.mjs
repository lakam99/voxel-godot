import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { runOwnedProcess } from '../lib/owned-process.mjs';

const [mode, ...args] = process.argv.slice(2);
if (mode === 'echo') {
  console.log(JSON.stringify({ args, env: process.env, cwd: process.cwd() }));
  console.error('fixture stderr');
} else if (mode === 'hold') {
  console.log(JSON.stringify({ pid: process.pid }));
  setInterval(() => {}, 1000);
} else if (mode === 'tree' || mode === 'orphan') {
  const child = spawn(process.execPath, [import.meta.filename, 'hold'], { stdio: 'ignore', detached: true });
  child.unref();
  console.log(JSON.stringify({ pid: process.pid, child: child.pid }));
  if (mode === 'tree') setInterval(() => {}, 1000);
} else if (mode === 'exit') {
  process.exit(Number(args[0]));
} else if (mode === 'orchestrator') {
  const result = await runOwnedProcess(JSON.parse(args[0]));
  writeFileSync(args[1], JSON.stringify(result));
}
