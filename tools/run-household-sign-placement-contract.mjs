import { cli } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
cli(() => runSpecial('household-sign-placement-contract', process.argv.slice(2)));
