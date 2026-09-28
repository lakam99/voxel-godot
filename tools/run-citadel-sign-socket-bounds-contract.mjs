import { cli } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
cli(() => runSpecial('citadel-sign-socket-bounds-contract', process.argv.slice(2)));
