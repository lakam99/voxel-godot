import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { mkdir, readFile, realpath, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { join, relative, resolve } from 'node:path';
import { tmpdir } from 'node:os';

export const N4_UNDERGROUND_PROP_RUNNER_ID = 'n4-underground-prop-source-differential';
export const N4_UNDERGROUND_PROP_BUILD_RECEIPT_PATHS = Object.freeze([
  'native/terrain_meshing/build/world_backend/debug/build-manifest.json',
  'native/terrain_meshing/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
  'artifacts/native-world-backend/n4-underground-props-msvc-debug-20260924-3/build-debug.watchdog.json',
  'artifacts/native-world-backend/n4-underground-props-msvc-debug-20260924-3/test-debug.watchdog.json',
  'artifacts/native-world-backend/n4-underground-props-llvm-20260924-4/coverage-report.json',
  'artifacts/native-world-backend/n4-underground-props-msvc-release-20260924-1/build-release.watchdog.json',
  'artifacts/native-world-backend/n4-underground-props-msvc-release-20260924-1/test-release.watchdog.json',
]);

export const N4_UNDERGROUND_PROP_SOURCE_PATHS = Object.freeze([
  'project.godot',
  'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
  'addons/zylann.voxel/voxel.gdextension',
  'tools/run-n4-underground-prop-source-differential.mjs',
  'tools/lib/n4-underground-prop-source-evidence.mjs',
  'tools/lib/voxel-tool-runtime.mjs',
  'tools/lib/godot-process.mjs',
  'tools/run-godot-scene-watchdog.mjs',
  'tools/lib/owned-process.mjs',
  'tools/lib/owned-native-host.mjs',
  'tools/lib/owned-live-clock.mjs',
  'tools/native/OwnedProcessHost.cs',
  'tools/native/OwnedProcessNative.cs',
  'scripts/testing/native_world/N4UndergroundPropSourceProbe.gd',
  'scripts/Main.gd',
  'scripts/MainPropFactory.gd',
  'scripts/MainChunkTerrain.gd',
  'scripts/MainInteractionFlow.gd',
  'scripts/MainPlaytestTools.gd',
  'scripts/MainRuntimeTools.gd',
  'scripts/MainDiscoveryFlow.gd',
  'scripts/MainHudFlow.gd',
  'scripts/MainWorldEntities.gd',
  'scripts/MainCharacterState.gd',
  'scripts/MainGameLoop.gd',
  'scripts/MainSetupScene.gd',
  'scripts/MainSaveState.gd',
  'scripts/MainCore.gd',
  'scripts/MainInterface.gd',
  'scripts/WorldGenerationSystem.gd',
  'scripts/TerrainVolumeService.gd',
  'scripts/world/BiomeRegionField.gd',
  'scripts/world/BuildingTerrainProfile.gd',
  'scripts/world/BuildingGroundMask.gd',
  'scripts/StructureSystem.gd',
  'scripts/world/CitadelTerrainAdmission.gd',
  'scripts/world/CitadelSiteField.gd',
  'scripts/world/CitadelSiteBuildQueue.gd',
  'scripts/world/CitadelSitePreparation.gd',
  'scripts/world/CitadelSiteSurvey.gd',
  'scripts/world/GeneratedSiteProfileStore.gd',
  'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd',
  'scripts/visual/ActiveVisualAssetSnapshot.gd',
  'scripts/world/ActiveRemovedPropsSnapshot.gd',
  'scripts/world/ActiveStructureExclusionChunkSnapshot.gd',
  'scripts/world/ActiveEffectiveTerrainChunkPin.gd',
  'scripts/world/ActiveSurfacePropOwnerBundle.gd',
  'scripts/environment/RockRecipeBuilder.gd',
  'scripts/environment/BiomeEnvironmentCatalog.gd',
  'scripts/environment/BiomeEnvironmentProfile.gd',
  'scripts/environment/TreeRuntimeRequestBuilder.gd',
  'scripts/environment/TreeSpawnService.gd',
  'scripts/environment/TreeEcologySampler.gd',
  'scripts/environment/tree_grammars/MathematicalTreePocRecipeBuilder.gd',
  'scripts/environment/tree_grammars/MathematicalTreePocConiferRecipeBuilder.gd',
  'scripts/environment/tree_grammars/MathematicalTreePocSavannaRecipeBuilder.gd',
  'scripts/environment/tree_grammars/MathematicalTreePocBushyOakRecipeBuilder.gd',
  'scripts/visual/ProceduralTreeVisualFactory.gd',
  'resources/visual/tree_wind_material.gdshader',
  'resources/visual/procedural_tree_branch.gdshader',
  'resources/visual/procedural_tree_foliage.gdshader',
  ...['default', 'ocean', 'beach', 'plains', 'forest', 'taiga', 'snow', 'tundra',
    'alpine', 'savanna', 'desert', 'swamp', 'town']
    .map(name => `resources/visual/biomes/${name}.tres`),
  'scripts/visual/VisualAssetRegistry.gd',
  'assets/visual/generated/visual-manifest.json',
  ...Array.from({ length: 6 }, (_, index) => {
    const suffix = String(index + 1).padStart(2, '0');
    return [`assets/visual/generated/environment/rock_${suffix}.glb`,
      `assets/visual/generated/environment/rock_${suffix}.glb.import`];
  }).flat(),
  'scripts/visual/AnimatedAssetRegistry.gd',
  ...['door_open_close', 'chest_open_close', 'boar_idle_walk', 'deer_idle_walk',
    'hare_idle_walk'].flatMap(name => [`assets/generated/animated/${name}.glb`,
    `assets/generated/animated/${name}.glb.import`]),
  'native/world_backend/source-manifest.json',
  'native/terrain_meshing/SConstruct',
  'native/terrain_meshing/scons_tools/windows.py',
  'native/terrain_meshing/godot-cpp-revision.txt',
  'native/terrain_meshing/terrain_meshing_backend.gdextension.in',
  'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
  'addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll',
]);

const demand = (condition, message) => { if (!condition) throw new Error(message); };
const canonical = value => resolve(value).replaceAll('\\', '/').toLowerCase();
const slash = value => value.replaceAll('\\', '/');
const exists = async path => {
  try { await stat(path); return true; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
};
const hashFile = path => new Promise((resolveHash, reject) => {
  const digest = createHash('sha256');
  const stream = createReadStream(path);
  stream.on('error', reject);
  stream.on('data', chunk => digest.update(chunk));
  stream.on('end', () => resolveHash(digest.digest('hex')));
});

async function extensionInputs(project) {
  const root = join(project, 'native', 'terrain_meshing', 'src');
  const paths = [];
  const visit = async directory => {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const absolute = join(directory, entry.name);
      if (entry.isDirectory()) await visit(absolute);
      else if (entry.isFile() && /\.(?:cpp|h|hpp)$/i.test(entry.name))
        paths.push(slash(relative(project, absolute)));
    }
  };
  await visit(root);
  return paths.sort();
}

export async function expandN4UndergroundPropSourcePaths(project) {
  const manifest = JSON.parse(await readFile(
    join(project, 'native', 'world_backend', 'source-manifest.json'), 'utf8'));
  demand(manifest.schema === 'native-world-backend-source-manifest/v1',
    'Unexpected native source manifest schema');
  const groups = {
    coreSources: ['core/', ['.cpp']], coreHeaders: ['core/', ['.h', '.hpp']],
    testSources: ['tests/', ['.cpp']], testHeaders: ['tests/', ['.h', '.hpp']],
  };
  const declared = [];
  for (const [group, [prefix, extensions]] of Object.entries(groups)) {
    const entries = manifest[group];
    demand(Array.isArray(entries), `Missing native source manifest group: ${group}`);
    for (const entry of entries) {
      demand(typeof entry === 'string' && entry.startsWith(prefix)
        && !entry.includes('\\') && !entry.split('/').some(part => ['', '.', '..'].includes(part))
        && extensions.some(extension => entry.endsWith(extension)),
      `Unsafe native source manifest entry: ${entry}`);
      const path = `native/world_backend/${entry}`;
      demand(await exists(join(project, path)), `Missing native source: ${path}`);
      declared.push(path);
    }
  }
  const result = [...N4_UNDERGROUND_PROP_SOURCE_PATHS, ...declared,
    ...await extensionInputs(project)];
  demand(new Set(result).size === result.length, 'N4 source inventory contains duplicates');
  for (const path of result)
    demand(await exists(join(project, path)), `Missing N4 source input: ${path}`);
  return Object.freeze(result);
}

export async function resolveN4ImportedArtifacts(project, sourcePaths) {
  const descriptors = sourcePaths.filter(path => path.endsWith('.glb.import'));
  demand(descriptors.length === 11, `Expected 11 GLB import descriptors, got ${descriptors.length}`);
  const artifacts = [];
  for (const descriptor of descriptors) {
    const text = await readFile(join(project, descriptor), 'utf8');
    const match = /^path="res:\/\/(\.godot\/imported\/[^"\r\n]+\.scn)"$/m.exec(text);
    demand(match, `Missing exact imported PackedScene path: ${descriptor}`);
    const path = match[1];
    const destination = /^dest_files=\["res:\/\/([^"\r\n]+)"\]$/m.exec(text);
    demand(destination?.[1] === path, `Import destination mismatch: ${descriptor}`);
    const info = await stat(join(project, path)).catch(error => {
      if (error.code === 'ENOENT') throw new Error(`Missing imported PackedScene artifact: ${path}`);
      throw error;
    });
    demand(info.isFile(), `Imported PackedScene is not a file: ${path}`);
    artifacts.push(path);
  }
  demand(new Set(artifacts).size === artifacts.length, 'Imported PackedScene paths are not unique');
  return Object.freeze(artifacts.sort());
}

export function godotCompanionExecutable(executable) {
  return /_console\.exe$/i.test(executable)
    ? executable.replace(/_console\.exe$/i, '.exe') : null;
}

export async function n4GodotRuntimeInventory(executable, options = {}) {
  const versionReader = options.versionReader ?? (path => execFileSync(path, ['--version'], {
    encoding: 'utf8', windowsHide: true, timeout: 15000,
  }).trim());
  const companion = godotCompanionExecutable(executable);
  demand(companion, 'N4 evidence requires the Godot Windows console executable');
  const binaries = {};
  for (const [id, path] of [['console', executable], ['engine', companion]]) {
    const info = await stat(path).catch(error => {
      if (error.code === 'ENOENT') throw new Error(`Missing Godot runtime binary: ${path}`);
      throw error;
    });
    demand(info.isFile(), `Godot runtime binary is not a file: ${path}`);
    binaries[id] = { path: resolve(path), bytes: info.size, sha256: await hashFile(path) };
  }
  const version = String(await versionReader(executable)).trim();
  demand(version.length > 0, 'Godot --version returned no identity');
  return Object.freeze({ version, binaries });
}

export async function n4BuildReceiptInventory(project) {
  const result = {};
  for (const path of N4_UNDERGROUND_PROP_BUILD_RECEIPT_PATHS) {
    const info = await stat(join(project, path)).catch(error => {
      if (error.code === 'ENOENT') throw new Error(`Missing N4 build receipt: ${path}`);
      throw error;
    });
    demand(info.isFile(), `N4 build receipt is not a file: ${path}`);
    result[path] = { bytes: info.size, sha256: await hashFile(join(project, path)) };
  }
  return Object.freeze(result);
}

export function n4GitState(project, options = {}) {
  const git = options.git ?? (args => execFileSync('git', ['-C', project, ...args], {
    encoding: 'utf8', windowsHide: true, maxBuffer: 64 * 1024 * 1024,
  }).trimEnd());
  const head = git(['rev-parse', 'HEAD']).trim();
  const tree = git(['rev-parse', 'HEAD^{tree}']).trim();
  const status = git(['status', '--porcelain=v1', '--untracked-files=all', '--ignored=no']);
  return Object.freeze({ head, tree, status, clean: status.length === 0 });
}

export function assertN4CleanGitState(state, phase) {
  demand(state?.clean === true && state.status === '',
    `N4 ${phase} Git state is not clean: ${state?.status || '<invalid state>'}`);
  demand(/^[0-9a-f]{40}$/i.test(state.head) && /^[0-9a-f]{40}$/i.test(state.tree),
    `N4 ${phase} Git identity is invalid`);
  return state;
}

const powershellProcessIdentity = pid => {
  demand(Number.isSafeInteger(pid) && pid > 0, 'Invalid lease PID');
  const script = `$p=Get-CimInstance Win32_Process -Filter 'ProcessId = ${pid}' -ErrorAction SilentlyContinue; if($null -eq $p){'ABSENT'}else{$p.CreationDate.ToUniversalTime().ToString('o')}`;
  const output = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
    encoding: 'utf8', windowsHide: true, timeout: 10000,
  }).trim();
  return output === 'ABSENT' ? null : output;
};

function assertLeaseChild(root, path) {
  const child = relative(resolve(root), resolve(path));
  demand(child && child !== '..' && !child.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`),
    'Lease path escaped its dedicated root');
}

export async function acquireN4UndergroundPropLease(options) {
  const project = await realpath(options.project);
  const runnerId = options.runnerId ?? N4_UNDERGROUND_PROP_RUNNER_ID;
  const pid = options.pid ?? process.pid;
  const identityForPid = options.identityForPid ?? powershellProcessIdentity;
  const startIdentity = await identityForPid(pid);
  demand(typeof startIdentity === 'string' && startIdentity.length > 0,
    'Could not resolve current runner process start identity');
  const key = createHash('sha256').update(`${canonical(project)}\0${runnerId}`).digest('hex');
  const leaseRoot = resolve(options.leaseRoot ?? join(tmpdir(), 'voxel-biome-world-godot-runner-leases'));
  const leasePath = join(leaseRoot, key);
  const ownerPath = join(leasePath, 'owner.json');
  await mkdir(leaseRoot, { recursive: true });
  assertLeaseChild(leaseRoot, leasePath);
  const owner = Object.freeze({ schema: 'n4-runner-lease/v1', key, runnerId,
    canonicalProject: canonical(project), pid, startIdentity,
    acquiredAtUtc: new Date().toISOString() });
  for (let attempt = 0; attempt < 8; attempt++) {
    try {
      await mkdir(leasePath);
      try { await writeFile(ownerPath, `${JSON.stringify(owner, null, 2)}\n`, { flag: 'wx' }); }
      catch (error) { await rm(leasePath, { recursive: true, force: true }); throw error; }
      let released = false;
      return Object.freeze({ ...owner, leasePath,
        async release() {
          if (released) return;
          const saved = JSON.parse(await readFile(ownerPath, 'utf8'));
          demand(saved.key === key && saved.pid === pid && saved.startIdentity === startIdentity,
            'Lease ownership changed before release');
          const releasing = `${leasePath}.release-${randomUUID()}`;
          assertLeaseChild(leaseRoot, releasing);
          await rename(leasePath, releasing);
          await rm(releasing, { recursive: true, force: true });
          released = true;
        },
      });
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      let current;
      try { current = JSON.parse(await readFile(ownerPath, 'utf8')); }
      catch (readError) {
        throw new Error(`N4 runner lease exists without a valid owner receipt: ${readError.message}`);
      }
      demand(current?.schema === 'n4-runner-lease/v1' && current.key === key
        && Number.isSafeInteger(current.pid) && current.pid > 0
        && typeof current.startIdentity === 'string' && current.startIdentity.length > 0,
      'N4 runner lease owner receipt is invalid');
      const liveIdentity = await identityForPid(current.pid);
      if (liveIdentity === current.startIdentity)
        throw new Error(`N4 runner lease is already held by PID ${current.pid}`);
      const stale = `${leasePath}.stale-${randomUUID()}`;
      assertLeaseChild(leaseRoot, stale);
      try { await rename(leasePath, stale); }
      catch (renameError) { if (renameError.code === 'ENOENT') continue; throw renameError; }
      await rm(stale, { recursive: true, force: true });
    }
  }
  throw new Error('N4 runner lease acquisition retry bound exceeded');
}

export async function withN4UndergroundPropLease(options, launch) {
  const lease = await acquireN4UndergroundPropLease(options);
  try { return await launch(lease); }
  finally { await lease.release(); }
}

const timestamp = (value, field) => {
  demand(typeof value === 'string' && value.length > 0, `Missing watchdog ${field}`);
  const milliseconds = Date.parse(value);
  demand(Number.isFinite(milliseconds), `Invalid watchdog ${field}`);
  return milliseconds;
};

export function n4UndergroundPropWatchdogIdentity(processResult, expected = {}) {
  demand(processResult && typeof processResult === 'object', 'Missing owned-process result');
  const summary = processResult.summary;
  demand(summary && typeof summary === 'object', 'Missing owned-process watchdog summary');
  demand(summary.schema === 'godot-scene-watchdog/v5', 'Unexpected watchdog schema');
  demand(typeof summary.runId === 'string' && /^[0-9a-f]{32}$/.test(summary.runId),
    'Invalid watchdog runId');
  demand(Number.isSafeInteger(summary.rootPid) && summary.rootPid > 0,
    'Invalid watchdog rootPid');
  const launched = timestamp(summary.launchTimeUtc, 'launchTimeUtc');
  const completed = timestamp(summary.completedTimeUtc, 'completedTimeUtc');
  demand(completed >= launched, 'Watchdog completion predates launch');
  demand(summary.ownershipAuthority === 'Windows Job Object membership only',
    'Unexpected watchdog ownershipAuthority');
  demand(summary.cleanupPassed === true && summary.authoritativeZeroProven === true
    && summary.rootExited === true && Array.isArray(summary.finalJobMemberPids)
    && summary.finalJobMemberPids.length === 0,
  'Watchdog did not prove natural zero membership');
  demand(typeof summary.zeroProofSource === 'string' && summary.zeroProofSource.length > 0,
    'Missing watchdog zeroProofSource');
  demand(typeof processResult.summaryPath === 'string' && processResult.summaryPath.length > 0,
    'Missing owned-process summaryPath');
  demand(summary.summaryPath === processResult.summaryPath,
    'Owned-process summaryPath does not match watchdog receipt');
  if (expected.projectPath)
    demand(canonical(summary.projectPath) === canonical(expected.projectPath),
      'Watchdog projectPath does not match the runner worktree');
  if (expected.executable)
    demand(canonical(summary.executable) === canonical(expected.executable)
      && canonical(summary.godotExe) === canonical(expected.executable),
    'Watchdog executable does not match the frozen Godot console');
  if (expected.args)
    demand(JSON.stringify(summary.args) === JSON.stringify(expected.args),
      'Watchdog arguments do not match the exact runner command');
  demand(typeof summary.exactCommandLine === 'string' && summary.exactCommandLine.length > 0,
    'Missing watchdog exactCommandLine');
  return Object.freeze({ schema: summary.schema, runId: summary.runId,
    rootPid: summary.rootPid, launchTimeUtc: summary.launchTimeUtc,
    completedTimeUtc: summary.completedTimeUtc, zeroProofSource: summary.zeroProofSource,
    ownershipAuthority: summary.ownershipAuthority, projectPath: summary.projectPath,
    executable: summary.executable, args: summary.args,
    exactCommandLine: summary.exactCommandLine, summaryPath: processResult.summaryPath });
}
