import { cli } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
cli(() => runSpecial('citadel-structural-composer-two-phase-contract', process.argv.slice(2)));
