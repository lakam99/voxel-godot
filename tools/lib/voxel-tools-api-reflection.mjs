import { constants as fsConstants } from 'node:fs';
import { access, mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { findGodot, parseArguments, projectRoot } from './voxel-tool-runtime.mjs';
import { runGodotProcess } from './godot-process.mjs';

export const probeSchema = 'voxel-tools-classdb-reflection/v1';
export const receiptSchema = 'voxel-tools-api-reflection-receipt/v1';
export const absenceInterpretation = 'An unobserved candidate means only that no matching member was present in the reflected ClassDB surface of the installed library loaded by this Godot process. It is not proof of universal impossibility: a capability may exist outside ClassDB, under another name or composition, in another build/configuration, or in another plugin or engine version.';

const requiredClasses = [
  'VoxelTerrain', 'VoxelViewer', 'VoxelBuffer', 'VoxelGenerator',
  'VoxelGeneratorScript', 'VoxelStream', 'VoxelStreamScript', 'VoxelTool'
];

export const projectIdentityFiles = [
  'scripts/testing/native_world/VoxelToolsApiReflectionProbe.gd',
  'scripts/terrain/VoxelTerrainRuntime.gd',
  'tools/native/OwnedProcessNative.cs',
  'tools/native/OwnedProcessHost.cs',
  'addons/zylann.voxel/voxel.gdextension',
  'addons/zylann.voxel/LICENSE.md',
  'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
  'native/terrain_meshing/godot-cpp-revision.txt'
];

export const projectModuleEntrypoints = [
  'tools/run-voxel-tools-api-reflection.mjs',
  'tools/tests/voxel-tools-api-reflection.test.mjs'
];

const binaryFiles = [
  ['voxelToolsEditor', 'addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll'],
  ['voxelToolsRelease', 'addons/zylann.voxel/bin/libvoxel.windows.template_release.x86_64.dll'],
  ['terrainMeshingDebug', 'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll'],
  ['terrainMeshingRelease', 'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_release.x86_64.dll']
];

const nativeWorldBackendManifestSchema = 'native-world-backend-source-manifest/v1';
const nativeWorldBackendManifestGroups = {
  coreSources: { prefix: 'core/', extensions: new Set(['.c', '.cc', '.cpp']) },
  coreHeaders: { prefix: 'core/', extensions: new Set(['.h', '.hpp']) },
  testSources: { prefix: 'tests/', extensions: new Set(['.c', '.cc', '.cpp']) },
  testHeaders: { prefix: 'tests/', extensions: new Set(['.h', '.hpp']) }
};

function normalizedRelative(file) {
  return relative(projectRoot, file).replaceAll('\\', '/');
}

export async function exists(file) {
  try {
    await access(file, fsConstants.F_OK);
    return true;
  } catch {
    return false;
  }
}

export async function sha256File(file) {
  return createHash('sha256').update(await readFile(file)).digest('hex');
}

async function fileReceipt(file, id = undefined) {
  const info = await stat(file);
  if (!info.isFile()) throw new Error(`Identity input is not a file: ${file}`);
  return {
    ...(id ? { id } : {}),
    path: normalizedRelative(file),
    bytes: info.size,
    sha256: await sha256File(file)
  };
}

export async function discoverProjectLocalModuleClosure(entries = projectModuleEntrypoints) {
  const root = resolve(projectRoot);
  const rootPrefix = `${root}${sep}`.toLowerCase();
  const pending = [...entries];
  const discovered = new Set();
  while (pending.length > 0) {
    const configured = pending.pop().replaceAll('\\', '/');
    if (discovered.has(configured)) continue;
    const file = resolve(root, configured);
    if (!file.toLowerCase().startsWith(rootPrefix)) throw new Error(`Module identity path escaped project root: ${configured}`);
    const info = await stat(file);
    if (!info.isFile()) throw new Error(`Module identity input is not a file: ${configured}`);
    discovered.add(configured);
    const source = await readFile(file, 'utf8');
    const imports = /(?:\bfrom\s*|\bimport\s*\()\s*(['"])(\.[^'"]+)\1/g;
    for (const match of source.matchAll(imports)) {
      let imported = resolve(dirname(file), match[2]);
      if (!extname(imported)) imported += '.mjs';
      if (!imported.toLowerCase().startsWith(rootPrefix)) throw new Error(`Local module import escaped project root: ${match[2]} from ${configured}`);
      pending.push(relative(root, imported).replaceAll('\\', '/'));
    }
  }
  return [...discovered].sort();
}

async function collectNativeSources(directory, root = directory) {
  const rows = [];
  const entries = await readdir(directory, { withFileTypes: true });
  entries.sort((left, right) => left.name.localeCompare(right.name));
  for (const entry of entries) {
    if (['.git', 'bin', 'build', 'godot-cpp', 'toolchains'].includes(entry.name)) continue;
    const file = join(directory, entry.name);
    if (entry.isDirectory()) {
      rows.push(...await collectNativeSources(file, root));
      continue;
    }
    if (!entry.isFile()) continue;
    const extension = extname(entry.name).toLowerCase();
    if (!['', '.c', '.cc', '.cpp', '.h', '.hpp', '.in', '.md', '.py', '.txt'].includes(extension)) continue;
    const receipt = await fileReceipt(file);
    receipt.path = relative(root, file).replaceAll('\\', '/');
    rows.push(receipt);
  }
  return rows;
}

async function discoverNativeWorldBackendSources(directory, root = directory) {
  const paths = [];
  const entries = await readdir(directory, { withFileTypes: true });
  entries.sort((left, right) => left.name.localeCompare(right.name));
  for (const entry of entries) {
    const file = join(directory, entry.name);
    if (entry.isDirectory()) {
      if (['core', 'tests'].includes(entry.name) || resolve(directory) !== resolve(root)) {
        paths.push(...await discoverNativeWorldBackendSources(file, root));
      }
      continue;
    }
    if (!entry.isFile()) continue;
    if (!['.c', '.cc', '.cpp', '.h', '.hpp'].includes(extname(entry.name).toLowerCase())) continue;
    paths.push(relative(root, file).replaceAll('\\', '/'));
  }
  return paths.sort();
}

export function validateNativeWorldBackendManifest(manifest, discoveredPaths) {
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) throw new Error('Native world backend source manifest is not an object.');
  if (manifest.schema !== nativeWorldBackendManifestSchema) throw new Error(`Unexpected native world backend source manifest schema: ${manifest.schema ?? '<missing>'}`);
  const declared = [];
  for (const [group, policy] of Object.entries(nativeWorldBackendManifestGroups)) {
    const entries = manifest[group];
    if (!Array.isArray(entries)) throw new Error(`Native world backend source manifest is missing array ${group}.`);
    for (const value of entries) {
      if (typeof value !== 'string') throw new Error(`Native world backend manifest path in ${group} is not a string.`);
      const path = value;
      const segments = path.split('/');
      if (!path.startsWith(policy.prefix) || path.includes('\\') || isAbsolute(path) || /^[A-Za-z]:/.test(path)
          || segments.some(segment => !segment || segment === '.' || segment === '..')) {
        throw new Error(`Invalid native world backend manifest path in ${group}: ${path}`);
      }
      if (!policy.extensions.has(extname(path).toLowerCase())) {
        throw new Error(`Unexpected extension for native world backend manifest path in ${group}: ${path}`);
      }
      declared.push(path);
    }
  }
  const sortedDeclared = [...declared].sort();
  if (new Set(sortedDeclared).size !== sortedDeclared.length) throw new Error('Native world backend source manifest contains duplicate paths.');
  const sortedDiscovered = [...discoveredPaths].sort();
  if (JSON.stringify(sortedDeclared) !== JSON.stringify(sortedDiscovered)) {
    const declaredSet = new Set(sortedDeclared);
    const discoveredSet = new Set(sortedDiscovered);
    const missingFromManifest = sortedDiscovered.filter(path => !declaredSet.has(path));
    const missingFromDisk = sortedDeclared.filter(path => !discoveredSet.has(path));
    throw new Error(`Native world backend source manifest mismatch: unmanifested=${JSON.stringify(missingFromManifest)} missing=${JSON.stringify(missingFromDisk)}`);
  }
  return sortedDeclared;
}

async function nativeWorldBackendIdentity() {
  const root = resolve(projectRoot, 'native/world_backend');
  const manifestPath = join(root, 'source-manifest.json');
  if (!(await exists(manifestPath))) throw new Error(`Missing native world backend source manifest: ${manifestPath}`);
  const manifest = JSON.parse((await readFile(manifestPath, 'utf8')).replace(/^\uFEFF/, ''));
  const discovered = await discoverNativeWorldBackendSources(root);
  const declared = validateNativeWorldBackendManifest(manifest, discovered);
  const rootPrefix = `${resolve(root)}${sep}`.toLowerCase();
  const sources = [];
  for (const configured of declared) {
    const file = resolve(root, configured);
    if (!file.toLowerCase().startsWith(rootPrefix)) throw new Error(`Native world backend manifest path escaped its root: ${configured}`);
    const receipt = await fileReceipt(file);
    receipt.path = configured;
    sources.push(receipt);
  }
  const manifestReceipt = await fileReceipt(manifestPath);
  manifestReceipt.path = 'source-manifest.json';
  return {
    manifest: manifestReceipt,
    manifestSchema: manifest.schema,
    manifestComplete: true,
    coreCoverageDenominator: [...manifest.coreSources].sort(),
    discoveredPaths: discovered,
    sources,
    aggregateSha256: aggregateReceipts([manifestReceipt, ...sources])
  };
}

function aggregateReceipts(rows) {
  const canonical = rows
    .map(row => `${row.id ?? ''}\0${row.path}\0${row.bytes}\0${row.sha256}\n`)
    .join('');
  return createHash('sha256').update(canonical).digest('hex');
}

export function engineSiblingPath(godotLauncher) {
  if (process.platform !== 'win32') return godotLauncher;
  const name = basename(godotLauncher);
  if (!/_console\.exe$/i.test(name)) return godotLauncher;
  return join(dirname(godotLauncher), name.replace(/_console\.exe$/i, '.exe'));
}

function git(args) {
  const result = spawnSync('git', ['-C', projectRoot, ...args], { encoding: 'utf8' });
  if (result.status !== 0) return '';
  return result.stdout.trim();
}

export async function buildIdentity(godotLauncher) {
  const projectSources = [];
  const moduleClosure = await discoverProjectLocalModuleClosure();
  for (const configured of [...projectIdentityFiles, ...moduleClosure]) {
    projectSources.push(await fileReceipt(resolve(projectRoot, configured)));
  }
  const nativeSources = await collectNativeSources(resolve(projectRoot, 'native/terrain_meshing'));
  const nativeWorldBackend = await nativeWorldBackendIdentity();
  const binaries = [];
  for (const [id, configured] of binaryFiles) {
    binaries.push(await fileReceipt(resolve(projectRoot, configured), id));
  }
  binaries.push(await fileReceipt(godotLauncher, 'godotConsoleLauncher'));
  const engine = engineSiblingPath(godotLauncher);
  if (resolve(engine) !== resolve(godotLauncher)) {
    binaries.push(await fileReceipt(engine, 'godotEngine'));
  }
  const projectSourceAggregateSha256 = aggregateReceipts(projectSources);
  const nativeSourceAggregateSha256 = aggregateReceipts(nativeSources);
  const binaryAggregateSha256 = aggregateReceipts(binaries);
  return {
    git: {
      head: git(['rev-parse', 'HEAD']),
      tree: git(['rev-parse', 'HEAD^{tree}']),
      statusShort: git(['status', '--short'])
    },
    dependency: {
      project: 'Zylann/godot_voxel',
      releaseTag: 'v1.6x',
      archiveSha256: 'dfee985a0cff7059a31ada665e88a634fdcc3eab51f83fe5f6dd48939dd5372a',
      sourceVendored: false,
      sourceLimit: 'This checkout contains the installed binary distribution, descriptor, license, and assets, not the complete Voxel Tools C++ source tree.'
    },
    projectSources,
    nativeTerrainMeshingSources: nativeSources,
    nativeWorldBackendManifest: nativeWorldBackend.manifest,
    nativeWorldBackendManifestSchema: nativeWorldBackend.manifestSchema,
    nativeWorldBackendManifestComplete: nativeWorldBackend.manifestComplete,
    nativeWorldBackendCoreCoverageDenominator: nativeWorldBackend.coreCoverageDenominator,
    nativeWorldBackendDiscoveredPaths: nativeWorldBackend.discoveredPaths,
    nativeWorldBackendSources: nativeWorldBackend.sources,
    binaries,
    projectSourceAggregateSha256,
    nativeSourceAggregateSha256,
    nativeWorldBackendSourceAggregateSha256: nativeWorldBackend.aggregateSha256,
    binaryAggregateSha256,
    observedInputAggregateSha256: createHash('sha256').update([
      projectSourceAggregateSha256,
      nativeSourceAggregateSha256,
      nativeWorldBackend.aggregateSha256,
      binaryAggregateSha256
    ].join('\0')).digest('hex')
  };
}

export async function prepareEvidencePaths(configuredReportPath = '') {
  let reportPath;
  if (configuredReportPath) {
    reportPath = isAbsolute(configuredReportPath)
      ? resolve(configuredReportPath)
      : resolve(projectRoot, configuredReportPath);
    await mkdir(dirname(reportPath), { recursive: true });
  } else {
    const parent = resolve(projectRoot, 'artifacts/native-world-backend/n1-api-reflection');
    await mkdir(parent, { recursive: true });
    const label = `${new Date().toISOString().replaceAll(':', '').replaceAll('.', '-')}-${randomUUID().slice(0, 8)}`;
    const directory = join(parent, label);
    await mkdir(directory, { recursive: false });
    reportPath = join(directory, 'report.json');
  }
  const probePath = join(dirname(reportPath), `${basename(reportPath, extname(reportPath))}.probe.json`);
  for (const file of [reportPath, probePath]) {
    if (await exists(file)) throw new Error(`Refusing to overwrite existing API reflection evidence: ${file}`);
  }
  return { reportPath, probePath };
}

export function validateProbeReport(report, expectedRunToken, expectedIdentityDigest) {
  const errors = [];
  if (!report || typeof report !== 'object' || Array.isArray(report)) errors.push('report_not_an_object');
  if (report?.schema !== probeSchema) errors.push('schema_mismatch');
  if (report?.runnerId !== 'voxel_tools_api_reflection_probe') errors.push('runner_id_mismatch');
  if (report?.finished !== true) errors.push('probe_not_finished');
  if (report?.passed !== true) errors.push('probe_not_passed');
  if (report?.runToken !== expectedRunToken) errors.push('run_token_mismatch');
  if (report?.absenceInterpretation !== absenceInterpretation) errors.push('absence_interpretation_missing_or_broadened');
  if (report?.providedIdentity?.observedInputAggregateSha256 !== expectedIdentityDigest) errors.push('input_identity_mismatch');
  const classInventory = Array.isArray(report?.classes) ? report.classes : [];
  if (!Array.isArray(report?.classes)) errors.push('class_inventory_missing');
  const byName = new Map(classInventory.map(record => [record.name, record]));
  for (const className of requiredClasses) {
    const record = byName.get(className);
    if (!record?.exists) errors.push(`required_class_missing:${className}`);
    for (const scope of ['declared', 'includingInherited']) {
      for (const memberKind of ['methods', 'properties', 'signals', 'integerConstants', 'enums']) {
        if (!Array.isArray(record?.[scope]?.[memberKind])) errors.push(`member_inventory_missing:${className}:${scope}:${memberKind}`);
      }
    }
  }
  if (!Array.isArray(report?.capabilityCandidateObservations) || report.capabilityCandidateObservations.length < 4) {
    errors.push('capability_observations_missing');
  } else {
    for (const observation of report.capabilityCandidateObservations) {
      if (observation.interpretation !== absenceInterpretation) errors.push(`capability_interpretation_missing:${observation.id ?? 'unknown'}`);
      if (!['observed_in_reflected_classdb_surface', 'not_observed_in_reflected_classdb_surface'].includes(observation.exactCandidateObservation)) {
        errors.push(`capability_observation_invalid:${observation.id ?? 'unknown'}`);
      }
    }
  }
  return errors;
}

export async function runVoxelToolsApiReflection(rawArgs = process.argv.slice(2)) {
  const parsed = parseArguments(rawArgs);
  if (parsed.options.help) {
    return {
      help: 'Usage: node tools/run-voxel-tools-api-reflection.mjs [--godot-exe PATH] [--report-path FRESH_PATH] [--timeout-seconds 60]'
    };
  }
  const { reportPath, probePath } = await prepareEvidencePaths(String(parsed.options.reportPath ?? ''));
  const godot = await findGodot(parsed.options.godotExe);
  const identityBefore = await buildIdentity(godot);
  const runToken = randomUUID().replaceAll('-', '');
  const providedIdentity = {
    observedInputAggregateSha256: identityBefore.observedInputAggregateSha256,
    gitHead: identityBefore.git.head,
    binarySha256: Object.fromEntries(identityBefore.binaries.map(record => [record.id, record.sha256]))
  };
  const execution = await runGodotProcess(godot, [
    '--headless', '--audio-driver', 'Dummy', '--path', projectRoot,
    '--script', 'res://scripts/testing/native_world/VoxelToolsApiReflectionProbe.gd'
  ], {
    env: {
      ...process.env,
      VOXEL_DISABLE_AUDIO_PLAYBACK: '1',
      VOXEL_TOOLS_API_PROBE_REPORT: probePath,
      VOXEL_TOOLS_API_PROBE_RUN_TOKEN: runToken,
      VOXEL_TOOLS_API_PROBE_IDENTITY_JSON: JSON.stringify(providedIdentity)
    },
    timeoutSeconds: Number(parsed.options.timeoutSeconds ?? 60),
    workTimeoutSeconds: Number(parsed.options.timeoutSeconds ?? 60),
    reportPath: probePath,
    expectedRunToken: runToken,
    stdio: 'ignore'
  });
  if (!(await exists(probePath))) throw new Error(`Voxel Tools API probe did not produce a report: ${probePath}`);
  const probeBytes = await readFile(probePath);
  const probe = JSON.parse(probeBytes.toString('utf8').replace(/^\uFEFF/, ''));
  const identityAfter = await buildIdentity(godot);
  const validationErrors = validateProbeReport(probe, runToken, identityBefore.observedInputAggregateSha256);
  if (identityAfter.observedInputAggregateSha256 !== identityBefore.observedInputAggregateSha256) {
    validationErrors.push('observed_source_or_binary_changed_during_probe');
  }
  const runtimeHash = String(probe?.godot?.runtimeExecutableSha256 ?? '').toLowerCase();
  const launchedHashes = new Set(identityAfter.binaries
    .filter(record => ['godotConsoleLauncher', 'godotEngine'].includes(record.id))
    .map(record => record.sha256.toLowerCase()));
  if (!launchedHashes.has(runtimeHash)) validationErrors.push('runtime_executable_identity_not_in_launch_manifest');
  if (execution.code !== 0) validationErrors.push(`owned_process_failed:${execution.code}`);
  if (!execution.summary?.cleanupPassed || !execution.summary?.authoritativeZeroProven) {
    validationErrors.push('owned_process_cleanup_not_authoritative_zero');
  }
  const receipt = {
    schema: receiptSchema,
    runnerId: 'run_voxel_tools_api_reflection',
    finished: true,
    passed: validationErrors.length === 0,
    validationErrors,
    observationScope: 'Installed Voxel Tools editor/debug GDExtension loaded by this Godot process; read-only ClassDB reflection only.',
    absenceInterpretation,
    evidenceLimits: [
      'This does not invoke candidate APIs, install collision, mutate gameplay, or prove physics/rendering behavior.',
      'ClassDB absence is not universal API impossibility and does not cover non-ClassDB C++ entry points or other builds/versions.',
      'The release DLL is hashed for identity but this headless editor run reflects the editor/debug library selected by Godot.'
    ],
    reportPath: normalizedRelative(reportPath),
    probeReport: {
      path: normalizedRelative(probePath),
      bytes: probeBytes.length,
      sha256: createHash('sha256').update(probeBytes).digest('hex')
    },
    identity: identityAfter,
    ownedProcess: {
      summaryPath: normalizedRelative(execution.summaryPath),
      summary: execution.summary
    },
    probe
  };
  await writeFile(reportPath, `${JSON.stringify(receipt, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
  return { receipt, reportPath, probePath };
}
