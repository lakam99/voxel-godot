#!/usr/bin/env node
import { runEvidenceToolMain } from './lib/evidence-cli.mjs';

await runEvidenceToolMain('test-evidence-registry-self-test');
