import { cli } from './lib/building-runner.mjs';
import { runFocused } from './lib/building-focused.mjs';
cli(() => runFocused('citadel-profile-snapshot-contract', process.argv.slice(2)));
