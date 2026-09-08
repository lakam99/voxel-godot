#!/usr/bin/env node
import { runLegacyWorkflow } from './lib/legacy-workflow-ports.mjs';

try { await runLegacyWorkflow('run-canopy-release-playtest', process.argv.slice(2)); }
catch (error) { console.error(error.message); process.exitCode = 1; }
