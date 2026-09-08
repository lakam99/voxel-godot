import { cli } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
cli(() => runSpecial('npc-biped-recipe-contract', process.argv.slice(2)));
