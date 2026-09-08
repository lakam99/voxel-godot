import { validateEvidence } from './evidence-validation.mjs';
import { runEvidenceRegistrySelfTest } from './evidence-self-test.mjs';

const names = [
  'reportPath', 'runnerId', 'evidenceLevel', 'acceptanceClaims',
  'requiredScreenshots', 'screenshotDir', 'registryPath',
  'requireForbiddenCallSelfScan', 'requireVisualProof',
];
const switches = new Set(['requireForbiddenCallSelfScan', 'requireVisualProof']);
const normalize = (name) => name.replace(/-/g, '').toLowerCase();

export function parseEvidenceArguments(args, allowedNames = names) {
  const options = {};
  for (let i = 0; i < args.length; i += 1) {
    const match = /^--?([^=:]+)(?:[=:](.*))?$/.exec(args[i]);
    const name = match && allowedNames.find((candidate) => normalize(candidate) === normalize(match[1]));
    if (!name) throw new Error(`Unknown evidence argument: ${args[i]}`);
    if (Object.hasOwn(options, name)) throw new Error(`Duplicate evidence argument: ${name}`);
    if (switches.has(name)) {
      let value = match[2];
      if (value === undefined && /^(true|false|\$true|\$false|0|1)$/i.test(args[i + 1] ?? '')) {
        value = args[++i];
      }
      if (value !== undefined && !/^(true|false|\$true|\$false|0|1)$/i.test(value)) {
        throw new Error(`Invalid switch value for ${name}: ${value}`);
      }
      options[name] = value === undefined || /^(true|\$true|1)$/i.test(value);
    } else {
      const value = match[2] ?? args[++i];
      if (value === undefined || /^--?[A-Za-z]/.test(value)) {
        throw new Error(`Missing value for ${name}`);
      }
      options[name] = value;
    }
  }
  return options;
}

/**
 * Static dispatch hook: returns false for unrelated IDs, true when handled.
 * Errors propagate to the caller's normal CLI error handler. A failed self-test
 * throws after writing/printing its report. Never launches Godot.
 */
export async function runEvidenceStaticTool(toolId, rawArgs, context = {}) {
  let result;
  if (toolId === 'assert-test-evidence-report') {
    result = await validateEvidence(parseEvidenceArguments(rawArgs), context);
  } else if (toolId === 'test-evidence-registry-self-test') {
    result = await runEvidenceRegistrySelfTest(parseEvidenceArguments(rawArgs, ['reportPath']), context);
  } else {
    return false;
  }
  (context.stdout ?? process.stdout).write(JSON.stringify(result, null, 2) + '\n');
  if (result.passed === false) throw new Error(`Evidence registry self-test failed: ${result.failureCount} case(s)`);
  return true;
}

export async function runEvidenceToolMain(toolId, args = process.argv.slice(2)) {
  if(args.some(arg=>/^(--?help|-h)$/i.test(arg))) { console.log(`Usage: node tools/${toolId}.mjs --report-path PATH${toolId==='assert-test-evidence-report'?' --runner-id ID --evidence-level LEVEL [--required-screenshots FILES] [--screenshot-dir PATH]':''}`);return; }
  try {
    if (!(await runEvidenceStaticTool(toolId, args))) throw new Error(`Unknown evidence tool: ${toolId}`);
  } catch (error) {
    process.stderr.write(error.message + '\n');
    process.exitCode = 1;
  }
}
