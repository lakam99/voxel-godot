import { cli } from './lib/building-runner.mjs';
import { runFocused } from './lib/building-focused.mjs';
cli(() => runFocused('building-scene-publication-contract', process.argv.slice(2)));
