import { cli } from './lib/building-runner.mjs';
import { runFocused } from './lib/building-focused.mjs';
cli(() => runFocused('citadel-town-inputs-contract', process.argv.slice(2)));
