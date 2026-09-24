import { createHash, randomUUID } from 'node:crypto';
import { constants as fsConstants, existsSync } from 'node:fs';
import { access, cp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { runOwnedProcess } from './owned-process.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const defaultProject = resolve(here, '..', '..');
const llvmVersion = '23.1.1';
const llvmResourceDirVersion = '23';
const llvmArchiveName = `clang+llvm-${llvmVersion}-x86_64-pc-windows-msvc.tar.zst`;
const llvmArchiveUrl = `https://github.com/llvm/llvm-project/releases/download/llvmorg-${llvmVersion}/clang%2Bllvm-${llvmVersion}-x86_64-pc-windows-msvc.tar.zst`;
const llvmArchiveSha256 = 'c8a12d754b5050c5668b56a5425c806792d46c70f7244b1216046164aa4b6462';
const llvmArchiveBytes = 489740247;
const godotCppLicenseSha256 = '26a5b210d90760156ce886267ce9df235787dcc6cebfd7ecd95ef5b6fdcc95bf';
const llvmExpectedHashes = {
  clangCl: 'd43b7fa07b5b77b716e60600ad2792cfb2eeb370aecb6144bf6c698f2c6d7467',
  llvmProfdata: 'f91486f965caf0f83d71160c9d1b69c7ccef9897339d25e362383b80e7a5dbbe',
  llvmCov: '59b350ca719d03683e625b366ba0806e33e6effe7836116ced9200a29a59ac70',
  profileRuntime: '7753d4b1280faad4dc69df3317e5dbb700f47a5e822e17712e96c13945fd386c',
  licenseFile: '54cbc326a78b9400065bfc5830a57fdcdaf808286d4ac35d8a9e324aa77b7241',
};
export const expectedToolchainLockValue = {
  schema: 'native-world-backend-toolchain-lock/v1',
  godotCpp: {
    revisionFile: '../terrain_meshing/godot-cpp-revision.txt', license: 'MIT',
    licenseFile: '../terrain_meshing/godot-cpp/LICENSE.md', licenseSha256: godotCppLicenseSha256,
  },
  fastNoiseLite: {
    engineCommitSha: '14d19694e0c88a3f9e82d899a0400f27a24c176e',
    upstreamVersion: '1.1.0', upstreamCommitSha: 'f7af54b56518aa659e1cf9fb103c0b6e36a833d9',
    license: 'MIT', licenseFile: 'core/thirdparty/fast_noise_lite/LICENSE',
    licenseSha256: 'c08da3239b919c12f4ec616b457a8dd0fc923c8102c8a742c4006fcb5de28fb0',
    patchedHeaderFile: 'core/thirdparty/fast_noise_lite/FastNoiseLite.h',
    patchedHeaderSha256: '38b24b9b04aa5e9f1e63336d4acbbbb73b11f15b697bb08a25f5ec0c6c274901',
    godotPatchSha256: '123ec6a215a20154b5f33c0f63d04e1442fa6d98db0ddca4fa2960d0c3354a7c',
    upstreamHeaderSha256: '3faf87ccfa1b46a2d5af402ba0439a13a73a3e567b80c375be1dcf700d86fc6e',
  },
  msvc: {
    compilerVersion: '19.44.35228', linkerVersion: '14.44.35228.0', toolsetVersion: '14.44.35207',
    sconsProductVersion: '14.3', hostArchitecture: 'x64', targetArchitecture: 'amd64',
    vcvarsArgs: '-vcvars_ver=14.44.35207',
    vcvars64Sha256: '6b516d8fcf543c14b2d861e1f45661e0029230fe0dc48e86ce78522801822209',
    clSha256: '88c8344236a27a6e727e0a8edc49aaa2690bdc7a9464b9d18cc7abe70a9f1c0d',
    linkSha256: 'ca11e6c45debd34bf652dfe984c5360a531a005ed78bf72852330c9c2590cf0d',
  },
  godot: {
    version: '4.6.1.stable.official.14d19694e', major: 4, minor: 6, patch: 1,
    status: 'stable', hash: '14d19694e',
    engineCommitSha: '14d19694e0c88a3f9e82d899a0400f27a24c176e',
    consoleSha256: 'bd9e27c6994a128aaab45cdda4d372de87b91900618ba2de55c6aa29248d5b56',
    windowsReleaseX8664TemplateBytes: 104576512,
    windowsReleaseX8664TemplateSha256: '6a0266cb7571aa4d437a32094acd353f020c77dcf7ff5a3305ae45d0609e5c20',
  },
  llvmCoverage: {
    version: llvmVersion, resourceDirVersion: llvmResourceDirVersion, platform: 'x86_64-pc-windows-msvc',
    archive: llvmArchiveName,
    url: `https://github.com/llvm/llvm-project/releases/download/llvmorg-${llvmVersion}/clang+llvm-${llvmVersion}-x86_64-pc-windows-msvc.tar.zst`,
    bytes: llvmArchiveBytes, sha256: llvmArchiveSha256, license: 'Apache-2.0 WITH LLVM-exception',
    licenseFile: 'include/llvm/Support/LICENSE.TXT', licenseSha256: llvmExpectedHashes.licenseFile,
    toolSha256: {
      clangCl: llvmExpectedHashes.clangCl, llvmProfdata: llvmExpectedHashes.llvmProfdata,
      llvmCov: llvmExpectedHashes.llvmCov, profileRuntime: llvmExpectedHashes.profileRuntime,
    },
  },
};

export function validateToolchainLockValue(value) {
  if (!isDeepStrictEqual(value, expectedToolchainLockValue)) {
    throw new Error('Native world backend toolchain lock does not exactly match the compiled-in N1 pins.');
  }
  return value;
}

function normalizedBranchDetails(file) {
  const normalized = new Map();
  for (const branch of file.branches ?? []) {
    if (!Array.isArray(branch) || branch.length < 9) throw new Error('Unexpected LLVM branch tuple schema.');
    const trueCount = Number(branch[4]);
    const falseCount = Number(branch[5]);
    if (!Number.isSafeInteger(trueCount) || !Number.isSafeInteger(falseCount)
        || trueCount < 0 || falseCount < 0) {
      throw new Error('Invalid LLVM branch true/false-edge counts.');
    }
    const identity = [branch[0], branch[1], branch[2], branch[3], branch[6], branch[7], branch[8]].join(':');
    const detail = normalized.get(identity) ?? {
      line: Number(branch[0]), column: Number(branch[1]), trueCount: 0, falseCount: 0,
    };
    detail.trueCount += trueCount;
    detail.falseCount += falseCount;
    normalized.set(identity, detail);
  }
  return [...normalized.values()];
}

function parse(argv) {
  const options = {};
  for (let index = 0; index < argv.length; ++index) {
    const argument = argv[index];
    if (!argument.startsWith('--')) throw new Error(`Unexpected positional argument: ${argument}`);
    const equals = argument.indexOf('=');
    const rawName = argument.slice(2, equals < 0 ? undefined : equals);
    const name = rawName.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    if (equals >= 0) options[name] = argument.slice(equals + 1);
    else if (argv[index + 1] !== undefined && !argv[index + 1].startsWith('--')) options[name] = argv[++index];
    else options[name] = true;
  }
  return options;
}

export function coverageExecutionTimeoutMilliseconds(options = {}) {
  const raw = options.coverageExecuteTimeoutMs === undefined
    ? 120000 : options.coverageExecuteTimeoutMs;
  if ((typeof raw !== 'number' && typeof raw !== 'string')
      || (typeof raw === 'string' && !/^\d+$/.test(raw))) {
    throw new Error('coverageExecuteTimeoutMs must be an integer number of milliseconds.');
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1000 || value > 900000 || value % 1000 !== 0) {
    throw new Error('coverageExecuteTimeoutMs must be a whole-second value from 1000 through 900000.');
  }
  return value;
}

async function exists(path) {
  try { await access(path, fsConstants.F_OK); return true; } catch { return false; }
}

async function hashFile(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

export function normalizedUpstreamTextSha256(value) {
  const text = Buffer.isBuffer(value) ? value.toString('utf8') : String(value);
  return sha256Text(text.replace(/\r\n/g, '\n'));
}

export function assertNormalizedUpstreamTextIdentity(value, expectedSha256) {
  const normalizedSha256 = normalizedUpstreamTextSha256(value);
  if (normalizedSha256 !== expectedSha256) {
    throw new Error(`Upstream text identity mismatch after CRLF-to-LF normalization: ${normalizedSha256}`);
  }
  return normalizedSha256;
}

function projectPath(project, path) {
  return relative(project, path).replaceAll('\\', '/');
}

async function fileRecord(project, path) {
  const value = await stat(path);
  if (!value.isFile()) throw new Error(`Expected project build input to be a file: ${path}`);
  return { path: projectPath(project, path), sha256: await hashFile(path), bytes: value.size };
}

function sha256Text(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

async function filesBelow(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await filesBelow(path));
    else if (entry.isFile()) files.push(path);
  }
  return files;
}

function where(command) {
  try {
    const output = execFileSync(process.platform === 'win32' ? 'where.exe' : 'which', [command], { encoding: 'utf8' });
    return output.trim().split(/\r?\n/)[0] ?? '';
  } catch { return ''; }
}

function sconsCommand() {
  for (const command of process.platform === 'win32' ? ['scons.exe', 'scons'] : ['scons']) {
    const executable = where(command);
    if (executable && !/\.(cmd|bat)$/i.test(executable)) return { executable, prefix: [] };
  }
  for (const command of process.platform === 'win32' ? ['python.exe', 'python'] : ['python3', 'python']) {
    const executable = where(command);
    if (executable) return { executable, prefix: ['-m', 'SCons'] };
  }
  throw new Error('SCons is unavailable; no native build was launched.');
}

async function runOwned({ project, output, label, executable, args, timeoutSeconds = 900, env, cleanupGraceMilliseconds = 2000 }) {
  const stdoutPath = join(output, `${label}.stdout.log`);
  const stderrPath = join(output, `${label}.stderr.log`);
  const summaryPath = join(output, `${label}.watchdog.json`);
  const summary = await runOwnedProcess({ projectPath: project, executable, args, env, timeoutSeconds, cleanupGraceMilliseconds, stdoutPath, stderrPath, summaryPath });
  if (summary.overallExitCode !== 0 || summary.functionalExitCode !== 0 || !summary.cleanupPassed || !summary.authoritativeZeroProven) {
    throw new Error(`${label} failed or did not prove natural zero-owned-process cleanup; inspect ${summaryPath}`);
  }
  return { stdoutPath, stderrPath, summaryPath, summary };
}

async function gitText(project, args) {
  return execFileSync('git', args, { cwd: project, encoding: 'utf8' }).trim();
}

async function inventorySources(project) {
  const root = join(project, 'native', 'world_backend');
  const manifestPath = join(root, 'source-manifest.json');
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  if (manifest.schema !== 'native-world-backend-source-manifest/v1') throw new Error('Unsupported native source manifest schema.');
  const groups = ['coreSources', 'coreHeaders', 'testSources', 'testHeaders'];
  const extensions = { coreSources: ['.cpp'], coreHeaders: ['.h', '.hpp'], testSources: ['.cpp'], testHeaders: ['.h', '.hpp'] };
  const prefixes = { coreSources: 'core/', coreHeaders: 'core/', testSources: 'tests/', testHeaders: 'tests/' };
  const listed = groups.flatMap(group => {
    if (!Array.isArray(manifest[group]) || manifest[group].some(value => typeof value !== 'string')) throw new Error(`Invalid manifest group ${group}.`);
    for (const value of manifest[group]) {
      if (!value || value.includes('\\') || isAbsolute(value) || /^[A-Za-z]:/.test(value)) throw new Error(`Unsafe manifest path in ${group}: ${value}`);
      const segments = value.split('/');
      if (segments.some(segment => !segment || segment === '.' || segment === '..')) throw new Error(`Unsafe manifest segment in ${group}: ${value}`);
      if (!value.startsWith(prefixes[group]) || !extensions[group].includes(extname(value).toLowerCase())) throw new Error(`Manifest path has the wrong category or extension in ${group}: ${value}`);
    }
    return manifest[group];
  });
  if (new Set(listed).size !== listed.length) throw new Error('Native source manifest contains duplicate paths.');
  const discovered = (await Promise.all([filesBelow(join(root, 'core')), filesBelow(join(root, 'tests'))])).flat()
    .filter(path => ['.cpp', '.h', '.hpp'].includes(extname(path).toLowerCase()))
    .map(path => relative(root, path).replaceAll('\\', '/')).sort();
  const expected = [...listed].sort();
  if (JSON.stringify(discovered) !== JSON.stringify(expected)) {
    throw new Error(`Native source manifest mismatch. discovered=${JSON.stringify(discovered)} expected=${JSON.stringify(expected)}`);
  }
  const sources = [];
  for (const path of expected) {
    const absolute = join(root, path);
    sources.push({ path: `native/world_backend/${path}`, sha256: await hashFile(absolute), bytes: (await stat(absolute)).size });
  }
  const manifestRecord = await fileRecord(project, manifestPath);
  const pureCoreInputs = { manifest: manifestRecord, sources };
  return {
    schema: 'native-world-backend-pure-core-source-inventory/v1',
    scope: 'Pure-core standalone build/test/coverage denominator only; Godot adapter integration is inventoried separately.',
    manifestPath, manifestSha256: manifestRecord.sha256, manifestBytes: manifestRecord.bytes, sources,
    inputDigestSha256: sha256Text(JSON.stringify(pureCoreInputs)),
    coverageDenominator: manifest.coreSources.map(path => `native/world_backend/${path}`).sort(),
  };
}

export async function inventoryProjectBuildInputs(project) {
  const extensionRoot = join(project, 'native', 'terrain_meshing', 'src');
  const extensionFiles = (await filesBelow(extensionRoot)).filter(path => ['.cpp', '.h', '.hpp'].includes(extname(path).toLowerCase()));
  const extensionSources = extensionFiles.filter(path => extname(path).toLowerCase() === '.cpp').sort();
  const extensionHeaders = extensionFiles.filter(path => ['.h', '.hpp'].includes(extname(path).toLowerCase())).sort();
  const extensionBuildInputs = [
    'native/terrain_meshing/SConstruct',
    'native/terrain_meshing/scons_tools/windows.py',
    'native/terrain_meshing/godot-cpp-revision.txt',
    'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
  ].map(path => join(project, ...path.split('/')));
  const n1Inputs = [
    'native/world_backend/README.md',
    'native/world_backend/source-manifest.json',
    'native/world_backend/toolchain-lock.json',
    'native/world_backend/coverage_canary/coverage_canary.cpp',
    'native/world_backend/core/thirdparty/fast_noise_lite/LICENSE',
    'scripts/testing/native_world/NativeWorldBackendAdapterSmoke.gd',
    'scripts/testing/native_world/NativeWorldBackendReleaseSaveV2Probe.gd',
    'tools/run-native-world-backend-tests.mjs',
    'tools/lib/native-compiler-owned-wrapper.mjs',
    'tools/lib/native-world-backend-runner.mjs',
    'tools/lib/owned-process.mjs',
    'tools/lib/native-world-identity-reference.mjs',
    'tools/tests/native-world-backend-runner.test.mjs',
    'tools/tests/native-world-identity-reference.test.mjs',
  ].map(path => join(project, ...path.split('/')));
  const records = async paths => Promise.all(paths.map(path => fileRecord(project, path)));
  const value = {
    schema: 'native-world-backend-project-build-input-inventory/v1',
    extensionSources: await records(extensionSources),
    extensionHeaders: await records(extensionHeaders),
    extensionBuildInputs: await records(extensionBuildInputs),
    n1Inputs: await records(n1Inputs),
  };
  return { ...value, digestSha256: sha256Text(JSON.stringify(value)) };
}

async function findBuiltBinary(directory, pattern) {
  const matches = (await filesBelow(directory)).filter(path => pattern.test(basename(path)));
  if (matches.length !== 1) throw new Error(`Expected exactly one ${pattern} below ${directory}; found ${matches.length}.`);
  return matches[0];
}

async function findCompilerIdentity() {
  const vswhere = 'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe';
  if (!(await exists(vswhere))) return { status: 'unavailable', reason: 'vswhere.exe missing' };
  const installation = execFileSync(vswhere, ['-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'], { encoding: 'utf8' }).trim();
  if (!installation) return { status: 'unavailable', reason: 'MSVC workload not found' };
  const msvcRoot = join(installation, 'VC', 'Tools', 'MSVC');
  const versions = (await readdir(msvcRoot)).sort().reverse();
  const clPath = join(msvcRoot, versions[0], 'bin', 'Hostx64', 'x64', 'cl.exe');
  const linkPath = join(msvcRoot, versions[0], 'bin', 'Hostx64', 'x64', 'link.exe');
  const vcvarsPath = join(installation, 'VC', 'Auxiliary', 'Build', 'vcvars64.bat');
  const mspdbsrvPath = join(dirname(clPath), 'mspdbsrv.exe');
  const vctipPath = join(dirname(clPath), 'vctip.exe');
  if (!(await exists(clPath)) || !(await exists(linkPath)) || !(await exists(vcvarsPath))
      || !(await exists(mspdbsrvPath)) || !(await exists(vctipPath))) {
    return { status: 'unavailable', reason: 'Selected MSVC toolset is incomplete.' };
  }
  let vctipHelp = '';
  let vctipHelpExitCode = 0;
  try {
    vctipHelp = execFileSync(vctipPath, ['-?'], { encoding: 'utf8' }).trim();
  } catch (error) {
    vctipHelpExitCode = error.status ?? 1;
    vctipHelp = String(error.stdout ?? '').trim();
  }
  if (!vctipHelp.includes('VC++ Technology Improvement Program Uploader Version')) {
    return { status: 'unavailable', reason: 'VCTIP identity/help output was not recognized.' };
  }
  const clBanner = spawnSync(clPath, [], { encoding: 'utf8', windowsHide: true });
  const linkBanner = spawnSync(linkPath, [], { encoding: 'utf8', windowsHide: true });
  const clText = `${clBanner.stdout ?? ''}\n${clBanner.stderr ?? ''}`;
  const linkText = `${linkBanner.stdout ?? ''}\n${linkBanner.stderr ?? ''}`;
  const compilerVersion = /Compiler Version ([0-9.]+)/i.exec(clText)?.[1];
  const linkerVersion = /Linker Version ([0-9.]+)/i.exec(linkText)?.[1];
  if (!compilerVersion || !linkerVersion) {
    return { status: 'unavailable', reason: 'MSVC compiler/linker version output was not recognized.' };
  }
  return {
    status: 'available', installation, toolsetVersion: versions[0], compilerVersion, linkerVersion,
    cl: { path: clPath, sha256: await hashFile(clPath) },
    link: { path: linkPath, sha256: await hashFile(linkPath) },
    vcvars: { path: vcvarsPath, sha256: await hashFile(vcvarsPath), args: `-vcvars_ver=${versions[0]}` },
    mspdbsrv: { path: mspdbsrvPath, sha256: await hashFile(mspdbsrvPath), stopArgs: ['-stop'] },
    vctip: {
      path: vctipPath, sha256: await hashFile(vctipPath),
      version: vctipHelp.split(/\r?\n/, 1)[0], helpExitCode: vctipHelpExitCode, helpSha256: sha256Text(vctipHelp),
      ownedServerArgs: ['-upload:skip', '-timeout:60'],
    },
  };
}

function validateCompilerIdentity(compiler, pin) {
  if (compiler.status !== 'available'
      || compiler.toolsetVersion !== pin.toolsetVersion
      || compiler.compilerVersion !== pin.compilerVersion
      || compiler.linkerVersion !== pin.linkerVersion
      || compiler.vcvars.sha256 !== pin.vcvars64Sha256
      || compiler.vcvars.args !== pin.vcvarsArgs
      || compiler.cl.sha256 !== pin.clSha256
      || compiler.link.sha256 !== pin.linkSha256) {
    throw new Error('Resolved MSVC compiler/linker identity does not exactly match the N1 toolchain lock.');
  }
}

async function findGodot() {
  const candidates = [process.env.GODOT_EXE, process.env.GODOT_BIN,
    'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe'].filter(Boolean);
  for (const candidate of candidates) if (await exists(candidate)) return resolve(candidate);
  for (const command of ['godot.exe', 'godot4.exe', 'godot']) {
    const candidate = where(command);
    if (candidate) return candidate;
  }
  throw new Error('Godot console executable is unavailable for the N1 adapter smoke.');
}

async function runAdapterSmoke({ project, output, toolchainLock, projectInputs }) {
  const godot = await findGodot();
  const godotSha256 = await hashFile(godot);
  if (godotSha256 !== toolchainLock.godot.consoleSha256) {
    throw new Error('Godot console binary does not match the N1 toolchain lock.');
  }
  const reportPath = join(output, 'adapter-smoke-report.json');
  const run = await runOwned({ project, output, label: 'adapter-smoke', executable: godot,
    args: ['--headless', '--path', project, '--script', 'res://scripts/testing/native_world/NativeWorldBackendAdapterSmoke.gd'], timeoutSeconds: 120,
    env: { ...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1', VWB_ADAPTER_SMOKE_REPORT: reportPath } });
  const value = JSON.parse(await readFile(reportPath, 'utf8'));
  if (!value.passed) throw new Error('Native world backend Godot adapter smoke did not pass.');
  const version = value.engineVersion ?? {};
  if (Number(version.major) !== toolchainLock.godot.major
      || Number(version.minor) !== toolchainLock.godot.minor
      || Number(version.patch) !== toolchainLock.godot.patch
      || String(version.status) !== toolchainLock.godot.status
      || String(version.hash) !== toolchainLock.godot.engineCommitSha) {
    throw new Error('Godot runtime version does not match the N1 toolchain lock.');
  }
  return {
    evidenceScope: 'Godot 4.6.1 load, explicit adapter invocation, and unload integration smoke.',
    standaloneCoverage: false,
    inputsDigestSha256: projectInputs.digestSha256,
    adapterInputs: [
      'native/terrain_meshing/src/terrain_meshing_backend.cpp',
      'native/terrain_meshing/src/terrain_meshing_backend.h',
      'scripts/testing/native_world/NativeWorldBackendAdapterSmoke.gd',
    ],
    report: { path: projectPath(project, reportPath), sha256: await hashFile(reportPath), value },
    godot: { path: godot, sha256: godotSha256, pinnedVersion: toolchainLock.godot.version },
    ownedProcess: projectPath(project, run.summaryPath),
  };
}

export const releaseSaveV2ProbeChecks = [
  'release_feature',
  'template_feature',
  'debug_feature_absent',
  'editor_feature_absent',
  'editor_hint_absent',
  'engine_version',
  'extension_load_ok',
  'adapter_registered',
  'adapter_instantiated',
  'shadow_only',
  'save_methods_bound',
  'save_v2_restore_ready',
  'save_v2_export_ready',
  'save_v2_exact_roundtrip',
  'overlay_commit_ready',
  'overlay_excluded_from_save',
  'durable_commit_ready',
  'durable_export_updated',
].sort();

export function validateReleaseSaveV2ProbeReport(value, toolchainLock = expectedToolchainLockValue) {
  if (!value || value.schema !== 'native-world-backend-release-save-v2-probe/v1'
      || value.passed !== true
      || value.evidenceLevel !== 'isolated-release-export-shadow-adapter'
      || value.productionCutover !== false || value.shadowOnly !== true
      || !Array.isArray(value.failures) || value.failures.length !== 0
      || !value.checks || typeof value.checks !== 'object' || Array.isArray(value.checks)) {
    throw new Error('Release save-v2 probe report envelope is invalid.');
  }
  const actualChecks = Object.keys(value.checks).sort();
  if (!isDeepStrictEqual(actualChecks, releaseSaveV2ProbeChecks)
      || releaseSaveV2ProbeChecks.some(name => value.checks[name] !== true)) {
    throw new Error('Release save-v2 probe did not pass the exact required check set.');
  }
  const features = value.features;
  if (!features || features.release !== true || features.template !== true
      || features.debug !== false || features.editor !== false || features.editorHint !== false) {
    throw new Error('Release save-v2 probe did not execute in a release export template.');
  }
  const version = value.engineVersion;
  const pin = toolchainLock.godot;
  if (!version || Number(version.major) !== pin.major || Number(version.minor) !== pin.minor
      || Number(version.patch) !== pin.patch || String(version.status) !== pin.status
      || String(version.hash) !== pin.engineCommitSha) {
    throw new Error('Release save-v2 probe engine identity does not match the toolchain lock.');
  }
  return value;
}

function exportPresetString(releaseTemplate) {
  const template = releaseTemplate.replaceAll('\\', '/').replaceAll('"', '\\"');
  return `[preset.0]\n\nname="Native World Backend Release Gate"\nplatform="Windows Desktop"\nrunnable=false\nadvanced_options_enabled=false\ndedicated_server=false\ncustom_features=""\nexport_filter="all_resources"\ninclude_filter=""\nexclude_filter=""\nexport_path=""\npatches=PackedStringArray()\nencryption_include_filters=""\nencryption_exclude_filters=""\nseed=0\nencrypt_pck=false\nencrypt_directory=false\nscript_export_mode=2\n\n[preset.0.options]\n\ncustom_template/debug=""\ncustom_template/release="${template}"\ndebug/export_console_wrapper=0\nbinary_format/embed_pck=false\nbinary_format/architecture="x86_64"\ntexture_format/s3tc_bptc=true\ntexture_format/etc2_astc=false\napplication/modify_resources=false\ncodesign/enable=false\n`;
}

async function findReleaseTemplate(options, pin) {
  const candidates = [
    options.releaseTemplate,
    process.env.GODOT_WINDOWS_RELEASE_TEMPLATE,
    process.env.APPDATA ? join(process.env.APPDATA, 'Godot', 'export_templates', '4.6.1.stable', 'windows_release_x86_64.exe') : null,
  ].filter(Boolean).map(value => resolve(String(value)));
  for (const candidate of candidates) {
    if (!await exists(candidate)) continue;
    const value = await stat(candidate);
    const sha256 = await hashFile(candidate);
    if (value.size !== pin.windowsReleaseX8664TemplateBytes
        || sha256 !== pin.windowsReleaseX8664TemplateSha256) {
      throw new Error(`Godot release export template identity mismatch: ${candidate}`);
    }
    return { path: candidate, bytes: value.size, sha256 };
  }
  throw new Error('Pinned Godot 4.6.1 Windows x86_64 release export template is unavailable.');
}

export async function runReleaseAdapterSmoke({ project, output, toolchainLock, projectInputs, configurations, options }) {
  if (process.platform !== 'win32') throw new Error('The pinned release-export adapter gate currently requires Windows x86_64.');
  const godot = await findGodot();
  const godotSha256 = await hashFile(godot);
  if (godotSha256 !== toolchainLock.godot.consoleSha256) {
    throw new Error('Godot editor console binary does not match the native toolchain lock.');
  }
  const releaseTemplate = await findReleaseTemplate(options, toolchainLock.godot);
  const releaseBuild = configurations.find(value => value.configuration === 'release');
  if (!releaseBuild?.extension?.dll) {
    throw new Error('Release-export adapter gate requires the just-built Release extension.');
  }
  if (await hashFile(releaseBuild.extension.dll.path) !== releaseBuild.extension.dll.sha256) {
    throw new Error('Just-built Release extension changed before release-export staging.');
  }

  const stage = join(output, 'release-adapter-stage');
  const exportDirectory = join(output, 'release-adapter-export');
  await mkdir(stage, { recursive: true });
  await mkdir(exportDirectory, { recursive: false });
  const probeSource = join(project, 'scripts', 'testing', 'native_world', 'NativeWorldBackendReleaseSaveV2Probe.gd');
  const loaderSource = join(project, 'addons', 'terrain_meshing_backend', 'terrain_meshing_backend.gdextension');
  const stageProbe = join(stage, 'NativeWorldBackendReleaseSaveV2Probe.gd');
  await cp(probeSource, stageProbe, { force: false });
  await writeFile(join(stage, 'project.godot'), `; Isolated native release-export gate. Not a production project.\nconfig_version=5\n\n[application]\n\nconfig/name="Native World Backend Release Gate"\nrun/main_scene="res://ReleaseSaveV2Probe.tscn"\n\n[rendering]\n\nrenderer/rendering_method="gl_compatibility"\nrenderer/rendering_method.mobile="gl_compatibility"\n`, { flag: 'wx' });
  await writeFile(join(stage, 'ReleaseSaveV2Probe.tscn'), `[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://NativeWorldBackendReleaseSaveV2Probe.gd" id="1_probe"]\n\n[node name="NativeWorldBackendReleaseSaveV2Probe" type="Node"]\nscript = ExtResource("1_probe")\n`, { flag: 'wx' });
  await writeFile(join(stage, 'export_presets.cfg'), exportPresetString(releaseTemplate.path), { flag: 'wx' });

  const exportExecutable = join(exportDirectory, 'native-world-backend-release-gate.exe');
  const exportRun = await runOwned({ project: stage, output, label: 'release-adapter-export', executable: godot,
    args: ['--headless', '--path', stage, '--export-release', 'Native World Backend Release Gate', exportExecutable], timeoutSeconds: 180,
    env: { ...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1' } });
  if (!await exists(exportExecutable)) throw new Error('Release adapter export did not produce its executable.');
  const outputFiles = await filesBelow(exportDirectory);
  if (await hashFile(exportExecutable) !== releaseTemplate.sha256) {
    throw new Error('Artifact executable is not the exact pinned release export template.');
  }
  // Keep the editor entirely outside the GDExtension lifecycle: Godot 4.6.1
  // crashes after an otherwise successful export when it unloads this Debug
  // extension. Deploy the checked-in loader and the just-built Release DLL
  // into the finished artifact, then let the Release probe load it explicitly.
  const runtimeLoader = join(exportDirectory, 'addons', 'terrain_meshing_backend', 'terrain_meshing_backend.gdextension');
  const runtimeDll = join(exportDirectory, 'addons', 'terrain_meshing_backend', 'bin', releaseBuild.extension.dll.name);
  await mkdir(dirname(runtimeDll), { recursive: true });
  await cp(loaderSource, runtimeLoader, { force: false });
  await cp(releaseBuild.extension.dll.path, runtimeDll, { force: false });
  if (await hashFile(runtimeDll) !== releaseBuild.extension.dll.sha256) {
    throw new Error('Export artifact Release DLL differs from the just-built Release DLL.');
  }
  const reportPath = join(output, 'release-adapter-smoke-report.json');
  const runtimeRun = await runOwned({ project: exportDirectory, output, label: 'release-adapter-runtime', executable: exportExecutable,
    args: ['--headless', '--audio-driver', 'Dummy'], timeoutSeconds: 120,
    env: { ...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1', VWB_RELEASE_SAVE_V2_REPORT: reportPath } });
  if (!await exists(reportPath)) throw new Error('Release save-v2 adapter probe did not publish its report.');
  const report = validateReleaseSaveV2ProbeReport(JSON.parse(await readFile(reportPath, 'utf8')), toolchainLock);
  const runtimeStderr = await readFile(runtimeRun.stderrPath, 'utf8');
  if (runtimeStderr !== '') throw new Error('Release save-v2 adapter probe emitted stderr.');
  const pcks = outputFiles.filter(path => extname(path).toLowerCase() === '.pck');
  if (pcks.length !== 1) throw new Error(`Release adapter export must contain exactly one PCK; found ${pcks.length}.`);
  const record = async path => ({ path: relative(project, path).replaceAll('\\', '/'), sha256: await hashFile(path), bytes: (await stat(path)).size });
  return {
    evidenceScope: 'Artifact-staged Windows release export loading and exercising the shadow save-v2 adapter.',
    productionCutover: false,
    shadowOnly: true,
    inputsDigestSha256: projectInputs.digestSha256,
    godotEditor: { path: godot, sha256: godotSha256, pinnedVersion: toolchainLock.godot.version },
    releaseTemplate,
    justBuiltReleaseDll: { ...releaseBuild.extension.dll, hashBoundToExport: true },
    stagedInputs: {
      probe: await record(stageProbe), loaderSource: await record(loaderSource),
    },
    export: {
      executable: await record(exportExecutable), pck: await record(pcks[0]),
      runtimeLoader: await record(runtimeLoader), runtimeLoadDll: await record(runtimeDll),
      releaseDllMatchesJustBuilt: true,
      executableMatchesPinnedTemplate: true,
    },
    report: { ...await record(reportPath), value: report },
    ownedProcess: {
      export: relative(project, exportRun.summaryPath).replaceAll('\\', '/'),
      runtime: relative(project, runtimeRun.summaryPath).replaceAll('\\', '/'),
    },
    runtimeStderrEmpty: true,
  };
}

async function buildAndTest({ project, output, configuration, scons, compiler, projectInputs, source, dependency }) {
  const nativeDirectory = join(project, 'native', 'terrain_meshing');
  const args = [...scons.prefix, '-Q', '-j2', 'platform=windows', `target=${configuration === 'release' ? 'template_release' : 'template_debug'}`,
    'arch=x86_64', 'api_version=4.6', `custom_tools=${join(nativeDirectory, 'scons_tools')}`];
  if (compiler.status !== 'available') throw new Error('MSVC provenance is unavailable for the owned SCons build.');
  const mspdbsrv = compiler.mspdbsrv.path;
  const vctip = compiler.vctip.path;
  const wrapper = join(project, 'tools', 'lib', 'native-compiler-owned-wrapper.mjs');
  const wrappedArgs = args;
  const build = await runOwned({ project: nativeDirectory, output, label: `build-${configuration}`, executable: process.execPath,
    args: [wrapper, JSON.stringify({ executable: scons.executable, args: wrappedArgs, mspdbsrv, vctip })],
    cleanupGraceMilliseconds: 10000,
    env: { ...process.env, VWB_CONFIGURATION: configuration, _MSPDBSRV_ENDPOINT_: `vwb-${configuration}-${randomUUID()}`,
      GODOT_CPP_DIR: join(nativeDirectory, 'godot-cpp'),
      VWB_MSVC_USE_SCRIPT: compiler.vcvars.path, VWB_MSVC_TOOLSET_VERSION: compiler.toolsetVersion,
      VSCMD_SKIP_SENDTELEMETRY: '1', VCTIP_DISABLE: '1', DOTNET_CLI_TELEMETRY_OPTOUT: '1' } });
  const buildStdout = await readFile(build.stdoutPath, 'utf8');
  const buildStderr = await readFile(build.stderrPath, 'utf8');
  if (/MSVC version ['"]14\.3['"] working host\/target script was not found/i.test(`${buildStdout}\n${buildStderr}`)) {
    throw new Error(`${configuration} build emitted the forbidden MSVC auto-discovery warning.`);
  }
  const buildDirectory = join(nativeDirectory, 'build', 'world_backend', configuration);
  const buildManifestPath = join(buildDirectory, 'build-manifest.json');
  const buildManifest = JSON.parse(await readFile(buildManifestPath, 'utf8'));
  if (buildManifest.schema !== 'native-world-backend-build-manifest/v1' || buildManifest.configuration !== configuration) {
    throw new Error(`${configuration} build manifest does not match the requested configuration.`);
  }
  if (!buildManifest.godotCpp
      || resolve(buildManifest.godotCpp.path).toLowerCase() !== resolve(join(nativeDirectory, 'godot-cpp')).toLowerCase()
      || buildManifest.godotCpp.requiredRevision !== dependency.pinnedRevision
      || buildManifest.godotCpp.actualRevision !== dependency.actualRevision
      || buildManifest.godotCpp.status !== ''
      || buildManifest.godotCpp.apiVersion !== '4.6') {
    throw new Error(`${configuration} build did not use the exact clean vendored godot-cpp dependency/API inputs.`);
  }
  const expectedManifestInputs = Object.fromEntries(['extensionSources', 'extensionHeaders', 'extensionBuildInputs']
    .map(field => [field, projectInputs[field]]));
  for (const [field, expected] of Object.entries(expectedManifestInputs)) {
    if (!isDeepStrictEqual(buildManifest[field], expected)) {
      throw new Error(`${configuration} build manifest ${field} does not match the runner's pre-build inventory.`);
    }
  }
  const expectedPureCoreInputs = {
    manifest: {
      path: projectPath(project, source.manifestPath),
      sha256: source.manifestSha256,
      bytes: source.manifestBytes,
    },
    sources: source.sources,
  };
  if (!isDeepStrictEqual(buildManifest.pureCoreInputs, expectedPureCoreInputs)
      || buildManifest.pureCoreInputsDigestSha256 !== source.inputDigestSha256) {
    throw new Error(`${configuration} build manifest pure-core inputs do not match the runner's pre-build inventory.`);
  }
  const resolvedTools = buildManifest.resolvedTools;
  if (!resolvedTools
      || resolve(resolvedTools.cxx.path).toLowerCase() !== resolve(compiler.cl.path).toLowerCase()
      || resolvedTools.cxx.sha256 !== compiler.cl.sha256
      || resolve(resolvedTools.link.path).toLowerCase() !== resolve(compiler.link.path).toLowerCase()
      || resolvedTools.link.sha256 !== compiler.link.sha256) {
    throw new Error(`${configuration} SCons-resolved compiler/linker identities do not match the pinned runner identities.`);
  }
  const selection = buildManifest.msvcSelection;
  if (!selection
      || selection.sconsProductVersion !== expectedToolchainLockValue.msvc.sconsProductVersion
      || selection.requestedToolsetVersion !== compiler.toolsetVersion
      || selection.hostArchitecture !== expectedToolchainLockValue.msvc.hostArchitecture
      || selection.targetArchitecture !== expectedToolchainLockValue.msvc.targetArchitecture
      || resolve(selection.vcvarsPath).toLowerCase() !== resolve(compiler.vcvars.path).toLowerCase()
      || selection.vcvarsSha256 !== compiler.vcvars.sha256
      || selection.vcvarsArgs !== compiler.vcvars.args) {
    throw new Error(`${configuration} SCons MSVC selection does not match the pinned BuildTools vcvars/toolset identity.`);
  }
  for (const field of ['coreCxxFlags', 'extensionCxxFlags', 'kernelCxxFlags', 'testLinkFlags', 'extensionLinkFlags']) {
    if (!Array.isArray(buildManifest[field]) || buildManifest[field].some(flag => typeof flag !== 'string')) {
      throw new Error(`${configuration} build manifest has no trustworthy ${field}.`);
    }
  }
  const lowerFlags = field => buildManifest[field].map(flag => flag.toLowerCase());
  const expectedOptimization = process.platform === 'win32' ? '/o2' : '-o2';
  if (!lowerFlags('extensionCxxFlags').includes(expectedOptimization)
      || !lowerFlags('kernelCxxFlags').includes(expectedOptimization)) {
    throw new Error(`${configuration} extension build did not preserve its explicit O2 contract.`);
  }
  const coreCxxFlags = lowerFlags('coreCxxFlags');
  if (configuration === 'debug'
      ? (!coreCxxFlags.includes('/od') || !coreCxxFlags.includes('/rtc1') || coreCxxFlags.includes('/o2'))
      : (!coreCxxFlags.includes('/o2') || coreCxxFlags.includes('/od') || coreCxxFlags.includes('/rtc1'))) {
    throw new Error(`${configuration} pure-core optimization/debug flags do not match the requested configuration.`);
  }
  const executable = await findBuiltBinary(buildDirectory, /^world_backend_core_tests(?:\.exe)?$/i);
  const pdb = await findBuiltBinary(buildDirectory, /^world_backend_core_tests(?:\.exe)?\.pdb$|^world_backend_core_tests\.pdb$/i);
  const test = await runOwned({ project, output, label: `test-${configuration}`, executable, args: [], timeoutSeconds: 120 });
  const stdout = (await readFile(test.stdoutPath, 'utf8')).trim();
  const summary = JSON.parse(stdout.split(/\r?\n/).at(-1));
  if (summary.failed !== 0 || summary.passed !== summary.total) throw new Error(`${configuration} native unit-test summary is not passing.`);
  const result = {
    configuration,
    inputsDigestSha256: projectInputs.digestSha256,
    buildManifest: { path: relative(project, buildManifestPath).replaceAll('\\', '/'), sha256: await hashFile(buildManifestPath), value: buildManifest },
    buildLog: {
      stdout: { path: projectPath(project, build.stdoutPath), sha256: await hashFile(build.stdoutPath) },
      stderr: { path: projectPath(project, build.stderrPath), sha256: await hashFile(build.stderrPath) },
      forbiddenMsvcDiscoveryWarningAbsent: true,
    },
    binary: { path: relative(project, executable).replaceAll('\\', '/'), sha256: await hashFile(executable), bytes: (await stat(executable)).size },
    pdb: { path: relative(project, pdb).replaceAll('\\', '/'), sha256: await hashFile(pdb), bytes: (await stat(pdb)).size },
    tests: summary,
    ownedProcess: { build: relative(project, build.summaryPath).replaceAll('\\', '/'), test: relative(project, test.summaryPath).replaceAll('\\', '/') },
  };
  if (configuration !== 'coverage') {
    const suffix = configuration === 'release' ? 'template_release' : 'template_debug';
    const nativeBin = join(nativeDirectory, 'bin');
    const dll = await findBuiltBinary(nativeBin, new RegExp(`^terrain_meshing_backend\\.windows\\.${suffix}\\.x86_64\\.dll$`, 'i'));
    const pdb = await findBuiltBinary(nativeBin, new RegExp(`^terrain_meshing_backend\\.windows\\.${suffix}\\.x86_64(?:\\.dll)?\\.pdb$`, 'i'));
    const stageDirectory = join(output, 'built', configuration);
    await mkdir(stageDirectory, { recursive: true });
    const stagedDll = join(stageDirectory, basename(dll));
    const stagedPdb = join(stageDirectory, basename(pdb));
    await cp(dll, stagedDll, { force: false });
    await cp(pdb, stagedPdb, { force: false });
    result.extension = {
      dll: { path: stagedDll, name: basename(dll), sha256: await hashFile(stagedDll), bytes: (await stat(stagedDll)).size },
      pdb: { path: stagedPdb, name: basename(pdb), sha256: await hashFile(stagedPdb), bytes: (await stat(stagedPdb)).size },
    };
  }
  return result;
}

export function validateInstalledProvenance(installed) {
  if (!Array.isArray(installed) || installed.length !== 4
      || installed.some(item => !item.buildManifestSha256 || !item.inputsDigestSha256 || !item.pureCoreInputsDigestSha256)) {
    throw new Error('Installed extension receipt is missing a required build/source provenance digest.');
  }
  return installed;
}

async function installExtensions(project, configurations, projectInputs, sourceInventory) {
  const destinationDirectory = join(project, 'addons', 'terrain_meshing_backend', 'bin');
  await mkdir(destinationDirectory, { recursive: true });
  const selected = configurations.filter(item => item.configuration === 'debug' || item.configuration === 'release');
  if (selected.length !== 2 || new Set(selected.map(item => item.configuration)).size !== 2 || selected.some(item => !item.extension)) throw new Error('Exactly one just-built debug and release extension are required for installation.');
  const installed = [];
  for (const configuration of selected) {
    for (const kind of ['dll', 'pdb']) {
      const artifactSource = configuration.extension[kind];
      const destination = join(destinationDirectory, artifactSource.name);
      await cp(artifactSource.path, destination, { force: true });
      const installedHash = await hashFile(destination);
      if (artifactSource.sha256 !== installedHash) throw new Error(`Installed native ${kind} differs from the just-built ${configuration.configuration} output.`);
      installed.push({
        configuration: configuration.configuration, kind, name: artifactSource.name,
        sha256: installedHash, bytes: (await stat(destination)).size,
        buildManifestSha256: configuration.buildManifest.sha256,
        inputsDigestSha256: projectInputs.digestSha256,
        pureCoreInputsDigestSha256: sourceInventory.inputDigestSha256,
      });
    }
  }
  return validateInstalledProvenance(installed);
}

function assertInside(parent, child, label) {
  const parentPrefix = resolve(parent) + sep;
  if (!resolve(child).startsWith(parentPrefix)) throw new Error(`${label} escaped its declared parent directory.`);
}

async function validateLlvmRoot(root) {
  const paths = {
    root: resolve(root),
    clangCl: join(root, 'bin', 'clang-cl.exe'),
    llvmProfdata: join(root, 'bin', 'llvm-profdata.exe'),
    llvmCov: join(root, 'bin', 'llvm-cov.exe'),
    profileRuntime: join(root, 'lib', 'clang', llvmResourceDirVersion, 'lib', 'windows', 'clang_rt.profile-x86_64.lib'),
    licenseFile: join(root, 'include', 'llvm', 'Support', 'LICENSE.TXT'),
  };
  for (const [name, path] of Object.entries(paths)) {
    if (name !== 'root' && !(await exists(path))) throw new Error(`LLVM ${name} is missing at ${path}`);
  }
  const versionText = execFileSync(paths.clangCl, ['--version'], { encoding: 'utf8' });
  if (!versionText.includes(`clang version ${llvmVersion}`)) throw new Error(`LLVM root is not the pinned ${llvmVersion} Windows toolchain.`);
  const hashes = {
    clangCl: await hashFile(paths.clangCl), llvmProfdata: await hashFile(paths.llvmProfdata),
    llvmCov: await hashFile(paths.llvmCov), profileRuntime: await hashFile(paths.profileRuntime),
    licenseFile: await hashFile(paths.licenseFile),
  };
  if (!isDeepStrictEqual(hashes, llvmExpectedHashes)) throw new Error('LLVM extracted tool/runtime/license hashes differ from the N1 pins.');
  return { ...paths, versionText: versionText.trim(), hashes };
}

const llvmInstallMarkerName = '.vwb-install-complete.json';

async function validateInstalledLlvmRoot(root) {
  const markerPath = join(root, llvmInstallMarkerName);
  if (!(await exists(markerPath))) throw new Error(`Pinned LLVM directory has no completed-install marker: ${markerPath}`);
  const marker = JSON.parse(await readFile(markerPath, 'utf8'));
  const expectedMarker = {
    schema: 'native-world-backend-llvm-install/v1', version: llvmVersion,
    resourceDirVersion: llvmResourceDirVersion, archiveBytes: llvmArchiveBytes,
    archiveSha256: llvmArchiveSha256, hashes: llvmExpectedHashes,
  };
  if (!isDeepStrictEqual(marker, expectedMarker)) throw new Error('Pinned LLVM completed-install marker does not match N1 pins.');
  return { ...(await validateLlvmRoot(root)), installMarker: { path: markerPath, value: marker, sha256: await hashFile(markerPath) } };
}

async function fetchLlvmToolchain({ project, output }) {
  const toolchains = join(project, 'native', 'terrain_meshing', 'toolchains');
  const finalRoot = join(toolchains, `llvm-${llvmVersion}-x86_64-pc-windows-msvc`);
  if (await exists(finalRoot)) return validateInstalledLlvmRoot(finalRoot);
  await mkdir(toolchains, { recursive: true });
  const scratch = join(toolchains, `.llvm-${llvmVersion}-installing-${randomUUID()}`);
  const installLock = `${finalRoot}.installing`;
  assertInside(toolchains, scratch, 'LLVM scratch directory');
  assertInside(toolchains, installLock, 'LLVM install lock');
  await mkdir(scratch, { recursive: false });
  const installId = randomUUID();
  const archive = join(scratch, llvmArchiveName);
  let createdFinal = false;
  let lockOwned = false;
  try {
  await writeFile(installLock, `${JSON.stringify({ schema: 'native-world-backend-llvm-install-lock/v1', installId })}\n`, { flag: 'wx' });
  lockOwned = true;
  const curl = where('curl.exe') || where('curl');
  if (!curl) throw new Error('curl is required to download the pinned LLVM archive through the Windows trust store.');
  await runOwned({ project, output, label: 'llvm-archive-download', executable: curl,
    args: ['--fail', '--location', '--proto', '=https', '--tlsv1.2', '--output', archive, llvmArchiveUrl], timeoutSeconds: 1800 });
  const bytes = (await stat(archive)).size;
  const sha256 = await hashFile(archive);
  if (bytes !== llvmArchiveBytes || sha256 !== llvmArchiveSha256) throw new Error(`LLVM archive identity mismatch: bytes=${bytes}, sha256=${sha256}`);

  const tar = where('tar.exe') || where('tar');
  if (!tar) throw new Error('bsdtar is required to inspect and extract the pinned LLVM archive.');
  const listRun = await runOwned({ project, output, label: 'llvm-archive-list', executable: tar, args: ['-tf', archive], timeoutSeconds: 300 });
  const entries = (await readFile(listRun.stdoutPath, 'utf8')).split(/\r?\n/).filter(Boolean);
  if (!entries.length) throw new Error('Pinned LLVM archive listing is empty.');
  for (const entry of entries) {
    const normalized = entry.replaceAll('\\', '/');
    if (normalized.startsWith('/') || /^[A-Za-z]:/.test(normalized) || normalized.split('/').some(segment => segment === '..')) {
      throw new Error(`Unsafe path in pinned LLVM archive: ${entry}`);
    }
  }
  const archiveRoots = new Set(entries.map(entry => entry.replaceAll('\\', '/').split('/')[0]).filter(Boolean));
  if (archiveRoots.size !== 1) throw new Error('Pinned LLVM archive must contain exactly one root directory.');
  await mkdir(finalRoot, { recursive: false });
  createdFinal = true;
  // Strip the single, already-validated archive root directly into the exact
  // contained final path. The exclusive lock and absent completion marker
  // prevent another run from consuming the tree before validation completes.
  await runOwned({ project, output, label: 'llvm-archive-extract', executable: tar,
    args: ['-xf', archive, '--strip-components', '1', '-C', finalRoot], timeoutSeconds: 900 });
  const validated = await validateLlvmRoot(finalRoot);
  const installMarker = {
    schema: 'native-world-backend-llvm-install/v1', version: llvmVersion,
    resourceDirVersion: llvmResourceDirVersion, archiveBytes: llvmArchiveBytes,
    archiveSha256: llvmArchiveSha256, hashes: validated.hashes,
  };
  await writeFile(join(finalRoot, llvmInstallMarkerName), `${JSON.stringify(installMarker, null, 2)}\n`, { flag: 'wx' });
  return validateInstalledLlvmRoot(finalRoot);
  } catch (error) {
    if (createdFinal && await exists(finalRoot)) {
      assertInside(toolchains, finalRoot, 'LLVM failed-install cleanup directory');
      await rm(finalRoot, { recursive: true, force: false });
    }
    throw error;
  } finally {
    if (lockOwned && await exists(installLock)) {
      assertInside(toolchains, installLock, 'LLVM install-lock cleanup path');
      await rm(installLock, { force: false });
    }
    if (await exists(scratch)) {
      assertInside(toolchains, scratch, 'LLVM cleanup directory');
      await rm(scratch, { recursive: true, force: true });
    }
  }
}

async function resolveLlvmToolchain({ project, output, options }) {
  const explicit = options.llvmRoot ?? process.env.VWB_LLVM_ROOT;
  if (explicit) return validateLlvmRoot(resolve(project, String(explicit)));
  const installed = join(project, 'native', 'terrain_meshing', 'toolchains', `llvm-${llvmVersion}-x86_64-pc-windows-msvc`);
  if (await exists(installed)) {
    const marker = join(installed, llvmInstallMarkerName);
    if (await exists(marker)) return validateInstalledLlvmRoot(installed);
    const installLock = `${installed}.installing`;
    if (await exists(installLock)) throw new Error(`Pinned LLVM install is actively locked and incomplete: ${installLock}`);
    if (!(options.fetchLlvm === true || String(options.fetchLlvm).toLowerCase() === 'true')) {
      throw new Error(`Pinned LLVM install is incomplete because its completion marker is absent: ${marker}`);
    }
    const toolchains = dirname(installed);
    assertInside(toolchains, installed, 'LLVM abandoned-install cleanup directory');
    await rm(installed, { recursive: true, force: false });
  }
  if (options.fetchLlvm === true || String(options.fetchLlvm).toLowerCase() === 'true') return fetchLlvmToolchain({ project, output });
  throw new Error(`Pinned LLVM coverage toolchain is absent. Re-run with --fetch-llvm or --llvm-root PATH. Expected ${llvmArchiveUrl} (${llvmArchiveBytes} bytes, SHA-256 ${llvmArchiveSha256}).`);
}

export function parseLcovLineCoverage(lcovText, expectedFiles) {
  if (typeof lcovText !== 'string' || !lcovText.length) throw new Error('LLVM lcov line export is empty.');
  const expected = new Set(expectedFiles.map(path => resolve(path).toLowerCase()));
  const files = new Map();
  let activePath = null;
  let activeLines = null;
  for (const rawLine of lcovText.split(/\r?\n/)) {
    const line = rawLine.trimEnd();
    if (line.startsWith('SF:')) {
      if (activePath !== null) throw new Error('LLVM lcov started a source record before ending the previous record.');
      activePath = resolve(line.slice(3)).toLowerCase();
      if (!line.slice(3) || files.has(activePath)) throw new Error(`LLVM lcov has an empty or duplicate source record: ${line.slice(3)}.`);
      activeLines = new Map();
      continue;
    }
    if (line === 'end_of_record') {
      if (activePath === null) throw new Error('LLVM lcov ended a source record without an SF entry.');
      files.set(activePath, activeLines);
      activePath = null;
      activeLines = null;
      continue;
    }
    if (!line.startsWith('DA:')) continue;
    if (activePath === null) throw new Error('LLVM lcov emitted a line count outside a source record.');
    const match = /^DA:(\d+),(\d+)(?:,[^,]*)?$/.exec(line);
    if (!match) throw new Error(`LLVM lcov emitted an invalid DA record: ${line}.`);
    const sourceLine = Number(match[1]);
    const count = Number(match[2]);
    if (!Number.isSafeInteger(sourceLine) || sourceLine < 1 || !Number.isSafeInteger(count)) {
      throw new Error(`LLVM lcov emitted an invalid line/count value: ${line}.`);
    }
    if (activeLines.has(sourceLine)) throw new Error(`LLVM lcov duplicated line ${sourceLine} for ${activePath}.`);
    activeLines.set(sourceLine, count);
  }
  if (activePath !== null) throw new Error(`LLVM lcov source record was not terminated: ${activePath}.`);
  const missing = [...expected].filter(path => !files.has(path));
  if (missing.length) throw new Error(`LLVM lcov omitted expected first-party sources: ${missing.join(', ')}.`);
  return files;
}

export function coverageTotals(exportJson, expectedFiles, allowedCoreFiles = expectedFiles, lineCoverage = null) {
  if (exportJson.type !== 'llvm.coverage.json.export' || !Array.isArray(exportJson.data) || exportJson.data.length !== 1) throw new Error('Unexpected llvm-cov JSON schema.');
  if (!(lineCoverage instanceof Map)) throw new Error('Authoritative LLVM lcov line coverage is required.');
  const files = exportJson.data[0].files ?? [];
  const byPath = new Map(files.map(file => [resolve(file.filename).toLowerCase(), file]));
  const selected = expectedFiles.map(path => {
    const file = byPath.get(resolve(path).toLowerCase());
    if (!file) throw new Error(`llvm-cov omitted an expected first-party source: ${path}`);
    return file;
  });
  for (const file of selected) {
    for (const metric of ['lines', 'functions', 'branches']) {
      const count = Number(file.summary?.[metric]?.count);
      const covered = Number(file.summary?.[metric]?.covered);
      if (!Number.isSafeInteger(count) || !Number.isSafeInteger(covered)
          || count < 0 || covered < 0 || covered > count) {
        throw new Error(`Invalid LLVM ${metric} summary for ${file.filename}.`);
      }
    }
    const branchDetails = normalizedBranchDetails(file);
    const detailedBranchCovered = branchDetails.reduce((sum, branch) =>
      sum + Number(branch.trueCount > 0) + Number(branch.falseCount > 0), 0);
    if (file.summary.branches.count !== branchDetails.length * 2
        || file.summary.branches.covered !== detailedBranchCovered) {
      throw new Error(`LLVM branch summary/detail mismatch for ${file.filename}.`);
    }
  }
  const allowedCoreSet = new Set(allowedCoreFiles.map(path => resolve(path).toLowerCase()));
  const unexpectedCore = files.filter(file => /[\\/]native[\\/]world_backend[\\/]core[\\/]/i.test(file.filename)
    && !allowedCoreSet.has(resolve(file.filename).toLowerCase()));
  if (unexpectedCore.length) throw new Error(`llvm-cov reported unmanifested core sources: ${unexpectedCore.map(file => file.filename).join(', ')}`);
  const total = metric => selected.reduce((sum, file) => sum + Number(file.summary?.[metric]?.count ?? 0), 0);
  const covered = metric => selected.reduce((sum, file) => sum + Number(file.summary?.[metric]?.covered ?? 0), 0);
  const result = {};
  for (const metric of ['lines', 'functions', 'branches']) {
    result[metric] = { covered: covered(metric), count: total(metric) };
    result[metric].percent = result[metric].count ? result[metric].covered * 100 / result[metric].count : null;
  }
  const uncoveredLines = [];
  const uncoveredBranches = [];
  for (const file of selected) {
    const lineCounts = lineCoverage.get(resolve(file.filename).toLowerCase());
    if (!(lineCounts instanceof Map)) throw new Error(`LLVM lcov omitted line counts for ${file.filename}.`);
    const reportedLineCount = Number(file.summary.lines.count);
    const reportedCoveredLineCount = Number(file.summary.lines.covered);
    if (lineCounts.size !== reportedLineCount) {
      throw new Error(`LLVM lcov line/summary mismatch for ${file.filename}: `
        + `lcov identifies ${lineCounts.size} executable lines, summary identifies ${reportedLineCount}.`);
    }
    const fileUncoveredLines = [...lineCounts].filter(([, count]) => count === 0);
    const reportedUncoveredLineCount = reportedLineCount - reportedCoveredLineCount;
    if (fileUncoveredLines.length !== reportedUncoveredLineCount) {
      throw new Error(`LLVM lcov line/summary mismatch for ${file.filename}: `
        + `lcov identifies ${fileUncoveredLines.length} missed lines, summary identifies ${reportedUncoveredLineCount}.`);
    }
    for (const [line] of fileUncoveredLines) uncoveredLines.push({ file: file.filename, line });
    for (const branch of normalizedBranchDetails(file)) {
      if (branch.trueCount === 0 || branch.falseCount === 0) uncoveredBranches.push({
        file: file.filename, ...branch,
      });
    }
  }
  const expectedSet = new Set(expectedFiles.map(path => resolve(path).toLowerCase()));
  const uncoveredFunctions = (exportJson.data[0].functions ?? []).filter(item => Number(item.count) === 0
    && (item.filenames ?? []).some(filename => expectedSet.has(resolve(filename).toLowerCase())))
    .map(item => ({ name: item.name, filenames: item.filenames }));
  return {
    files: selected.map(file => ({ filename: file.filename, summary: file.summary })), totals: result,
    uncovered: { lines: uncoveredLines, functions: uncoveredFunctions, branches: uncoveredBranches },
  };
}

async function clangCompile({ project, output, label, llvm, sources, executable }) {
  const core = join(project, 'native', 'world_backend', 'core');
  const tests = join(project, 'native', 'world_backend', 'tests');
  const pdb = executable.replace(/\.exe$/i, '.pdb');
  const args = ['/nologo', '/std:c++17', '/EHsc', '/Od', '/Z7', '/fp:strict', '/clang:-fprofile-instr-generate', '/clang:-fcoverage-mapping',
    `/I${core}`, `/I${tests}`, ...sources, `/Fe:${executable}`, '/link', '/DEBUG:FULL', '/OPT:NOREF', '/OPT:NOICF', `/PDB:${pdb}`];
  const compiler = await findCompilerIdentity();
  if (compiler.status !== 'available') throw new Error('MSVC linker/PDB server provenance is unavailable for clang-cl coverage build.');
  const mspdbsrv = compiler.mspdbsrv.path;
  const vctip = compiler.vctip.path;
  if (!(await exists(mspdbsrv))) throw new Error(`MSVC PDB server missing at ${mspdbsrv}`);
  const wrapper = join(project, 'tools', 'lib', 'native-compiler-owned-wrapper.mjs');
  const run = await runOwned({ project, output, label, executable: process.execPath,
    args: [wrapper, JSON.stringify({ executable: llvm.clangCl, args, mspdbsrv, vctip })], timeoutSeconds: 300,
    env: { ...process.env, PATH: `${join(llvm.root, 'bin')};${process.env.PATH ?? ''}`, _MSPDBSRV_ENDPOINT_: `vwb-clang-${randomUUID()}` } });
  if (!(await exists(executable)) || !(await exists(pdb))) throw new Error(`${label} did not produce its executable and PDB.`);
  return { run, pdb, args };
}

async function collectLlvmCoverage({ project, output, label, llvm, executable, expectedFiles,
  allowedCoreFiles = expectedFiles, executeTimeoutSeconds = 120 }) {
  const profileRaw = join(output, `${label}.profraw`);
  const profileData = join(output, `${label}.profdata`);
  const test = await runOwned({ project, output, label: `${label}-execute`, executable, args: [], timeoutSeconds: executeTimeoutSeconds,
    env: { ...process.env, LLVM_PROFILE_FILE: profileRaw } });
  if (!(await exists(profileRaw))) throw new Error(`${label} did not produce an LLVM raw profile.`);
  const merge = await runOwned({ project, output, label: `${label}-merge`, executable: llvm.llvmProfdata,
    args: ['merge', '-sparse', profileRaw, '-o', profileData], timeoutSeconds: 120 });
  const exportRun = await runOwned({ project, output, label: `${label}-export`, executable: llvm.llvmCov,
    args: ['export', executable, `-instr-profile=${profileData}`, '-format=text'], timeoutSeconds: 120 });
  const lineExportRun = await runOwned({ project, output, label: `${label}-line-export`, executable: llvm.llvmCov,
    args: ['export', executable, `-instr-profile=${profileData}`, '-format=lcov'], timeoutSeconds: 120 });
  const reportRun = await runOwned({ project, output, label: `${label}-report`, executable: llvm.llvmCov,
    args: ['report', executable, `-instr-profile=${profileData}`, '--show-branch-summary', ...expectedFiles], timeoutSeconds: 120 });
  const exportJson = JSON.parse(await readFile(exportRun.stdoutPath, 'utf8'));
  const lcovText = await readFile(lineExportRun.stdoutPath, 'utf8');
  const lineCoverage = parseLcovLineCoverage(lcovText, expectedFiles);
  const coverage = coverageTotals(exportJson, expectedFiles, allowedCoreFiles, lineCoverage);
  return {
    ...coverage,
    artifacts: {
      profileRaw: { path: profileRaw, sha256: await hashFile(profileRaw) },
      profileData: { path: profileData, sha256: await hashFile(profileData) },
      exportJson: { path: exportRun.stdoutPath, sha256: await hashFile(exportRun.stdoutPath) },
      lineExport: { path: lineExportRun.stdoutPath, sha256: await hashFile(lineExportRun.stdoutPath) },
      textReport: { path: reportRun.stdoutPath, sha256: await hashFile(reportRun.stdoutPath) },
    },
    ownedProcess: { execute: test.summaryPath, merge: merge.summaryPath, export: exportRun.summaryPath,
      lineExport: lineExportRun.summaryPath, report: reportRun.summaryPath },
  };
}

export async function runLlvmCoverage({ project, output, options, source }) {
  const llvm = await resolveLlvmToolchain({ project, output, options });
  const coreExecutionTimeoutMs = coverageExecutionTimeoutMilliseconds(options);
  const coverageDirectory = join(output, 'llvm-coverage');
  await mkdir(coverageDirectory, { recursive: false });
  const canarySource = join(project, 'native', 'world_backend', 'coverage_canary', 'coverage_canary.cpp');
  const canaryExecutable = join(coverageDirectory, 'coverage_canary.exe');
  const canaryBuild = await clangCompile({ project, output, label: 'coverage-canary-build', llvm, sources: [canarySource], executable: canaryExecutable });
  const canary = await collectLlvmCoverage({ project, output, label: 'coverage-canary', llvm, executable: canaryExecutable, expectedFiles: [canarySource] });
  for (const metric of ['lines', 'functions', 'branches']) {
    if (!(canary.totals[metric].count > 0 && canary.totals[metric].covered < canary.totals[metric].count)) {
      throw new Error(`LLVM coverage canary did not detect intentionally missing ${metric} coverage.`);
    }
  }

  const manifest = JSON.parse(await readFile(source.manifestPath, 'utf8'));
  const coreSources = manifest.coreSources.map(path => join(project, 'native', 'world_backend', path));
  const allowedCoreFiles = [...coreSources,
    ...manifest.coreHeaders.map(path => join(project, 'native', 'world_backend', path))];
  const testSources = manifest.testSources.map(path => join(project, 'native', 'world_backend', path));
  const executable = join(coverageDirectory, 'world_backend_core_tests.exe');
  const build = await clangCompile({ project, output, label: 'coverage-core-build', llvm, sources: [...coreSources, ...testSources], executable });
  const coverage = await collectLlvmCoverage({ project, output, label: 'coverage-core', llvm, executable,
    expectedFiles: coreSources, allowedCoreFiles,
    executeTimeoutSeconds: coreExecutionTimeoutMs / 1000 });
  const complete = ['lines', 'functions', 'branches'].every(metric => coverage.totals[metric].count > 0 && coverage.totals[metric].covered === coverage.totals[metric].count);
  return {
    status: complete ? 'passed' : 'failed_threshold', requiredMetrics: ['line', 'function', 'branch'],
    toolchain: {
      version: llvmVersion, resourceDirVersion: llvmResourceDirVersion, root: llvm.root,
      versionText: llvm.versionText, hashes: llvm.hashes,
      archive: { name: llvmArchiveName, url: llvmArchiveUrl, bytes: llvmArchiveBytes, sha256: llvmArchiveSha256 },
      license: { path: llvm.licenseFile, sha256: llvm.hashes.licenseFile },
      installMarker: llvm.installMarker ?? null,
    },
    canary: { status: 'passed', totals: canary.totals, uncovered: canary.uncovered, buildArgs: canaryBuild.args, artifacts: canary.artifacts },
    core: { ...coverage, executionTimeoutMilliseconds: coreExecutionTimeoutMs,
      buildArgs: build.args, binary: { path: executable, sha256: await hashFile(executable) },
      pdb: { path: build.pdb, sha256: await hashFile(build.pdb) } },
    denominatorValidated: true,
  };
}

async function microsoftCoverageProbe() {
  const candidates = [
    process.env.MICROSOFT_CODE_COVERAGE_CONSOLE,
    'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/Extensions/Microsoft/CodeCoverage.Console/Microsoft.CodeCoverage.Console.exe',
    'C:/Program Files/Microsoft Visual Studio/2022/Enterprise/Common7/IDE/Extensions/Microsoft/CodeCoverage.Console/Microsoft.CodeCoverage.Console.exe',
    'C:/Program Files/Microsoft Visual Studio/2022/Community/Common7/IDE/Extensions/Microsoft/CodeCoverage.Console/Microsoft.CodeCoverage.Console.exe',
  ].filter(Boolean);
  const tool = candidates.find(path => isAbsolute(path) && existsSync(path));
  return {
    status: 'blocked', tool: tool ?? null,
    requiredMetrics: ['line', 'function', 'branch'],
    reason: tool
      ? 'Microsoft native coverage output has not been proven to expose branch coverage; collection is fail-closed until an independently verified parser/metric mapping is checked in.'
      : 'Microsoft.CodeCoverage.Console is not installed on this host; no line/function/branch native coverage report can be produced.',
    denominatorValidated: false,
  };
}

export async function runNativeWorldBackend(argv, dependencies = {}) {
  const options = parse(argv);
  const project = resolve(String(options.projectPath ?? defaultProject));
  const runName = String(options.runName ?? `n1-${new Date().toISOString().replace(/[:.]/g, '-')}-${randomUUID().slice(0, 8)}`);
  const output = resolve(project, String(options.outputDirectory ?? join('artifacts', 'native-world-backend', runName)));
  if (await exists(output)) throw new Error(`Output directory already exists: ${output}`);
  await mkdir(output, { recursive: true });
  const reportPath = join(output, 'report.json');
  const receipt = {
    schema: 'native-world-backend-n1-receipt/v1',
    status: 'running', startedAtUtc: new Date().toISOString(), project, runName,
    git: { commit: await gitText(project, ['rev-parse', 'HEAD']), branch: await gitText(project, ['branch', '--show-current']), statusBefore: await gitText(project, ['status', '--short']) },
    source: {}, projectInputs: {},
    dependency: {}, toolchainLock: {}, compiler: await findCompilerIdentity(), compilerAfter: null,
    configurations: [], installed: [], adapterSmoke: null, releaseAdapterSmoke: null, coverage: null,
  };
  try {
    receipt.source = await inventorySources(project);
    receipt.projectInputs.before = await inventoryProjectBuildInputs(project);
    const toolchainLockPath = join(project, 'native', 'world_backend', 'toolchain-lock.json');
    const toolchainLockValue = validateToolchainLockValue(JSON.parse(await readFile(toolchainLockPath, 'utf8')));
    receipt.toolchainLock = {
      path: relative(project, toolchainLockPath).replaceAll('\\', '/'),
      sha256: await hashFile(toolchainLockPath), value: toolchainLockValue, validatedAgainstCompiledPins: true,
    };
    validateCompilerIdentity(receipt.compiler, toolchainLockValue.msvc);
    const pinPath = join(project, 'native', 'terrain_meshing', 'godot-cpp-revision.txt');
    const dependencyDirectory = join(project, 'native', 'terrain_meshing', 'godot-cpp');
    const dependencyLicensePath = resolve(dirname(toolchainLockPath), toolchainLockValue.godotCpp.licenseFile);
    const dependencyLicenseSha256 = await hashFile(dependencyLicensePath);
    const noiseLicensePath = resolve(dirname(toolchainLockPath), toolchainLockValue.fastNoiseLite.licenseFile);
    const noiseHeaderPath = resolve(dirname(toolchainLockPath), toolchainLockValue.fastNoiseLite.patchedHeaderFile);
    const noiseLicenseBytes = await readFile(noiseLicensePath);
    const noiseLicenseRawSha256 = createHash('sha256').update(noiseLicenseBytes).digest('hex');
    const noiseLicenseNormalizedSha256 = assertNormalizedUpstreamTextIdentity(
      noiseLicenseBytes, toolchainLockValue.fastNoiseLite.licenseSha256);
    const noiseHeaderSha256 = await hashFile(noiseHeaderPath);
    receipt.dependency = {
      pinnedRevision: (await readFile(pinPath, 'utf8')).trim(),
      actualRevision: await gitText(dependencyDirectory, ['rev-parse', 'HEAD']),
      status: await gitText(dependencyDirectory, ['status', '--short']),
      license: {
        identifier: toolchainLockValue.godotCpp.license,
        path: relative(project, dependencyLicensePath).replaceAll('\\', '/'),
        sha256: dependencyLicenseSha256,
        pinnedSha256: toolchainLockValue.godotCpp.licenseSha256,
      },
      fastNoiseLite: {
        engineCommitSha: toolchainLockValue.fastNoiseLite.engineCommitSha,
        upstreamVersion: toolchainLockValue.fastNoiseLite.upstreamVersion,
        upstreamCommitSha: toolchainLockValue.fastNoiseLite.upstreamCommitSha,
        license: {
          identifier: toolchainLockValue.fastNoiseLite.license,
          path: relative(project, noiseLicensePath).replaceAll('\\', '/'),
          rawSha256: noiseLicenseRawSha256,
          normalizedSha256: noiseLicenseNormalizedSha256,
          normalization: 'CRLF to LF for upstream text identity only; raw project-input hash remains byte-exact',
          pinnedSha256: toolchainLockValue.fastNoiseLite.licenseSha256,
        },
        patchedHeader: {
          path: relative(project, noiseHeaderPath).replaceAll('\\', '/'),
          sha256: noiseHeaderSha256,
          pinnedSha256: toolchainLockValue.fastNoiseLite.patchedHeaderSha256,
        },
        godotPatchSha256: toolchainLockValue.fastNoiseLite.godotPatchSha256,
        upstreamHeaderSha256: toolchainLockValue.fastNoiseLite.upstreamHeaderSha256,
      },
    };
    if (receipt.dependency.actualRevision !== receipt.dependency.pinnedRevision || receipt.dependency.status) throw new Error('godot-cpp dependency does not match the clean pinned revision.');
    if (dependencyLicenseSha256 !== toolchainLockValue.godotCpp.licenseSha256) throw new Error('godot-cpp license file differs from the N1 pin.');
    if (noiseHeaderSha256 !== toolchainLockValue.fastNoiseLite.patchedHeaderSha256) throw new Error('FastNoiseLite patched header differs from the N2 pin.');
    const scons = dependencies.scons ?? sconsCommand();
    for (const configuration of ['debug', 'release']) {
      receipt.configurations.push(await buildAndTest({
        project, output, configuration, scons, compiler: receipt.compiler,
        projectInputs: receipt.projectInputs.before, source: receipt.source, dependency: receipt.dependency,
      }));
    }
    receipt.installed = await installExtensions(project, receipt.configurations, receipt.projectInputs.before, receipt.source);
    receipt.adapterSmoke = await runAdapterSmoke({
      project, output, toolchainLock: toolchainLockValue, projectInputs: receipt.projectInputs.before,
    });
    receipt.releaseAdapterSmoke = await runReleaseAdapterSmoke({
      project, output, toolchainLock: toolchainLockValue, projectInputs: receipt.projectInputs.before,
      configurations: receipt.configurations, options,
    });
    try {
      receipt.coverage = dependencies.coverageProbe
        ? await dependencies.coverageProbe({ project, output, receipt })
        : await runLlvmCoverage({ project, output, options, source: receipt.source });
    } catch (coverageError) {
      receipt.coverage = { ...(await microsoftCoverageProbe()), llvmFailure: coverageError.message,
        pinnedLlvm: { version: llvmVersion, url: llvmArchiveUrl, bytes: llvmArchiveBytes, sha256: llvmArchiveSha256 } };
    }
    receipt.status = receipt.coverage.status === 'passed' ? 'passed' : 'blocked';
  } catch (error) {
    receipt.status = 'failed';
    receipt.failure = { message: error.message, stack: error.stack };
  }
  try {
    receipt.compilerAfter = await findCompilerIdentity();
    validateCompilerIdentity(receipt.compilerAfter, expectedToolchainLockValue.msvc);
    if (!isDeepStrictEqual(receipt.compiler, receipt.compilerAfter)) {
      throw new Error('MSVC compiler/linker/vcvars identity changed during the N1 run.');
    }
    const sourceAfter = await inventorySources(project);
    const projectInputsAfter = await inventoryProjectBuildInputs(project);
    receipt.projectInputs.after = projectInputsAfter;
    receipt.projectInputs.unchanged = isDeepStrictEqual(receipt.projectInputs.before, projectInputsAfter);
    receipt.source.unchanged = isDeepStrictEqual(
      { ...receipt.source, unchanged: undefined }, { ...sourceAfter, unchanged: undefined });
    if (!receipt.projectInputs.unchanged || !receipt.source.unchanged) {
      throw new Error('Native source or project build-input inventory changed during the N1 run.');
    }
  } catch (error) {
    receipt.status = 'failed';
    if (!receipt.failure) receipt.failure = { message: error.message, stack: error.stack };
    else receipt.inputVerificationFailure = { message: error.message, stack: error.stack };
  }
  receipt.completedAtUtc = new Date().toISOString();
  receipt.git.statusAfter = await gitText(project, ['status', '--short']);
  await writeFile(reportPath, `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'wx' });
  if (receipt.status === 'failed') throw Object.assign(new Error(receipt.failure.message), { reportPath });
  return { status: receipt.status, reportPath, receipt };
}
