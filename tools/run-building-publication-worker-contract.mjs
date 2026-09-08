import { cli } from './lib/building-runner.mjs';
import { runFocused } from './lib/building-focused.mjs';
cli(() => runFocused('building-publication-worker-contract', process.argv.slice(2)));
