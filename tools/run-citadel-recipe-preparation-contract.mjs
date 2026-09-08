import { cli } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
cli(() => runSpecial('citadel-recipe-preparation-contract', process.argv.slice(2)));
