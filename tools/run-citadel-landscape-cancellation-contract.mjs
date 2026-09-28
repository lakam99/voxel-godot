import { cli } from './lib/building-runner.mjs';
import { runFrozen } from './lib/building-frozen.mjs';
cli(() => runFrozen('landscape', process.argv.slice(2)));
