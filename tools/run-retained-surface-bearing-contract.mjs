import { cli } from './lib/building-runner.mjs';
import { runFocused } from './lib/building-focused.mjs';
cli(() => runFocused('retained-surface-bearing-contract', process.argv.slice(2)));
