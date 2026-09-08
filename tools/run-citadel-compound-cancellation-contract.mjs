import { cli } from './lib/building-runner.mjs';
import { runFrozen } from './lib/building-frozen.mjs';
cli(() => runFrozen('compound', process.argv.slice(2)));
