import fs from 'node:fs';
import path from 'node:path';
import { sha, demand, git, hashes, godotDefault, resolveExecutablePair } from './building-runner.mjs';

export function continuationSources(project) {
  const files = git(project, 'ls-files', '-z', '--cached', '--others', '--exclude-standard').toString().split('\0')
    .filter(file => file === 'project.godot' || /^(scripts|resources|scenes|shaders|addons|tools)\//.test(file) && /\.(gd|tscn|tres|gdshader|json|mjs|cs|gdextension|dll)$/.test(file));
  // Installed native libraries may be ignored by Git, but are executable input.
  const native = path.join(project, 'addons');
  const visit = directory => {
    if (!fs.existsSync(directory)) return;
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const target = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(target);
      else if (entry.isFile() && /\.(dll|gdextension)$/.test(entry.name)) files.push(target);
    }
  };
  visit(native);
  const pair = resolveExecutablePair(godotDefault);
  files.push(pair.executable, pair.runtime);
  return hashes(project, files);
}

export function auditContinuationSources(project, before) {
  const changed = [], unreadable = [];
  for (const [file, expected] of Object.entries(before)) {
    try {
      const actual = sha(path.resolve(project, file));
      if (actual !== expected) changed.push({ file, expected, actual });
    } catch (error) { unreadable.push({ file, error: error.message }); }
  }
  return { unchanged: !changed.length && !unreadable.length, changed, unreadable, count: Object.keys(before).length };
}

export function assertContinuationOrigin(report, source, input, sourceSha, inputSha) {
  demand(report?.sourceSha256 === sourceSha && report?.inputSha256 === inputSha &&
    path.resolve(report.sourcePath ?? '') === source && path.resolve(report.inputPath ?? '') === input,
  'Continuation report does not match the exact origin artifacts.');
}

export function auditContinuationInventory(project, before, inventory = continuationSources) {
  const audit = auditContinuationSources(project, before);
  audit.added = []; audit.removed = [];
  try {
    const current = inventory(project);
    audit.added = Object.keys(current).filter(file => !(file in before));
    audit.removed = Object.keys(before).filter(file => !(file in current));
  } catch (error) { audit.unreadable.push({ file: '<current-inventory>', error: error.message }); }
  audit.unchanged = !audit.changed.length && !audit.unreadable.length && !audit.added.length && !audit.removed.length;
  return audit;
}
