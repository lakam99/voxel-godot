#!/usr/bin/env node
import { runScenarios, runProductionTutorial } from '../lib/npc-workflows.mjs';

if (process.argv.includes('--help')) console.log('Usage: node tools/npc/run-npc-scenario-tests.mjs [options]');
else try { console.log(JSON.stringify(await runScenarios(process.argv.slice(2)), null, 2)); }
catch (error) { console.error(error.message); process.exitCode = 1; }
